import Testing
import Foundation
@testable import AlfredHelpCore

/// Sammelt Werte aus nebenläufigen Aufgaben ein.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ item: String) { lock.withLock { items.append(item) } }
    func all() -> [String] { lock.withLock { items } }
}

@Suite("Serielle Warteschlange")
struct SerialQueueTests {

    @Test("Arbeit läuft in der Reihenfolge des Einstellens")
    func keepsOrder() async {
        let queue = SerialQueue()
        let box = Box()
        for name in ["A", "B", "C"] {
            await queue.enqueue {
                try? await Task.sleep(for: .milliseconds(20))
                box.add(name)
            }
        }
        await queue.drain()
        #expect(box.all() == ["A", "B", "C"])
    }

    @Test("cancelAll stoppt auch die laufende und die wartende Arbeit")
    func cancelAllStopsEverything() async {
        // Genau das war beim „Gespräch zurücksetzen“ kaputt: cancelAll brach
        // nur die zuletzt eingestellte Aufgabe ab. Die laufende Übersetzung
        // lief zu Ende, die nächste startete danach noch – und weil `tail`
        // dabei auf nil ging, liefen sie zusätzlich parallel zu den
        // Übersetzungen des neuen Gesprächs auf derselben GPU.
        let queue = SerialQueue()
        let box = Box()

        await queue.enqueue {
            box.add("A-start")
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { box.add("A-abgebrochen"); return }
            box.add("A-fertig")
        }
        await queue.enqueue { box.add("B-gelaufen") }
        await queue.enqueue { box.add("C-gelaufen") }

        try? await Task.sleep(for: .milliseconds(80))   // A läuft jetzt
        await queue.cancelAll()
        try? await Task.sleep(for: .milliseconds(700))  // reichlich Zeit für B und C

        let seen = box.all()
        #expect(seen.contains("A-start"))
        #expect(!seen.contains("A-fertig"), "Laufende Arbeit wurde nicht abgebrochen")
        #expect(!seen.contains("B-gelaufen"), "Wartende Arbeit lief trotz cancelAll")
        #expect(!seen.contains("C-gelaufen"), "Wartende Arbeit lief trotz cancelAll")
    }

    @Test("Nach cancelAll nimmt die Warteschlange normal wieder auf")
    func resumesAfterCancel() async {
        let queue = SerialQueue()
        let box = Box()
        await queue.enqueue { try? await Task.sleep(for: .milliseconds(200)) }
        await queue.cancelAll()
        await queue.enqueue { box.add("neu") }
        await queue.drain()
        #expect(box.all() == ["neu"])
    }
}

@Suite("Gespräch zurücksetzen")
struct ConversationResetTests {

    private func makePipeline() -> AssistantPipeline {
        var settings = AppSettings()
        settings.translationEnabled = false
        settings.autoAnswerEnabled = false
        settings.qualityModel = "testmodell"
        settings.fastModel = ""
        return AssistantPipeline(client: OllamaClient(), settings: settings)
    }

    @Test("Nach dem Zurücksetzen läuft die Transkription weiter")
    func keepsTranscribingAfterReset() async {
        let pipeline = makePipeline()
        let box = Box()
        await pipeline.setEmitter { event, _ in
            if case .utteranceAdded(let utterance) = event { box.add(utterance.original) }
        }

        await pipeline.ingest(Utterance(source: .system, original: "vorher", startSeconds: 0, endSeconds: 1))
        await pipeline.reset()
        await pipeline.ingest(Utterance(source: .system, original: "nachher", startSeconds: 0, endSeconds: 1))
        await pipeline.ingest(Utterance(source: .system, original: "und weiter", startSeconds: 0, endSeconds: 1))

        #expect(box.all() == ["vorher", "nachher", "und weiter"])
    }

    @Test("Das Gedächtnis behält nur, was nach dem Zurücksetzen kam")
    func memoryStartsOver() async {
        let pipeline = makePipeline()
        await pipeline.ingest(Utterance(source: .system, original: "altes Thema", startSeconds: 0, endSeconds: 1))
        await pipeline.reset()
        await pipeline.ingest(Utterance(source: .system, original: "neues Thema", startSeconds: 0, endSeconds: 1))

        let transcript = await pipeline.transcript()
        #expect(transcript.map(\.original) == ["neues Thema"])
    }

    @Test("Eine angeklickte Äußerung nach dem Zurücksetzen bleibt beantwortbar")
    func manualAnswerWorksAfterReset() async {
        let pipeline = makePipeline()
        let box = Box()
        await pipeline.setEmitter { event, _ in
            if case .answerStarted(let card) = event { box.add("antwort:\(card.question)") }
        }
        await pipeline.reset()
        let utterance = Utterance(
            source: .system, original: "Wie lange dauert das", startSeconds: 0, endSeconds: 1
        )
        await pipeline.ingest(utterance)
        await pipeline.answer(utteranceID: utterance.id)

        #expect(box.all() == ["antwort:Wie lange dauert das"])
    }

    @Test("Eine vor dem Reset geplante Übersetzung bleibt in der alten Sitzung")
    func resetSuppressesScheduledTranslation() async {
        TranslationResetTransport.reset()

        var settings = AppSettings()
        settings.translationEnabled = true
        settings.autoAnswerEnabled = false
        settings.fastModel = "testmodell"
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [TranslationResetTransport.self]
        )
        let pipeline = AssistantPipeline(client: client, settings: settings)
        let box = Box()
        await pipeline.setEmitter { event, _ in
            if case .translation = event { box.add("translation") }
        }

        await pipeline.ingest(Utterance(
            source: .system, original: "old utterance", startSeconds: 0, endSeconds: 1
        ))
        await pipeline.reset()
        try? await Task.sleep(for: .milliseconds(450))

        #expect(box.all().isEmpty)
        #expect(await pipeline.transcript().isEmpty)
    }
}

@Suite("Summary-Reset-Rennen", .serialized)
struct SummaryResetRaceTests {

    @Test("Cleanup einer alten Summary löscht nicht den neuen Task")
    func oldCleanupCannotClearNewTask() async {
        DelayedPipelineTransport.configure(delays: [
            .seconds(2), .seconds(2), .seconds(2)
        ])
        defer { DelayedPipelineTransport.reset() }
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [DelayedPipelineTransport.self]
        )
        let memory = ConversationMemory(client: client)

        await memory.add(Utterance(
            source: .system, original: "alte Sitzung", startSeconds: 0, endSeconds: 1
        ))
        await memory.summarizeIfNeeded(model: "testmodell", every: 1, keepVerbatim: 0) { _ in }
        await waitForRequests(1)

        await memory.reset()
        await memory.add(Utterance(
            source: .system, original: "neue Sitzung", startSeconds: 0, endSeconds: 1
        ))
        await memory.summarizeIfNeeded(model: "testmodell", every: 1, keepVerbatim: 0) { _ in }
        await waitForRequests(2)

        // Give the cancelled old task ample opportunity to execute its cleanup.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await memory.isSummarizing)

        await memory.add(Utterance(
            source: .system, original: "noch ein Satz", startSeconds: 1, endSeconds: 2
        ))
        await memory.summarizeIfNeeded(model: "testmodell", every: 1, keepVerbatim: 0) { _ in }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(DelayedPipelineTransport.requestCount == 2)

        await memory.reset()
        #expect(!(await memory.isSummarizing))
    }

    private func waitForRequests(_ count: Int) async {
        for _ in 0..<100 where DelayedPipelineTransport.requestCount < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Delays loopback responses so cancellation and actor cleanup can be ordered
/// deterministically in the reset regression tests.
private final class DelayedPipelineTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var delays: [Duration] = []
    nonisolated(unsafe) private static var started = 0

    static var requestCount: Int { lock.withLock { started } }

    static func configure(delays newDelays: [Duration]) {
        lock.withLock {
            delays = newDelays
            started = 0
        }
    }

    static func reset() {
        lock.withLock {
            delays = []
            started = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let delay = Self.lock.withLock { () -> Duration in
            let index = Self.started
            Self.started += 1
            return index < Self.delays.count ? Self.delays[index] : .milliseconds(10)
        }
        let transport = DelayedTransportReference(self)
        Task { [transport] in
            try? await Task.sleep(for: delay)
            let owner = transport.value
            guard let client = owner.client else { return }
            let response = HTTPURLResponse(
                url: owner.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            let summary = #"{\"zusammenfassung\":\"ok\",\"kernpunkte\":[],\"offene_punkte\":[]}"#
            let line = #"{\"message\":{\"content\":"#
                + String(reflecting: summary)
                + #"},\"done\":true}"#
            client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(owner, didLoad: Data((line + "\n").utf8))
            client.urlProtocolDidFinishLoading(owner)
        }
    }

    override func stopLoading() {}
}

private final class DelayedTransportReference: @unchecked Sendable {
    let value: DelayedPipelineTransport
    init(_ value: DelayedPipelineTransport) { self.value = value }
}

private final class TranslationResetTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func reset() {}

    override func startLoading() {
        let transport = TranslationTransportReference(self)
        Task { [transport] in
            try? await Task.sleep(for: .milliseconds(250))
            let owner = transport.value
            guard let client = owner.client else { return }
            let response = HTTPURLResponse(
                url: owner.request.url!, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"]
            )!
            let line = #"{\"message\":{\"content\":\"Hallo\"},\"done\":true}"#
            client.urlProtocol(owner, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(owner, didLoad: Data((line + "\n").utf8))
            client.urlProtocolDidFinishLoading(owner)
        }
    }

    override func stopLoading() {}
}

private final class TranslationTransportReference: @unchecked Sendable {
    let value: TranslationResetTransport
    init(_ value: TranslationResetTransport) { self.value = value }
}

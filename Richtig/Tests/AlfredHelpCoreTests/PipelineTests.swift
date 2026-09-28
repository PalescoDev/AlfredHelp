import Testing
import Foundation
@testable import AlfredHelpCore

@Suite("Utterance-Zusammenbau")
struct AssemblerTests {

    private func event(_ text: String, at time: Double = 0, capturedAt: Double = 0) -> TranscriptEvent {
        TranscriptEvent(
            source: .system,
            text: text,
            isFinal: true,
            startSeconds: time,
            endSeconds: time + 1,
            confidence: 0.9,
            capturedAt: capturedAt
        )
    }

    @Test("Gibt vollständige Sätze sofort heraus")
    func emitsCompleteSentences() {
        let assembler = UtteranceAssembler(source: .system)
        let produced = assembler.append(event("How long does the reindex take? I mean roughly"))
        #expect(produced.count == 1)
        #expect(produced.first?.original == "How long does the reindex take?")
        #expect(assembler.pendingText == "I mean roughly")
    }

    @Test("Setzt Teilergebnisse über mehrere Events zusammen")
    func joinsAcrossEvents() {
        let assembler = UtteranceAssembler(source: .system)
        #expect(assembler.append(event("Der Rollout ist")).isEmpty)
        let produced = assembler.append(event("für März geplant."))
        #expect(produced.count == 1)
        #expect(produced.first?.original == "Der Rollout ist für März geplant.")
    }

    @Test("Zwischenergebnisse werden ignoriert")
    func ignoresVolatile() {
        let assembler = UtteranceAssembler(source: .system)
        let volatileEvent = TranscriptEvent(
            source: .system, text: "halb fertig", isFinal: false,
            startSeconds: 0, endSeconds: 1, confidence: nil
        )
        #expect(assembler.append(volatileEvent).isEmpty)
        #expect(assembler.pendingText.isEmpty)
    }

    @Test("Gibt nach Sprechpause auch ohne Satzzeichen heraus")
    func flushesOnSilence() {
        var options = UtteranceAssembler.Options()
        options.silenceFlushSeconds = 0.5
        let assembler = UtteranceAssembler(source: .system, options: options)
        _ = assembler.append(event("kein Satzzeichen hier", capturedAt: 100))

        #expect(assembler.flushIfIdle(now: 100.2) == nil)
        let flushed = assembler.flushIfIdle(now: 100.8)
        #expect(flushed?.original == "kein Satzzeichen hier")
        #expect(assembler.pendingText.isEmpty)
    }

    @Test("Sehr lange Fragmente werden nicht endlos gepuffert")
    func flushesOnLength() {
        var options = UtteranceAssembler.Options()
        options.maxPendingCharacters = 40
        let assembler = UtteranceAssembler(source: .system, options: options)
        let produced = assembler.append(
            event("das ist ein sehr langer fragmentierter Redefluss ohne jedes Satzzeichen")
        )
        #expect(produced.count == 1)
        #expect(assembler.pendingText.isEmpty)
    }
}

@Suite("JSON-Auswertung")
struct JSONTests {

    @Test("Findet das Objekt in umgebendem Text")
    func extractsEmbedded() {
        let data = ConversationMemory.extractJSON(from: "Hier: {\"frage\": true} – fertig")
        #expect(data != nil)
        let object = (try? JSONSerialization.jsonObject(with: data!)) as? [String: Any]
        #expect((object?["frage"] as? Bool) == true)
    }

    @Test("Verschachtelte Objekte werden vollständig gelesen")
    func extractsNested() {
        let text = "{\"a\": {\"b\": 1}, \"c\": \"}\"}"
        let data = ConversationMemory.extractJSON(from: text)
        #expect(data != nil)
        let object = (try? JSONSerialization.jsonObject(with: data!)) as? [String: Any]
        #expect((object?["c"] as? String) == "}")
    }

    @Test("Zusammenfassung wird korrekt gelesen")
    func parsesSummary() {
        let snapshot = ConversationMemory.parseSummary("""
        {"zusammenfassung":"Es geht um die Migration.",
         "kernpunkte":["Rollout im März","Freigabe fehlt"],
         "offene_punkte":["Wer macht die Abnahme?"]}
        """)
        #expect(snapshot?.summary == "Es geht um die Migration.")
        #expect(snapshot?.keyPoints.count == 2)
        #expect(snapshot?.openPoints == ["Wer macht die Abnahme?"])
        #expect(ConversationMemory.parseSummary(
            #"{"zusammenfassung":"Teilantwort","kernpunkte":[]}"#
        ) == nil)
    }

    @Test("Status wird im Teilstrom am ersten Buchstaben erkannt")
    func readsEarlyStatus() {
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\": \"") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\": \"f") == true)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"frage\",\"eig") == true)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\": \"k") == false)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"unvoll") == false)
        #expect(QuestionClassifier.earlyDecision(in: "{\"eigen") == nil)
    }

    @Test("Vollständige Klassifikator-Antwort wird geparst")
    func parsesVerdict() {
        #expect(QuestionClassifier.parse(
            "{\"status\":\"frage\",\"eigenstaendig\":\"Warum wurde das so entschieden?\"}"
        ) == .question(standalone: "Warum wurde das so entschieden?"))
        #expect(QuestionClassifier.parse(
            "{\"status\":\"keine_frage\",\"eigenstaendig\":\"\"}"
        ) == .notQuestion)
        #expect(QuestionClassifier.parse(
            "{\"status\":\"unvollstaendig\",\"eigenstaendig\":\"\"}"
        ) == .incomplete)
    }
}

@Suite("Manuelle Antwort auf angeklickte Äußerung")
struct ManualAnswerTests {

    /// Sammelt Pipeline-Ereignisse threadsicher ein.
    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [PipelineEvent] = []
        func add(_ event: PipelineEvent) { lock.withLock { events.append(event) } }
        func all() -> [PipelineEvent] { lock.withLock { events } }
    }

    private func makePipeline(qualityModel: String) async -> (AssistantPipeline, EventBox) {
        var settings = AppSettings()
        settings.autoAnswerEnabled = false      // die Erkennung hat nichts bemerkt
        settings.translationEnabled = false
        settings.qualityModel = qualityModel
        settings.fastModel = ""
        let pipeline = AssistantPipeline(client: OllamaClient(), settings: settings)
        let box = EventBox()
        await pipeline.setEmitter { event, _ in box.add(event) }
        return (pipeline, box)
    }

    @Test("Klick startet die Antwort ohne Frageerkennung")
    func clickStartsAnswer() async {
        // Ein erfundener Modellname: entscheidend ist, dass die Antwortkarte
        // sofort erscheint – nicht, ob die Generierung danach gelingt.
        let (pipeline, box) = await makePipeline(qualityModel: "testmodell")
        let utterance = Utterance(
            source: .system,
            original: "Der Rollout ist übrigens erst am Freitag.",
            startSeconds: 0, endSeconds: 1
        )
        await pipeline.ingest(utterance)
        await pipeline.answer(utteranceID: utterance.id)

        let started = box.all().compactMap { event -> AnswerCard? in
            if case .answerStarted(let card) = event { return card }
            return nil
        }
        #expect(started.count == 1)
        #expect(started.first?.id == utterance.id)
        #expect(started.first?.question == utterance.original)
        #expect(started.first?.wasManuallyTriggered == true)
    }

    @Test("Ohne Antwortmodell gibt es eine klare Fehlermeldung")
    func missingModelFailsLoudly() async {
        let (pipeline, box) = await makePipeline(qualityModel: "")
        let utterance = Utterance(
            source: .system, original: "Passt das für euch",
            startSeconds: 0, endSeconds: 1
        )
        await pipeline.ingest(utterance)
        await pipeline.answer(utteranceID: utterance.id)

        let sawFailure = box.all().contains {
            if case .failure = $0 { return true } else { return false }
        }
        #expect(sawFailure)
    }

    @Test("Wiederholen bewahrt die angezeigte kontextuelle Frage")
    func retryKeepsDisplayedQuestion() async {
        let (pipeline, box) = await makePipeline(qualityModel: "testmodell")
        let utterance = Utterance(
            source: .system,
            original: "Und warum?",
            startSeconds: 0, endSeconds: 1
        )
        await pipeline.ingest(utterance)
        await pipeline.answer(
            question: "Warum wurde der Rollout auf Freitag verschoben?",
            utteranceID: utterance.id
        )

        let started = box.all().compactMap { event -> AnswerCard? in
            if case .answerStarted(let card) = event { return card }
            return nil
        }
        #expect(started.first?.question == "Warum wurde der Rollout auf Freitag verschoben?")
        #expect(started.first?.wasManuallyTriggered == true)
    }

    @Test("Unbekannte Äußerung wird benannt statt ignoriert")
    func unknownUtteranceIsReported() async {
        let (pipeline, box) = await makePipeline(qualityModel: "testmodell")
        await pipeline.answer(utteranceID: UUID())

        let sawNotice = box.all().contains {
            if case .notice = $0 { return true } else { return false }
        }
        #expect(sawNotice)
        #expect(!box.all().contains {
            if case .answerStarted = $0 { return true } else { return false }
        })
    }
}

@Suite("Antwort-Pipeline – Fehler und Verfeinerung", .serialized)
struct AnswerPipelineBehaviorTests {

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [PipelineEvent] = []
        func add(_ event: PipelineEvent) { lock.withLock { events.append(event) } }
        func startedCount() -> Int {
            lock.withLock { events.filter { if case .answerStarted = $0 { true } else { false } }.count }
        }
        func hasFailedAnswer() -> Bool {
            lock.withLock {
                events.contains {
                    if case .answerFinished(let card) = $0 { card.errorMessage != nil } else { false }
                }
            }
        }
    }

    private func client() -> OllamaClient {
        OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [PipelineBehaviorTransport.self]
        )
    }

    private func settings(autoAnswer: Bool) -> AppSettings {
        var settings = AppSettings()
        settings.autoAnswerEnabled = autoAnswer
        settings.translationEnabled = false
        settings.qualityModel = "quality-test"
        settings.fastModel = ""
        return settings
    }

    private func utterance(_ text: String) -> Utterance {
        Utterance(
            source: .system,
            original: text,
            startSeconds: 0,
            endSeconds: 1,
            capturedAt: Clock.now()
        )
    }

    private func eventually(
        _ predicate: @escaping @Sendable () -> Bool,
        attempts: Int = 100
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("Fehlgeschlagene Antwort sperrt eine erneut gestellte Frage nicht")
    func failedAnswerDoesNotBecomeDuplicate() async {
        PipelineBehaviorTransport.configure(.failure)
        defer { PipelineBehaviorTransport.reset() }
        let pipeline = AssistantPipeline(client: client(), settings: settings(autoAnswer: true))
        let box = EventBox()
        await pipeline.setEmitter { event, _ in box.add(event) }

        await pipeline.ingest(utterance("Wie lange dauert die Migration?"))
        #expect(await eventually { box.hasFailedAnswer() })
        await pipeline.ingest(utterance("Wie lange dauert die Migration?"))
        #expect(await eventually { box.startedCount() == 2 })
        await pipeline.reset()
    }

    @Test("Kontextualisierte Frage ersetzt den laufenden Ollama-Prompt")
    func refinedQuestionReachesAnswerPrompt() async {
        PipelineBehaviorTransport.configure(.hold)
        defer { PipelineBehaviorTransport.reset() }
        let pipeline = AssistantPipeline(client: client(), settings: settings(autoAnswer: false))
        let original = utterance("Und wie lange dauert das?")
        await pipeline.ingest(original)
        await pipeline.answer(utteranceID: original.id)
        #expect(await eventually { !PipelineBehaviorTransport.requestBodies().isEmpty })

        let standalone = "Wie lange dauert die Migration des Kundenportals?"
        await pipeline.refineQuestionText(for: original.id, to: standalone)
        #expect(await eventually {
            PipelineBehaviorTransport.requestBodies().contains { body in
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let messages = object["messages"] as? [[String: Any]] else { return false }
                return messages.contains { ($0["content"] as? String)?.contains(standalone) == true }
            }
        })
        await pipeline.reset()
    }

    @Test("Antwortanfrage erzwingt das strukturierte Schema")
    func answerRequestUsesSchema() async {
        PipelineBehaviorTransport.configure(.hold)
        defer { PipelineBehaviorTransport.reset() }
        let pipeline = AssistantPipeline(client: client(), settings: settings(autoAnswer: false))
        let original = utterance("Was ist der aktuelle Stand?")
        await pipeline.ingest(original)
        await pipeline.answer(utteranceID: original.id)
        #expect(await eventually {
            PipelineBehaviorTransport.requestBodies().contains { body in
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let format = object["format"] as? [String: Any],
                      let properties = format["properties"] as? [String: Any] else { return false }
                return properties["spoken"] != nil
                    && properties["details"] != nil
                    && properties["confidence"] != nil
                    && properties["missingContext"] != nil
            }
        })
        await pipeline.reset()
    }
}

/// Captures requests for the actor-level behavior tests. In hold mode the HTTP
/// stream deliberately remains open until cancellation, making the refinement
/// race deterministic without sleeping inside production code.
final class PipelineBehaviorTransport: URLProtocol, @unchecked Sendable {
    enum Mode { case failure, hold }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode: Mode = .failure
    nonisolated(unsafe) private static var bodies: [Data] = []

    static func configure(_ mode: Mode) {
        lock.withLock {
            self.mode = mode
            bodies = []
        }
    }

    static func reset() {
        lock.withLock {
            mode = .failure
            bodies = []
        }
    }

    static func requestBodies() -> [Data] { lock.withLock { bodies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)
        let current = Self.lock.withLock { () -> Mode in
            if let body { Self.bodies.append(body) }
            return Self.mode
        }
        let status: Int
        switch current {
        case .failure: status = 500
        case .hold: status = 200
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if case .failure = current {
            client?.urlProtocol(self, didLoad: Data("generation failed".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result.isEmpty ? nil : result
    }
}

@Suite("Gesprächsgedächtnis")
struct MemoryTests {

    private func utterance(_ text: String, source: AudioSourceKind = .system) -> Utterance {
        Utterance(source: source, original: text, startSeconds: 0, endSeconds: 1)
    }

    @Test("Kürzt den Verlauf auf das Token-Budget")
    func respectsBudget() async {
        let memory = ConversationMemory(client: OllamaClient())
        for index in 0..<20 {
            await memory.add(utterance("Wortmeldung Nummer \(index) mit etwas Text dahinter"))
        }
        let short = await memory.recentTranscript(turns: 20, tokenBudget: 40)
        let long = await memory.recentTranscript(turns: 20, tokenBudget: 4000)
        #expect(short.count < long.count)
        #expect(short.contains("Nummer 19"))
    }

    @Test("Übersetzungskontext bleibt kurz")
    func translationContextIsBounded() async {
        let memory = ConversationMemory(client: OllamaClient())
        for index in 0..<10 {
            await memory.add(utterance(String(repeating: "x", count: 120) + "\(index)"))
        }
        let context = await memory.translationContext(maxCharacters: 300)
        #expect(context.count <= 300)
    }

    @Test("Promptdarstellung enthält alle Abschnitte")
    func rendersPrompt() {
        var snapshot = MemorySnapshot()
        snapshot.summary = "Migration des Kundenportals."
        snapshot.keyPoints = ["Rollout im März"]
        snapshot.openPoints = ["Freigabe der Rechtsabteilung"]
        let text = snapshot.promptText
        #expect(text.contains("Migration"))
        #expect(text.contains("Kernpunkte:"))
        #expect(text.contains("Offen:"))
    }
}

import Testing
import Foundation
@testable import AlfredHelpCore

/// Das Auslegen der Antwort ist die einzige Stelle, an der die App fremde Daten
/// interpretiert. Geprüft wurde sie bisher nur, indem jemand ein echtes Ollama
/// laufen ließ – also nirgends automatisch. Hier steht stattdessen ein
/// vorgeschobener Transport, der die NDJSON-Zeilen liefert.
@Suite("Ollama-Antwortstrom", .serialized)
struct OllamaStreamTests {

    private func client() -> OllamaClient {
        OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [StubTransport.self]
        )
    }

    private func collect(_ lines: [String], status: Int = 200) async throws -> [StreamChunk] {
        StubTransport.set(body: lines.joined(separator: "\n"), status: status)
        defer { StubTransport.reset() }
        var chunks: [StreamChunk] = []
        for try await chunk in client().chatStream(model: "test", messages: [.user("hallo")]) {
            chunks.append(chunk)
        }
        return chunks
    }

    @Test("Inhalt wird Zeile für Zeile durchgereicht")
    func yieldsContentPerLine() async throws {
        let chunks = try await collect([
            #"{"message":{"content":"Vier "},"done":false}"#,
            #"{"message":{"content":"Stunden."},"done":false}"#,
            #"{"message":{"content":""},"done":true}"#
        ])
        #expect(chunks.map(\.text).joined() == "Vier Stunden.")
        #expect(chunks.last?.isDone == true)
    }

    @Test("Die alte Feldform `response` wird ebenso gelesen")
    func readsLegacyResponseField() async throws {
        let chunks = try await collect([
            #"{"response":"Vier","done":false}"#,
            #"{"response":" Stunden.","done":true}"#
        ])
        #expect(chunks.map(\.text).joined() == "Vier Stunden.")
    }

    @Test("Getrennt ausgewiesenes Nachdenken landet nicht im Antworttext")
    func keepsThinkingSeparate() async throws {
        let chunks = try await collect([
            #"{"message":{"content":"","thinking":"Er fragt nach der Dauer."},"done":false}"#,
            #"{"message":{"content":"Vier Stunden."},"done":true}"#
        ])
        #expect(chunks.map(\.text).joined() == "Vier Stunden.")
        #expect(chunks.first?.thinking == "Er fragt nach der Dauer.")
    }

    @Test("Kennzahlen kommen mit dem Abschluss")
    func readsMetricsOnDone() async throws {
        let chunks = try await collect([
            #"{"message":{"content":"Kurz."},"done":false}"#,
            #"{"message":{"content":""},"done":true,"prompt_eval_count":128,"eval_count":42,"#
                + #""eval_duration":2000000000,"total_duration":2500000000}"#
        ])
        let metrics = try #require(chunks.last?.metrics)
        #expect(metrics.promptTokens == 128)
        #expect(metrics.completionTokens == 42)
        // 42 Token in 2 s.
        #expect(abs(metrics.tokensPerSecond - 21) < 0.5)
    }

    @Test("Ein Fehlerfeld im Strom wird zum Fehler, nicht zu Text")
    func errorFieldThrows() async throws {
        await #expect(throws: OllamaError.self) {
            _ = try await collect([
                #"{"message":{"content":"Vier"},"done":false}"#,
                #"{"error":"model 'test' not found"}"#
            ])
        }
    }

    @Test("Kaputte Zeilen werden übersprungen statt zu scheitern")
    func skipsUndecodableLines() async throws {
        let chunks = try await collect([
            #"{"message":{"content":"Vier "},"done":false}"#,
            "das ist kein JSON",
            #"{"message":{"content":"Stunden."},"done":true}"#
        ])
        #expect(chunks.map(\.text).joined() == "Vier Stunden.")
    }

    @Test("HTTP 500 wird gemeldet, samt Text")
    func reportsHTTPFailure() async throws {
        await #expect(throws: OllamaError.self) {
            _ = try await collect(["etwas ist schiefgegangen"], status: 500)
        }
    }

    @Test("Ein Modell-Pull ist erst mit dem Status success vollständig")
    func pullRequiresSuccessStatus() async throws {
        StubTransport.set(body: [
            #"{"status":"pulling manifest"}"#,
            #"{"status":"success"}"#
        ].joined(separator: "\n"))
        defer { StubTransport.reset() }

        var statuses: [String] = []
        for try await progress in client().pull(model: "test") {
            statuses.append(progress.status)
        }
        #expect(statuses == ["pulling manifest", "success"])
    }

    @Test("Ein sauber beendeter Strom ohne success gilt als unvollständiger Pull")
    func incompletePullThrows() async {
        StubTransport.set(body: #"{"status":"pulling manifest"}"#)
        defer { StubTransport.reset() }

        do {
            for try await _ in client().pull(model: "test") {}
            Issue.record("unvollständiger Pull wurde fälschlich als Erfolg beendet")
        } catch let error as OllamaPullError {
            #expect(error == .incomplete("test"))
        } catch {
            Issue.record("unerwarteter Fehler: \(error)")
        }
    }

    @Test("Ein nicht erreichbarer Dienst wird als solcher gemeldet")
    func mapsConnectionRefused() async throws {
        StubTransport.set(failure: URLError(.cannotConnectToHost))
        defer { StubTransport.reset() }

        var thrown: Error?
        do {
            for try await _ in client().chatStream(model: "test", messages: [.user("hallo")]) {}
        } catch {
            thrown = error
        }
        guard case .serverUnreachable? = thrown as? OllamaError else {
            Issue.record("erwartet: serverUnreachable, erhalten: \(String(describing: thrown))")
            return
        }
    }

    @Test("Abgerissener Keine-Frage-Strom bewahrt den eindeutigen Status")
    func classifierPreservesRecognizableNegativeVerdict() async {
        StubTransport.set(body: #"{"message":{"content":"{\"status\":\"kei"},"done":true}"#)
        defer { StubTransport.reset() }

        let verdict = await QuestionClassifier.classify(
            client: client(),
            model: "test",
            context: "",
            utterance: "Das wäre gut."
        )
        #expect(verdict == .notQuestion)
    }
}

/// Vorgeschobener Transport. Antwortet mit dem, was zuvor hinterlegt wurde.
final class StubTransport: URLProtocol, @unchecked Sendable {

    private struct Response {
        var body = ""
        var status = 200
        var failure: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Response()

    static func set(body: String, status: Int = 200) {
        lock.withLock { response = Response(body: body, status: status, failure: nil) }
    }

    static func set(failure: URLError) {
        lock.withLock { response = Response(body: "", status: 200, failure: failure) }
    }

    static func reset() {
        lock.withLock { response = Response() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let current = Self.lock.withLock { Self.response }

        if let failure = current.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: current.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/x-ndjson"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(current.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

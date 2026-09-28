import Testing
import Foundation
@testable import AlfredHelpCore

@Suite("Gesprächsprotokolle", .serialized)
struct SessionArchiveTests {

    private func utterance(_ text: String, at date: Date) -> Utterance {
        Utterance(
            source: .system, original: text,
            startSeconds: 0, endSeconds: 1, createdAt: date
        )
    }

    /// Zwei Sitzungen in derselben Minute dürfen einander nicht überschreiben.
    ///
    /// Der Dateiname trug nur Datum, Stunde und Minute, und geschrieben wurde
    /// atomar – zwei kurze Gespräche hintereinander bedeuteten damit, dass das
    /// erste Protokoll stillschweigend verschwand.
    @Test("Zwei Protokolle derselben Minute bleiben beide erhalten")
    func doesNotOverwriteWithinSameMinute() throws {
        let stamp = Date(timeIntervalSince1970: 1_754_900_000)
        let before = Set(SessionArchive.listSessions())

        guard let first = SessionArchive.save(
            utterances: [utterance("erstes Gespräch", at: stamp)],
            memory: MemorySnapshot(), sourceLanguage: "en-US"
        ) else {
            Issue.record("Erstes Protokoll wurde nicht geschrieben")
            return
        }
        guard let second = SessionArchive.save(
            utterances: [utterance("zweites Gespräch", at: stamp)],
            memory: MemorySnapshot(), sourceLanguage: "en-US"
        ) else {
            Issue.record("Zweites Protokoll wurde nicht geschrieben")
            return
        }
        defer {
            for url in Set(SessionArchive.listSessions()).subtracting(before) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(first != second, "Beide Sitzungen bekamen denselben Dateinamen")

        // Und das Entscheidende: der Inhalt der ersten steht noch da.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let firstRecord = try decoder.decode(
            SessionArchive.Record.self, from: Data(contentsOf: first)
        )
        let secondRecord = try decoder.decode(
            SessionArchive.Record.self, from: Data(contentsOf: second)
        )
        #expect(firstRecord.entries.first?.original == "erstes Gespräch")
        #expect(secondRecord.entries.first?.original == "zweites Gespräch")
    }

    /// Der Dateiname muss maschinenlesbar bleiben, egal welchen Kalender der
    /// Nutzer eingestellt hat. Ohne festes Locale liefert `yyyy` unter einem
    /// japanischen oder buddhistischen Kalender ein völlig anderes Jahr.
    @Test("Der Zeitstempel im Dateinamen ist gregorianisch")
    func fileNameUsesGregorianCalendar() throws {
        let stamp = Date(timeIntervalSince1970: 1_754_900_000)   // 2025-08-11
        let before = Set(SessionArchive.listSessions())

        guard let url = SessionArchive.save(
            utterances: [utterance("Test", at: stamp)],
            memory: MemorySnapshot(), sourceLanguage: "en-US"
        ) else {
            Issue.record("Protokoll wurde nicht geschrieben")
            return
        }
        defer {
            for extra in Set(SessionArchive.listSessions()).subtracting(before) {
                try? FileManager.default.removeItem(at: extra)
            }
        }

        let name = url.lastPathComponent
        #expect(name.contains("2025-08-11"), "Unerwarteter Zeitstempel: \(name)")
    }

    @Test("Ohne Äußerungen wird nichts geschrieben")
    func writesNothingWhenEmpty() {
        #expect(SessionArchive.save(
            utterances: [], memory: MemorySnapshot(), sourceLanguage: "en-US"
        ) == nil)
    }
}

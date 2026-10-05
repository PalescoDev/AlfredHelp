import Foundation

/// Writes finished sessions to disk – locally, in the app's own support folder,
/// and only when the user leaves the option enabled.
public struct SessionArchive: Sendable {

    public struct Entry: Codable, Sendable {
        public let speaker: String
        public let original: String
        public let german: String?
        public let time: Date
    }

    public struct Record: Codable, Sendable {
        /// Wasserzeichen im Dateikopf – jedes exportierte Protokoll trägt es.
        public var erstelltMit: String = Branding.signature
        public let startedAt: Date
        public let endedAt: Date
        public let sourceLanguage: String
        public let entries: [Entry]
        public let summary: String
        public let keyPoints: [String]
        public let openPoints: [String]
    }

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(Branding.appName)/Protokolle", isDirectory: true)
    }

    /// Returns the file it wrote, or `nil` when there was nothing worth saving.
    @discardableResult
    public static func save(
        utterances: [Utterance],
        memory: MemorySnapshot,
        sourceLanguage: String
    ) -> URL? {
        guard !utterances.isEmpty else { return nil }

        let record = Record(
            erstelltMit: Branding.signature,
            startedAt: utterances.first?.createdAt ?? Date(),
            endedAt: utterances.last?.createdAt ?? Date(),
            sourceLanguage: sourceLanguage,
            entries: utterances.map {
                Entry(
                    speaker: $0.source.speakerLabel,
                    original: $0.original,
                    german: $0.german,
                    time: $0.createdAt
                )
            },
            summary: memory.summary,
            keyPoints: memory.keyPoints,
            openPoints: memory.openPoints
        )

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let url = uniqueURL(for: record.startedAt)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url, options: .atomic)
            Log.pipeline.info("Session archived (\(record.entries.count, privacy: .public) Einträge)")
            return url
        } catch {
            Log.pipeline.error("Archive failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Ein Dateiname, der nichts überschreibt.
    ///
    /// Der Zeitstempel allein genügte nicht: Er löst nur auf die Minute auf, und
    /// geschrieben wird atomar. Zwei kurze Gespräche hintereinander – beim
    /// Ausprobieren der Normalfall – ließen das erste Protokoll damit
    /// stillschweigend verschwinden. Bei Gleichstand wird deshalb durchgezählt.
    private static func uniqueURL(for date: Date) -> URL {
        let stamp = DateFormatter()
        // Fest gregorianisch und POSIX: unter einem japanischen oder
        // buddhistischen Kalender läge im Dateinamen sonst ein anderes Jahr.
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.timeZone = .current
        stamp.dateFormat = "yyyy-MM-dd_HH-mm"

        let base = "Gespräch_\(stamp.string(from: date))"
        var candidate = directory.appendingPathComponent("\(base).json")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(counter).json")
            counter += 1
        }
        return candidate
    }

    public static func listSessions() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension == "json" }
        .sorted { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        } ?? []
    }
}

import Foundation

/// The models AlfredHelp knows how to use, and how it picks defaults.
///
/// The ranking below is not guesswork – it is the outcome of
/// `Benchmarks/benchmark.py`, which scores every candidate on the three jobs
/// this app actually performs (translation into German, question detection,
/// contextual answering) plus measured latency on this machine.
public enum ModelCatalog {

    public enum Role: String, Sendable, CaseIterable {
        case fast
        case quality

        public var germanName: String {
            switch self {
            case .fast: return "Schnellmodell (Übersetzung, Frageerkennung)"
            case .quality: return "Antwortmodell"
            }
        }
    }

    public struct Recommendation: Sendable, Identifiable, Hashable {
        public let name: String
        public let approximateGigabytes: Double
        public let note: String
        public var id: String { name }
    }

    // MARK: - Was der Nutzer sieht

    /// One entry in the single model list the app shows.
    ///
    /// Quality and speed are not adjectives: they come from
    /// `Benchmarks/benchmark.py`, which asks every model the same eight
    /// technical questions and counts how many of the required key points the
    /// answer actually contains, and measures throughput while doing it.
    public struct Profile: Sendable, Identifiable, Hashable {
        public let name: String
        public let approximateGigabytes: Double
        /// Share of required key points the answers covered, 0…100.
        public let coveragePercent: Int
        /// Measured generation speed in tokens per second.
        public let tokensPerSecond: Int
        public let summary: String

        public var id: String { name }

        /// 1…5, derived from the measured coverage.
        public var qualityStars: Int {
            switch coveragePercent {
            case 99...: return 5
            case 95...98: return 5
            case 90...94: return 4
            case 85...89: return 3
            case 75...84: return 2
            default: return 1
            }
        }

        /// 1…5, derived from measured throughput.
        public var speedStars: Int {
            switch tokensPerSecond {
            case 28...: return 5
            case 17...27: return 4
            case 12...16: return 3
            case 8...11: return 2
            default: return 1
            }
        }

        public var qualityLabel: String { "Antwortqualität \(stars(qualityStars))" }
        public var speedLabel: String { "Tempo \(stars(speedStars))" }

        private func stars(_ count: Int) -> String {
            String(repeating: "●", count: count) + String(repeating: "○", count: 5 - count)
        }

        /// One line for menus, where there is no room for two columns.
        public var compactLabel: String {
            "\(name) · \(qualityLabel) · \(speedLabel)"
        }
    }

    /// Everything measured, best answers first. This is the list the user picks
    /// from; the small helper model is derived automatically.
    public static let profiles: [Profile] = [
        .init(name: "gemma3:12b", approximateGigabytes: 8.1, coveragePercent: 100,
              tokensPerSecond: 14,
              summary: "Beste Antworten im Test, sehr gutes Deutsch. Empfohlen."),
        .init(name: "qwen3:14b", approximateGigabytes: 9.3, coveragePercent: 96,
              tokensPerSecond: 9,
              summary: "Fast gleichwertig, etwas langsamer beim Schreiben."),
        .init(name: "phi4:14b", approximateGigabytes: 9.1, coveragePercent: 96,
              tokensPerSecond: 8,
              summary: "Stark bei technischen Themen, langsamste Ausgabe im Test."),
        .init(name: "gemma3:4b", approximateGigabytes: 3.3, coveragePercent: 94,
              tokensPerSecond: 24,
              summary: "Deutlich schneller, sechs Punkte weniger Abdeckung. Für schwächere Macs."),
        .init(name: "aya-expanse:8b", approximateGigabytes: 5.1, coveragePercent: 94,
              tokensPerSecond: 14,
              summary: "Mehrsprachig, kompakt."),
        .init(name: "qwen3:8b", approximateGigabytes: 5.2, coveragePercent: 92,
              tokensPerSecond: 14,
              summary: "Guter Kompromiss bei knappem Speicher."),
        .init(name: "llama3.2:3b", approximateGigabytes: 2.0, coveragePercent: 88,
              tokensPerSecond: 32,
              summary: "Am schnellsten, spürbar oberflächlichere Antworten."),
        .init(name: "mistral-nemo:12b", approximateGigabytes: 7.1, coveragePercent: 75,
              tokensPerSecond: 11,
              summary: "Flüssiges Deutsch, aber lückenhafte Fachantworten.")
    ]

    public static func profile(for name: String) -> Profile? {
        profiles.first { $0.name == name }
    }

    /// The model AlfredHelp uses for translation and question detection while the
    /// user's pick answers. Small, fast, and never something the user has to
    /// think about: the best measured small model that is installed, otherwise
    /// the chosen model does both jobs.
    public static func helperModel(
        for chosen: String,
        installed: [OllamaModel]
    ) -> String {
        let names = Set(installed.map(\.name))
        for candidate in fastRanking where names.contains(candidate.name) {
            // A helper only helps when it is smaller than the answer model.
            let chosenSize = profile(for: chosen)?.approximateGigabytes ?? 99
            if candidate.approximateGigabytes < chosenSize { return candidate.name }
        }
        return chosen
    }

    /// The small model AlfredHelp would like to have alongside the answer model.
    public static let preferredHelper = Recommendation(
        name: "gemma3:4b",
        approximateGigabytes: 3.3,
        note: "Übersetzt und erkennt Fragen im Hintergrund"
    )

    /// Preference order for the small, latency-critical model.
    /// Gemessen mit `Benchmarks/benchmark.py` (chrF2 gegen Referenzübersetzungen,
    /// Genauigkeit auf 16 gelabelten Äußerungen).
    public static let fastRanking: [Recommendation] = [
        .init(name: "gemma3:4b", approximateGigabytes: 3.3,
              note: "chrF2 70,7 · beste Übersetzungsqualität pro Millisekunde"),
        .init(name: "qwen3:8b", approximateGigabytes: 5.2,
              note: "chrF2 68,7 · Frageerkennung 100 %, etwa doppelte Laufzeit"),
        .init(name: "aya-expanse:8b", approximateGigabytes: 5.1,
              note: "chrF2 68,7 · mehrsprachig, langsamer bei JSON"),
        .init(name: "llama3.2:3b", approximateGigabytes: 2.0,
              note: "Am schnellsten, aber chrF2 nur 60,8"),
        .init(name: "mistral-nemo:12b", approximateGigabytes: 7.1,
              note: "chrF2 72,4 · nur sinnvoll, wenn Latenz zweitrangig ist")
    ]

    /// Preference order for the answering model.
    /// Bewertet über die Abdeckung geforderter Kernpunkte in acht Fachfragen.
    public static let qualityRanking: [Recommendation] = [
        .init(name: "gemma3:12b", approximateGigabytes: 8.1,
              note: "100 % Kernpunktabdeckung · bestes Deutsch"),
        .init(name: "qwen3:14b", approximateGigabytes: 9.3,
              note: "96 % Abdeckung · etwas schnellere erste Ausgabe"),
        .init(name: "phi4:14b", approximateGigabytes: 9.1,
              note: "96 % Abdeckung · langsamste Ausgabe im Test"),
        .init(name: "gemma3:4b", approximateGigabytes: 3.3,
              note: "94 % Abdeckung bei einem Drittel der Latenz"),
        .init(name: "qwen3:8b", approximateGigabytes: 5.2,
              note: "92 % Abdeckung · guter Kompromiss auf kleinen Macs"),
        .init(name: "aya-expanse:8b", approximateGigabytes: 5.1,
              note: "94 % Abdeckung · kompakt")
    ]

    /// Modelle, die für diese Anwendung nachweislich ungeeignet sind.
    ///
    /// `qwen3:4b` denkt vor jeder Ausgabe laut, und weder `think: false` noch
    /// `/no_think` schalten das ab – die Übersetzung landet nie in der Antwort
    /// (chrF2 18,5 bei 13 s pro Satz). `gpt-oss:20b` stellt jeder Antwort rund
    /// 900 Zeichen Analyse voran und liegt zudem über der 20-B-Grenze.
    /// Code-Modelle beantworten Gesprächsfragen erkennbar schlecht.
    private static let unsuitableExact: Set<String> = [
        "qwen3:4b", "gpt-oss:20b", "gpt-oss:120b"
    ]

    /// Auch für die Oberfläche: Code-Modelle und die im Benchmark
    /// durchgefallenen tauchen gar nicht erst als Auswahl auf.
    public static func isKnownUnsuitable(_ name: String) -> Bool {
        isUnsuitable(name)
    }

    private static func isUnsuitable(_ name: String) -> Bool {
        if unsuitableExact.contains(name) { return true }
        let lowered = name.lowercased()
        return lowered.contains("coder")
            || lowered.contains("embed")
            || lowered.contains("code-")
            || lowered.contains("starcoder")
            || lowered.contains("deepseek-r1")
    }

    /// Picks defaults from what is installed, honouring the parameter ceiling.
    public static func autoSelect(
        from installed: [OllamaModel],
        maximumParameters: Double = 20.5
    ) -> (fast: String, quality: String) {
        let usable = installed.filter { model in
            guard !isUnsuitable(model.name) else { return false }
            if let billions = model.parameterBillions { return billions <= maximumParameters }
            return true
        }
        let names = Set(usable.map(\.name))

        func firstAvailable(_ ranking: [Recommendation]) -> String? {
            for entry in ranking where names.contains(entry.name) { return entry.name }
            // Also accept a different tag of the same base model, e.g. "gemma3:4b-it-q8_0".
            for entry in ranking {
                let base = entry.name.split(separator: ":").first.map(String.init) ?? entry.name
                if let match = usable.first(where: { $0.name.hasPrefix(base + ":") }) {
                    return match.name
                }
            }
            return nil
        }

        let smallest = usable
            .min { ($0.parameterBillions ?? 99) < ($1.parameterBillions ?? 99) }?.name
        let largest = usable
            .max { ($0.parameterBillions ?? 0) < ($1.parameterBillions ?? 0) }?.name

        return (
            fast: firstAvailable(fastRanking) ?? smallest ?? "",
            quality: firstAvailable(qualityRanking) ?? largest ?? smallest ?? ""
        )
    }

    /// Recommendations that are not installed yet, for the setup screen.
    public static func missingRecommendations(
        installed: [OllamaModel]
    ) -> (fast: [Recommendation], quality: [Recommendation]) {
        let names = Set(installed.map(\.name))
        return (
            fast: fastRanking.filter { !names.contains($0.name) },
            quality: qualityRanking.filter { !names.contains($0.name) }
        )
    }
}

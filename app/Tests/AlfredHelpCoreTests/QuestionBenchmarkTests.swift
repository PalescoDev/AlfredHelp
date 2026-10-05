import Testing
import Foundation
@testable import AlfredHelpCore

/// Loads `Benchmarks/frageerkennung.json` – the single labelled dataset both
/// benchmark stages share.
struct QuestionDataset {
    struct Example: Decodable {
        let text: String
        let kontext: String
        let lang: String
        let label: String       // frage | keine | unvollstaendig
        let kategorie: String
    }

    struct File: Decodable {
        let beispiele: [Example]
    }

    static func load(_ dateiname: String = "frageerkennung.json") throws -> [Example] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AlfredHelpCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Paketwurzel
            .appendingPathComponent("Benchmarks/\(dateiname)")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(File.self, from: data).beispiele
    }

    /// Der Haltedatensatz. Bewusst eine zweite Datei und nicht ein Flag in der
    /// ersten: `frageerkennung.json` ist der Satz, an dem die Heuristik
    /// *entwickelt* wurde – ein Teil seiner Negativbeispiele wurde ausdrücklich
    /// als Schatten der eigenen neuen Regeln geschrieben. Null Fehlalarme
    /// darauf sind deshalb kein Messwert, sondern eine Tautologie. Der
    /// Haltedatensatz entstand ohne Blick in `TextUtilities.swift` und ist die
    /// einzige Grundlage im Projekt, aus der sich eine Aussage über eine
    /// *ungesehene* Formulierung ableiten lässt.
    static func loadHoldout() throws -> [Example] {
        try load("frageerkennung-holdout.json")
    }
}

/// Wohin die Heuristik eine Äußerung bei einer gegebenen Sofort-Schwelle legt.
///
/// Steht hier einmal, weil drei Tests dieselbe Einordnung brauchen und drei
/// Kopien genau die Art von Doppelung wären, bei der später eine gepflegt wird
/// und die anderen nicht.
enum QuestionTier: String {
    /// Wird ohne Rückfrage beim Modell beantwortet; der Klassifikator ist nur
    /// noch Veto (`verifyInBackground`).
    case sofort
    /// Wartet auf die Modellstufe – rund 300 ms Median.
    case pruefen
    case keine
    case unvollstaendig

    static func of(_ text: String, shortcut: Double, gate: Double) -> QuestionTier {
        switch TextUtilities.assessQuestion(text) {
        case .notQuestion: return .keine
        case .incomplete: return .unvollstaendig
        case .question(let confidence):
            if confidence >= shortcut { return .sofort }
            if confidence >= gate { return .pruefen }
            return .keine
        }
    }
}

/// Stage-1 benchmark: pure heuristic, runs on every `swift test`.
///
/// What must hold:
/// - The immediate-answer tier must never fire on a non-question: those
///   answers appear before any model can veto them.
/// - Real questions must not be dropped below the gate, because nothing
///   downstream ever sees them again.
///
/// Beide Schwellen stehen nicht mehr hier, sondern in `AppSettings` – der
/// Test misst, was ausgeliefert wird. Wo sie liegen dürfen, klärt der
/// Schwellen-Sweep in `HoldoutBenchmarkTests`.
@Suite("Frageerkennung – Heuristik-Benchmark")
struct HeuristicBenchmarkTests {

    /// Beide Schwellen kommen aus den ausgelieferten Standardwerten und nicht
    /// mehr aus Konstanten im Test. Vorher stand hier 0,95 fest verdrahtet –
    /// wer `AppSettings.questionCertaintyShortcut` verstellte, bekam davon im
    /// Test nichts mit, und die Zusicherung „0 sofortige Fehlalarme" galt
    /// stillschweigend für einen Wert, den die App gar nicht mehr benutzte.
    static let gate = AppSettings().questionHeuristicThreshold
    static let shortcut = AppSettings().questionCertaintyShortcut

    @Test("Konfusionsmatrix und Schwellen")
    func benchmark() throws {
        let examples = try QuestionDataset.load()
        #expect(examples.count >= 100)

        var immediateFalsePositives: [String] = []
        var droppedQuestions: [String] = []
        var incompleteAsQuestion: [String] = []
        var counts: [String: [String: Int]] = [:]   // label -> predicted tier -> n

        for example in examples {
            let tier = QuestionTier.of(example.text, shortcut: Self.shortcut, gate: Self.gate)
            counts[example.label, default: [:]][tier.rawValue, default: 0] += 1

            if example.label == "keine" && tier == .sofort {
                immediateFalsePositives.append(example.text)
            }
            if example.label == "frage" && (tier == .keine || tier == .unvollstaendig) {
                droppedQuestions.append(example.text)
            }
            if example.label == "unvollstaendig" && (tier == .sofort || tier == .pruefen) {
                incompleteAsQuestion.append(example.text)
            }
        }

        // Report for the transcript.
        print("── Heuristik-Konfusion (Zeile = Goldlabel) ──")
        for label in ["frage", "keine", "unvollstaendig"] {
            let row = counts[label] ?? [:]
            print(String(
                format: "%-14@ sofort:%3d  pruefen:%3d  keine:%3d  unvollst.:%3d",
                label as NSString,
                row["sofort"] ?? 0, row["pruefen"] ?? 0,
                row["keine"] ?? 0, row["unvollstaendig"] ?? 0
            ))
        }
        if !immediateFalsePositives.isEmpty {
            print("Sofort-FPs: \(immediateFalsePositives)")
        }
        if !droppedQuestions.isEmpty {
            print("Verlorene Fragen: \(droppedQuestions)")
        }
        if !incompleteAsQuestion.isEmpty {
            print("Fragmente als Frage: \(incompleteAsQuestion)")
        }

        // Hard requirements.
        #expect(immediateFalsePositives.isEmpty,
                "Nicht-Fragen dürfen nie die Sofort-Stufe erreichen")
        #expect(incompleteAsQuestion.isEmpty,
                "Fragmente dürfen keine Antwort auslösen")

        let questionTotal = examples.filter { $0.label == "frage" }.count
        let dropped = droppedQuestions.count
        let gateRecall = Double(questionTotal - dropped) / Double(questionTotal)
        print(String(format: "Gate-Recall (Fragen, die Stufe 1 überleben): %.3f", gateRecall))
        #expect(gateRecall >= 0.95, "Zu viele Fragen fallen unter die Prüfschwelle")
    }

    @Test("Fragment-Erkennung fürs längere Warten im Assembler")
    func fragmentDetection() throws {
        let examples = try QuestionDataset.load().filter { $0.label == "unvollstaendig" }
        var missed: [String] = []
        for example in examples where !TextUtilities.endsIncomplete(example.text) {
            missed.append(example.text)
        }
        if !missed.isEmpty { print("Nicht als unvollständig erkannt: \(missed)") }
        #expect(Double(missed.count) / Double(examples.count) <= 0.2)
    }
}

/// Haltedatensatz-Benchmark: dieselbe Heuristik, andere Daten.
///
/// Warum es diese zweite Suite gibt: `frageerkennung.json` ist der Satz, an dem
/// die Heuristik entwickelt wurde. Dort erreichen von 76 Nicht-Fragen ganze
/// fünf überhaupt die Stufe „Frage“ – und ein Teil dieser Negativbeispiele
/// wurde erst geschrieben, als die zugehörigen Regeln schon standen. „Null
/// Fehlalarme“ auf so einem Satz ist kein Messwert über eine ungesehene
/// Formulierung, sondern eine Aussage über die Regeln über sich selbst.
///
/// `frageerkennung-holdout.json` dreht das Verhältnis um: 115 Nicht-Fragen
/// gegen 45 Fragen, mit Schwerpunkt auf Besprechungssprache, die *fast* wie
/// eine Frage klingt – berichtete Fragen („Er hat gefragt, wann wir liefern
/// können“), höfliche Konjunktive („Wäre schön, wenn wir das bis Freitag
/// hätten“), verbfirste Zusagen („Können wir gerne so machen“), Ausrufe mit
/// Fragewort („Was für ein Chaos war das gestern“), laut Gedachtes („Ich frag
/// mich, ob das überhaupt jemand braucht“).
@Suite("Frageerkennung – Haltedatensatz")
struct HoldoutBenchmarkTests {

    @Test("Konfusionsmatrix auf ungesehenen Formulierungen")
    func holdout() throws {
        let examples = try QuestionDataset.loadHoldout()
        #expect(examples.count >= 150)
        // Der Zweck des Satzes steht und fällt mit dem Übergewicht der
        // Negativbeispiele. Kippt das durch eine spätere Erweiterung, ist die
        // Fehlalarm-Aussage wieder so dünn wie im Abstimmsatz.
        let negatives = examples.filter { $0.label == "keine" }.count
        let positives = examples.filter { $0.label == "frage" }.count
        #expect(negatives > positives, "Der Haltedatensatz lebt von den Negativbeispielen")

        let shortcut = HeuristicBenchmarkTests.shortcut
        let gate = HeuristicBenchmarkTests.gate

        var immediateFalsePositives: [String] = []
        var droppedQuestions: [String] = []
        var incompleteAsQuestion: [String] = []
        var counts: [String: [String: Int]] = [:]

        for example in examples {
            let tier = QuestionTier.of(example.text, shortcut: shortcut, gate: gate)
            counts[example.label, default: [:]][tier.rawValue, default: 0] += 1
            if example.label == "keine" && tier == .sofort {
                immediateFalsePositives.append(example.text)
            }
            if example.label == "frage" && (tier == .keine || tier == .unvollstaendig) {
                droppedQuestions.append(example.text)
            }
            if example.label == "unvollstaendig" && (tier == .sofort || tier == .pruefen) {
                incompleteAsQuestion.append(example.text)
            }
        }

        print("── Haltedatensatz-Konfusion (Zeile = Goldlabel) ──")
        for label in ["frage", "keine", "unvollstaendig"] {
            let row = counts[label] ?? [:]
            print(String(
                format: "%-14@ sofort:%3d  pruefen:%3d  keine:%3d  unvollst.:%3d",
                label as NSString,
                row["sofort"] ?? 0, row["pruefen"] ?? 0,
                row["keine"] ?? 0, row["unvollstaendig"] ?? 0
            ))
        }
        if !immediateFalsePositives.isEmpty { print("Sofort-FPs: \(immediateFalsePositives)") }
        if !droppedQuestions.isEmpty { print("Verlorene Fragen: \(droppedQuestions)") }
        if !incompleteAsQuestion.isEmpty { print("Fragmente als Frage: \(incompleteAsQuestion)") }

        let questionTotal = max(1, positives)
        let gateRecall = Double(questionTotal - droppedQuestions.count) / Double(questionTotal)
        print(String(format: "Gate-Recall auf dem Haltedatensatz: %.3f", gateRecall))

        // Die Konfidenzverteilung der Nicht-Fragen ist die eigentlich
        // interessante Zahl: sie sagt, wie viel Luft zwischen der höchsten
        // Nicht-Frage und der Sofort-Schwelle liegt. Auf dem Abstimmsatz
        // kommen die Nicht-Fragen nie über 0,4 – auf ungesehener Sprache
        // sieht das anders aus, und genau das soll im Protokoll stehen.
        var verteilung: [Double: [String]] = [:]
        for beispiel in examples where beispiel.label == "keine" {
            if case .question(let confidence) = TextUtilities.assessQuestion(beispiel.text) {
                verteilung[confidence, default: []].append(beispiel.text)
            }
        }
        print("── Nicht-Fragen, die die Stufe „Frage“ überhaupt erreichen ──")
        for stufe in verteilung.keys.sorted(by: >) {
            let texte = verteilung[stufe] ?? []
            print(String(format: "  %.2f × %2d", stufe, texte.count))
            for text in texte { print("        · \(text)") }
        }
        let hoechsteNichtFrage = verteilung.keys.max() ?? 0
        print(String(format: "Höchste Nicht-Frage: %.2f – ausgelieferte Schwelle: %.2f",
                     hoechsteNichtFrage, shortcut))

        // Bewusst keine Forderung „keine Fehlalarme“, sondern „kein *anderer*
        // Fehlalarm als der bekannte“. Der eine Fall läuft über das Muster
        // `"das nochmal"` in `repeatRequests` (TextUtilities) und trifft jeden
        // Satz der Bauart „…, das nochmal <Verb>“ – er sitzt fest auf 0,95 und
        // tritt bei jeder Schwelle auf. Ihn hier wegzuwünschen würde die
        // Zusicherung wertlos machen; ihn namentlich zu dulden hält den Test
        // scharf für alles andere und macht den offenen Defekt sichtbar.
        #expect(immediateFalsePositives == Self.bekannteFehlalarme,
                "Neue Nicht-Frage auf der Sofort-Stufe: \(immediateFalsePositives)")
    }

    /// Sofortige Fehlalarme, die nicht an der Schwelle hängen, sondern an
    /// einer zu breiten Musterliste. Wer einen davon behebt, streicht ihn hier.
    static let bekannteFehlalarme: [String] = []

    /// Der eigentliche Kalibrierungstest: bei welchem Wert bricht die
    /// Sofort-Stufe?
    ///
    /// Vorbild ist die Fenster-Messung in `StitchTests` – dieselbe Idee, nur
    /// mit einer Schwelle statt einer Frist: den ganzen Bereich abtasten,
    /// das Plateau ausdrucken, und den ausgelieferten Wert daraufhin prüfen,
    /// dass er *mit Abstand* darin liegt. Ein Plateau aus einem einzigen Wert
    /// wäre kein Plateau, sondern Zufall.
    ///
    /// Gemessen wird gegen **beide** Datensätze zusammen. Der Abstimmsatz
    /// allein würde jedes Absenken rechtfertigen, weil er die Regeln kennt;
    /// der Haltedatensatz allein hätte zu wenige echte Fragen, um die
    /// Sofort-Ausbeute zu beurteilen.
    @Test("Schwellen-Sweep: wo liegt das Plateau der Sofort-Schwelle?")
    func shortcutSweep() throws {
        let tuning = try QuestionDataset.load()
        let holdout = try QuestionDataset.loadHoldout()
        let gate = HeuristicBenchmarkTests.gate

        /// Die Konfidenzleiter in `TextUtilities.assessSentence` ist diskret:
        /// 0,4 · 0,5 · 0,55 · 0,6 · 0,65 · 0,7 · 0,75 · 0,8 · 0,9 · 0,95.
        /// Abgetastet wird auf den Sprossen **und** dazwischen – nur so wird
        /// sichtbar, dass der ausgelieferte Wert in einer Lücke sitzt und
        /// nicht auf einer Kante.
        let candidates: [Double] = [0.45, 0.55, 0.6, 0.65, 0.7, 0.75, 0.78, 0.8, 0.85, 0.9, 0.95]

        struct Zeile {
            let schwelle: Double
            let sofort: Int
            let grau: Int
            let fpAbstimm: [String]
            let fpHalte: [String]
        }

        func messen(_ schwelle: Double) -> Zeile {
            func zaehlen(_ satz: [QuestionDataset.Example]) -> (sofort: Int, grau: Int, fp: [String]) {
                var sofort = 0, grau = 0
                var fp: [String] = []
                for beispiel in satz {
                    let tier = QuestionTier.of(beispiel.text, shortcut: schwelle, gate: gate)
                    if beispiel.label == "frage" {
                        if tier == .sofort { sofort += 1 }
                        if tier == .pruefen { grau += 1 }
                    } else if tier == .sofort {
                        fp.append(beispiel.text)
                    }
                }
                return (sofort, grau, fp)
            }
            let a = zaehlen(tuning)
            let h = zaehlen(holdout)
            return Zeile(schwelle: schwelle,
                         sofort: a.sofort + h.sofort,
                         grau: a.grau + h.grau,
                         fpAbstimm: a.fp,
                         fpHalte: h.fp)
        }

        // Belegt, dass der Sprung zwischen 0,75 und 0,80 keine Datengrenze ist,
        // sondern eine Strukturgrenze: ab 0,80 vergibt die Heuristik ihre
        // Konfidenz fast nur noch an Sätze, die der Erkenner mit Fragezeichen
        // abgeschlossen hat – also an gemessene Intonation statt an Satzbau.
        var proStufe: [Double: (gesamt: Int, mitZeichen: Int, nichtFragen: Int)] = [:]
        for beispiel in tuning + holdout {
            guard case .question(let c) = TextUtilities.assessQuestion(beispiel.text) else { continue }
            var eintrag = proStufe[c] ?? (0, 0, 0)
            eintrag.gesamt += 1
            if beispiel.text.trimmingCharacters(in: .whitespaces).hasSuffix("?") { eintrag.mitZeichen += 1 }
            if beispiel.label != "frage" { eintrag.nichtFragen += 1 }
            proStufe[c] = eintrag
        }
        print("── Konfidenzleiter, beide Datensätze ──")
        print("Stufe | Beispiele | davon mit „?“ | davon Nicht-Fragen")
        for stufe in proStufe.keys.sorted(by: >) {
            let e = proStufe[stufe]!
            print(String(format: " %.2f |   %4d    |     %4d      |      %4d",
                         stufe, e.gesamt, e.mitZeichen, e.nichtFragen))
        }

        print("── Sofort-Schwelle, beide Datensätze ──")
        print("Schwelle | sofort | grau | FP Abstimmsatz | FP Haltedatensatz")
        var zeilen: [Double: Zeile] = [:]
        for kandidat in candidates {
            let z = messen(kandidat)
            zeilen[kandidat] = z
            print(String(format: "  %.2f   |  %4d  | %4d |       %3d      |       %3d",
                         z.schwelle, z.sofort, z.grau, z.fpAbstimm.count, z.fpHalte.count))
        }

        // Der Bezugspunkt ist der frühere Auslieferungswert 0,95 – die
        // vorsichtigste Einstellung, die je gefahren wurde. Das Plateau ist
        // der Bereich, in dem das Absenken *nichts kostet*: dieselben
        // Fehlalarme wie bei 0,95, kein einziger neuer. Absolute
        // Fehlalarmfreiheit taugt hier nicht als Maßstab, weil ein bekannter
        // Musterlisten-Defekt schon bei 0,95 zuschlägt (siehe
        // `bekannteFehlalarme`) und jede Schwelle gleichermaßen belastet.
        let referenz = messen(0.95)
        let referenzFP = Set(referenz.fpAbstimm + referenz.fpHalte)
        let plateau = candidates.filter {
            let z = zeilen[$0]!
            return Set(z.fpAbstimm + z.fpHalte) == referenzFP
        }
        print("Plateau (keine zusätzlichen Fehlalarme gegenüber 0,95): \(plateau)")

        let ausgeliefert = HeuristicBenchmarkTests.shortcut
        let hier = zeilen[ausgeliefert]
        #expect(hier != nil, "Der ausgelieferte Wert \(ausgeliefert) wird gar nicht abgetastet – Raster ergänzen")
        let gekauft = Set((hier?.fpAbstimm ?? []) + (hier?.fpHalte ?? [])).subtracting(referenzFP)
        #expect(plateau.contains(ausgeliefert),
                Comment(rawValue: "Die ausgelieferte Sofort-Schwelle kauft Fehlalarme, "
                        + "die es bei 0,95 nicht gab: \(gekauft.sorted())"))
        // Ein Plateau aus einem einzigen Wert wäre kein Plateau, sondern Zufall.
        #expect(plateau.count >= 3)

        // Der untere Rand des Plateaus ist die eigentliche Zahl, um die es
        // geht: unterhalb davon bricht die Sofort-Stufe, und zwar nicht
        // allmählich, sondern in einem Schritt. Wird dieser Rand nicht mehr
        // gefunden, hat die Messung ihre Trennschärfe verloren – dann sagt
        // auch das Plateau darüber nichts mehr.
        guard let untererRand = plateau.min(),
              let letzteSaubere = candidates.last(where: { $0 < untererRand }) else {
            Issue.record("Kein unterer Plateaurand im Raster – der Sweep misst nichts mehr")
            return
        }
        let unterhalb = zeilen[letzteSaubere]!
        let zusaetzlich = Set(unterhalb.fpAbstimm + unterhalb.fpHalte).subtracting(referenzFP)
        print(String(format: "Unterer Plateaurand: %.2f – eine Stufe tiefer (%.2f) kommen %d Fehlalarme dazu",
                     untererRand, letzteSaubere, zusaetzlich.count))
        print(String(format: "Sicherheitsabstand des ausgelieferten Werts nach unten: %.2f",
                     ausgeliefert - letzteSaubere))
        #expect(!zusaetzlich.isEmpty, """
                Unterhalb des Plateaus müsste es schlechter werden – tut es das nicht, \
                steht die Schwelle unnötig hoch oder der Haltedatensatz greift nicht mehr
                """)
        #expect(ausgeliefert > letzteSaubere,
                "Der ausgelieferte Wert liegt nicht über der letzten Stufe mit zusätzlichen Fehlalarmen")
    }
}

/// Stage-2 benchmark: the full shipped decision path including gemma3:4b.
/// Slow (one model call per mid-confidence example), therefore opt-in:
///
///     ALFREDHELP_LLM_BENCH=1 swift test --filter VollerPfad
///
/// Measures precision, recall, false positives/negatives and the decision
/// latency after end of sentence, then writes `Benchmarks/frage_report.txt`.
@Suite("Frageerkennung – VollerPfad")
struct FullPathBenchmarkTests {

    @Test("Precision, Recall und Latenz mit lokalem Modell")
    func fullPath() async throws {
        guard ProcessInfo.processInfo.environment["ALFREDHELP_LLM_BENCH"] == "1" else {
            return   // opt-in only
        }
        let client = OllamaClient()
        // Vergleichbar machen: das zu prüfende Hilfsmodell ist einstellbar.
        let model = ProcessInfo.processInfo.environment["ALFREDHELP_FAST_MODEL"] ?? "gemma3:4b"
        guard await client.isReachable() else {
            Issue.record("Ollama nicht erreichbar")
            return
        }
        _ = try? await client.chat(
            model: model,
            messages: [.system("Antworte mit OK."), .user("Bereit?")],
            options: GenerationOptions(temperature: 0, numPredict: 4),
            think: false
        )

        let examples = try QuestionDataset.load()
        var truePositives = 0, falsePositives = 0, falseNegatives = 0, trueNegatives = 0
        var falsePositiveTexts: [String] = []
        var falseNegativeTexts: [String] = []
        var latencies: [Double] = []          // ms bis zur Entscheidung
        var immediateCount = 0, modelCount = 0

        for example in examples {
            let goldIsQuestion = example.label == "frage"
            var predictedQuestion = false
            var latency: Double = 0

            switch TextUtilities.assessQuestion(example.text) {
            case .question(let confidence)
                where confidence >= HeuristicBenchmarkTests.shortcut:
                predictedQuestion = true
                latency = 0
                immediateCount += 1

            case .question(let confidence)
                where confidence >= HeuristicBenchmarkTests.gate:
                modelCount += 1
                let start = Clock.now()
                let decided = DecisionBox()
                let verdict = await QuestionClassifier.classify(
                    client: client,
                    model: model,
                    context: "Gegenüber: \(example.kontext)",
                    utterance: example.text,
                    onEarlyDecision: { isQuestion in
                        decided.record(isQuestion: isQuestion, at: Clock.now())
                    }
                )
                if let early = decided.snapshot() {
                    predictedQuestion = early.isQuestion
                    latency = (early.at - start) * 1000
                } else if case .question = verdict {
                    predictedQuestion = true
                    latency = (Clock.now() - start) * 1000
                } else {
                    predictedQuestion = false
                    latency = (Clock.now() - start) * 1000
                }

            default:
                predictedQuestion = false
                latency = 0
            }

            if goldIsQuestion && predictedQuestion { truePositives += 1; latencies.append(latency) }
            if !goldIsQuestion && predictedQuestion {
                falsePositives += 1
                falsePositiveTexts.append(example.text)
            }
            if goldIsQuestion && !predictedQuestion {
                falseNegatives += 1
                falseNegativeTexts.append(example.text)
            }
            if !goldIsQuestion && !predictedQuestion { trueNegatives += 1 }
        }

        let precision = Double(truePositives) / Double(max(1, truePositives + falsePositives))
        let recall = Double(truePositives) / Double(max(1, truePositives + falseNegatives))
        let sorted = latencies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]

        var report = """
        Frageerkennung – voller Pfad (Heuristik + \(model))
        Beispiele        : \(examples.count)
        Sofort-Stufe     : \(immediateCount) (0 ms)
        Modell-Stufe     : \(modelCount)
        ─────────────────────────────────────
        Precision        : \(String(format: "%.3f", precision))
        Recall           : \(String(format: "%.3f", recall))
        False Positives  : \(falsePositives)
        False Negatives  : \(falseNegatives)
        Latenz Median    : \(String(format: "%.0f", median)) ms
        Latenz p90       : \(String(format: "%.0f", p90)) ms
        """
        if !falsePositiveTexts.isEmpty {
            report += "\n\nFP:\n" + falsePositiveTexts.map { "  · \($0)" }.joined(separator: "\n")
        }
        if !falseNegativeTexts.isEmpty {
            report += "\n\nFN:\n" + falseNegativeTexts.map { "  · \($0)" }.joined(separator: "\n")
        }
        print(report)

        let reportURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/frage_report.txt")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        #expect(precision >= 0.9)
        #expect(recall >= 0.9)
    }
}

/// Thread-safe capture of the early-decision moment.
private final class DecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (isQuestion: Bool, at: Double)?

    func record(isQuestion: Bool, at: Double) {
        lock.withLock { if value == nil { value = (isQuestion, at) } }
    }

    func snapshot() -> (isQuestion: Bool, at: Double)? {
        lock.withLock { value }
    }
}

@Suite("Frageerkennung – Pipeline-Schutz")
struct QuestionPipelineGuardTests {

    @Test("Wiederholte Frage wird als Duplikat erkannt")
    func duplicateDetection() {
        let first = AssistantPipeline.questionFingerprint(
            "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem?"
        )
        let repeated = AssistantPipeline.questionFingerprint(
            "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem"
        )
        let related = AssistantPipeline.questionFingerprint(
            "Und wie lange dauert danach der inkrementelle Lauf im Testsystem?"
        )
        #expect(AssistantPipeline.questionsSimilar(first, repeated))
        #expect(!AssistantPipeline.questionsSimilar(first, related))
    }

    @Test("Recognizer-Doppelung gilt als Duplikat, neue Kurzfrage nicht")
    func nearDuplicates() {
        let a = AssistantPipeline.questionFingerprint("What happens if all three retries fail?")
        let b = AssistantPipeline.questionFingerprint("What happens if all three retries fail")
        let c = AssistantPipeline.questionFingerprint("And what happens after a success?")
        #expect(AssistantPipeline.questionsSimilar(a, b))
        #expect(!AssistantPipeline.questionsSimilar(a, c))
    }

    @Test("Assembler hält erkennbar halbe Sätze länger zurück")
    func assemblerHoldsFragments() {
        var options = UtteranceAssembler.Options()
        options.silenceFlushSeconds = 1.0
        options.continuationFlushSeconds = 2.5
        let assembler = UtteranceAssembler(source: .system)

        _ = assembler
        let holdAssembler = UtteranceAssembler(source: .system, options: options)
        let event = TranscriptEvent(
            source: .system, text: "Wenn wir das so machen und dann", isFinal: true,
            startSeconds: 0, endSeconds: 1, confidence: nil, capturedAt: 100
        )
        _ = holdAssembler.append(event)
        // Nach 1,4 s noch nichts – das Fragment endet mitten im Gedanken.
        #expect(holdAssembler.flushIfIdle(now: 101.4) == nil)
        // Nach 2,6 s kommt es heraus.
        #expect(holdAssembler.flushIfIdle(now: 102.6) != nil)

        // Ein sauber endendes Fragment fließt weiterhin nach der kurzen Frist.
        let cleanAssembler = UtteranceAssembler(source: .system, options: options)
        let cleanEvent = TranscriptEvent(
            source: .system, text: "Das klingt nach einem guten Plan", isFinal: true,
            startSeconds: 0, endSeconds: 1, confidence: nil, capturedAt: 100
        )
        _ = cleanAssembler.append(cleanEvent)
        #expect(cleanAssembler.flushIfIdle(now: 101.2) != nil)
    }

    @Test("Selbstbeantwortete Frage im selben Redefluss löst nichts aus")
    func selfAnsweredRhetoric() {
        #expect(TextUtilities.assessQuestion(
            "Warum erzähle ich das? Weil uns genau das letztes Jahr passiert ist."
        ) == .notQuestion)
        #expect(TextUtilities.assessQuestion(
            "Why does this matter? Because every minute of downtime costs money."
        ) == .notQuestion)
        // Ohne Selbstantwort bleibt es eine Frage.
        if case .question = TextUtilities.assessQuestion("Warum ist das so?") {} else {
            Issue.record("Echte Frage verworfen")
        }
    }

    @Test("Mehrere Fragen hintereinander bleiben eine Frage")
    func multiQuestion() {
        if case .question(let confidence) = TextUtilities.assessQuestion(
            "Wie teuer ist das? Und wie lange dauert die Einführung?"
        ) {
            #expect(confidence >= 0.9)
        } else {
            Issue.record("Mehrfachfrage nicht erkannt")
        }
    }
}

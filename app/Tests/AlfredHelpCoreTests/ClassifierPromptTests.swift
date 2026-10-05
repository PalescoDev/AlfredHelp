import Testing
import Foundation
@testable import AlfredHelpCore

@Suite("Antwortqualität – Prompt-Invarianten")
struct AnswerPromptInvariantTests {
    @Test("spoken steht für frühes Streaming an erster Stelle")
    func spokenIsFirstSchemaField() throws {
        guard case .schema(let schema) = Prompts.answerSchema else {
            Issue.record("answerSchema ist kein JSON-Schema")
            return
        }
        let properties = try #require(schema.range(of: "\"properties\":{"))
        #expect(schema[properties.upperBound...].hasPrefix("\"spoken\""))
        for field in ["spoken", "details", "confidence", "missingContext"] {
            #expect(schema.contains("\"\(field)\""))
        }
    }

    @Test("Prompt verbietet unbelegte Zahlen und Zusagen")
    func promptRequiresGrounding() {
        let prompt = Prompts.answerSystem(
            language: .german, conversationLanguage: "Deutsch", profile: ""
        ).lowercased()
        #expect(prompt.contains("zahlen"))
        #expect(prompt.contains("zusagen"))
        #expect(prompt.contains("erfinde niemals"))
        #expect(prompt.contains("missingcontext"))
        #expect(prompt.contains("ja/nein"))
        #expect(prompt.contains("statusfrage"))
        #expect(prompt.contains("entscheidungsfrage"))
    }
}

// MARK: - Offline-Prüfungen des Klassifikator-Prompts
//
// Diese Prüfungen laufen bei jedem `swift test` mit und brauchen kein Ollama.
// Sie sichern die Eigenschaften des Prompts ab, die man beim Umformulieren am
// leichtesten kaputt macht und die im Betrieb sofort teuer werden:
// die Feldreihenfolge (Latenz) und die Auswertung des Statuswerts (Korrektheit).

@Suite("Frageerkennung – Prompt-Invarianten")
struct ClassifierPromptInvariantTests {

    /// Der Frühentscheider liest den JSON-Strom, während er entsteht. Er kann
    /// nur greifen, solange `status` das ERSTE Feld ist – kommt vorher ein
    /// langer `eigenstaendig`-String, wartet er auf dessen Ende und die
    /// Entscheidung fällt statt nach einem Dutzend erst nach sechzig Token.
    /// Das Schema legt die Reihenfolge fest, an die sich Ollamas
    /// eingeschränkte Dekodierung hält; deshalb wird hier das Schema geprüft
    /// und nicht die Prosa des Systemprompts.
    @Test("status steht im Schema an erster Stelle")
    func statusIsFirstSchemaField() throws {
        guard case .schema(let text) = Prompts.classifySchema else {
            Issue.record("classifySchema ist kein JSON-Schema")
            return
        }
        // Kein JSON-Parsing: Dictionaries sind ungeordnet, die Reihenfolge
        // steht nur im Text. Genau die will der Test schützen.
        let properties = try #require(text.range(of: "\"properties\":{"))
        let afterProperties = text[properties.upperBound...]
        #expect(afterProperties.hasPrefix("\"status\""),
                "status muss das erste Feld im Schema sein, sonst ist earlyDecision wirkungslos")

        let statusIndex = try #require(text.range(of: "\"status\""))
        let standaloneIndex = try #require(text.range(of: "\"eigenstaendig\""))
        #expect(statusIndex.lowerBound < standaloneIndex.lowerBound)

        // Auch die AUSGABEVORLAGE am Ende des Systemprompts muss die
        // Reihenfolge zeigen: das Modell übernimmt sie, wenn die
        // eingeschränkte Dekodierung einmal nicht greift (etwa weil ein
        // anderer Server das Schema ignoriert). Geprüft wird gezielt die
        // JSON-Vorlage – die Feldnamen kommen im erklärenden Text davor in
        // beliebiger Reihenfolge vor, das ist unschädlich.
        let template = try #require(
            Prompts.classifySystem.range(of: "{\"status\"").map {
                String(Prompts.classifySystem[$0.lowerBound...])
            },
            "Die JSON-Vorlage muss mit dem Feld status beginnen"
        )
        let templateStandalone = try #require(template.range(of: "\"eigenstaendig\""))
        #expect(template.distance(from: template.startIndex, to: templateStandalone.lowerBound) > 0,
                "In der Ausgabevorlage steht status vor eigenstaendig")
    }

    /// Der Frühentscheider unterscheidet nur nach dem ersten Buchstaben des
    /// Statuswerts. Alle drei erlaubten Werte müssen sich darin unterscheiden –
    /// sonst wäre die Frühentscheidung mehrdeutig. Ein umbenannter Status wie
    /// „fraglich“ neben „frage“ würde das still brechen.
    @Test("Die drei Statuswerte bleiben am ersten Buchstaben unterscheidbar")
    func statusValuesAreDistinguishableByFirstLetter() throws {
        guard case .schema(let text) = Prompts.classifySchema else {
            Issue.record("classifySchema ist kein JSON-Schema")
            return
        }
        for value in ["frage", "keine_frage", "unvollstaendig"] {
            #expect(text.contains("\"\(value)\""), "Statuswert \(value) fehlt im Schema")
            #expect(Prompts.classifySystem.contains(value),
                    "Statuswert \(value) fehlt im Systemprompt")
        }
        let firstLetters = Set(["frage", "keine_frage", "unvollstaendig"].map { $0.first! })
        #expect(firstLetters.count == 3)

        // Und die Frühentscheidung muss diese Buchstaben auch wirklich lesen.
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"f") == true)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"k") == false)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"u") == false)
    }

    /// Realistische Präfixe aus dem Tokenstrom: die Entscheidung darf nicht
    /// erst fallen, wenn der Statuswert fertig ist, und darf vorher nichts
    /// raten. Der letzte Fall ist der teure: stünde `eigenstaendig` vorn, käme
    /// die Entscheidung erst nach dem ganzen umgeschriebenen Satz.
    @Test("Frühentscheidung greift am Tokenstrom, nicht erst am fertigen JSON")
    func earlyDecisionOnStreamPrefixes() {
        #expect(QuestionClassifier.earlyDecision(in: "") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"stat") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\"") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\": \"") == nil)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\": \"fr") == true)
        #expect(QuestionClassifier.earlyDecision(in: "{\"status\":\"keine_frage\",\"eigenstaendig\":\"\"}") == false)

        // Gegenprobe: mit vorangestelltem eigenstaendig-Feld fällt die
        // Entscheidung erst am Ende – exakt der Zustand, den das Schema
        // verhindert. Der Test hält fest, warum die Reihenfolge zählt.
        let umgekehrt = "{\"eigenstaendig\":\"Was passiert nach dem Rollout"
        #expect(QuestionClassifier.earlyDecision(in: umgekehrt) == nil)
    }

    /// Der Prompt muss dem Modell die Ellipse ausdrücklich erklären. Ohne diese
    /// Anleitung stuft gemma3:4b belegte Nachfragen wie „Und danach“ oder
    /// „And the cost“ als keine_frage ein – gemessen im Ausgangszustand.
    @Test("Prompt behandelt Ellipsen und die Umschreibung ausdrücklich")
    func promptCoversEllipsis() {
        let prompt = Prompts.classifySystem.lowercased()
        #expect(prompt.contains("ellip") || prompt.contains("bruchstück") || prompt.contains("fragment"),
                "Der Prompt muss elliptische Nachfragen benennen")
        // Die Abgrenzung Ellipse ↔ Abbruch ist der gefährlichste Verwechsler:
        // beide sind kurz, nur eine ist eine Frage.
        #expect(Prompts.classifySystem.contains("unvollstaendig"))
        #expect(Prompts.classifySystem.contains("eigenstaendig"))
    }

    /// Der Nutzerteil muss den Verlauf und die letzte Äußerung sichtbar
    /// trennen. Verschmelzen beide, beurteilt das Modell die vorletzte Zeile
    /// mit – eine häufige Ursache für falsche „frage“-Urteile.
    @Test("Nutzerteil trennt Verlauf und letzte Äußerung")
    func userPromptSeparatesContext() {
        let text = Prompts.classifyUser(
            context: "A: Erst kommt der Import, dann die Prüfung.",
            utterance: "Und danach"
        )
        #expect(text.contains("Erst kommt der Import"))
        #expect(text.contains("Und danach"))
        let contextIndex = text.range(of: "Erst kommt der Import")!.lowerBound
        let utteranceIndex = text.range(of: "Und danach")!.lowerBound
        #expect(contextIndex < utteranceIndex, "Der Verlauf steht vor der zu beurteilenden Äußerung")

        let leer = Prompts.classifyUser(context: "", utterance: "Warum")
        #expect(leer.contains("Gesprächsbeginn"),
                "Ohne Verlauf muss das ausdrücklich dastehen, sonst halluziniert das Modell einen")
    }

    /// Die Auswertung muss unbekannte oder fehlende Statuswerte auf
    /// „keine_frage“ abbilden – ein Fehlalarm ist teurer als eine verpasste
    /// Frage, weil die App dann mitten im Gespräch dazwischenfährt.
    @Test("Auswertung ordnet die Statuswerte richtig zu")
    func parseMapsStatus() {
        #expect(QuestionClassifier.parse("{\"status\":\"frage\",\"eigenstaendig\":\"Was kostet das?\"}")
                == .question(standalone: "Was kostet das?"))
        #expect(QuestionClassifier.parse("{\"status\":\"keine_frage\",\"eigenstaendig\":\"\"}")
                == .notQuestion)
        #expect(QuestionClassifier.parse("{\"status\":\"unvollstaendig\",\"eigenstaendig\":\"\"}")
                == .incomplete)
        #expect(QuestionClassifier.parse("{\"status\":\"quatsch\",\"eigenstaendig\":\"\"}")
                == .failed)
        #expect(QuestionClassifier.parse("") == .failed)
        #expect(QuestionClassifier.parse("kein JSON") == .failed)
        // Abgerissener Strom nach positivem Frühsignal: das Signal gilt.
        #expect(QuestionClassifier.parse("{\"status\":\"fra", earlyDecision: true)
                == .question(standalone: ""))
        // Ein abgerissenes Nein ist nicht eindeutig: Der Status könnte noch
        // "keine_frage" oder "unvollstaendig" geworden sein.
        #expect(QuestionClassifier.parse("{\"status\":\"kei", earlyDecision: false)
                == .notQuestion)
        #expect(QuestionClassifier.parse("{\"status\":\"unv", earlyDecision: false)
                == .incomplete)
    }

    @Test("Aktuelle Äußerung wird aus dem Kontext entfernt")
    func removesCurrentUtteranceFromContext() {
        let context = "Mikrofon: Erst kommt der Import.\nSystemaudio: Und danach?"
        #expect(QuestionClassifier.contextExcludingCurrentUtterance(
            context, utterance: "Und danach?"
        ) == "Mikrofon: Erst kommt der Import.")

        #expect(QuestionClassifier.contextExcludingCurrentUtterance(
            context, utterance: "Was kostet das?"
        ) == context)
    }

    @Test("Niedrige ASR-Sicherheit sperrt nur die Sofortentscheidung")
    func asrConfidenceGatesShortcut() {
        #expect(QuestionClassifier.mayUseHeuristicShortcut(
            questionConfidence: 0.95, certaintyShortcut: 0.95, asrConfidence: 0.9
        ))
        #expect(!QuestionClassifier.mayUseHeuristicShortcut(
            questionConfidence: 0.95, certaintyShortcut: 0.95, asrConfidence: 0.4
        ))
        #expect(QuestionClassifier.mayUseHeuristicShortcut(
            questionConfidence: 0.95, certaintyShortcut: 0.95, asrConfidence: nil
        ))
    }

    @Test("Nur das neueste Klassifikationsticket ist aktuell")
    func sequenceRejectsStaleResults() {
        var sequence = QuestionClassifier.Sequence()
        let first = sequence.register()
        #expect(sequence.isCurrent(first))
        let second = sequence.register()
        #expect(!sequence.isCurrent(first))
        #expect(sequence.isCurrent(second))
    }
}

// MARK: - Messung der Modellstufe gegen das gelabelte Datenset
//
// Läuft nur mit ALFREDHELP_LLM_BENCH=1, weil jede Äußerung einen Modellaufruf
// kostet. Ohne laufendes Ollama passiert nichts – die CI bleibt grün.
//
//     ALFREDHELP_LLM_BENCH=1 ALFREDHELP_BENCH_RUNS=3 \
//       swift test --filter ClassifierStageBenchmarkTests
//
// Gemessen wird ausdrücklich die MODELLSTUFE allein (die Beispiele, die die
// Heuristik weiterreicht) und zusätzlich der volle Pfad. Nur die Modellstufe
// zeigt die Wirkung einer Prompt-Änderung unverdünnt; die Zahlen des vollen
// Pfads sind mit dem bestehenden Bericht vergleichbar.
//
// Mehrere Läufe sind Pflicht: die Frühentscheidung am Tokenstrom macht die
// Stufe lauflabil, eine Verbesserung um 0,005 ist Rauschen.

@Suite("Frageerkennung – Prompt-Messung", .serialized)
struct ClassifierStageBenchmarkTests {

    private static let gate = 0.35
    private static let shortcut = 0.95

    /// Schreibt die Liste der Äußerungen heraus, die Stufe 1 an das Modell
    /// weiterreicht. Läuft ohne Ollama und ist die Brücke zu
    /// `Benchmarks/prompt_probe.py`: das Sondierskript darf die Schwellen
    /// nicht nachprogrammieren, sonst misst es beim nächsten Eingriff in die
    /// Heuristik lautlos die falsche Teilmenge.
    @Test("Modellfälle für das Sondierskript ausschreiben")
    func dumpModelStageCases() throws {
        let examples = try QuestionDataset.load()
        let texts = examples.filter { example in
            if case .question(let confidence) = TextUtilities.assessQuestion(example.text) {
                return confidence >= Self.gate && confidence < Self.shortcut
            }
            return false
        }.map(\.text)
        #expect(texts.count > 50, "Die Modellstufe darf nicht leerlaufen")

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/modellfaelle.json")
        let data = try JSONSerialization.data(
            withJSONObject: texts,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        try? data.write(to: url)
    }

    /// Ergebnis eines einzelnen Durchlaufs über alle Modellfälle.
    private struct RunResult {
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        var trueNegatives = 0
        var latencies: [Double] = []
        /// Text → wurde als Frage entschieden. Für die Stabilitätsanalyse.
        var decisions: [String: Bool] = [:]
        /// Text → umgeschriebene, eigenständige Fassung.
        var rewrites: [String: String] = [:]

        var precision: Double { Double(truePositives) / Double(max(1, truePositives + falsePositives)) }
        var recall: Double { Double(truePositives) / Double(max(1, truePositives + falseNegatives)) }
    }

    @Test("Modellstufe: Präzision, Recall, Fehlalarme, Latenz")
    func stageBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["ALFREDHELP_LLM_BENCH"] == "1" else {
            return   // nur auf Anforderung – die CI hat kein Ollama
        }
        let environment = ProcessInfo.processInfo.environment
        let model = environment["ALFREDHELP_FAST_MODEL"] ?? "gemma3:4b"
        let runs = max(1, Int(environment["ALFREDHELP_BENCH_RUNS"] ?? "3") ?? 3)
        let label = environment["ALFREDHELP_BENCH_LABEL"] ?? "aktuell"

        let client = OllamaClient()
        guard await client.isReachable() else {
            Issue.record("Ollama nicht erreichbar")
            return
        }
        // Modell einmal warmladen, damit der erste Fall die Latenzstatistik
        // nicht verzerrt.
        _ = try? await client.chat(
            model: model,
            messages: [.system("Antworte mit OK."), .user("Bereit?")],
            options: GenerationOptions(temperature: 0, numPredict: 4),
            think: false
        )

        let examples = try QuestionDataset.load()
        // Genau die Fälle, die Stufe 1 an das Modell weiterreicht.
        let modelStage = examples.filter { example in
            if case .question(let confidence) = TextUtilities.assessQuestion(example.text) {
                return confidence >= Self.gate && confidence < Self.shortcut
            }
            return false
        }
        // Was die Heuristik allein schon entscheidet – für die Zahlen des
        // vollen Pfads, ohne dafür noch einmal das Modell zu bemühen.
        var heuristicTP = 0, heuristicFP = 0, heuristicFN = 0, heuristicTN = 0
        var immediateCount = 0
        for example in examples {
            let gold = example.label == "frage"
            var predicted = false
            var handledByModel = false
            if case .question(let confidence) = TextUtilities.assessQuestion(example.text) {
                if confidence >= Self.shortcut { predicted = true; immediateCount += 1 }
                else if confidence >= Self.gate { handledByModel = true }
            }
            if handledByModel { continue }
            if gold && predicted { heuristicTP += 1 }
            if !gold && predicted { heuristicFP += 1 }
            if gold && !predicted { heuristicFN += 1 }
            if !gold && !predicted { heuristicTN += 1 }
        }

        var results: [RunResult] = []
        for _ in 0..<runs {
            var result = RunResult()
            for example in modelStage {
                let gold = example.label == "frage"
                let start = Clock.now()
                let box = EarlyDecisionBox()
                let verdict = await QuestionClassifier.classify(
                    client: client,
                    model: model,
                    context: "Gegenüber: \(example.kontext)",
                    utterance: example.text,
                    onEarlyDecision: { isQuestion in
                        box.record(isQuestion: isQuestion, at: Clock.now())
                    }
                )
                var predicted = false
                var latency = (Clock.now() - start) * 1000
                if let early = box.snapshot() {
                    predicted = early.isQuestion
                    latency = (early.at - start) * 1000
                } else if case .question = verdict {
                    predicted = true
                }
                if case .question(let standalone) = verdict {
                    result.rewrites[example.text] = standalone
                }
                result.decisions[example.text] = predicted
                if gold && predicted { result.truePositives += 1; result.latencies.append(latency) }
                if !gold && predicted { result.falsePositives += 1 }
                if gold && !predicted { result.falseNegatives += 1 }
                if !gold && !predicted { result.trueNegatives += 1 }
            }
            results.append(result)
        }

        // ── Auswertung ──────────────────────────────────────────────────
        // Ein Fall gilt nur dann als sicher richtig, wenn er in ALLEN Läufen
        // richtig lag. Fälle, die zwischen den Läufen kippen, werden getrennt
        // ausgewiesen: sie sind der Rauschanteil, gegen den man eine
        // Prompt-Änderung nicht messen darf.
        var alwaysWrong: [(String, String, Bool)] = []   // Text, Kategorie, Goldwert
        var unstable: [(String, String, Int)] = []       // Text, Kategorie, wie oft „Frage“
        for example in modelStage {
            let gold = example.label == "frage"
            let asQuestion = results.filter { $0.decisions[example.text] == true }.count
            if asQuestion == 0 && gold { alwaysWrong.append((example.text, example.kategorie, gold)) }
            else if asQuestion == runs && !gold { alwaysWrong.append((example.text, example.kategorie, gold)) }
            else if asQuestion != 0 && asQuestion != runs { unstable.append((example.text, example.kategorie, asQuestion)) }
        }

        let precisions = results.map(\.precision)
        let recalls = results.map(\.recall)
        let allLatencies = results.flatMap(\.latencies).sorted()
        let median = allLatencies.isEmpty ? 0 : allLatencies[allLatencies.count / 2]
        let p90 = allLatencies.isEmpty ? 0
            : allLatencies[min(allLatencies.count - 1, Int(Double(allLatencies.count) * 0.9))]

        // Voller Pfad: Heuristik-Entscheidungen plus Modellstufe, gemittelt.
        let fullPrecision = results.map { r in
            Double(heuristicTP + r.truePositives)
                / Double(max(1, heuristicTP + r.truePositives + heuristicFP + r.falsePositives))
        }
        let fullRecall = results.map { r in
            Double(heuristicTP + r.truePositives)
                / Double(max(1, heuristicTP + r.truePositives + heuristicFN + r.falseNegatives))
        }

        func format(_ values: [Double]) -> String {
            let mean = values.reduce(0, +) / Double(values.count)
            return String(format: "%.3f  (min %.3f / max %.3f)", mean, values.min() ?? 0, values.max() ?? 0)
        }
        func mean(_ values: [Int]) -> String {
            String(format: "%.1f", Double(values.reduce(0, +)) / Double(values.count))
        }

        var report = """
        Frageerkennung – Modellstufe (\(model), \(runs) Läufe, Variante „\(label)“)
        Beispiele gesamt : \(examples.count)
        Sofort-Stufe     : \(immediateCount)
        Modell-Stufe     : \(modelStage.count)   (davon Gold=frage: \(modelStage.filter { $0.label == "frage" }.count))
        ─────────────────────────────────────
        Nur Modellstufe
          Precision      : \(format(precisions))
          Recall         : \(format(recalls))
          False Positives: \(mean(results.map(\.falsePositives)))
          False Negatives: \(mean(results.map(\.falseNegatives)))
        Voller Pfad (Heuristik + Modell)
          Precision      : \(format(fullPrecision))
          Recall         : \(format(fullRecall))
        Latenz bis zur Entscheidung
          Median         : \(String(format: "%.0f", median)) ms
          p90            : \(String(format: "%.0f", p90)) ms
        Stabilität
          in allen Läufen falsch : \(alwaysWrong.count)
          zwischen Läufen kippend: \(unstable.count)
        """

        if !alwaysWrong.isEmpty {
            report += "\n\nDurchgehend falsch:\n" + alwaysWrong.map {
                "  · [\($0.1)] \($0.0)  → Gold: \($0.2 ? "frage" : "keine")"
            }.joined(separator: "\n")
        }
        if !unstable.isEmpty {
            report += "\n\nWackelkandidaten (x von \(runs) Läufen „frage“):\n" + unstable.map { entry in
                let gold = modelStage.first(where: { $0.text == entry.0 })?.label ?? "?"
                return "  · [\(entry.1)] \(entry.0)  → \(entry.2)/\(runs), Gold: \(gold)"
            }.joined(separator: "\n")
        }

        // Die Umschreibungen der kurzen Nachfragen sind das zweite Ziel: sie
        // gehen als Frage ins Antwortmodell. „Und danach?“ muss zu einer
        // Frage werden, die für sich steht.
        let elliptical = modelStage.filter { $0.kategorie == "ellipse" || $0.kategorie == "kurzfrage" }
        if !elliptical.isEmpty, let last = results.last {
            report += "\n\nUmschreibungen kurzer Nachfragen (letzter Lauf):\n" + elliptical.map {
                "  · „\($0.text)“ [Kontext: \($0.kontext)]\n      → \(last.rewrites[$0.text] ?? "—")"
            }.joined(separator: "\n")
        }
        print(report)

        let reportURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/frage_promptstufe_report.txt")
        try? report.write(to: reportURL, atomically: true, encoding: .utf8)

        // Absicherung, keine Zielmarke: die Messung soll berichten, nicht
        // beim ersten Ausreißer die Suite abbrechen.
        #expect(precisions.allSatisfy { $0 >= 0.8 })
        #expect(recalls.allSatisfy { $0 >= 0.8 })
    }
}

/// Fängt den Moment der Frühentscheidung threadsicher ab.
private final class EarlyDecisionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (isQuestion: Bool, at: Double)?

    func record(isQuestion: Bool, at: Double) {
        lock.withLock { if value == nil { value = (isQuestion, at) } }
    }

    func snapshot() -> (isQuestion: Bool, at: Double)? {
        lock.withLock { value }
    }
}

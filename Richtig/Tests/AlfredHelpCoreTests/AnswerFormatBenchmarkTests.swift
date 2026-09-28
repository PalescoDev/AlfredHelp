import Testing
import Foundation
@testable import AlfredHelpCore

/// Prüft das zweiteilige Antwortformat für **jedes wählbare Modell**.
///
/// Entscheidend: hier läuft der ausgelieferte Weg – `Prompts.answerSystem`
/// erzeugt den Prompt, `OllamaClient` streamt, `TextUtilities.parseStructuredAnswer`
/// validiert. Ein Nachbau in einer anderen Sprache würde etwas anderes messen
/// als das, was der Nutzer bekommt.
///
/// Läuft nur mit gesetztem `ALFREDHELP_FORMAT_BENCH=1` und einer freien GPU:
///
///     ALFREDHELP_FORMAT_BENCH=1 swift test --filter AnswerFormatBenchmarkTests
@Suite("Antwortformat – alle wählbaren Modelle", .enabled(if: ProcessInfo.processInfo.environment["ALFREDHELP_FORMAT_BENCH"] == "1"))
struct AnswerFormatBenchmarkTests {

    /// Vier Fragen, die typische Fallen für das Format aufspannen: eine mit
    /// naheliegender Aufzählung, eine Ja/Nein-Frage, eine Wissensfrage und eine
    /// Abwägung – letztere verleitet Modelle besonders zu Listen.
    private static let questions: [(frage: String, kontext: String, muss: [String])] = [
        ("Welchen HTTP-Statuscode geben wir zurück, wenn ein Client sein Rate-Limit überschreitet?",
         "Es geht um eine öffentliche REST-API.", ["429"]),
        ("Können wir die Migration auch ohne Wartungsfenster fahren?",
         "Die Umstellung ändert das Datenbankschema.", []),
        ("Was ist der Unterschied zwischen Authentifizierung und Autorisierung?",
         "Ein neuer Kollege wird eingearbeitet.", []),
        ("Sollten wir auf Kubernetes umsteigen oder bei den virtuellen Maschinen bleiben?",
         "Wir betreiben aktuell zwölf Dienste auf sechs VMs.", [])
    ]

    private struct Outcome {
        var model = ""
        var schemaFound = 0
        var spokenWords: [Int] = []
        var speakable = 0          // ohne Aufzählungen, Sternchen, Überschriften
        var detailsPresent = 0
        var coverage: [Double] = []
        var failures = 0
        var sample = ""

        var runs: Int { spokenWords.count }
        var averageWords: Double {
            spokenWords.isEmpty ? 0 : Double(spokenWords.reduce(0, +)) / Double(spokenWords.count)
        }
        var longestSpoken: Int { spokenWords.max() ?? 0 }
    }

    /// Enthält der Vorlesetext etwas, das man nicht aussprechen kann?
    private func isSpeakable(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("•")
                || trimmed.hasPrefix("#") || trimmed.first?.isNumber == true
                && trimmed.dropFirst().first == "." {
                return false
            }
        }
        return !text.contains("**") && !text.contains("---MEHR---")
    }

    @Test("Jedes wählbare Modell liefert vorlesbaren Kurzteil und Langfassung")
    func allModelsProduceBothParts() async throws {
        let client = OllamaClient()
        guard await client.isReachable() else {
            Issue.record("Ollama nicht erreichbar – Test übersprungen")
            return
        }
        let installed = Set((try? await client.installedModels())?.map(\.name) ?? [])
        let candidates = ModelCatalog.profiles.map(\.name).filter { installed.contains($0) }
        guard !candidates.isEmpty else {
            Issue.record("Keines der wählbaren Modelle installiert")
            return
        }

        let system = Prompts.answerSystem(
            language: .german, conversationLanguage: "Englisch", profile: ""
        )

        var results: [Outcome] = []
        for model in candidates {
            var outcome = Outcome(model: model)
            // Aufwärmen, damit die Ladezeit nicht in die erste Messung fällt.
            _ = try? await client.chat(
                model: model,
                messages: [.system("Antworte mit OK."), .user("Bereit?")],
                options: GenerationOptions(temperature: 0, numPredict: 4),
                think: modelSupportsThinking(model) ? false : nil
            )

            for question in Self.questions {
                var accumulated = ""
                do {
                    for try await chunk in client.chatStream(
                        model: model,
                        messages: [
                            .system(system),
                            .user(Prompts.answerUser(
                                memory: "", recent: question.kontext, question: question.frage
                            ))
                        ],
                        options: GenerationOptions(
                            temperature: 0, numPredict: 420, numCtx: 8192, seed: 7
                        ),
                        think: modelSupportsThinking(model) ? false : nil
                    ) {
                        accumulated += chunk.text
                    }
                } catch {
                    outcome.failures += 1
                    continue
                }

                let cleaned = TextUtilities.stripThinking(accumulated)
                let parts = TextUtilities.parseStructuredAnswer(cleaned)

                if (try? JSONDecoder().decode(
                    StructuredAnswer.self, from: Data(cleaned.utf8)
                )) != nil { outcome.schemaFound += 1 }
                outcome.spokenWords.append(parts.spoken.split(whereSeparator: \.isWhitespace).count)
                if isSpeakable(parts.spoken) { outcome.speakable += 1 }
                if !parts.details.isEmpty { outcome.detailsPresent += 1 }
                if !question.muss.isEmpty {
                    let whole = (parts.spoken + " " + parts.details).lowercased()
                    let hits = question.muss.filter { whole.contains($0.lowercased()) }.count
                    outcome.coverage.append(Double(hits) / Double(question.muss.count))
                }
                if outcome.sample.isEmpty { outcome.sample = parts.spoken }
            }
            results.append(outcome)

            // Speicher freigeben, sonst verdrängen sich die Modelle gegenseitig.
            _ = try? await client.chat(
                model: model, messages: [],
                options: GenerationOptions(numPredict: 1), keepAlive: "0"
            )
        }

        // MARK: Ausgabe
        print("\nAntwortformat je Modell (\(Self.questions.count) Fragen, "
              + "ausgelieferter Prompt und Aufteilung)")
        print(String(repeating: "─", count: 92))
        print(String(
            format: "%-20@ %7@ %10@ %10@ %9@ %8@",
            "Modell" as NSString, "Schema" as NSString, "vorlesbar" as NSString,
            "Langteil" as NSString, "Ø Wörter" as NSString, "max" as NSString
        ))
        print(String(repeating: "─", count: 92))
        for outcome in results {
            print(String(
                format: "%-20@ %5d/%d %8d/%d %8d/%d %9.1f %8d",
                outcome.model as NSString,
                outcome.schemaFound, outcome.runs,
                outcome.speakable, outcome.runs,
                outcome.detailsPresent, outcome.runs,
                outcome.averageWords, outcome.longestSpoken
            ))
        }
        print(String(repeating: "─", count: 92))
        for outcome in results {
            print("· \(outcome.model): „\(outcome.sample.prefix(96))“")
        }

        // MARK: Zusicherungen
        for outcome in results {
            #expect(outcome.failures == 0, "\(outcome.model): \(outcome.failures) Aufrufe fehlgeschlagen")
            #expect(
                outcome.schemaFound == outcome.runs,
                "\(outcome.model): JSON-Schema fehlt bei \(outcome.runs - outcome.schemaFound) von \(outcome.runs)"
            )
            #expect(
                outcome.detailsPresent == outcome.runs,
                "\(outcome.model): Langfassung fehlt bei \(outcome.runs - outcome.detailsPresent) von \(outcome.runs)"
            )
            #expect(
                outcome.speakable == outcome.runs,
                "\(outcome.model): Kurzteil nicht vorlesbar bei \(outcome.runs - outcome.speakable) von \(outcome.runs)"
            )
            #expect(
                outcome.longestSpoken <= 70,
                "\(outcome.model): längster Vorlesetext \(outcome.longestSpoken) Wörter"
            )
            if !outcome.coverage.isEmpty {
                let mean = outcome.coverage.reduce(0, +) / Double(outcome.coverage.count)
                #expect(mean >= 0.9, "\(outcome.model): Abdeckung \(mean)")
            }
        }
    }
}

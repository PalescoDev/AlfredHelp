import Foundation
import Testing
@testable import AlfredHelpCore

@Suite("Relevanter Gesprächskontext")
struct RelevantConversationContextTests {

    private func utterance(
        _ text: String,
        id: UUID = UUID(),
        start: Double = 0,
        end: Double = 1
    ) -> Utterance {
        Utterance(id: id, source: .system, original: text, startSeconds: start, endSeconds: end)
    }

    @Test("Ältere passende Fakten ergänzen den aktuellen Verlauf")
    func includesRelevantOlderStatement() async {
        let memory = ConversationMemory(client: OllamaClient())
        await memory.add(utterance("Der Rollout für das Kundenportal wurde auf Donnerstag verschoben."))
        for index in 1...8 {
            await memory.add(utterance("Unabhängige Wortmeldung Nummer \(index)."))
        }

        let context = await memory.relevantTranscript(
            for: "Wann startet der Rollout für das Kundenportal?",
            recentTurns: 3,
            tokenBudget: 300
        )

        #expect(context.contains("Donnerstag"))
        #expect(context.contains("Nummer 8"))
        #expect(!context.contains("Nummer 4"))
    }

    @Test("Namen und Zahlen holen das richtige alte Detail zurück")
    func prioritizesNamesAndNumbers() async {
        let memory = ConversationMemory(client: OllamaClient())
        await memory.add(utterance("Das Angebot für Acme umfasst 120 Lizenzen."))
        await memory.add(utterance("Das Angebot für Globex umfasst 80 Lizenzen."))
        for index in 1...6 {
            await memory.add(utterance("Der allgemeine Projektstatus ist unverändert \(index)."))
        }

        let context = await memory.relevantTranscript(
            for: "Gilt das Acme-Angebot weiterhin für 120 Lizenzen?",
            recentTurns: 2,
            tokenBudget: 55,
            maximumOlderTurns: 1
        )

        #expect(context.contains("Acme"))
        #expect(context.contains("120 Lizenzen"))
        #expect(!context.contains("Globex"))
    }

    @Test("Die separat übergebene Frage wird nicht im Kontext dupliziert")
    func omitsQuestionItself() async {
        let memory = ConversationMemory(client: OllamaClient())
        let questionID = UUID()
        await memory.add(utterance("Der Termin wurde auf Freitag gelegt."))
        await memory.add(utterance("Wann ist der Termin?", id: questionID))

        let context = await memory.relevantTranscript(
            for: "Wann ist der Termin?",
            recentTurns: 4,
            tokenBudget: 100,
            excludingUtteranceIDs: [questionID]
        )

        #expect(context.contains("Freitag"))
        #expect(!context.contains("Wann ist der Termin?"))
    }

    @Test("Gleichlautende frühere Aussage bleibt als Beleg erhalten")
    func excludesByIdentityNotText() async {
        let memory = ConversationMemory(client: OllamaClient())
        let currentID = UUID()
        await memory.add(utterance("Wann ist der Termin?"))
        await memory.add(utterance("Der Termin ist Freitag."))
        await memory.add(utterance("Wann ist der Termin?", id: currentID))

        let context = await memory.relevantTranscript(
            for: "Wann ist der Termin?",
            recentTurns: 4,
            tokenBudget: 100,
            excludingUtteranceIDs: [currentID]
        )

        #expect(context.contains("Der Termin ist Freitag."))
        #expect(context.components(separatedBy: "Wann ist der Termin?").count == 2)
    }

    @Test("Zusammengesetzte Fragmente werden nicht als Kontext dupliziert")
    func excludesStitchedFragmentsFromClassificationContext() async {
        let memory = ConversationMemory(client: OllamaClient())
        let currentID = UUID()
        await memory.add(utterance("Der Stand ist offen.", start: 0, end: 1))
        await memory.add(utterance("Und wann", start: 2, end: 3))
        await memory.add(utterance("genau?", id: currentID, start: 3.2, end: 4))

        let context = await memory.classificationContext(
            target: "Und wann genau?",
            currentUtteranceID: currentID,
            turns: 8,
            tokenBudget: 100
        )

        #expect(context.contains("Der Stand ist offen."))
        #expect(!context.contains("Und wann"))
        #expect(!context.contains("genau?"))
    }

    @Test("Neue Zusammenfassungslisten beleben entfernte Fakten nicht wieder")
    func updatedSummaryListIsAuthoritative() {
        #expect(ConversationMemory.updatedList([" Neuer Stand ", "neuer stand", ""], limit: 14)
                == ["Neuer Stand"])
        #expect(ConversationMemory.updatedList([], limit: 14).isEmpty)
    }

    @Test("Das Token-Budget bleibt auch mit relevanten Alt-Aussagen bindend")
    func respectsTokenBudget() async {
        let memory = ConversationMemory(client: OllamaClient())
        for index in 0..<12 {
            await memory.add(utterance("Migration Kundenportal Detail \(index) mit zusätzlichem Erklärtext."))
        }

        let short = await memory.relevantTranscript(
            for: "Was ist der Stand der Migration des Kundenportals?",
            recentTurns: 4,
            tokenBudget: 35
        )
        let long = await memory.relevantTranscript(
            for: "Was ist der Stand der Migration des Kundenportals?",
            recentTurns: 4,
            tokenBudget: 350
        )

        #expect(short.count < long.count)
        #expect(TextUtilities.estimatedTokens(short) <= 35)
    }
}

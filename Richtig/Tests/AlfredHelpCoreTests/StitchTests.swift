import Testing
import Foundation
@testable import AlfredHelpCore

/// Lädt `Benchmarks/satzzusammenfuehrung.json` – der Datensatz, an dem die
/// Zusammenführung gemessen wird.
struct StitchDataset {

    struct Part: Decodable {
        let text: String
        let start: Double
        let ende: Double
    }

    struct Sequence: Decodable {
        let id: String
        let kategorie: String
        let lang: String
        let teile: [Part]
        let erwartet: String
        /// Der Teil des erwarteten Textes, der beantwortet werden soll.
        /// Fehlt er, ist es der ganze erwartete Text.
        let frage: String?
        let label: String       // frage | keine
    }

    struct File: Decodable {
        let sequenzen: [Sequence]
    }

    static func load() throws -> [Sequence] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AlfredHelpCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Paketwurzel
            .appendingPathComponent("Benchmarks/satzzusammenfuehrung.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(File.self, from: data).sequenzen
    }

    /// Spielt eine Sequenz durch den Stitcher – genau so, wie die Pipeline es
    /// tut, nur ohne Spracherkennung, ohne Modell und ohne Actor.
    ///
    /// Die monotone Uhr wird mit dem Ende des jeweiligen Teils gleichgesetzt.
    /// In der laufenden App ist das `capturedAt`, also der Moment, in dem das
    /// letzte Erkenner-Ereignis dieser Äußerung ankam – der Unterschied zur
    /// Zeitachse des Erkenners ist die Erkennungslatenz, und die ist für beide
    /// Teile dieselbe und fällt aus der Differenz heraus.
    static func replay(
        _ sequence: Sequence,
        options: UtteranceStitcher.Options = UtteranceStitcher.Options()
    ) -> UtteranceStitcher.Outcome {
        var stitcher = UtteranceStitcher(options: options)
        var last: UtteranceStitcher.Outcome = .nothing(assessed: "")
        for part in sequence.teile {
            let utterance = Utterance(
                source: .system,
                original: part.text,
                startSeconds: part.start,
                endSeconds: part.ende,
                capturedAt: part.ende
            )
            last = stitcher.offer(utterance, now: part.ende)
        }
        return last
    }

    static func assessedText(of outcome: UtteranceStitcher.Outcome) -> String {
        switch outcome {
        case .nothing(let text), .waiting(let text): return text
        case .question(let text, _, _): return text
        }
    }

    /// Welches Urteil dabei herauskommt – „frage“, sobald die Heuristik über
    /// der Prüfschwelle liegt, sonst „keine“.
    static func predictedLabel(of outcome: UtteranceStitcher.Outcome) -> String {
        if case .question(_, _, let confidence) = outcome, confidence >= 0.35 {
            return "frage"
        }
        return "keine"
    }
}

/// Misst die Zusammenführung gegen den Datensatz. Läuft bei jedem `swift test`.
///
/// Zwei Dinge müssen gelten:
/// - Jede Sequenz muss am Ende genau den Text zur Bewertung stellen, der in
///   `erwartet` steht – zusammengefügt, wo sie zusammengehört, und getrennt,
///   wo nicht.
/// - Das Urteil darüber muss zum Goldlabel passen. Zusammenführen darf keine
///   Frage erfinden, wo keine war.
@Suite("Satzzusammenführung – Benchmark")
struct StitchBenchmarkTests {

    @Test("Zusammenbau und Urteil über den ganzen Datensatz")
    func benchmark() throws {
        let sequences = try StitchDataset.load()
        #expect(sequences.count >= 40)

        var wrongText: [String] = []
        var wrongLabel: [String] = []
        var wrongFocus: [String] = []
        var byCategory: [String: (total: Int, ok: Int)] = [:]

        for sequence in sequences {
            let outcome = StitchDataset.replay(sequence)
            let assembled = StitchDataset.assessedText(of: outcome)
            let label = StitchDataset.predictedLabel(of: outcome)

            var ok = true
            if assembled != sequence.erwartet {
                wrongText.append("\(sequence.id): „\(assembled)“ statt „\(sequence.erwartet)“")
                ok = false
            }
            if label != sequence.label {
                wrongLabel.append("\(sequence.id): \(label) statt \(sequence.label)")
                ok = false
            }
            if let expected = sequence.frage,
               case .question(_, let question, _) = outcome,
               question != expected {
                wrongFocus.append("\(sequence.id): „\(question)“ statt „\(expected)“")
                ok = false
            }
            var entry = byCategory[sequence.kategorie] ?? (0, 0)
            entry.total += 1
            if ok { entry.ok += 1 }
            byCategory[sequence.kategorie] = entry
        }

        print("── Satzzusammenführung (Sequenzen je Kategorie) ──")
        for key in byCategory.keys.sorted() {
            let entry = byCategory[key]!
            print(String(format: "%-18@ %2d / %2d", key as NSString, entry.ok, entry.total))
        }
        if !wrongText.isEmpty { print("Falsch zusammengesetzt:\n  " + wrongText.joined(separator: "\n  ")) }
        if !wrongLabel.isEmpty { print("Falsches Urteil:\n  " + wrongLabel.joined(separator: "\n  ")) }
        if !wrongFocus.isEmpty { print("Falscher Fragefokus:\n  " + wrongFocus.joined(separator: "\n  ")) }

        #expect(wrongText.isEmpty, "Sequenzen falsch zusammengesetzt")
        #expect(wrongLabel.isEmpty, "Urteil weicht vom Goldlabel ab")
        #expect(wrongFocus.isEmpty, "Beantwortet würde der falsche Teil")
    }

    /// Die Messung, aus der die beiden Fristen stammen.
    ///
    /// Beide Fenster werden über den ganzen Datensatz durchgefahren und für
    /// jeden Wert gezählt, wie viele Sequenzen richtig herauskommen. Gesucht
    /// ist das Plateau: der Bereich, in dem alle echten Fortsetzungen gefunden
    /// und noch keine fremden Sätze angeklebt werden. Der ausgelieferte Wert
    /// muss darin liegen – und zwar mit Abstand zu beiden Rändern, weil die
    /// Ränder von einzelnen Beispielen abhängen und nicht von einem Gesetz.
    @Test("Fenster-Messung: wo liegt das Plateau?")
    func windowSweep() throws {
        let sequences = try StitchDataset.load()

        func correct(_ options: UtteranceStitcher.Options) -> Int {
            sequences.filter {
                StitchDataset.assessedText(of: StitchDataset.replay($0, options: options))
                    == $0.erwartet
            }.count
        }

        let defaults = UtteranceStitcher.Options()
        let total = sequences.count

        print("── Lange Frist (abgerissene Bruchstücke), Sekunden ──")
        var loosePlateau: [Double] = []
        for gap in [0.5, 0.8, 1.0, 1.2, 1.4, 1.8, 2.2, 2.6, 3.0, 3.4, 4.0, 5.0, 6.5, 8.0] {
            var options = defaults
            options.maximumGapSeconds = gap
            let hits = correct(options)
            if hits == total { loosePlateau.append(gap) }
            print(String(format: "  %.1f s → %2d / %2d", gap, hits, total))
        }

        print("── Kurze Frist (Trennung ohne Sprechpause), Sekunden ──")
        var tightPlateau: [Double] = []
        for gap in [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0, 1.2, 1.4, 2.0, 3.0] {
            var options = defaults
            options.sentenceEndGapSeconds = gap
            let hits = correct(options)
            if hits == total { tightPlateau.append(gap) }
            print(String(format: "  %.1f s → %2d / %2d", gap, hits, total))
        }

        print("Plateau lang : \(loosePlateau)")
        print("Plateau kurz : \(tightPlateau)")

        #expect(loosePlateau.contains(defaults.maximumGapSeconds),
                "Die ausgelieferte lange Frist liegt nicht im gemessenen Plateau")
        #expect(tightPlateau.contains(defaults.sentenceEndGapSeconds),
                "Die ausgelieferte kurze Frist liegt nicht im gemessenen Plateau")
        // Ein Plateau aus einem einzigen Wert wäre kein Plateau, sondern Zufall.
        #expect(loosePlateau.count >= 3)
        #expect(tightPlateau.count >= 3)
    }
}

@Suite("Satzzusammenführung – Verbinden")
struct JoinTests {

    @Test("Wiederholter Anfang wird nicht verdoppelt")
    func removesRepeatedHead() {
        #expect(UtteranceStitcher.join(
            "The question is whether the",
            "The question is whether the rollout is on track?"
        ) == "The question is whether the rollout is on track?")
    }

    @Test("Ein wiederholtes Inhaltswort am Stoß fällt weg")
    func removesRepeatedContentWord() {
        #expect(UtteranceStitcher.join(
            "Wie lange dauert eine vollständige",
            "vollständige Neuindizierung auf dem Produktivsystem?"
        ) == "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem?")
    }

    @Test("Ein wiederholtes Funktionswort bleibt stehen")
    func keepsRepeatedFunctionWord() {
        // „das“ steht hier zweimal zu Recht: einmal als Objekt, einmal als
        // Subjekt des nächsten Satzes. Ein Abzug machte daraus „Wir machen das
        // ist der Plan“.
        #expect(UtteranceStitcher.join("Wir machen das", "Das ist der Plan.")
                == "Wir machen das Das ist der Plan.")
    }

    @Test("Sagt der zweite Teil nichts Neues, überlebt sein Satzzeichen")
    func keepsTerminatorOfRedundantTail() {
        #expect(UtteranceStitcher.join("Was macht ihr dann", "Was macht ihr dann?")
                == "Was macht ihr dann?")
        #expect(UtteranceStitcher.join("Das passt so.", "Das passt so")
                == "Das passt so.")
    }

    @Test("Kein doppeltes Leerzeichen, auch mit Rand")
    func normalizesWhitespace() {
        #expect(UtteranceStitcher.join("  Der Rollout ist  ", "  für März geplant. ")
                == "Der Rollout ist für März geplant.")
        #expect(!UtteranceStitcher.join("Der Rollout ist ", " für März geplant.").contains("  "))
    }

    @Test("Interpunktion des ersten Teils bleibt unangetastet")
    func keepsHeadPunctuation() {
        #expect(UtteranceStitcher.join("Wenn das nicht klappt,", "was macht ihr dann?")
                == "Wenn das nicht klappt, was macht ihr dann?")
    }

    @Test("Leere Stücke ändern nichts")
    func handlesEmptyParts() {
        #expect(UtteranceStitcher.join("", "Wie geht es weiter?") == "Wie geht es weiter?")
        #expect(UtteranceStitcher.join("Wie geht es weiter?", "   ") == "Wie geht es weiter?")
    }

    @Test("Der Assembler zieht die Wiederholung schon beim Zusammenbau ab")
    func assemblerRemovesRepeat() {
        let assembler = UtteranceAssembler(source: .system)
        func event(_ text: String) -> TranscriptEvent {
            TranscriptEvent(
                source: .system, text: text, isFinal: true,
                startSeconds: 0, endSeconds: 1, confidence: nil, capturedAt: 0
            )
        }
        #expect(assembler.append(event("The question is whether the")).isEmpty)
        let produced = assembler.append(event("The question is whether the rollout is on track."))
        #expect(produced.first?.original == "The question is whether the rollout is on track.")
    }
}

@Suite("Satzzusammenführung – Fenster und Zustand")
struct StitcherStateTests {

    private func utterance(
        _ text: String,
        from start: Double,
        to end: Double,
        source: AudioSourceKind = .system
    ) -> Utterance {
        Utterance(
            source: source,
            original: text,
            startSeconds: start,
            endSeconds: end,
            capturedAt: end
        )
    }

    @Test("Ein abgerissenes Bruchstück wartet und antwortet nicht")
    func holdsFragment() {
        var stitcher = UtteranceStitcher()
        let outcome = stitcher.offer(utterance("Die Frage ist ob wir mit dem", from: 0, to: 2), now: 2)
        #expect(outcome == .waiting(assessed: "Die Frage ist ob wir mit dem"))
        #expect(stitcher.pendingText(for: .system) == "Die Frage ist ob wir mit dem")
    }

    @Test("Nach zu langer Stille wird nicht mehr angeklebt")
    func dropsStaleFragment() {
        var stitcher = UtteranceStitcher()
        _ = stitcher.offer(utterance("Wenn wir das so machen und dann", from: 0, to: 2), now: 2)
        let outcome = stitcher.offer(utterance("Wie sieht euer Zeitplan aus?", from: 9, to: 11), now: 11)
        #expect(StitchDataset.assessedText(of: outcome) == "Wie sieht euer Zeitplan aus?")
    }

    @Test("Die kurze Frist gilt nur ohne Sprechpause")
    func tightWindow() {
        // Ohne Pause: der Erkenner hat mitten im Satz getrennt.
        var joined = UtteranceStitcher()
        _ = joined.offer(utterance("Wie lange dauert eine vollständige", from: 0, to: 2), now: 2)
        let merged = joined.offer(
            utterance("Neuindizierung auf dem Produktivsystem?", from: 2.1, to: 4.4), now: 4.4
        )
        #expect(StitchDataset.assessedText(of: merged)
                == "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem?")

        // Mit Pause: zwei Sätze, die nichts miteinander zu tun haben.
        var separate = UtteranceStitcher()
        _ = separate.offer(utterance("Das war es von meiner Seite", from: 0, to: 2), now: 2)
        let alone = separate.offer(
            utterance("Wie sieht das bei euch aus?", from: 3.4, to: 5), now: 5
        )
        #expect(StitchDataset.assessedText(of: alone) == "Wie sieht das bei euch aus?")
    }

    @Test("Ohne brauchbare Zeitachse wird nur das sichtbar Abgerissene verbunden")
    func withoutTimeline() {
        // Sichtbar abgerissen: die Wanduhr allein genügt.
        var loose = UtteranceStitcher()
        _ = loose.offer(utterance("Der Rollout ist", from: 0, to: 0), now: 100)
        let merged = loose.offer(utterance("für März geplant.", from: 0, to: 0), now: 101)
        #expect(StitchDataset.assessedText(of: merged) == "Der Rollout ist für März geplant.")

        // Nicht abgerissen: ohne akustischen Beleg wird nichts verbunden.
        var tight = UtteranceStitcher()
        _ = tight.offer(utterance("Wir haben gestern die Zahlen", from: 0, to: 0), now: 100)
        let alone = tight.offer(utterance("noch einmal geprüft.", from: 0, to: 0), now: 100.2)
        #expect(StitchDataset.assessedText(of: alone) == "noch einmal geprüft.")
    }

    @Test("Drei Teile wachsen zu einem Satz zusammen")
    func threeParts() {
        var stitcher = UtteranceStitcher()
        _ = stitcher.offer(utterance("Wie lange dauert eine vollständige", from: 0, to: 1.9), now: 1.9)
        _ = stitcher.offer(utterance("Neuindizierung auf dem", from: 2.0, to: 3.1), now: 3.1)
        let outcome = stitcher.offer(utterance("Produktivsystem?", from: 3.3, to: 4.2), now: 4.2)
        #expect(StitchDataset.assessedText(of: outcome)
                == "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem?")
    }

    @Test("Eine endlose Kette wird gekappt")
    func stopsAfterTooManyParts() {
        var stitcher = UtteranceStitcher()
        var time = 0.0
        for _ in 0..<6 {
            _ = stitcher.offer(utterance("und noch etwas mit", from: time, to: time + 1), now: time + 1)
            time += 1.2
        }
        let held = stitcher.pendingText(for: .system) ?? ""
        #expect(held.split(separator: " ").count <= 4 * 4)
    }

    @Test("Die Quellen kommen sich nicht in die Quere")
    func sourcesAreIndependent() {
        var stitcher = UtteranceStitcher()
        _ = stitcher.offer(utterance("Die Frage ist ob wir mit dem", from: 0, to: 2), now: 2)
        let microphone = stitcher.offer(
            utterance("Ja, das sehe ich auch so.", from: 2.1, to: 3.5, source: .microphone),
            now: 3.5
        )
        #expect(StitchDataset.assessedText(of: microphone) == "Ja, das sehe ich auch so.")
        #expect(stitcher.pendingText(for: .system) == "Die Frage ist ob wir mit dem")
    }

    @Test("Der offene Rest hinter einer fertigen Frage geht nicht verloren")
    func keepsTailAfterQuestion() {
        var stitcher = UtteranceStitcher()
        let first = stitcher.offer(
            utterance("Wie sieht euer Rollback aus? Und wie lange dauert das", from: 0, to: 2.6),
            now: 2.6
        )
        // Die fertige Frage wird sofort beantwortet – kein Warten.
        guard case .question(_, let question, _) = first else {
            Issue.record("Die fertige Frage hätte sofort beantwortet werden müssen")
            return
        }
        #expect(question == "Wie sieht euer Rollback aus?")
        // Und der Rest wartet trotzdem auf seine Fortsetzung.
        #expect(stitcher.pendingText(for: .system) == "Und wie lange dauert das")

        let second = stitcher.offer(utterance("ganze dann insgesamt?", from: 3.4, to: 5.2), now: 5.2)
        #expect(StitchDataset.assessedText(of: second)
                == "Und wie lange dauert das ganze dann insgesamt?")
    }

    @Test("Eine von Hand beantwortete Äußerung löst ihren Halt auf")
    func manualAnswerClearsHold() {
        var stitcher = UtteranceStitcher()
        let fragment = utterance("Die Frage ist ob wir mit dem", from: 0, to: 2)
        _ = stitcher.offer(fragment, now: 2)
        stitcher.forget(utteranceID: fragment.id)
        #expect(stitcher.pendingText(for: .system) == nil)
    }
}

/// Der Weg durch die echte Pipeline – ohne Ollama, ohne Spracherkennung.
/// Der Modellname ist erfunden; entscheidend ist, **welche** Frage die
/// Antwortkarte trägt, nicht ob die Generierung danach gelingt.
@Suite("Pipeline – zerfallene Frage")
struct PipelineStitchTests {

    private final class EventBox: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [PipelineEvent] = []
        func add(_ event: PipelineEvent) { lock.withLock { events.append(event) } }
        func startedCards() -> [AnswerCard] {
            lock.withLock {
                events.compactMap { if case .answerStarted(let card) = $0 { return card } else { return nil } }
            }
        }
    }

    private func makePipeline() async -> (AssistantPipeline, EventBox) {
        var settings = AppSettings()
        settings.translationEnabled = false
        settings.qualityModel = "testmodell"
        settings.fastModel = ""          // kein Klassifikator: nur die Heuristik zählt
        let pipeline = AssistantPipeline(client: OllamaClient(), settings: settings)
        let box = EventBox()
        await pipeline.setEmitter { event, _ in box.add(event) }
        return (pipeline, box)
    }

    private func utterance(_ text: String, from start: Double, to end: Double) -> Utterance {
        Utterance(
            source: .system, original: text,
            startSeconds: start, endSeconds: end, capturedAt: Clock.now()
        )
    }

    @Test("Die zusammengesetzte Frage wird beantwortet, nicht ihr letztes Drittel")
    func answersTheWholeQuestion() async {
        let (pipeline, box) = await makePipeline()
        await pipeline.ingest(utterance("Wie lange dauert eine vollständige", from: 0, to: 1.9))
        await pipeline.ingest(utterance("Neuindizierung auf dem Produktivsystem?", from: 2.0, to: 4.4))

        let cards = box.startedCards()
        #expect(cards.count == 1)
        #expect(cards.first?.question
                == "Wie lange dauert eine vollständige Neuindizierung auf dem Produktivsystem?")
    }

    @Test("Ohne Fortsetzung bleibt das Bruchstück unbeantwortet")
    func doesNotAnswerFragments() async {
        let (pipeline, box) = await makePipeline()
        await pipeline.ingest(utterance("Die Frage ist ob wir mit dem", from: 0, to: 2))
        #expect(box.startedCards().isEmpty)
    }

    @Test("Aus einem Block mit Aussage und Frage wird nur die Frage beantwortet")
    func answersOnlyTheQuestionSentence() async {
        let (pipeline, box) = await makePipeline()
        await pipeline.ingest(utterance(
            "Wir haben das gestern ausgerollt. Wie lange dauert die Neuindizierung?",
            from: 0, to: 4
        ))
        #expect(box.startedCards().first?.question == "Wie lange dauert die Neuindizierung?")
    }
}

@Suite("Fragefokus in mehrsätzigen Äußerungen")
struct QuestionFocusTests {

    @Test("Nur der fragende Satz wird beantwortet")
    func picksQuestionSentence() {
        #expect(TextUtilities.questionFocus(
            "Wir haben das gestern ausgerollt. Wie lange dauert die Neuindizierung?"
        ) == "Wie lange dauert die Neuindizierung?")
    }

    @Test("Eine Frage in der Mitte findet sich auch")
    func picksMiddleSentence() {
        #expect(TextUtilities.questionFocus(
            "Das lief soweit gut. Habt ihr das auch schon getestet? Ich frage nur."
        ) == "Habt ihr das auch schon getestet?")
    }

    @Test("Mehrere Fragen bleiben beide stehen")
    func keepsBothQuestions() {
        #expect(TextUtilities.questionFocus(
            "Wie teuer ist das? Und wie lange dauert die Einführung?"
        ) == "Wie teuer ist das? Und wie lange dauert die Einführung?")
    }

    @Test("Eine einzelne Äußerung bleibt unverändert")
    func leavesSingleSentence() {
        #expect(TextUtilities.questionFocus("Wie lange dauert das?") == "Wie lange dauert das?")
        #expect(TextUtilities.questionFocus("Das passt so für mich.") == "Das passt so für mich.")
    }

    @Test("Ohne erkennbare Frage bleibt der ganze Text stehen")
    func fallsBackToFullText() {
        let text = "Das lief gut. Wir machen nächste Woche weiter."
        #expect(TextUtilities.questionFocus(text) == text)
    }
}

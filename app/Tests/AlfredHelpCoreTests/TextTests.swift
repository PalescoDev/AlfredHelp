import Testing
import Foundation
@testable import AlfredHelpCore

@Suite("Satzsegmentierung")
struct SentenceTests {

    @Test("Trennt an Satzzeichen und behält den Rest")
    func splitsSentences() {
        let (complete, remainder) = TextUtilities.splitSentences(
            "Das ist der erste Satz. Und hier der zweite! Der dritte ist noch nicht"
        )
        #expect(complete == ["Das ist der erste Satz.", "Und hier der zweite!"])
        #expect(remainder == "Der dritte ist noch nicht")
    }

    @Test("Abkürzungen beenden keinen Satz")
    func keepsAbbreviations() {
        let (complete, remainder) = TextUtilities.splitSentences("Wir nutzen z.B. Postgres")
        #expect(complete.isEmpty)
        #expect(remainder == "Wir nutzen z.B. Postgres")
    }

    @Test("Zahlen mit Punkt beenden keinen Satz")
    func keepsOrdinals() {
        let (complete, _) = TextUtilities.splitSentences("Der Termin ist am 3. März geplant")
        #expect(complete.isEmpty)
    }

    @Test("Fragezeichen am Ende schließt den Satz ab")
    func closesOnQuestionMark() {
        let (complete, remainder) = TextUtilities.splitSentences("Wie lange dauert das?")
        #expect(complete == ["Wie lange dauert das?"])
        #expect(remainder.isEmpty)
    }

    @Test("Anführungszeichen nach dem Satzzeichen gehören noch dazu")
    func keepsTrailingQuotes() {
        let (complete, _) = TextUtilities.splitSentences("Er sagte \"das passt.\" Danach ging er")
        #expect(complete.first == "Er sagte \"das passt.\"")
    }
}

@Suite("Frageerkennung (Heuristik)")
struct QuestionHeuristicTests {

    @Test("Eindeutige Fragen liegen hoch", arguments: [
        "How long does a full reindex take?",
        "Was kostet die Lizenz im Jahr?",
        "Pourquoi est-ce que le service est tombé ?",
        "¿Cuándo podemos firmar el contrato?",
        "Can you walk us through the architecture?"
    ])
    func detectsQuestions(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.6)
    }

    @Test("Aussagen liegen niedrig", arguments: [
        "I'll run it on staging tonight and report back tomorrow.",
        "Der Dienst war etwa vierzig Minuten ausgefallen.",
        "Both runs gave nearly identical numbers, so I trust the result.",
        "Genau, das passt zu unserer Dokumentation."
    ])
    func ignoresStatements(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35)
    }

    @Test("Bitten ohne Fragezeichen werden erkannt")
    func detectsRequests() {
        #expect(TextUtilities.questionLikelihood("Tell me about a time you debugged consumer lag.") >= 0.35)
        #expect(TextUtilities.questionLikelihood("Erkläre uns kurz den Unterschied.") >= 0.35)
    }

    @Test("Kurze Einwürfe lösen nichts aus")
    func ignoresBackchannels() {
        #expect(TextUtilities.questionLikelihood("Ja genau") < 0.3)
        #expect(TextUtilities.questionLikelihood("Okay") < 0.3)
    }

    @Test("Füllwörter am Satzanfang verdecken die Frage nicht", arguments: [
        "Also, wie machen wir jetzt weiter",
        "Ja und was bedeutet das für den Zeitplan?",
        "Okay, und wer übernimmt dann das Testing",
        "Sag mal, was kostet das Ganze",
        "So, and what happens after the rollout",
        "Well, how does the failover work then",
        "Right, so what's the timeline for phase two"
    ])
    func detectsFillerQuestions(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.6, "\(text)")
    }

    @Test("Bestätigungs-Anhängsel ohne Fragezeichen werden erkannt", arguments: [
        "Das schaffen wir bis Freitag, oder",
        "Die Schnittstelle bleibt so stabil, richtig",
        "Das war so abgesprochen, korrekt",
        "That matches your numbers, right"
    ])
    func detectsTagsWithoutQuestionMark(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.6, "\(text)")
    }

    @Test("Elliptische Kurzfragen gehen zur Prüfung statt verloren", arguments: [
        "Wie lange", "Wie viel denn", "How many", "Wozu"
    ])
    func detectsEllipticalQuestions(_ text: String) {
        // Mittlere Konfidenz: nicht verlieren, aber der Klassifikator prüft
        // mit Kontext, ob es wirklich eine Frage oder ein Bruchstück war.
        #expect(TextUtilities.questionLikelihood(text) >= 0.35, "\(text)")
    }

    @Test("Höfliche Bitten mit bitte/please werden erkannt")
    func detectsPoliteRequests() {
        #expect(TextUtilities.questionLikelihood("Bitte erklären Sie kurz den Rollback-Prozess.") >= 0.6)
        #expect(TextUtilities.questionLikelihood("Please walk us through the incident timeline.") >= 0.6)
    }

    @Test("Wiederholungswort mitten in einer Aussage ist keine Sofortfrage")
    func repeatWordDoesNotTriggerStatement() {
        #expect(TextUtilities.questionLikelihood("Nochmal bitte") == 0.95)
        #expect(TextUtilities.questionLikelihood("Es wäre gut, das nochmal gegenzulesen.") < 0.95)
        #expect(TextUtilities.questionLikelihood("Wir sollten das nochmal intern prüfen.") < 0.95)
    }

    @Test("Kontraktionen zählen als Frageeinstieg")
    func detectsContractions() {
        #expect(TextUtilities.questionLikelihood("What's the current error rate") >= 0.6)
        #expect(TextUtilities.questionLikelihood("Isn't that covered by the retry logic") >= 0.35)
    }

    @Test("An den Zuhörer gerichtete Aussagen gehen zur Modellprüfung", arguments: [
        "Ich bin gespannt, wie ihr das gelöst habt.",
        "Mich interessiert vor allem, wie ihr die Last verteilt.",
        "Ich bin neugierig, was du davon hältst.",
        "I'm interested in how you scaled that to ten thousand users."
    ])
    func detectsListenerDirectedStatements(_ text: String) {
        let value = TextUtilities.questionLikelihood(text)
        // Muss die Schwelle überleben …
        #expect(value >= 0.35, "\(text) → \(value)")
        // … darf aber nie ohne Modellprüfung sofort antworten.
        #expect(value < 0.95, "\(text) → \(value)")
    }

    @Test("Die Anrede-Stufe liegt genau auf der einstellbaren Schwelle")
    func listenerTierConfidence() {
        // 0,40 ist der Wert, den der Regler in den Einstellungen ein- und
        // ausschaltet: darunter prüft das Modell mit, darüber nicht mehr.
        #expect(TextUtilities.questionLikelihood("Ich bin gespannt, wie ihr das gelöst habt.") == 0.4)
    }

    @Test("Anrede allein macht noch keine Frage")
    func addressAloneIsNotEnough() {
        #expect(TextUtilities.questionLikelihood("Ich schicke dir gleich die Unterlagen.") < 0.35)
        #expect(TextUtilities.questionLikelihood("Danke dir, das hilft weiter.") < 0.35)
        #expect(TextUtilities.questionLikelihood("I'll send you the numbers tonight.") < 0.35)
    }

    @Test("Gefüllte Aussagen bleiben unten", arguments: [
        "Ja genau, so machen wir das.",
        "Also gut, dann übernehme ich das Ticket.",
        "Right, sounds good to me.",
        "Mhm, macht Sinn.",
        "Dann machen wir mit dem nächsten Punkt weiter.",
        "Genau richtig."
    ])
    func fillerStatementsStayLow(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35, "\(text)")
    }

    @Test("Indirekte Fragen im „ich frage mich“-Rahmen kommen durch", arguments: [
        "I was wondering whether you have a rollback plan.",
        "We were wondering if you could send us the raw numbers.",
        "Ich frage mich, wie ihr das mit den Zeitzonen löst.",
        "Ich habe mich gefragt, ob ihr dafür schon eine Lösung habt."
    ])
    func detectsWonderingQuestions(_ text: String) {
        let value = TextUtilities.questionLikelihood(text)
        #expect(value >= 0.35, "\(text) → \(value)")
        // Nie sofort: ob dahinter ein Anliegen steckt, entscheidet der Kontext.
        #expect(value < 0.95, "\(text) → \(value)")
    }

    @Test("Grübeln über sich selbst bleibt eine Aussage", arguments: [
        "I wonder why the cache misses spiked last night.",
        "I wonder if the cache warmed up in time.",
        // Ohne Nebensatz wird nichts erfragt – nur zugestimmt.
        "I was wondering about that too.",
        "Ich frage mich, ob das überhaupt nötig war.",
        "Wir haben uns gefragt, warum das damals so gebaut wurde."
    ])
    func selfDirectedWonderingStaysLow(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35, "\(text)")
    }

    @Test("Aufforderungen in Aussageform gelten als Frage", arguments: [
        "Erläutern Sie bitte kurz die Abnahmekriterien.",
        "Fassen Sie das bitte kurz zusammen.",
        "Sagen Sie uns bitte, was das im Jahr kosten würde.",
        "Run me through the numbers for the last quarter.",
        "Take us through the incident timeline step by step.",
        "Summarize the main risks for us.",
        "Break down the licensing costs for me.",
        "Clarify what happens to the old records."
    ])
    func detectsStatementShapedRequests(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.6, "\(text)")
    }

    @Test("Dieselben Wörter mitten im Aussagesatz lösen nichts aus", arguments: [
        // Partizip statt Imperativ – der Wortgrenzenabgleich muss das trennen.
        "Erklärt hat uns das bisher niemand.",
        "Fassen wir zusammen: der Termin bleibt.",
        "Outline of the plan is in the deck.",
        "Summary of the risks is on slide four."
    ])
    func requestWordsInsideStatementsStayLow(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35, "\(text)")
    }

    @Test("Mehrwortige Anhängsel ohne Fragezeichen werden erkannt", arguments: [
        "That is still the plan, isn't it",
        "We agreed on Thursday, didn't we",
        "This covers the mobile clients too, doesn't it",
        "Das bleibt bei zwei Wochen, ne",
        "Der Termin steht, gell"
    ])
    func detectsMultiWordTags(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.6, "\(text)")
    }

    @Test("Zustimmung mit demselben Schlusswort bleibt Zustimmung", arguments: [
        // Ohne Komma unmittelbar davor ist „right“/„korrekt“ kein Anhängsel.
        "Right, that is correct.",
        "Sounds about right.",
        "You got that right.",
        "Das war so besprochen, das ist korrekt."
    ])
    func agreementIsNotATag(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35, "\(text)")
    }

    @Test("Elliptische Nachfragen mit Präposition davor überleben", arguments: [
        "Seit wann", "Since when", "Bis wann genau", "For how long",
        "Wie oft", "How often", "Und danach", "And the cost"
    ])
    func detectsPrefixedEllipses(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) >= 0.35, "\(text)")
    }

    @Test("Kurze Abschlüsse hinter „und“ bleiben Aussagen", arguments: [
        "Und fertig", "Und das war's", "Passt schon.", "Not right now, thanks."
    ])
    func shortConnectorStatementsStayLow(_ text: String) {
        #expect(TextUtilities.questionLikelihood(text) < 0.35, "\(text)")
    }

    @Test("Trennbare Verbpartikel beendet die Frage, statt sie abzuschneiden")
    func separableParticleEndsQuestion() {
        #expect(TextUtilities.questionLikelihood("Wie geht ihr mit solchen Ausfällen um") >= 0.6)
        #expect(TextUtilities.questionLikelihood("Wie stellt ihr euch die Migration vor") >= 0.6)
        // Eine Präposition, die kein Partikel ist, bleibt ein Bruchstück.
        #expect(TextUtilities.assessQuestion("Wie das dann weitergeht mit") == .incomplete)
    }

    @Test("Nebensatz-Endverb ist kein Satzabbruch")
    func subordinateClauseIsComplete() {
        #expect(TextUtilities.questionLikelihood("Könntest du kurz sagen, wie das gemeint ist") >= 0.6)
        // Ohne Komma wartet der Hauptsatz noch auf sein Objekt.
        #expect(TextUtilities.assessQuestion("Was mich dabei noch interessieren würde ist") == .incomplete)
    }

    @Test("Angefangene Bitten warten weiter auf die Fortsetzung", arguments: [
        "I was wondering whether you could",
        "Erklär mir bitte kurz den",
        "Would you mind walking us through the"
    ])
    func startedRequestsStayIncomplete(_ text: String) {
        #expect(TextUtilities.assessQuestion(text) == .incomplete, "\(text)")
    }
}

@Suite("Modelltext-Aufbereitung")
struct ModelTextTests {

    @Test("Entfernt Denkblöcke")
    func stripsThinking() {
        let cleaned = TextUtilities.stripThinking("<think>Überlegung …</think>Die Antwort.")
        #expect(cleaned == "Die Antwort.")
    }

    @Test("Entfernt unvollständige Denkblöcke")
    func stripsUnterminatedThinking() {
        #expect(TextUtilities.stripThinking("Text <think>abgeschnitten") == "Text ")
    }

    @Test("Entfernt Präfixe und Anführungszeichen")
    func cleansPrefixes() {
        #expect(TextUtilities.cleanModelText("Übersetzung: \"Guten Morgen.\"") == "Guten Morgen.")
        #expect(TextUtilities.cleanModelText("„Das passt.“") == "Das passt.")
    }

    @Test("Kürzt an der letzten Satzgrenze")
    func clampsAtSentence() {
        let text = "Erster Satz. Zweiter Satz. Dritter Satz, der abgeschnitten wird"
        let clamped = TextUtilities.clampToSentence(text, maxCharacters: 30)
        #expect(clamped == "Erster Satz. Zweiter Satz.")
    }
}

@Suite("Antwort in Vorlese- und Hintergrundteil trennen")
struct AnswerSplitTests {

    @Test("Liest das strukturierte Antwortformat vollständig")
    func parsesStructuredAnswer() {
        let answer = TextUtilities.parseStructuredAnswer(
            #"{"spoken":"Ja, das passt.","details":"Freigabe wurde heute erteilt.","confidence":"high","missingContext":[]}"#
        )
        #expect(answer.spoken == "Ja, das passt.")
        #expect(answer.details == "Freigabe wurde heute erteilt.")
        #expect(answer.confidence == .high)
        #expect(answer.missingContext.isEmpty)
    }

    @Test("Unvollständiges JSON wird nicht roh vorgelesen")
    func malformedJSONUsesSafeFallback() {
        let answer = TextUtilities.parseStructuredAnswer(
            #"{"spoken":"Die Zahl ist nicht belegt.","details":"Es fehlt"#
        )
        #expect(answer.spoken == "Die Zahl ist nicht belegt.")
        #expect(!answer.spoken.contains("{\"spoken\""))
        #expect(answer.confidence == .low)
        #expect(!answer.missingContext.isEmpty)
    }

    @Test("Freitext-Fallback begrenzt den Vorleseteil")
    func freeTextFallbackIsBounded() {
        let long = (1...70).map { "Wort\($0)" }.joined(separator: " ")
        let answer = TextUtilities.parseStructuredAnswer(long)
        #expect(answer.spoken.split(whereSeparator: \.isWhitespace).count == 45)
        #expect(answer.confidence == .low)
    }

    @Test("Strukturiertes Streaming zeigt nur den Feldinhalt")
    func structuredStreamingHidesJSONSyntax() {
        var stream = TextUtilities.StructuredAnswerStreamFormatter()
        stream.append(#"{"spoken":"Das ist belegt"#)
        #expect(stream.current.spoken == "Das ist belegt")
        #expect(!stream.current.spoken.contains("spoken"))
        stream.append(#".","details":"Quelle im Gespräch","confidence":"medium","missingContext":[]}"#)
        let result = stream.finish()
        #expect(result.spoken == "Das ist belegt.")
        #expect(result.confidence == .medium)
    }

    @Test("Codeblock-Präfix wird beim Streaming niemals vorgelesen")
    func structuredStreamingHidesPrefixedJSONSyntax() {
        var stream = TextUtilities.StructuredAnswerStreamFormatter()
        stream.append("```json\n")
        #expect(stream.current.spoken.isEmpty)
        stream.append(#"{"spoken":"Sicherer Inhalt","details":"Beleg","confidence":"high","missingContext":[]}"#)
        #expect(stream.current.spoken == "Sicherer Inhalt")
        #expect(!stream.current.spoken.contains("spoken"))
        #expect(stream.finish().spoken == "Sicherer Inhalt")
    }

    @Test("Fehlender Kontext erzwingt niedrige Sicherheit")
    func missingContextForcesLowConfidence() {
        let answer = TextUtilities.parseStructuredAnswer(
            #"{"spoken":"Das ist unklar.","details":"","confidence":"high","missingContext":["Termin"]}"#
        )
        #expect(answer.confidence == .low)
    }

    @Test("Unbelegte Zahlen werden deterministisch markiert")
    func unsupportedNumbersAreDowngraded() {
        let answer = StructuredAnswer(
            spoken: "Der Termin ist in 14 Tagen.",
            details: "",
            confidence: .high
        )
        let grounded = TextUtilities.groundStructuredAnswer(answer, evidence: "Genannt wurden 7 Tage.")
        #expect(grounded.confidence == .low)
        #expect(grounded.missingContext.contains { $0.contains("14") })
        #expect(!grounded.spoken.contains("14"))

        let supported = TextUtilities.groundStructuredAnswer(answer, evidence: "Genannt wurden 14 Tage.")
        #expect(supported.confidence == .high)
    }

    @Test("Gleiche Zahl mit anderer Einheit ist kein Beleg")
    func numberRequiresMatchingUnit() {
        let answer = StructuredAnswer(
            spoken: "Die Frist beträgt 14 Tage.",
            confidence: .high
        )
        let grounded = TextUtilities.groundStructuredAnswer(
            answer,
            evidence: "Im Projekt arbeiten 14 Nutzer."
        )
        #expect(grounded.confidence == .low)
        #expect(!grounded.spoken.contains("14"))
    }

    @Test("Verb nach Statuscode wird nicht als Maßeinheit behandelt")
    func verbAfterNumberIsNotAUnit() {
        let answer = StructuredAnswer(
            spoken: "429 bedeutet zu viele Anfragen.",
            confidence: .high
        )
        let grounded = TextUtilities.groundStructuredAnswer(
            answer,
            evidence: "Was bedeutet 429?"
        )
        #expect(grounded.confidence == .high)
        #expect(grounded.spoken.contains("429"))
    }

    @Test("Trennt an der Marke")
    func splitsAtMarker() {
        let (spoken, details) = TextUtilities.splitAnswer(
            "Wir geben da 429 zurück.\n---MEHR---\nZusätzlich gehört ein Retry-After-Header dazu."
        )
        #expect(spoken == "Wir geben da 429 zurück.")
        #expect(details == "Zusätzlich gehört ein Retry-After-Header dazu.")
    }

    @Test("Ohne Marke ist alles vorlesbar")
    func noMarkerMeansAllSpoken() {
        let (spoken, details) = TextUtilities.splitAnswer("Wir geben 429 zurück.")
        #expect(spoken == "Wir geben 429 zurück.")
        #expect(details.isEmpty)
    }

    @Test("Halb angekommene Marke blitzt nicht auf")
    func hidesPartialMarker() {
        // Genau das passiert beim Streamen Zeichen für Zeichen.
        for partial in ["-", "--", "---", "---M", "---ME", "---MEH", "---MEHR", "---MEHR--"] {
            let (spoken, _) = TextUtilities.splitAnswer("Antwort.\n" + partial)
            #expect(
                !spoken.contains("-"),
                "Bruchstück „\(partial)“ ist sichtbar geworden: \(spoken)"
            )
        }
    }

    @Test("Verträgt abweichende Schreibweisen des Modells")
    func toleratesVariants() {
        for variant in ["[[MEHR]]", "**---MEHR---**", "TEIL 2"] {
            let (spoken, details) = TextUtilities.splitAnswer(
                "Kurze Antwort.\n\(variant)\nLange Erklärung."
            )
            #expect(spoken == "Kurze Antwort.", "Variante \(variant)")
            #expect(details == "Lange Erklärung.", "Variante \(variant)")
        }
    }

    @Test("Entfernt Teil-Beschriftungen, wenn das Modell sie doch setzt")
    func stripsLabels() {
        let (spoken, details) = TextUtilities.splitAnswer(
            "TEIL 1: Kurze Antwort.\n---MEHR---\nTeil 2: Lange Erklärung."
        )
        #expect(spoken == "Kurze Antwort.")
        #expect(details == "Lange Erklärung.")
    }

    @Test("Entfernt Beschriftungen, die auf einer eigenen Zeile stehen")
    func stripsLabelLines() {
        // Genau so beschriftet gemma3:12b in der Praxis.
        let (spoken, details) = TextUtilities.splitAnswer(
            """
            TEIL 1 – zum Vorlesen.
            Ich würde 429 Too Many Requests verwenden.
            ---MEHR---
            **TEIL 2 – Hintergrund.**
            Gemäß RFC 6585 ist das der empfohlene Code.
            """
        )
        #expect(spoken == "Ich würde 429 Too Many Requests verwenden.")
        #expect(details == "Gemäß RFC 6585 ist das der empfohlene Code.")
    }

    @Test("Streaming führt nie zu verlorenem Text")
    func streamingKeepsEverything() {
        let complete = "Wir geben 429 zurück.\n---MEHR---\nMit Retry-After-Header."
        var seen = ""
        for index in complete.indices {
            let prefix = String(complete[...index])
            let (spoken, details) = TextUtilities.splitAnswer(prefix)
            seen = spoken + details
        }
        #expect(seen.contains("429"))
        #expect(seen.contains("Retry-After"))
    }
}

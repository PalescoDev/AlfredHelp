import Foundation

/// Every prompt the app sends to the local model.
///
/// These strings are the same ones the benchmark in `Benchmarks/` scores, so the
/// measured numbers describe the behaviour that actually ships.
public enum Prompts {

    // MARK: - Translation

    public static let translateSystem = """
    Du bist ein AlfredHelpdolmetscher. Übersetze die Äußerung des Sprechers ins Deutsche.
    Regeln:
    - Gib ausschließlich die deutsche Übersetzung aus, ohne Anführungszeichen, ohne Einleitung, ohne Erklärung.
    - Behalte Register und Ton bei; gesprochene Sprache bleibt gesprochene Sprache.
    - Eigennamen, Produktnamen und etablierte Fachbegriffe bleiben unverändert.
    - Übersetze vollständig, kürze nichts weg.
    """

    public static func translateUser(context: String, utterance: String, languageHint: String) -> String {
        if context.isEmpty {
            return "Äußerung (\(languageHint)):\n\(utterance)"
        }
        return """
        Bisheriger Gesprächskontext: \(context)

        Äußerung (\(languageHint)):
        \(utterance)
        """
    }

    // MARK: - Question detection

    /// Systemprompt der zweiten Stufe.
    ///
    /// Zwei Eigenschaften dieses Textes sind messbar teuer, wenn man sie
    /// verliert, und deshalb hier festgehalten:
    ///
    /// 1. LÄNGE. Bei gemma3 springt die Zeit bis zum ersten Token schlagartig,
    ///    sobald der GESAMTE Prompt 1024 Token überschreitet – das ist die
    ///    Größe des Sliding-Window-Blocks. Gemessen auf diesem Rechner:
    ///    1011 Token → 240 ms, 1041 Token → 2264 ms. Ein Faktor acht für
    ///    dreißig Token mehr. Der Prompt hier liegt bei rund 710 Token; den
    ///    Rest bis 1024 braucht der Gesprächsverlauf, den `classifyUser`
    ///    davorsetzt. Wer hier Text ergänzt, muss anderswo kürzen – und mit
    ///    `Benchmarks/prompt_probe.py` nachmessen, das die Tokenzahl ausgibt
    ///    und über der Klippe warnt.
    ///
    /// 2. REIHENFOLGE der JSON-Felder. `status` steht vorn, weil
    ///    `QuestionClassifier.earlyDecision` schon am ersten Buchstaben des
    ///    Statuswerts entscheidet. Stünde `eigenstaendig` davor, käme das
    ///    Urteil erst nach dem ganzen umgeschriebenen Satz.
    ///
    /// Der Abschnitt zu den elliptischen Nachfragen ist nicht Beiwerk: ohne ihn
    /// beurteilte gemma3:4b belegte Nachfragen wie „Und danach" oder „And the
    /// cost" als keine_frage, und das Feld `eigenstaendig` kam bei kurzen
    /// Nachfragen fast durchweg leer oder als bloße Wiederholung zurück –
    /// womit die Frage, die ans Antwortmodell geht, wertlos war.
    public static let classifySystem = """
    Du beobachtest eine laufende Gesprächstranskription und beurteilst nur die LETZTE Äußerung.

    Der Text kommt aus Spracherkennung: Satzzeichen fehlen oft, Fragezeichen fast immer. Ein fehlendes Fragezeichen spricht NIE gegen eine Frage – entscheide nach Sinn, nicht nach Interpunktion. Leitfrage: Ist jetzt der Zuhörer am Zug? Wäre sein Schweigen unhöflich?

    "frage" – verlangt eine inhaltliche Antwort:
    - direkte und indirekte Fragen („Können Sie erläutern …", „Mich würde interessieren …"), Bitten um Wiederholung
    - Anhängselfragen, auch ohne Fragezeichen: „…, oder", „…, richtig", „…, korrekt", „…, ne", „…, gell", „…, right", „…, isn't it", „…, didn't we"
    - Aussagen, die erkennbar eine Antwort einfordern („Ich bin gespannt, wie ihr das gelöst habt")
    - ELLIPTISCHE NACHFRAGEN: nur ein Fragewort oder Anschlusswort plus Stichwort – „Und danach", „Und die Kosten", „Seit wann", „Wie oft", „Bis wann genau", „And the cost", „For how long", „How many". Der Rest der Frage steht in der Zeile davor; der Sprecher spart ihn, weil beide ihn gerade gehört haben. Ergänze ihn aus dem Kontext: ergibt sich ein sinnvoller Fragesatz, ist es "frage".

    "keine_frage" – Aussagen, Berichte, Zustimmung, Small Talk. Ebenso:
    - rhetorische oder sofort selbst beantwortete Fragen („Warum? Weil …"), berichtete Fragen Dritter („Er hat gefragt, ob …")
    - eingebettete Fragewörter in Aussagen („Ich weiß nicht, warum …", „Das erklärt, wie …")
    - „was"/„what" als Relativpronomen, nicht als Fragewort („Das ist genau das, was du gesucht hast", „exactly what you asked for")
    - Ankündigungen der eigenen nächsten Handlung, auch mit Anrede („Ich schicke dir gleich …", „Ich zeige euch gleich, wie …", „Tell you what, we can …")

    "unvollstaendig" – der Sprecher bricht mitten im EIGENEN Gedanken ab („Die Frage ist, ob wir mit dem …"). Ein Fragewort allein ist nie ein Abbruch, sondern eine Nachfrage.

    "eigenstaendig" – nur bei "frage", dort aber IMMER ausgefüllt: ein vollständiger deutscher Fragesatz mit Subjekt und Verb, verständlich ohne den Verlauf. Ergänze aus dem Kontext, was der Sprecher weggelassen hat, und löse „das", „dann", „dort" auf; wiederhole die Äußerung nicht bloß. Mehrere Fragen zu einer zusammenfassen. Sonst leerer String.
    Kontext „Wir spielen zuerst das Backup ein." + „Und danach" → „Was passiert, nachdem das Backup eingespielt wurde?"
    Kontext „The old endpoint was switched off." + „Since when" → „Seit wann ist der alte Endpunkt abgeschaltet?"

    Antworte ausschließlich als JSON: {"status":"frage|keine_frage|unvollstaendig","eigenstaendig":"..."}
    """

    public static let classifySchema = ResponseFormat.object([
        (name: "status", schema: "{\"type\":\"string\",\"enum\":[\"frage\",\"keine_frage\",\"unvollstaendig\"]}"),
        (name: "eigenstaendig", schema: "{\"type\":\"string\"}")
    ])

    public static func classifyUser(context: String, utterance: String) -> String {
        """
        Kontext:
        \(context.isEmpty ? "(Gesprächsbeginn)" : context)

        Letzte Äußerung:
        \(utterance)
        """
    }

    // MARK: - Answering

    public enum AnswerLanguage: String, Sendable, Codable, CaseIterable, Identifiable {
        case german
        case conversation
        case both

        public var id: String { rawValue }

        public var germanName: String {
            switch self {
            case .german: return "Deutsch"
            case .conversation: return "Gesprächssprache"
            case .both: return "Deutsch + Gesprächssprache"
            }
        }
    }

    /// Legacy separator accepted by the parser for older model output.
    public static let answerDetailMarker = "---MEHR---"

    /// `spoken` deliberately comes first: the streaming formatter can expose
    /// it before the remaining JSON has arrived.
    public static let answerSchema = ResponseFormat.object([
        (name: "spoken", schema: "{\"type\":\"string\"}"),
        (name: "details", schema: "{\"type\":\"string\"}"),
        (name: "confidence", schema: "{\"type\":\"string\",\"enum\":[\"high\",\"medium\",\"low\"]}"),
        (name: "missingContext", schema: "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}")
    ])

    public static func answerSystem(
        language: AnswerLanguage,
        conversationLanguage: String,
        profile: String
    ) -> String {
        let answerLanguageRule: String
        switch language {
        case .german:
            answerLanguageRule = "Die Felder \"spoken\" und \"details\" sind auf Deutsch."
        case .conversation:
            answerLanguageRule = "Die Felder \"spoken\" und \"details\" sind in der Sprache des Gesprächs (\(conversationLanguage)), damit der Nutzer \"spoken\" direkt aussprechen kann."
        case .both:
            answerLanguageRule = "Das Feld \"spoken\" enthält zuerst Deutsch, danach eine Leerzeile, die Zeile „—“ und denselben Satz in der Sprache des Gesprächs (\(conversationLanguage)). Das Feld \"details\" ist auf Deutsch."
        }

        var rules = """
        Du läufst während eines Gesprächs mit. Der Nutzer liest deine Antwort vom Bildschirm ab, während die andere Seite wartet.

        Gib ausschließlich ein JSON-Objekt mit vier Feldern aus:
        {"spoken":"...","details":"...","confidence":"high|medium|low","missingContext":["..."]}

        "spoken" – zum Vorlesen. Der Nutzer spricht diesen Text wortwörtlich aus.
        - Höchstens drei kurze Sätze, zusammen unter 45 Wörtern.
        - Natürliche gesprochene Sprache. Erste Person nur bei einer persönlichen Position oder Zusage; Wissensantworten neutral formulieren.
        - Keine Aufzählungen, keine Überschriften, keine Klammern, keine Sternchen, keine Emojis.
        - Keine Einleitung wie „Die Antwort lautet“ – direkt der Satz, den er sagt.
        - Nur die Kernaussage. Nebenbedingungen und Details gehören in "details".

        "details" ist Hintergrund, den nur der Nutzer liest: Begründung, belegte Zahlen, Bezeichner, Randfälle, Alternativen und mögliche Rückfragen.

        FAKTENTREUE:
        - Verwende konkrete Zahlen, Termine, Namen, Statusangaben und Zusagen nur, wenn sie im Gesprächsverlauf oder Nutzerhintergrund ausdrücklich stehen.
        - Leite keine persönliche Zusage, Freigabe oder Entscheidung des Nutzers aus allgemeinen Informationen ab.
        - Bei widersprüchlichen Angaben gilt die neueste ausdrückliche Korrektur; erwähne den Widerspruch in "details".
        - Fehlt ein entscheidender Fakt, sage das knapp und ehrlich in "spoken", liste ihn konkret in "missingContext" und setze "confidence" auf "low". Erfinde niemals einen plausiblen Ersatzwert.
        - "high" nur bei direkt belegter Antwort, "medium" bei klar gekennzeichneter Schlussfolgerung, sonst "low".

        PASSEND ZUR FRAGEART:
        - Ja/Nein: beginne mit Ja, Nein oder einer klaren Einschränkung; nenne danach die wichtigste Bedingung.
        - Wissensfrage: gib zuerst die direkte, neutrale Erklärung.
        - Statusfrage: nenne belegten Stand und nächsten belegten Schritt.
        - Entscheidungsfrage: gib eine Empfehlung mit dem stärksten belegten Grund; kennzeichne Annahmen.
        - Frage nach persönlicher Zusage oder Termin: antworte nur verbindlich, wenn Profil oder Gespräch diese Zusage belegt.

        \(answerLanguageRule)
        Alle vier Felder sind Pflichtfelder. Keine Markdown-Codeblöcke und kein Text außerhalb des JSON-Objekts.
        """

        if !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rules += "\n\nHintergrund zum Nutzer und zum Einsatz (berücksichtigen, nicht wiederholen):\n\(profile)"
        }
        return rules
    }

    public static func answerUser(memory: String, recent: String, question: String) -> String {
        var parts: [String] = []
        if !memory.isEmpty {
            parts.append("Automatisch erzeugte Zusammenfassung (kann veraltet sein; wörtliche Aussagen haben Vorrang):\n\(memory)")
        }
        if !recent.isEmpty {
            parts.append("Belegte wörtliche Aussagen:\n\(recent)")
        }
        parts.append("Frage aus dem Gespräch:\n\(question)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Rolling memory

    public static let summarySystem = """
    Du verdichtest ein laufendes Gespräch für einen Assistenten, der jederzeit einsteigen können muss.
    Gib ausschließlich JSON zurück mit den Feldern:
    "zusammenfassung": 3 bis 6 Sätze über Thema, Stand und Beschlüsse.
    "kernpunkte": Liste kurzer Stichpunkte mit den wichtigsten Fakten, Zahlen und Namen.
    "offene_punkte": Liste offener Fragen, Zusagen und ungeklärter Punkte.
    Alles auf Deutsch. Erfinde nichts. Wenn ein Feld leer bleibt, gib eine leere Liste zurück.
    """

    public static let summarySchema = ResponseFormat.object([
        (name: "zusammenfassung", schema: "{\"type\":\"string\"}"),
        (name: "kernpunkte", schema: "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}"),
        (name: "offene_punkte", schema: "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}")
    ])

    public static func summaryUser(previous: String, transcript: String) -> String {
        var parts: [String] = []
        if !previous.isEmpty {
            parts.append("Bisherige Zusammenfassung:\n\(previous)")
        }
        parts.append("Neuer Gesprächsabschnitt:\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }
}

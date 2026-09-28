import Foundation

public enum TextUtilities {

    private static let abbreviations: Set<String> = [
        "z.b.", "u.a.", "d.h.", "bzw.", "ca.", "usw.", "evtl.", "ggf.", "inkl.",
        "dr.", "prof.", "mr.", "mrs.", "ms.", "st.", "nr.", "abb.", "vgl.",
        "e.g.", "i.e.", "etc.", "vs.", "approx.", "fig.", "no."
    ]

    /// Removes the reasoning blocks some models emit inline.
    public static func stripThinking(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>") {
            if let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    /// Ob irgendwo ein Denkblock beginnt. Spart den vollen `stripThinking`-Lauf
    /// im Regelfall: die App fragt die Modelle mit `think: false`, ein `<think>`
    /// kommt also normalerweise gar nicht vor.
    static func containsThinkingTag(_ text: String) -> Bool {
        text.utf8.count >= 7 && text.contains("<think>")
    }

    /// Strips wrapping quotes and leading "Übersetzung:" style prefixes that
    /// smaller models sometimes add despite instructions.
    public static func cleanModelText(_ text: String) -> String {
        var result = (containsThinkingTag(text) ? stripThinking(text) : text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = [
            "übersetzung:", "translation:", "deutsch:", "german:",
            "antwort:", "answer:", "auf deutsch:"
        ]
        // Nur den Anfang kleinschreiben, nicht den ganzen Text: die Funktion
        // läuft beim Streamen pro Token, und `result.lowercased()` legte dabei
        // je Präfix eine vollständige Kopie an – sieben Kopien des gesamten
        // bisherigen Textes für jedes einzelne Token.
        let longest = prefixes.map(\.count).max() ?? 0
        let head = String(result.prefix(longest)).lowercased()
        for prefix in prefixes where head.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        if result.count > 1 {
            let first = result.first!
            let last = result.last!
            if (first == "\"" && last == "\"") || (first == "„" && last == "“")
                || (first == "»" && last == "«") || (first == "'" && last == "'") {
                result = String(result.dropFirst().dropLast())
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into complete sentences plus the trailing incomplete part.
    public static func splitSentences(_ text: String) -> (complete: [String], remainder: String) {
        var sentences: [String] = []
        var current = ""
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            current.append(character)

            if character == "." || character == "?" || character == "!" || character == "…" {
                // Look ahead: a terminator only ends a sentence when whitespace
                // or end-of-text follows.
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead] == "\"" || text[lookahead] == "”"
                    || text[lookahead] == "“" || text[lookahead] == "'" || text[lookahead] == ")" {
                    current.append(text[lookahead])
                    lookahead = text.index(after: lookahead)
                }
                let atEnd = lookahead >= text.endIndex
                let followedBySpace = !atEnd && text[lookahead].isWhitespace

                if atEnd || followedBySpace {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    let lastWord = trimmed
                        .split(separator: " ", omittingEmptySubsequences: true)
                        .last
                        .map(String.init)?
                        .lowercased() ?? ""
                    let isAbbreviation = character == "." && abbreviations.contains(lastWord)
                    // A single trailing decimal point ("3.") is not a sentence end.
                    let endsWithDigit = character == "."
                        && trimmed.dropLast().last.map { $0.isNumber } == true

                    if !isAbbreviation && !endsWithDigit && !trimmed.isEmpty {
                        sentences.append(trimmed)
                        current = ""
                    }
                }
                index = lookahead
                continue
            }
            index = text.index(after: index)
        }

        return (sentences, current.trimmingCharacters(in: .whitespaces))
    }

    private static let interrogativeOpeners: Set<String> = [
        // Deutsch
        "was", "wann", "wo", "wohin", "woher", "warum", "wieso", "weshalb", "wie",
        "wer", "wen", "wem", "wessen", "welche", "welcher", "welches", "welchen",
        "wozu", "wofür", "womit", "wodurch", "woran", "worauf", "worum",
        "worüber", "wovon", "wobei", "wieviel", "wieviele", "inwiefern", "inwieweit",
        "kannst", "können", "könnt", "könnten", "könntest", "würdest", "würden",
        "ist", "sind", "war", "waren", "soll", "sollen", "sollte", "sollten",
        "würdet", "möchtet", "möchten", "möchtest", "wollt", "wollen", "willst",
        "dürft", "dürfte", "braucht", "brauchen", "brauchst", "passt", "geht", "klappt",
        "hast", "habt", "haben", "hat", "darf", "dürfen", "gibt", "gibts", "musst",
        "müssen", "wird", "werden", "wurde", "wurden", "macht", "machst",
        "hätte", "hätten", "hättest", "hättet", "wäre", "wären", "wärst", "wärt",
        "bist", "seid", "weißt", "wisst", "kennst", "kennt", "denkst", "meinst",
        "meint", "findest", "findet", "glaubst", "glaubt", "siehst", "seht",
        "lässt", "schaffen", "schafft", "schaffst", "gäbe", "kriegen", "kriegt",
        "bekommen", "bekommt", "reicht", "genügt", "funktioniert", "läuft",
        // English
        "what", "when", "where", "why", "how", "who", "whom", "whose", "which",
        "can", "could", "would", "will", "shall", "should", "do", "does", "did",
        "is", "are", "was", "were", "am", "have", "has", "had", "may", "might",
        "any", "anyone", "anybody", "anything",
        // English contractions – the recognizer writes "What's the plan" far
        // more often than "What is the plan".
        "what's", "whats", "who's", "whos", "where's", "wheres", "when's",
        "whens", "how's", "hows", "why's", "whys", "isn't", "isnt", "aren't",
        "arent", "don't", "dont", "doesn't", "doesnt", "didn't", "didnt",
        "can't", "cant", "couldn't", "couldnt", "won't", "wont", "wouldn't",
        "wouldnt", "shouldn't", "shouldnt", "wasn't", "wasnt", "weren't",
        "werent", "haven't", "havent", "hasn't", "hasnt",
        // Français
        "quoi", "que", "qui", "quand", "où", "pourquoi", "comment", "quel",
        "quelle", "quels", "quelles", "combien", "peux", "pouvez", "pourriez",
        "est-ce", "avez", "as-tu", "sais",
        // Español
        "qué", "quién", "quiénes", "cuándo", "dónde", "cómo", "cuál", "cuáles",
        "cuánto", "cuánta", "puedes", "puede", "podría", "podrías", "sabes",
        // Italiano
        "che", "chi", "quando", "dove", "perché", "come", "quale", "quali",
        "quanto", "puoi", "potresti", "sai",
        // Nederlands
        "wat", "wanneer", "waar", "waarom", "hoe", "wie", "welke", "kun", "kunt",
        "zou", "zullen", "heb", "heeft", "is", "zijn"
    ]

    /// Genuine question words – the subset of the openers that carries a
    /// question on its own. "Wie lange" is a question, "Macht Sinn" is not.
    private static let strongInterrogatives: Set<String> = [
        "was", "wann", "wo", "wohin", "woher", "warum", "wieso", "weshalb",
        "wie", "wer", "wen", "wem", "wessen", "welche", "welcher", "welches",
        "wozu", "wofür", "womit", "wieviel", "wieviele",
        "what", "when", "where", "why", "how", "who", "whom", "whose", "which",
        "what's", "whats", "who's", "whos", "where's", "wheres", "how's", "hows"
    ]

    /// Leading discourse fillers that never change whether something is a
    /// question: "Also, wie machen wir weiter" asks exactly what "Wie machen
    /// wir weiter" asks. At most three are peeled off before the opener checks.
    /// Deliberately disjoint from `interrogativeOpeners` – stripping must never
    /// remove the question word itself.
    private static let leadingFillers: Set<String> = [
        // Deutsch
        "ja", "nee", "nein", "gut", "okay", "ok", "also", "und", "aber", "na",
        "naja", "dann", "so", "ähm", "äh", "hm", "mhm", "tja", "ach", "achso",
        "eben", "halt", "genau", "bitte", "sorry", "entschuldigung", "moment",
        "kurz", "übrigens", "apropos",
        // English
        // "er" fehlt bewusst: als englischer Zögerlaut selten, als deutsches
        // Pronomen („Er hat …") würde das Schälen Aussagen zu Fragen machen.
        "and", "but", "well", "right", "now", "then", "yeah", "yes", "no",
        "um", "uh", "alright", "anyway", "actually", "basically", "look",
        "listen", "hey", "please", "just", "quickly"
    ]

    // MARK: - Question assessment

    /// The three-way verdict the pipeline acts on.
    public enum QuestionAssessment: Equatable, Sendable {
        /// Statement, backchannel, rhetoric, reported speech – do nothing.
        case notQuestion
        /// The sentence is visibly cut off – wait for the continuation.
        case incomplete
        /// A real question. High confidence answers immediately, mid
        /// confidence goes through the local model first.
        case question(confidence: Double)
    }

    /// Words a sentence does not end on when the speaker is actually done.
    /// Used both here and by the assembler to hold back half sentences.
    private static let continuationEndings: Set<String> = [
        // Deutsch – Konjunktionen, Präpositionen, Artikel, Hilfsverben
        "und", "oder", "aber", "weil", "dass", "wenn", "ob", "als", "beziehungsweise",
        "mit", "für", "von", "vom", "zu", "zur", "zum", "im", "am", "beim", "über",
        "unter", "nach", "vor", "bei", "durch", "ohne", "gegen", "um",
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem",
        "einer", "eines", "unser", "unsere", "unserem", "ihre", "ihrem", "seinen",
        "ist", "sind", "wird", "wäre", "wären", "hätte", "hätten", "sollte",
        "dann", "noch", "auch", "mal", "erstmal", "sich", "uns", "sehr", "ganz",
        "diese", "dieser", "dieses", "diesen", "jetzt", "gerade", "sozusagen",
        // English – conjunctions, prepositions, articles, auxiliaries
        "and", "or", "but", "because", "if", "whether", "that", "which", "while",
        "the", "a", "an", "with", "for", "to", "of", "in", "on", "at", "by",
        "into", "onto", "from", "about", "over", "under", "between",
        "is", "are", "was", "were", "be", "being", "been", "would", "could",
        "should", "will", "can", "may", "might", "must", "have", "has", "had",
        "we", "they", "it", "i", "you", "he", "she", "my", "our", "their",
        "your", "his", "her", "its", "this", "these", "those", "there",
        "more", "very", "so", "just", "still", "then", "also", "really",
        "wanted", "gonna", "going"
    ]

    /// Ob ein Wort zur geschlossenen Klasse der Funktionswörter gehört –
    /// Artikel, Konjunktionen, Präpositionen, Pronomen, Hilfsverben.
    ///
    /// Gebraucht wird das außerhalb der Frageerkennung: `UtteranceStitcher`
    /// entscheidet damit, ob ein einzelnes gemeinsames Wort am Stoß zweier
    /// Bruchstücke eine Wiederholung des Erkenners ist oder schlicht ein Wort,
    /// das im Deutschen und Englischen alle paar Sätze einmal vorkommt.
    static func isContinuationWord(_ word: String) -> Bool {
        continuationEndings.contains(word)
    }

    /// Complete short questions that need no verb and often arrive without a
    /// question mark when the intonation is flat.
    private static let shortQuestionWhitelist: Set<String> = [
        "warum", "wieso", "weshalb", "wozu", "wofür", "inwiefern", "und dann",
        "wie genau", "wieso nicht", "warum nicht", "wozu das ganze", "wie bitte",
        "noch fragen", "und sonst", "sonst noch was", "sonst noch fragen",
        "why", "how come", "and then", "how exactly", "how so", "why not",
        "in what way", "what for", "says who", "any questions",
        "any questions so far", "anything else", "what else", "who else"
    ]

    /// Tag endings that still mark a question when the recognizer dropped the
    /// question mark ("Das passt so, oder"). By the time such an utterance
    /// reaches the pipeline, the assembler has already waited through the
    /// pause – a trailing "oder" was the end, not the start of an alternative.
    ///
    /// Erkannt wird nur mit Komma unmittelbar davor, siehe `trailingTag`.
    private static let tagWordsWithoutMark: Set<String> = [
        "oder", "richtig", "korrekt", "stimmts", "stimmt's", "ne", "gell",
        "right", "correct"
    ]

    /// Mehrwortige Anhängsel derselben Art. Sie brauchen einen eigenen Weg,
    /// weil sie auf einem Pronomen enden: „…, isn't it“ hört auf „it“ auf,
    /// einem Fortsetzungswort – ohne diese Liste galt der Satz als abgerissen
    /// und wurde zurückgehalten statt beantwortet.
    private static let tagPhrasesWithoutMark: [String] = [
        "nicht wahr", "oder nicht", "oder etwa nicht", "oder was",
        "isn't it", "isnt it", "doesn't it", "doesnt it",
        "don't you", "dont you", "didn't you", "didnt you",
        "didn't we", "didnt we", "haven't you", "havent you",
        "haven't we", "havent we", "hasn't it", "hasnt it",
        "won't it", "wont it", "wouldn't it", "wouldnt it",
        "aren't they", "arent they", "aren't you", "arent you",
        "can't we", "cant we", "isn't that right", "isnt that right"
    ]

    /// Continuation words that can nevertheless end a complete flat-intonation
    /// question: "Und was machen wir dann", "Who signs off on this". Only
    /// consulted when the sentence opens with a genuine question word – for
    /// everything else they keep marking an unfinished thought.
    ///
    /// „um“ und „vor“ stehen hier als trennbare Verbpartikeln: „Wie geht ihr
    /// damit um“ und „Wie stellt ihr euch das vor“ sind fertige Fragen, obwohl
    /// beide Wörter sonst Präpositionen sind und einen Satz offen lassen. Das
    /// Risiko ist eng begrenzt – die Regel greift nur nach einem echten
    /// Fragewort am Satzanfang und ab vier Wörtern.
    private static let softQuestionTrailers: Set<String> = [
        "dann", "noch", "auch", "mal", "jetzt", "gerade", "um", "vor",
        "then", "this", "these", "those", "there", "still", "also", "more",
        "really", "so", "very", "just"
    ]

    /// Einleitewörter eines Nebensatzes. Zwei Stellen brauchen sie: die
    /// indirekte Frage („…, ob ihr das anbietet“) und der Nebensatzabschluss
    /// im Deutschen (`closesGermanSubordinateClause`).
    private static let clauseIntroducers: Set<String> = [
        "ob", "dass", "wie", "was", "warum", "wieso", "weshalb", "wann", "wo",
        "wer", "wen", "wem", "welche", "welcher", "welches", "welchen",
        "wieviel", "wieviele", "wofür", "wozu", "womit", "inwiefern", "inwieweit",
        "whether", "if", "how", "what", "why", "when", "where", "who", "which"
    ]

    /// Finite Verbformen, die einen deutschen Nebensatz abschließen können.
    /// Bewusst nur deutsche: das Englische stellt das Verb nicht ans Ende, dort
    /// bleibt ein schließendes „is“ ein Zeichen für einen abgerissenen Satz.
    private static let clauseFinalVerbs: Set<String> = [
        "ist", "sind", "war", "waren", "wird", "werden", "wurde", "wurden",
        "wäre", "wären", "hätte", "hätten", "sollte", "sollten"
    ]

    /// Bindewörter, hinter denen eine elliptische Nachfrage stehen kann.
    private static let connectorOpeners: Set<String> = [
        "und", "aber", "and", "but"
    ]

    /// Köpfe, mit denen so eine Ellipse anfängt. Absichtlich schmal gehalten:
    /// „Und danach“ und „And the cost“ fragen nach, „Und fertig“ und „Und das
    /// war's“ stellen fest. „das“ fehlt deshalb – als Pronomen leitet es viel
    /// häufiger einen Abschluss ein als eine Nachfrage.
    private static let ellipticalFollowUpHeads: Set<String> = [
        "danach", "davor", "vorher", "nachher", "später", "dazu", "damit",
        "dabei", "die", "der", "den", "dem",
        "the", "a", "an", "those", "these", "after", "before", "next",
        "afterwards"
    ]

    /// Phrases that make a question-word sentence a statement: reported
    /// speech, embedded clauses, self-directed wondering, meta talk.
    private static let reportedSpeechMarkers: [String] = [
        "hat gefragt", "hat er gefragt", "hat sie gefragt", "gefragt ob",
        "gefragt, ob", "fragte", "die frage gestellt",
        "weiß nicht warum", "weiß nicht, warum", "weiß nicht wie", "weiß nicht, wie",
        "weiß nicht ob", "weiß nicht, ob", "wissen nicht warum", "wissen nicht, warum",
        "das erklärt", "erklärt warum", "erklärt, warum", "erklärt wie", "erklärt, wie",
        "das ist der grund", "deshalb", "darum geht es",
        "zeige euch", "zeige ihnen", "zeig euch", "ich zeige", "wir zeigen",
        "wie gesagt", "wie dem auch sei", "gute frage", "meine erste frage",
        "asked whether", "asked if", "she asked", "he asked", "they asked",
        "don't know why", "dont know why", "not sure why", "not sure how",
        "figure out", "that's why", "that is why", "thats why",
        "i'll show you", "ill show you", "show you how", "we'll show",
        "as i said", "good question", "my first question", "what matters"
    ]

    /// „Sich fragen / to wonder“ – mitten durch diese Wendung läuft die Grenze
    /// zwischen Selbstgespräch und Frage, deshalb steht sie nicht mehr bei der
    /// berichteten Rede. „I wonder why the cache misses spiked“ erwartet keine
    /// Antwort; „I was wondering whether you have a rollback plan“ ist die
    /// höflichste Form, eine zu stellen. Bis hierher fiel beides stumm heraus.
    private static let wonderingMarkers: [String] = [
        "i wonder", "wonder why", "wonder how", "wonder if", "wondering",
        "ich frage mich", "wir fragen uns", "ich habe mich gefragt",
        "ich hab mich gefragt", "wir haben uns gefragt", "wir hatten uns gefragt"
    ]

    /// Die englische Verlaufsform in der Vergangenheit ist konventionalisiert:
    /// „I was wondering …“ leitet eine Bitte ein, kein Grübeln. Das gilt nur
    /// fürs Englische – „Ich habe mich gefragt …“ bleibt zweideutig und braucht
    /// zusätzlich die Anrede des Zuhörers, sonst wäre „Wir haben uns gefragt,
    /// warum das damals so gebaut wurde“ plötzlich eine Frage an die Runde.
    private static let politeWonderOpeners: [String] = [
        "i was wondering", "we were wondering",
        "i've been wondering", "ive been wondering",
        "i had been wondering"
    ]

    /// Rhetorical questions – question-shaped, but nobody expects an answer.
    private static let rhetoricalMarkers: [String] = [
        "wer hätte das gedacht", "wer hätte gedacht", "was soll da schon",
        "was soll schon", "was kann da schon", "wen interessiert",
        "wen wundert", "wen wundert's", "na und",
        "who would have thought", "what could possibly go wrong",
        "who cares", "isn't that always", "isnt that always", "who knew"
    ]

    /// Requests that count as questions only when they open the sentence –
    /// "Explain the setup" asks, "they explain the setup" does not. Checked
    /// against the sentence with and without leading fillers, so "Bitte
    /// erklären Sie …" and "Please walk us through …" match too.
    ///
    /// Der Abgleich läuft über `startsWithRequest` auf Wortgrenze. Vorher war
    /// es ein reiner Präfixvergleich, und „Erklärt hat uns das bisher niemand“
    /// – ein Aussagesatz mit Partizip – galt als Bitte.
    private static let anchoredRequests: [String] = [
        "erklär", "erkläre", "erklärt mir", "erklärt uns", "erklären sie",
        "erläutere", "erläuter mir", "erläutert mir", "erläutern sie",
        "erzähl", "erzählen sie",
        "beschreib", "beschreibe", "beschreiben sie", "schildere", "schildern sie",
        "sag mir", "sag uns", "sagen sie mir", "sagen sie uns", "sagt mir",
        "nenn mir", "nennen sie mir", "definiere",
        "sag mal", "sagt mal", "sagen sie mal", "zeig mir", "zeig uns",
        "zeigen sie", "zeig mal", "schick mir", "schick uns", "schicken sie",
        "gib mir", "geben sie mir", "verrate mir", "verrat mir",
        "fass zusammen", "fasse zusammen", "fassen sie",
        "hilf mir", "helfen sie mir", "helft mir",
        "tell me", "tell us", "walk me through", "walk us through",
        "talk me through", "run me through", "run us through",
        "take me through", "take us through",
        "explain", "describe", "summarize", "summarise", "clarify",
        "elaborate on", "break down", "lay out",
        "outline the", "outline how", "outline what",
        "give me a sense",
        "give me an idea", "help me understand", "show me", "show us",
        "send me", "send us", "give us", "mind sharing", "mind telling",
        "mind walking",
        "expliquez", "explique", "dis-moi", "dites-moi",
        "explícame", "dime", "cuéntame",
        "spiegami", "dimmi", "raccontami",
        "leg uit", "vertel me"
    ]

    /// Request phrases that are safe to match anywhere in the sentence.
    private static let anywhereRequests: [String] = [
        "mich würde interessieren", "uns würde interessieren",
        "würde mich interessieren", "würde uns interessieren",
        "ich würde gern wissen", "ich würde gerne wissen", "wir würden gern wissen",
        "wüsste gern", "wüsste gerne", "wüssten gern", "wüssten gerne",
        "wäre spannend zu wissen", "wäre hilfreich zu wissen",
        "was meinst du", "was denkst du", "was hältst du", "was halten sie",
        "deine meinung", "ihre meinung", "wie siehst du das", "wie sehen sie das",
        "wollte fragen", "wollte noch fragen", "wollte kurz fragen",
        "wollte mal fragen", "hätte da eine frage", "hätte noch eine frage",
        "habe da eine frage", "habe noch eine frage", "eine frage hätte ich",
        "wäre gut zu wissen", "wäre interessant zu wissen",
        "i'd like to know", "i would like to know", "i'd love to know",
        "i'd be interested", "i would be interested", "we'd be interested",
        "would love to hear", "keen to know", "keen to hear",
        "i'm curious", "i am curious", "curious how", "curious what",
        "your take", "your thoughts", "any thoughts", "let me know what you think",
        "what do you think", "how do you see", "wanted to ask", "meant to ask",
        "i have a question", "quick question", "one more question",
        "would be good to know", "would be great to know"
    ]

    /// Asking for a repeat is one of the most common turns in a call and was
    /// the single false negative the model stage produced. It never needs a
    /// model round trip – the wording is unambiguous.
    private static let repeatRequests: [String] = [
        "könnten sie das wiederholen", "können sie das wiederholen",
        "kannst du das wiederholen", "könntest du das wiederholen",
        "wiederholen sie das", "wiederhol das", "wiederhole das",
        "nochmal bitte", "bitte nochmal", "das nochmal", "wie bitte",
        "den letzten teil wiederholen", "was hast du gesagt", "was haben sie gesagt",
        "could you repeat", "can you repeat", "could you say that again",
        "say that again", "come again", "one more time", "you broke up",
        "you cut out", "i missed that", "i didn't catch that", "i didnt catch that",
        "repeat the last", "what was that"
    ]

    /// Tag endings that turn a statement into a confirmation question.
    private static let tagEndings: [String] = [
        ", oder?", " oder?", "richtig?", "stimmt's?", "stimmts?", "korrekt?",
        "nicht wahr?", "oder nicht?", ", ja?", ", ne?", ", gell?",
        "right?", "correct?", "isn't it?", "isnt it?",
        "doesn't it?", "doesnt it?", "didn't you?", "didnt you?",
        "didn't we?", "didnt we?", "haven't you?", "havent you?",
        "haven't we?", "havent we?", "hasn't it?", "hasnt it?",
        "aren't you?", "arent you?", "aren't they?", "arent they?",
        "can't we?", "cant we?", "won't it?", "wont it?",
        "don't you?", "dont you?", "wouldn't it?", "no?", "yes?"
    ]

    /// Unmissverständliche Anreden an den Zuhörer. „sie/ihre/ihnen“ fehlen
    /// bewusst – klein geschrieben heißen sie genauso oft „she/they“. Die
    /// Höflichkeitsform wird stattdessen über ihre Großschreibung erkannt.
    private static let secondPersonWords: Set<String> = [
        "du", "dich", "dir", "dein", "deine", "deinem", "deinen", "deiner", "deins",
        "ihr", "euch", "euer", "eure", "eurem", "euren", "eurer", "eures",
        "you", "your", "yours", "yourself", "yourselves"
    ]

    private static let formalAddress: Set<String> = [
        "Sie", "Ihnen", "Ihr", "Ihre", "Ihrem", "Ihren", "Ihrer", "Ihres"
    ]

    /// Ob der Satz erkennbar den Zuhörer anspricht.
    private static func addressesListener(_ sentence: String, words: [String]) -> Bool {
        if words.contains(where: { secondPersonWords.contains($0) }) { return true }
        // Im Deutschen bleibt die Höflichkeitsform auch mitten im Satz groß,
        // „sie“ nicht. Das erste Wort zählt nicht mit – dort sagt die
        // Großschreibung nichts aus.
        let original = sentence
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
        return original.dropFirst().contains { formalAddress.contains($0) }
    }

    /// Ob der Satz mit einer der verankerten Bitten anfängt. Anders als ein
    /// nackter Präfixvergleich endet der Treffer auf einer Wortgrenze: „erklär“
    /// trifft „Erklär mir mal den Ablauf“, aber nicht mehr „Erklärt hat uns das
    /// bisher niemand“ – dort ist es ein Partizip mitten in einer Aussage.
    private static func startsWithRequest(_ text: String) -> Bool {
        for pattern in anchoredRequests where text.hasPrefix(pattern) {
            let rest = text.dropFirst(pattern.count)
            if rest.isEmpty || rest.first?.isLetter == false { return true }
        }
        return false
    }

    /// Liefert die Konfidenz, wenn der Satz auf einer Rückversicherung endet,
    /// deren Fragezeichen die Spracherkennung verschluckt hat.
    ///
    /// Verlangt wird das Komma unmittelbar vor dem Anhängsel. Ohne diese
    /// Bedingung galt „Sounds about right.“ und „Right, that is correct.“ als
    /// Rückfrage, weil beide auf „right“/„correct“ enden – dort steht das Komma
    /// aber vorne. Ein abschließender Punkt stört nicht: er kommt vom
    /// Satzzerleger, nicht von der Betonung.
    private static func trailingTag(_ lowered: String) -> Double? {
        let core = lowered.trimmingCharacters(
            in: CharacterSet(charactersIn: " .!…")
        )
        for phrase in tagPhrasesWithoutMark where core.hasSuffix(", " + phrase) {
            return 0.65
        }
        guard let last = core.split(whereSeparator: { $0.isWhitespace }).last else { return nil }
        let word = String(last).trimmingCharacters(in: CharacterSet.punctuationCharacters)
        if tagWordsWithoutMark.contains(word), core.hasSuffix(", " + word) {
            return 0.65
        }
        return nil
    }

    /// Ob ein schließendes Verb einen deutschen Nebensatz beendet, statt einen
    /// abgerissenen Satz zu markieren.
    ///
    /// Deutsch stellt das Verb im Nebensatz ans Ende, deshalb hört „Könntest du
    /// kurz sagen, wie das gemeint ist“ auf „ist“ auf – genau wie das echte
    /// Bruchstück „Was mich dabei noch interessieren würde ist“. Unterscheiden
    /// lässt sich beides am Komma: folgt darauf ein Einleitewort, schließt das
    /// Endverb den Nebensatz ab und der Satz ist fertig. Ohne Komma wartet der
    /// Hauptsatz noch auf sein Objekt.
    private static func closesGermanSubordinateClause(_ lowered: String, words: [String]) -> Bool {
        guard let last = words.last, clauseFinalVerbs.contains(last) else { return false }
        guard let comma = lowered.lastIndex(of: ",") else { return false }
        let tail = lowered[lowered.index(after: comma)...]
        guard let head = tail.split(whereSeparator: { $0.isWhitespace }).first else { return false }
        return clauseIntroducers.contains(
            String(head).trimmingCharacters(in: CharacterSet.punctuationCharacters)
        )
    }

    private static func normalizedWords(_ lowered: String) -> [String] {
        lowered
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Peels at most three leading fillers off the word list. Falls back to
    /// the original words when everything would be stripped ("Ja genau").
    private static func stripLeadingFillers(_ words: [String]) -> [String] {
        var remainder = words[...]
        var removed = 0
        while removed < 3, let first = remainder.first, leadingFillers.contains(first) {
            remainder = remainder.dropFirst()
            removed += 1
        }
        return remainder.isEmpty ? words : Array(remainder)
    }

    /// Whether a fragment without a terminator visibly stops mid-thought.
    /// The assembler uses this to wait longer before flushing.
    public static func endsIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix(".") || trimmed.hasSuffix("!")
            || trimmed.hasSuffix("…") {
            return false
        }
        if trimmed.hasSuffix(",") { return true }
        let words = normalizedWords(trimmed.lowercased())
        guard let last = words.last else { return false }
        // "Und dann" alone is a complete short question – but only alone.
        // "… machen und dann" is a sentence stopping mid-thought.
        if words.count <= 3, shortQuestionWhitelist.contains(words.joined(separator: " ")) {
            return false
        }
        return continuationEndings.contains(last)
    }

    /// Classifies one utterance. Handles multi-sentence utterances: the whole
    /// text is split, questions are found per sentence, and a question that the
    /// speaker immediately answers themselves ("Warum? Weil …") is dismissed.
    public static func assessQuestion(_ text: String) -> QuestionAssessment {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notQuestion }

        let split = splitSentences(trimmed)
        var sentences = split.complete
        if !split.remainder.isEmpty { sentences.append(split.remainder) }
        guard !sentences.isEmpty else { return .notQuestion }

        if sentences.count == 1 {
            return assessSentence(sentences[0], isTrailingFragment: split.complete.isEmpty)
        }

        // Multi-sentence: find questions, watch for self-answers right after.
        var best: Double = 0
        for (index, sentence) in sentences.enumerated() {
            guard case .question(let confidence) = assessSentence(
                sentence,
                isTrailingFragment: index == sentences.count - 1 && !split.remainder.isEmpty
            ) else { continue }
            if index + 1 < sentences.count, answersPreviousQuestion(sentences[index + 1]) {
                continue   // rhetorical: asked and answered in one breath
            }
            best = max(best, confidence)
        }
        if best > 0 { return .question(confidence: best) }

        // No question found – incomplete if the tail is a dangling fragment.
        if !split.remainder.isEmpty && endsIncomplete(split.remainder) {
            return .incomplete
        }
        return .notQuestion
    }

    private static func assessSentence(_ sentence: String, isTrailingFragment: Bool) -> QuestionAssessment {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notQuestion }
        let lowered = trimmed.lowercased()
        let words = normalizedWords(lowered)
        guard !words.isEmpty else { return .notQuestion }
        let endsWithQuestionMark = trimmed.hasSuffix("?")
        let bare = words.joined(separator: " ")

        // Complete short questions win before any other rule.
        if shortQuestionWhitelist.contains(bare) {
            return .question(confidence: 0.95)
        }
        if isRepeatRequest(lowered) {
            return .question(confidence: 0.95)
        }

        // Rhetoric: question-shaped, no answer expected.
        for marker in rhetoricalMarkers where lowered.contains(marker) {
            return .notQuestion
        }

        // Opener checks run on the sentence without its leading fillers:
        // "Also, wie machen wir weiter" asks the same thing as "Wie machen
        // wir weiter". The stripped view never removes a question word,
        // because the filler list is disjoint from the opener list.
        let effective = stripLeadingFillers(words)
        let strippedLowered = effective.joined(separator: " ")
        let firstIsInterrogative = interrogativeOpeners.contains(effective[0])
        let secondIsInterrogative = effective.count > 1 && interrogativeOpeners.contains(effective[1])
        let containsInterrogative = words.contains { interrogativeOpeners.contains($0) }
        let addressed = addressesListener(trimmed, words: words)

        // "Und was machen wir dann" opens with a question word and ends on an
        // adverb – a complete flat question, not a fragment. Hard enders
        // ("Was mich interessieren würde ist") still count as unfinished.
        let flatQuestionDespiteTrailer = strongInterrogatives.contains(effective[0])
            && effective.count >= 4
            && words.last.map { softQuestionTrailers.contains($0) } == true

        // Einmal berechnet, dreimal gebraucht: hört der Satz sichtbar mitten im
        // Gedanken auf? Der deutsche Nebensatzabschluss ist die Ausnahme, sonst
        // gälte „…, wie das gemeint ist“ wegen des Endverbs als abgerissen.
        let dangling = endsIncomplete(trimmed)
            && !flatQuestionDespiteTrailer
            && !closesGermanSubordinateClause(lowered, words: words)

        // Indirekte Frage im „Ich frage mich …“-Rahmen. Steht vor der
        // berichteten Rede, weil deren Marker „gefragt, ob“ sonst jedes
        // „Ich habe mich gefragt, ob ihr …“ verschluckt.
        if let frame = wonderingMarkers
            .compactMap({ lowered.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            if isTrailingFragment && dangling { return .incomplete }
            // Ohne Nebensatz wird nichts erfragt: „I was wondering about that
            // too“ ist eine Zustimmung, kein Anliegen.
            //
            // Gesucht wird nur hinter der Wendung. Davor stünde sonst das
            // englische „was“ aus „I was wondering“ – im Deutschen ein
            // Fragewort, und jede höfliche Floskel wäre eine Frage.
            let clauseWords = normalizedWords(String(lowered[frame.upperBound...]))
            let hasClause = clauseWords.contains { clauseIntroducers.contains($0) }
            if hasClause {
                if politeWonderOpeners.contains(where: {
                    lowered.hasPrefix($0) || strippedLowered.hasPrefix($0)
                }) {
                    return .question(confidence: 0.7)
                }
                if addressed { return .question(confidence: 0.6) }
            }
            return endsWithQuestionMark ? .question(confidence: 0.5) : .notQuestion
        }

        // Reported speech, embedded clauses, meta talk.
        for marker in reportedSpeechMarkers where lowered.contains(marker) {
            // With a question mark this may still be a genuine question
            // ("Das erklärt es, oder?") – leave the call to the model.
            return endsWithQuestionMark ? .question(confidence: 0.5) : .notQuestion
        }

        if endsWithQuestionMark {
            for tag in tagEndings where lowered.hasSuffix(tag) {
                return .question(confidence: 0.95)
            }
            if words.count <= 3 {
                // "Warum?" is unambiguous, "Wirklich?" is not.
                return .question(confidence: firstIsInterrogative ? 0.95 : 0.6)
            }
            if firstIsInterrogative || secondIsInterrogative {
                return .question(confidence: 0.95)
            }
            // Question mark, but interrogative buried mid-sentence or absent:
            // usually still a question, occasionally rhetoric – model confirms.
            return .question(confidence: containsInterrogative ? 0.9 : 0.8)
        }

        // No question mark from here on (flat intonation, "." or nothing).

        // Tag endings survive a dropped question mark: "Das passt so, oder".
        // Checked before the fragment rule, because "oder" also counts as a
        // continuation word – here the pause already decided the reading.
        // Mehrwortige Anhängsel („…, isn't it“) laufen über dieselbe Prüfung;
        // sie enden auf einem Pronomen und galten vorher als Bruchstück.
        if words.count >= 3, let confidence = trailingTag(lowered) {
            return .question(confidence: confidence)
        }

        // A dangling fragment is not a question yet.
        if isTrailingFragment && dangling {
            return .incomplete
        }

        if startsWithRequest(lowered) || startsWithRequest(strippedLowered) {
            return .question(confidence: 0.75)
        }
        for pattern in anywhereRequests where lowered.contains(pattern) {
            return .question(confidence: 0.8)
        }

        // Statement-final continuation words without a terminator: unfinished.
        if dangling {
            return .incomplete
        }

        // Elliptical short questions ("Wie lange", "Seit wann", "Wie oft"): at
        // most three words with a genuine question word among them.
        //
        // Das Fragewort musste früher vorn stehen. Damit fielen genau die
        // Nachfragen heraus, die im Gespräch am häufigsten sind – „Seit wann“,
        // „Bis wann genau“, „For how long“ –, weil eine Präposition davorsteht.
        // Bei höchstens drei Wörtern ist die Position kein Risiko: kein
        // Einwurf im Datensatz („Mhm, macht Sinn“, „Genau richtig“, „Passt
        // schon“) enthält ein echtes Fragewort.
        if effective.count <= 3 && effective.contains(where: { strongInterrogatives.contains($0) }) {
            return .question(confidence: 0.6)
        }

        // Elliptische Nachfrage hinter einem Bindewort: „Und danach“, „And the
        // cost“. Nur wenn das Bindewort wirklich abgeschält wurde, der Rest
        // höchstens drei Wörter lang ist und mit einem Zeit- oder
        // Bestimmungswort beginnt. 0,5 statt 0,95: die Lesart hängt am
        // Vorgängersatz, den nur Stufe 2 kennt.
        if words.count > effective.count,
           connectorOpeners.contains(words[0]),
           effective.count <= 3,
           ellipticalFollowUpHeads.contains(effective[0]) {
            return .question(confidence: 0.5)
        }

        if effective.count <= 2 { return .notQuestion }   // backchannels

        // After the filler peel the question word has to stand FIRST: German
        // and English put the verb second in statements ("Genau, das passt …"),
        // so a second-position opener in the stripped sentence is declarative.
        if firstIsInterrogative {
            // "Wie sieht euer Prozess aus" – full question, flat intonation.
            return .question(confidence: effective.count >= 4 ? 0.75 : 0.55)
        }

        // Letzte Instanz vor „keine Frage“: Der Satz spricht den Zuhörer an
        // und enthält ein Frage- oder Modalwort, passt aber in keines der
        // Muster oben – „Ich bin gespannt, wie ihr das gelöst habt“ ist der
        // Normalfall. Bisher fiel so etwas hier stillschweigend heraus und
        // wurde dem Modell nie gezeigt. Jetzt geht es mit niedriger Konfidenz
        // weiter: genau diese Stufe steuert die Auslöseschwelle.
        if effective.count >= 5, addressed, containsInterrogative {
            return .question(confidence: 0.4)
        }

        return .notQuestion
    }

    /// Repeat requests used to be substring matches. That made statements such
    /// as "Es wäre gut, das nochmal gegenzulesen" immediate questions merely
    /// because they contained "das nochmal". Short forms now have to be the
    /// whole utterance; longer request clauses may start the utterance after a
    /// small conversational filler.
    static func isRepeatRequest(_ text: String) -> Bool {
        let words = normalizedWords(text)
        let bare = words.joined(separator: " ")
        let withoutFillers = stripLeadingFillers(words).joined(separator: " ")

        return repeatRequests.contains { pattern in
            let normalizedPattern = normalizedWords(pattern).joined(separator: " ")
            if normalizedPattern.split(separator: " ").count <= 3 {
                return bare == normalizedPattern || withoutFillers == normalizedPattern
            }
            return bare == normalizedPattern
                || bare.hasPrefix(normalizedPattern + " ")
                || withoutFillers == normalizedPattern
                || withoutFillers.hasPrefix(normalizedPattern + " ")
        }
    }

    /// Ob dieser Satz die unmittelbar davor gestellte Frage selbst beantwortet
    /// – „Warum machen wir das? Weil uns das letztes Jahr auf die Füße
    /// gefallen ist.“ Gefragt wurde da niemand.
    ///
    /// Zwei Stellen brauchen dieselbe Entscheidung: `assessQuestion` innerhalb
    /// einer Äußerung und die Pipeline über Äußerungsgrenzen hinweg. Zwei
    /// Kopien derselben Wortliste sind genau die Art von Doppelung, bei der
    /// später eine der beiden gepflegt wird und die andere nicht.
    public static func answersPreviousQuestion(_ sentence: String) -> Bool {
        let lowered = sentence.lowercased().trimmingCharacters(in: .whitespaces)
        return lowered.hasPrefix("weil") || lowered.hasPrefix("because")
            || lowered.hasPrefix("na weil") || lowered.hasPrefix("denn ")
    }

    /// Dampft eine Äußerung auf die Sätze ein, die tatsächlich eine Frage
    /// stellen.
    ///
    /// Der Erkenner liefert nicht satzweise: „Wir haben das gestern
    /// ausgerollt. Wie lange dauert die Neuindizierung?“ kommt als ein Stück.
    /// `assessQuestion` erkennt darin die Frage – aber beantwortet wurde
    /// bisher der **ganze Block**, samt der Aussage davor. Das Antwortmodell
    /// bekam damit eine Frage, die zur Hälfte gar keine war, und die
    /// Dublettenprüfung einen Fingerabdruck, der an der Aussage hing.
    ///
    /// Der Zusammenhang geht dabei nicht verloren: die vollständige Äußerung
    /// steht im Gesprächsgedächtnis und wird dem Antwortmodell ohnehin als
    /// Verlauf mitgegeben – „Wäre das sinnvoll?“ bleibt also auflösbar.
    ///
    /// Findet sich keine Frage, bleibt der Text unverändert. Diese Funktion
    /// urteilt nicht darüber, **ob** etwas eine Frage ist; das tut
    /// `assessQuestion`.
    public static func questionFocus(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let split = splitSentences(trimmed)
        var sentences = split.complete
        if !split.remainder.isEmpty { sentences.append(split.remainder) }
        guard sentences.count > 1 else { return trimmed }

        var kept: [String] = []
        for (index, sentence) in sentences.enumerated() {
            guard case .question = assessSentence(
                sentence,
                isTrailingFragment: index == sentences.count - 1 && !split.remainder.isEmpty
            ) else { continue }
            if index + 1 < sentences.count, answersPreviousQuestion(sentences[index + 1]) {
                continue
            }
            kept.append(sentence)
        }
        return kept.isEmpty ? trimmed : kept.joined(separator: " ")
    }

    /// Backwards-compatible scalar view of `assessQuestion`.
    public static func questionLikelihood(_ text: String) -> Double {
        switch assessQuestion(text) {
        case .notQuestion: return 0.1
        case .incomplete: return 0.2
        case .question(let confidence): return confidence
        }
    }

    /// Splits a streamed answer into the sentence the user reads aloud and the
    /// background behind the disclosure triangle.
    ///
    /// Built for streaming: while the marker is still arriving character by
    /// character, its partial text must not flash up in the spoken part, so any
    /// trailing prefix of the marker is held back.
    public static func splitAnswer(
        _ text: String,
        marker: String = Prompts.answerDetailMarker
    ) -> (spoken: String, details: String) {
        // Tolerate the shapes models reach for when they drift from the prompt.
        // Decorated forms come first so the bare marker does not match inside
        // them and leave the decoration behind on both sides.
        if let hit = findMarker(in: text, marker: marker) {
            let spoken = String(text[..<hit.range.lowerBound])
            let details = String(text[hit.range.upperBound...])
            return (cleanAnswerPart(spoken), cleanAnswerPart(details))
        }

        // No marker yet: everything is spoken, minus a half-arrived marker.
        var spoken = text
        for length in stride(from: min(marker.count, text.count), through: 1, by: -1) {
            let tail = String(text.suffix(length))
            if marker.hasPrefix(tail) {
                spoken = String(text.dropLast(length))
                break
            }
        }
        return (cleanAnswerPart(spoken), "")
    }

    /// Parses the constrained JSON answer and falls back to the legacy two-part
    /// text format. The fallback is intentionally conservative: malformed JSON
    /// must never become something the user reads aloud verbatim.
    public static func parseStructuredAnswer(_ text: String) -> StructuredAnswer {
        let cleaned = stripThinking(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = jsonObjectData(in: cleaned),
           let decoded = try? JSONDecoder().decode(StructuredAnswer.self, from: data) {
            return sanitize(decoded)
        }

        if let objectStart = cleaned.firstIndex(of: "{") {
            let object = String(cleaned[objectStart...])
            let spoken = jsonStringField("spoken", in: object, allowIncomplete: true) ?? ""
            let details = jsonStringField("details", in: object, allowIncomplete: true) ?? ""
            return sanitize(StructuredAnswer(
                spoken: spoken.isEmpty ? "Dazu fehlen mir verlässliche Informationen." : spoken,
                details: details,
                confidence: .low,
                missingContext: ["Die Modellantwort war unvollständig oder nicht lesbar."]
            ))
        }

        let legacy = splitAnswer(cleaned)
        return sanitize(StructuredAnswer(
            spoken: legacy.spoken.isEmpty
                ? "Dazu fehlen mir verlässliche Informationen."
                : legacy.spoken,
            details: legacy.details,
            confidence: .low,
            missingContext: []
        ))
    }

    private static func sanitize(_ answer: StructuredAnswer) -> StructuredAnswer {
        var result = answer
        result.spoken = clampSpokenAnswer(cleanAnswerPart(result.spoken))
        if result.spoken.isEmpty {
            result.spoken = "Dazu fehlen mir verlässliche Informationen."
            result.confidence = .low
        }
        result.details = cleanAnswerPart(result.details)
        var seen = Set<String>()
        result.missingContext = result.missingContext.compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
        if !result.missingContext.isEmpty { result.confidence = .low }
        return result
    }

    /// Downgrades answers containing concrete numeric claims absent from the
    /// verbatim transcript or user profile. This complements the prompt with a
    /// deterministic check for the most damaging kind of invented detail.
    public static func groundStructuredAnswer(
        _ answer: StructuredAnswer,
        evidence: String
    ) -> StructuredAnswer {
        var result = answer
        let claimed = numericClaims(in: result.spoken + " " + result.details)
        let supported = numericClaims(in: evidence)
        let unsupported = claimed.subtracting(supported).sorted()
        guard !unsupported.isEmpty else { return result }
        result.confidence = .low
        let unsupportedInSpoken = numericClaims(in: result.spoken).intersection(unsupported)
        if !unsupportedInSpoken.isEmpty {
            result.spoken = "Dazu fehlt mir noch eine verlässliche Zahlenangabe."
        }
        result.details = "Nicht belegte Zahlenangabe des Modells wurde verworfen: "
            + unsupported.joined(separator: ", ") + "."
        for claim in unsupported {
            let note = "Beleg für die Zahlenangabe „\(claim)“"
            if !result.missingContext.contains(note) { result.missingContext.append(note) }
        }
        return result
    }

    private static func numericClaims(in text: String) -> Set<String> {
        let tokens = text.split { !$0.isLetter && !$0.isNumber }.map { String($0).lowercased() }
        var claims = Set<String>()
        for index in tokens.indices where tokens[index].contains(where: \.isNumber) {
            var claim = tokens[index]
            let next = tokens.index(after: index)
            if next < tokens.endIndex, tokens[next].contains(where: \.isLetter) {
                let unit = normalizedUnit(tokens[next])
                if groundingUnits.contains(unit) { claim += " " + unit }
            }
            claims.insert(claim)
        }
        return claims
    }

    private static func normalizedUnit(_ unit: String) -> String {
        for suffix in ["ern", "en", "er", "es", "e", "n", "s"]
        where unit.count - suffix.count >= 3 && unit.hasSuffix(suffix) {
            return String(unit.dropLast(suffix.count))
        }
        return unit
    }

    private static let groundingUnits: Set<String> = [
        "tag", "woch", "monat", "jahr", "stund", "minut", "sekund", "millisekund",
        "euro", "dollar", "prozent", "percent", "lizenz", "nutz", "user", "person",
        "byte", "kilobyte", "megabyte", "gigabyte", "terabyte", "kb", "mb", "gb", "tb",
        "ms", "hz", "khz", "mhz", "ghz", "bit", "kbit", "mbit", "gbit"
    ]

    /// Final safety net for a model that ignores the requested 45-word limit.
    static func clampSpokenAnswer(_ text: String, maxWords: Int = 45, maxSentences: Int = 3) -> String {
        let split = splitSentences(text)
        var candidate: String
        if split.complete.count >= maxSentences {
            candidate = split.complete.prefix(maxSentences).joined(separator: " ")
        } else {
            candidate = text
        }
        let words = candidate.split(whereSeparator: \.isWhitespace)
        guard words.count > maxWords else { return candidate.trimmingCharacters(in: .whitespacesAndNewlines) }
        var limited = words.prefix(maxWords).joined(separator: " ")
        limited = limited.trimmingCharacters(in: CharacterSet(charactersIn: ",;:–—-"))
        if limited.last.map({ ".!?".contains($0) }) != true { limited += "…" }
        return limited
    }

    private static func jsonObjectData(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else {
            return nil
        }
        return String(text[start...end]).data(using: .utf8)
    }

    /// Extracts a JSON string field even while its value is still streaming.
    /// Decoding through JSONSerialization handles escaped quotes and newlines.
    private static func jsonStringField(
        _ field: String,
        in text: String,
        allowIncomplete: Bool
    ) -> String? {
        guard let key = text.range(of: "\"\(field)\"") else { return nil }
        var cursor = key.upperBound
        while cursor < text.endIndex, text[cursor].isWhitespace || text[cursor] == ":" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "\"" else { return nil }
        cursor = text.index(after: cursor)
        var encoded = "\""
        var escaped = false
        var terminated = false
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "\"", !escaped {
                encoded.append("\"")
                terminated = true
                break
            }
            encoded.append(character)
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            cursor = text.index(after: cursor)
        }
        guard terminated || allowIncomplete else { return nil }
        if !terminated {
            if escaped { encoded.removeLast() }
            encoded.append("\"")
        }
        guard let data = encoded.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return value
    }

    /// Streaming facade for structured answers. During JSON generation only
    /// `spoken` and `details` are exposed; metadata is committed at `finish`.
    public struct StructuredAnswerStreamFormatter {
        private var accumulated = ""
        private var legacy = AnswerStreamFormatter()

        public init() {}

        public mutating func append(_ chunk: String) {
            accumulated += chunk
            legacy.append(chunk)
        }

        public var current: (spoken: String, details: String) {
            let visible = stripThinking(accumulated).trimmingCharacters(in: .whitespacesAndNewlines)
            // This formatter is only used for schema-constrained requests.
            // Before the object begins, any bytes are a preamble/code fence,
            // never safe spoken content. Legacy free text remains available at
            // `finish`, once we know no JSON object arrived.
            guard let objectStart = visible.firstIndex(of: "{") else { return ("", "") }
            let object = String(visible[objectStart...])
            return (
                clampSpokenAnswer(jsonStringField("spoken", in: object, allowIncomplete: true) ?? ""),
                cleanAnswerPart(jsonStringField("details", in: object, allowIncomplete: true) ?? "")
            )
        }

        public func finish() -> StructuredAnswer {
            parseStructuredAnswer(accumulated)
        }

        public var rawText: String { accumulated }
    }

    /// Ein Marker-Fund samt der Frage, ob er endgültig ist.
    struct MarkerHit {
        let range: Range<String.Index>
        /// Kann eine höherwertige Variante diesen Fund noch überholen?
        ///
        /// Ja, solange dem Fund eine Auszeichnung vorausgeht: aus
        /// `**Hintergrund` wird eine Zeile später `**Hintergrund**`, und dann
        /// liegt die Trennstelle zwei Zeichen weiter vorn. Das gilt über zwei
        /// Stufen – auch ein bereits gefundenes `*Hintergrund*` kann noch zu
        /// `**Hintergrund**` werden. Wer zu früh festlegt, lässt die
        /// Sternchen im gesprochenen Teil stehen.
        let isSettled: Bool
    }

    /// Sucht die Trennstelle zwischen Gesprochenem und Hintergrund.
    ///
    /// Die Reihenfolge ist Absicht: ausgezeichnete Formen zuerst, damit der
    /// nackte Marker nicht mitten in ihnen greift und die Auszeichnung auf
    /// beiden Seiten liegen lässt.
    static func findMarker(in text: String, marker: String) -> MarkerHit? {
        let variants = [
            "**\(marker)**", "*\(marker)*", "__\(marker)__",
            marker, "[[MEHR]]", "TEIL 2"
        ]
        for (rank, variant) in variants.enumerated() {
            guard let range = text.range(of: variant) else { continue }
            // Die höchstwertige Form kann von nichts mehr überholt werden.
            var settled = rank == 0
            if !settled {
                if range.lowerBound == text.startIndex {
                    settled = true
                } else {
                    let before = text[text.index(before: range.lowerBound)]
                    settled = !(before == "*" || before == "_")
                }
            }
            return MarkerHit(range: range, isSettled: settled)
        }
        return nil
    }

    static func cleanAnswerPart(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Models label the parts even when told not to, and they do it with
        // whatever decoration they feel like: "TEIL 1", "**Teil 2 – Hintergrund**",
        // "## Teil 1:". Drop the whole first line whenever it is just a label.
        if let lineEnd = result.firstIndex(where: { $0.isNewline }) {
            let firstLine = result[..<lineEnd]
                .trimmingCharacters(in: CharacterSet(charactersIn: " *#_-–—:"))
                .lowercased()
            if firstLine.hasPrefix("teil 1") || firstLine.hasPrefix("teil 2")
                || firstLine.hasPrefix("part 1") || firstLine.hasPrefix("part 2") {
                result = String(result[result.index(after: lineEnd)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Same label, but inline instead of on its own line.
        for prefix in ["TEIL 1", "TEIL 2", "Teil 1", "Teil 2", "**Teil 1**", "**Teil 2**"]
        where result.hasPrefix(prefix) {
            result = String(result.dropFirst(prefix.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: " :–—-\n*"))
            break
        }
        return result
    }

    /// Baut eine streamende Antwort Stück für Stück zusammen.
    ///
    /// Der naheliegende Weg – bei jedem Token `splitAnswer(stripThinking(alles))`
    /// – ist quadratisch: sechs Markervarianten werden über den **gesamten**
    /// bisherigen Text gesucht, dazu zwei Aufräumläufe, und das für jedes
    /// einzelne Token. Das läuft auf dem Pipeline-Actor, blockiert also
    /// Aufnahme, Übersetzung und Klassifikation – ausgerechnet in der Phase, in
    /// der es auf Latenz ankommt.
    ///
    /// Ausgenutzt wird hier, dass Text nur hinten wächst: sobald die Trennstelle
    /// endgültig feststeht, ist der gesprochene Teil fertig und jedes weitere
    /// Token hängt nur noch an den Hintergrund an. Gesucht wird ab da nichts
    /// mehr.
    ///
    /// `finish()` rechnet bewusst noch einmal vollständig – das Ergebnis, das
    /// gespeichert und angezeigt wird, ist damit Zeichen für Zeichen dasselbe
    /// wie vorher.
    public struct AnswerStreamFormatter {

        private let marker: String
        private var accumulated = ""
        /// Steht die Trennstelle fest, ist das hier der fertige Sprechteil.
        private var latchedSpoken: String?
        private var detailsRaw = ""
        /// Ist überhaupt ein Denkblock im Spiel? Die Modelle werden mit
        /// `think: false` gefragt, im Regelfall also nicht – dann entfällt
        /// `stripThinking` ganz.
        private var sawThinkingTag = false
        /// Die letzten Zeichen, damit ein über zwei Chunks zerrissenes
        /// `<think>` nicht durchrutscht.
        private var tail = ""

        public init(marker: String = Prompts.answerDetailMarker) {
            self.marker = marker
        }

        public mutating func append(_ chunk: String) {
            guard !chunk.isEmpty else { return }
            accumulated += chunk

            // Die Erkennung von Denkblöcken läuft **auch nach dem Einrasten**
            // weiter. Sonst zeigte die Live-Ansicht ein rohes Denkprotokoll,
            // das im gespeicherten Ergebnis anschließend fehlt: `finish()`
            // rechnet immer über den gesamten Text, `current` aber sähe den
            // Block nie. Ein Modell, das `think: false` übergeht, reicht dafür.
            if !sawThinkingTag {
                let window = tail + chunk
                if window.contains("<") { sawThinkingTag = window.contains("<think>") }
                tail = String(window.suffix(6))
            }

            if latchedSpoken != nil {
                detailsRaw += chunk
                return
            }
            latchIfPossible()
        }

        private mutating func latchIfPossible() {
            let visible = sawThinkingTag ? stripThinking(accumulated) : accumulated
            guard let hit = findMarker(in: visible, marker: marker), hit.isSettled else { return }
            latchedSpoken = cleanAnswerPart(String(visible[..<hit.range.lowerBound]))
            detailsRaw = String(visible[hit.range.upperBound...])
        }

        /// Was gerade angezeigt werden soll.
        public var current: (spoken: String, details: String) {
            if let latchedSpoken {
                let details = sawThinkingTag ? stripThinking(detailsRaw) : detailsRaw
                return (latchedSpoken, cleanAnswerPart(details))
            }
            return splitAnswer(
                sawThinkingTag ? stripThinking(accumulated) : accumulated,
                marker: marker
            )
        }

        /// Das endgültige Ergebnis – volle Rechnung, ohne Abkürzung.
        public func finish() -> (spoken: String, details: String) {
            splitAnswer(stripThinking(accumulated), marker: marker)
        }

        public var rawText: String { accumulated }
    }

    /// Rough token estimate used for context budgeting. Deliberately
    /// conservative: over-estimating costs a little context, under-estimating
    /// costs a truncated prompt.
    public static func estimatedTokens(_ text: String) -> Int {
        max(1, Int(Double(text.count) / 3.4))
    }

    /// Trims an answer that ran past its budget at the last sentence boundary.
    public static func clampToSentence(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        let prefix = String(text.prefix(maxCharacters))
        if let lastTerminator = prefix.lastIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            return String(prefix[...lastTerminator])
        }
        return prefix
    }
}

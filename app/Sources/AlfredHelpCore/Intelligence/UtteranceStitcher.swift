import Foundation

/// Setzt zerfallene Äußerungen wieder zu ganzen Sätzen zusammen.
///
/// Die Spracherkennung liefert nicht satzweise. Ein gesprochener Satz zerfällt
/// regelmäßig in mehrere finalisierte Bruchstücke – „Wie lange dauert eine
/// vollständige“ / „Neuindizierung auf dem Produktivsystem?“ –, und umgekehrt
/// kommen mehrere Sätze in einem Stück. Beides ist für die Frageerkennung
/// tödlich: das erste Bruchstück ist keine Frage, das zweite ist eine Frage
/// ohne Anfang, und beantwortet würde bestenfalls das letzte Drittel.
///
/// Diese Struktur ist bewusst aus `AssistantPipeline` herausgelöst. Dort steckte
/// die Zusammenführung zwischen Modellaufrufen und Actor-Zustand fest und war
/// nur mit laufender Spracherkennung zu prüfen, also gar nicht – genau deshalb
/// konnte sie sich unbemerkt verschieben. Hier ist sie reine Rechnerei auf
/// Text und Zeitstempeln und wird gegen `Benchmarks/satzzusammenfuehrung.json`
/// gemessen.
public struct UtteranceStitcher: Sendable {

    // MARK: - Einstellungen

    public struct Options: Sendable {

        /// Wie lange die **akustische** Stille zwischen zwei Teilen höchstens
        /// sein darf, damit der zweite noch als Fortsetzung des ersten gilt.
        ///
        /// Der Wert ist keine neue Schätzung, sondern derselbe, den der
        /// `UtteranceAssembler` als `continuationFlushSeconds` benutzt: dort
        /// beantwortet er dieselbe Frage eine Stufe früher – „wie lange warte
        /// ich auf die Fortsetzung eines sichtbar abgerissenen Gedankens?“.
        /// Zwei verschiedene Antworten auf dieselbe Frage wären ein Fehler.
        ///
        /// Nachgemessen wird er in `StitchBenchmarkTests.windowSweep`, das den
        /// Wert über den ganzen Datensatz durchfährt: unter 1,4 s gehen echte
        /// Fortsetzungen verloren, ab 3,4 s werden fremde Sätze angeklebt.
        /// Das Plateau ist 1,4 bis 3,0 s; 2,6 s liegt darin. Der Test schlägt
        /// fehl, sobald der ausgelieferte Wert das Plateau verlässt.
        public var maximumGapSeconds: Double = 2.6

        /// Die kurze Frist für den zweiten, häufigeren Zerfall: der Erkenner
        /// trennt **mitten im Satz**, ohne dass jemand eine Pause gemacht hat.
        /// „Wie lange dauert eine vollständige“ / „Neuindizierung auf dem
        /// Produktivsystem?“ ist genau das – der erste Teil sieht nicht
        /// abgerissen aus, er hört nur auf einem Adjektiv auf.
        ///
        /// Solche Teile sind an der Stille zwischen ihnen zu erkennen: es gab
        /// keine. Der Wert ist deshalb `SessionCoordinator.speechPauseSeconds`
        /// – die gemessene Pause, die einen Satz beendet. Wer darunter bleibt,
        /// hat den Satz nicht beendet, egal was der Erkenner meldet.
        ///
        /// Anders als bei `maximumGapSeconds` wird hier **ohne** brauchbare
        /// Zeitachse nicht zusammengefügt: ohne den akustischen Beleg gibt es
        /// keinen Grund, zwei abgeschlossen aussehende Äußerungen zu verbinden.
        ///
        /// Dieselbe Messung wie oben: unter 0,5 s gehen Trennungen mitten im
        /// Satz durch, ab 1,4 s werden zwei getrennte Sätze zusammengezogen.
        /// Plateau 0,5 bis 1,2 s, der ausgelieferte Wert liegt darin.
        public var sentenceEndGapSeconds: Double = 0.6

        /// Wanduhr-Rückfalltür für den Fall, dass die Zeitachse des Erkenners
        /// nichts hergibt (beide Zeitstempel 0, oder ein Rücksprung nach einem
        /// Neustart des Analysators).
        ///
        /// Bewusst **unverändert bei 8 s** gelassen. Die Wanduhr misst etwas
        /// anderes als die akustische Lücke: zwischen dem Empfang von Teil 1
        /// und dem Empfang von Teil 2 liegt nicht nur die Stille, sondern auch
        /// die gesamte Sprechzeit von Teil 2 (im Assembler auf 320 Zeichen
        /// gedeckelt) plus die erzwungene Finalisierung – 0,6 s Sprechpause,
        /// bis zu 0,25 s Timerraster und bis zu 1,0 s Ratenbegrenzung. Ein
        /// enger Wanduhr-Wert würde also genau die langen, aber korrekten
        /// Fortsetzungen abschneiden. Die Genauigkeit liefert jetzt die
        /// akustische Lücke; die Wanduhr ist nur noch die Notbremse gegen
        /// Zustand, der eine Sitzungspause überlebt.
        ///
        /// Im Datensatz greift dieser Wert an keiner Stelle – die längste
        /// Wanduhr-Differenz dort liegt bei 7,2 s, und alle Entscheidungen
        /// fallen schon an der akustischen Lücke. Er bleibt deshalb, wie er
        /// war; ihn zu ändern hieße, eine Zahl zu bewegen, für die es keine
        /// Messung gibt.
        public var maximumHoldSeconds: Double = 8

        /// Wie viele Teile höchstens zu einem Satz zusammenwachsen dürfen.
        ///
        /// Vier, weil die längste echte Kette im Datensatz drei Teile hat und
        /// ein Teil Luft bleiben soll. Ohne Deckel wächst ein einmal falsch
        /// festgehaltenes Bruchstück endlos weiter und zieht jede folgende
        /// Wortmeldung in sich hinein.
        public var maximumParts: Int = 4

        /// Obergrenze für den zusammengesetzten Text. 400 Zeichen entsprechen
        /// dem Assembler-Deckel von 320 plus einem weiteren Teil.
        public var maximumCharacters: Int = 400

        /// Wie viele Wörter Überlappung am Stoß höchstens abgezogen werden.
        /// Zwölf deckt die längste Wiederholung im Datensatz („The question is
        /// whether the“, fünf Wörter) mit deutlichem Abstand ab und hält den
        /// Vergleich zugleich billig – er läuft bei jeder Äußerung.
        public var maximumOverlapWords: Int = 12

        public init() {}
    }

    // MARK: - Zustand

    /// Ein festgehaltenes Bruchstück samt allem, was für die Entscheidung über
    /// seine Fortsetzung nötig ist.
    struct Pending: Sendable {
        var text: String
        /// Wie viele Erkenner-Äußerungen schon darin stecken.
        var parts: Int
        /// Ende auf der Zeitachse des Erkenners – die eine Hälfte der
        /// akustischen Lücke.
        var endSeconds: Double
        /// `true`, wenn der Text **nicht** sichtbar abgerissen ist und nur
        /// deshalb festgehalten wird, weil ihm das Satzzeichen fehlt. Für ihn
        /// gilt die kurze Frist: nur eine Trennung ohne jede Sprechpause zählt
        /// als Fortsetzung.
        var isTight: Bool
        /// Monotone Uhr, für die Rückfalltür.
        var at: Double
        /// Die Äußerung, aus der das Bruchstück stammt. Wird gebraucht, damit
        /// eine von Hand ausgelöste Antwort ihren eigenen Halt auflösen kann.
        var utteranceID: UUID
    }

    private var pending: [AudioSourceKind: Pending] = [:]
    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - Ergebnis

    /// Was mit einer Äußerung geschehen soll, nachdem sie mit allem
    /// zusammengeführt wurde, was noch offen war.
    public enum Outcome: Equatable, Sendable {
        /// Keine Frage – nichts zu tun.
        case nothing(assessed: String)
        /// Sichtbar abgerissen. Der Text wartet jetzt auf seine Fortsetzung;
        /// beantwortbar ist an ihm nichts, es geht also keine Antwort verloren.
        case waiting(assessed: String)
        /// Beantwortbar. `assessed` ist der volle zusammengesetzte Text (für
        /// Klassifikator und Dublettenprüfung), `question` der auf die
        /// eigentliche Frage eingedampfte Teil davon.
        case question(assessed: String, question: String, confidence: Double)
    }

    // MARK: - Hauptweg

    /// Nimmt eine fertige Äußerung entgegen und entscheidet.
    ///
    /// Die Bewertung passiert **sofort** und auf dem zusammengesetzten Text.
    /// Es gibt keinen Timer, der auf eine mögliche Fortsetzung wartet: was
    /// jetzt schon beantwortbar ist, wird jetzt beantwortet. Festgehalten wird
    /// nur, was für sich genommen ohnehin keine Antwort trägt.
    public mutating func offer(_ utterance: Utterance, now: Double = Clock.now()) -> Outcome {
        let merged = merge(utterance, now: now)

        switch TextUtilities.assessQuestion(merged.text) {
        case .notQuestion:
            keepOpenIfUnfinished(merged, from: utterance, at: now)
            return .nothing(assessed: merged.text)

        case .incomplete:
            store(merged.text, from: utterance, at: now, parts: merged.parts, tight: false)
            return .waiting(assessed: merged.text)

        case .question(let confidence):
            keepOpenIfUnfinished(merged, from: utterance, at: now)
            return .question(
                assessed: merged.text,
                question: TextUtilities.questionFocus(merged.text),
                confidence: confidence
            )
        }
    }

    /// Merkt sich, was von diesem Text noch weitergehen könnte.
    ///
    /// Zwei Fälle, zwei Fristen:
    ///
    /// * Hinter einer fertigen Frage steht ein sichtbar abgerissener Rest –
    ///   „Wie sieht euer Rollback aus? Und wie lange dauert das“. Die Frage
    ///   wird sofort beantwortet, der Rest wartet die lange Frist ab. Bisher
    ///   fiel er hier ersatzlos weg, und die Nachfrage kam nie an.
    /// * Der Text hat gar kein Satzzeichen. Dann kann der Erkenner mitten im
    ///   Satz getrennt haben, und es gilt die kurze Frist. Beantwortet wird
    ///   trotzdem sofort, was jetzt schon beantwortbar ist – kommt die
    ///   Fortsetzung, wird die vollständige Frage neu beantwortet, statt dass
    ///   ihr Schluss allein als eigene Frage durchgeht.
    private mutating func keepOpenIfUnfinished(
        _ merged: (text: String, parts: Int),
        from utterance: Utterance,
        at now: Double
    ) {
        if let remainder = Self.trailingFragment(of: merged.text) {
            store(remainder, from: utterance, at: now, parts: merged.parts, tight: false)
        } else if !Self.endsWithTerminator(merged.text) {
            store(merged.text, from: utterance, at: now, parts: merged.parts, tight: true)
        }
    }

    /// Fügt die Äußerung an ein noch offenes Bruchstück derselben Quelle an –
    /// oder gibt sie unverändert zurück, wenn keines mehr passt.
    private mutating func merge(
        _ utterance: Utterance,
        now: Double
    ) -> (text: String, parts: Int) {
        guard let open = pending.removeValue(forKey: utterance.source) else {
            return (utterance.original, 1)
        }
        guard open.parts < options.maximumParts else { return (utterance.original, 1) }
        guard continues(open, utterance, now: now) else { return (utterance.original, 1) }

        let joined = Self.join(open.text, utterance.original)
        guard joined.count <= options.maximumCharacters else { return (utterance.original, 1) }
        return (joined, open.parts + 1)
    }

    /// Ob die neue Äußerung als Fortsetzung des offenen Bruchstücks durchgeht.
    ///
    /// Entscheidend ist die **akustische** Lücke, nicht die Wanduhr: der
    /// Erkenner liefert zu jeder Äußerung ihre Position auf seiner eigenen
    /// Zeitachse, und der Abstand dazwischen ist die tatsächliche Stille
    /// zwischen den beiden Teilen. Die Wanduhr enthält demgegenüber auch die
    /// Sprechzeit des zweiten Teils und die Verzögerung der Finalisierung –
    /// über sie lässt sich „gehört das noch zusammen?“ nicht scharf stellen.
    private func continues(_ open: Pending, _ utterance: Utterance, now: Double) -> Bool {
        guard now - open.at <= options.maximumHoldSeconds else { return false }
        let gap = Self.acousticGap(from: open.endSeconds, to: utterance.startSeconds)

        guard !open.isTight else {
            // Ohne akustischen Beleg wird hier nicht verbunden: zwei
            // abgeschlossen aussehende Äußerungen ohne erkennbare Pause
            // dazwischen sind ein Satz, zwei mit Pause sind zwei Sätze – und
            // ohne Zeitachse ist beides nicht zu unterscheiden.
            guard let gap else { return false }
            return gap < options.sentenceEndGapSeconds
        }
        // Sichtbar abgerissen: hier ist der Fortsetzungswunsch schon aus dem
        // Text belegt, die Zeitachse ist nur noch die Gegenprobe. Fehlt sie,
        // bleibt die Wanduhr oben.
        guard let gap else { return true }
        return gap <= options.maximumGapSeconds
    }

    /// Die tatsächliche Stille zwischen zwei Teilen auf der Zeitachse des
    /// Erkenners – oder `nil`, wenn die Zeitachse nichts hergibt.
    ///
    /// Nichts hergeben tut sie in zwei Fällen: beide Stempel stehen auf 0
    /// (frisch gestarteter Analysator, Tests), oder der zweite Teil beginnt vor
    /// dem Ende des ersten. Letzteres passiert regulär – zerlegt der Assembler
    /// ein Erkenner-Ereignis in mehrere Sätze, tragen alle denselben Anfang.
    static func acousticGap(from end: Double, to start: Double) -> Double? {
        guard end.isFinite, start.isFinite else { return nil }
        guard end > 0 || start > 0 else { return nil }
        guard start >= end else { return nil }
        return start - end
    }

    // MARK: - Festhalten und Vergessen

    /// Hält einen Text als offenes Bruchstück fest.
    ///
    /// Öffentlich, weil auch der Klassifikator zu dem Urteil kommen kann, dass
    /// eine Äußerung unvollständig ist – dann gilt dasselbe wie für die
    /// Heuristik.
    public mutating func hold(
        _ text: String,
        from utterance: Utterance,
        at now: Double = Clock.now()
    ) {
        store(text, from: utterance, at: now, parts: 1, tight: false)
    }

    private mutating func store(
        _ text: String,
        from utterance: Utterance,
        at now: Double,
        parts: Int,
        tight: Bool
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending[utterance.source] = Pending(
            text: trimmed,
            parts: parts,
            endSeconds: utterance.endSeconds,
            isTight: tight,
            at: now,
            utteranceID: utterance.id
        )
    }

    private static func endsWithTerminator(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return true
        }
        return terminators.contains(last)
    }

    /// Der abgerissene Schluss eines Textes, dessen Frage schon beantwortet
    /// wird – oder `nil`, wenn der Text sauber endet.
    private static func trailingFragment(of text: String) -> String? {
        let remainder = TextUtilities.splitSentences(text).remainder
        guard !remainder.isEmpty, TextUtilities.endsIncomplete(remainder) else { return nil }
        // Ein Text, der **nur** aus dem Rest besteht, war gar nicht zerlegt –
        // dann wäre das Festhalten kein Nachschlag, sondern eine Wiederholung
        // des eben Beantworteten.
        guard remainder != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return remainder
    }

    /// Vergisst ein Bruchstück, das aus dieser Äußerung stammt.
    /// Nach einer von Hand ausgelösten Antwort ist der Halt gegenstandslos.
    public mutating func forget(utteranceID: UUID) {
        for (source, open) in pending where open.utteranceID == utteranceID {
            pending[source] = nil
        }
    }

    public mutating func removeAll() {
        pending.removeAll()
    }

    /// Nur für Tests und Diagnose: was gerade auf seine Fortsetzung wartet.
    public func pendingText(for source: AudioSourceKind) -> String? {
        pending[source]?.text
    }

    // MARK: - Verbinden

    /// Setzt zwei Textstücke zu einem zusammen.
    ///
    /// Drei Dinge müssen dabei stimmen, und alle drei gingen vorher schief,
    /// weil schlicht `a + " " + b` gerechnet wurde:
    ///
    /// 1. **Keine Verdopplung.** Der Erkenner liefert beim Finalisieren gern
    ///    Wörter erneut, die er im Bruchstück davor schon geliefert hat:
    ///    „The question is whether the“ + „The question is whether the rollout
    ///    is on track?“. Die längste Überlappung zwischen dem Ende des ersten
    ///    und dem Anfang des zweiten Stücks wird deshalb aus dem **zweiten**
    ///    abgezogen – aus dem zweiten, damit die Interpunktion des ersten
    ///    (etwa ein abschließendes Komma) unangetastet bleibt.
    /// 2. **Kein doppeltes Leerzeichen**, auch nicht bei Stücken mit Rand.
    /// 3. **Keine verlorene Interpunktion.** Sagt der zweite Teil nichts Neues
    ///    („Was macht ihr dann“ + „Was macht ihr dann?“), bleibt der erste
    ///    stehen und bekommt das Satzzeichen des zweiten – sonst ginge genau
    ///    das Fragezeichen verloren, an dem die Erkennung hängt.
    ///
    /// Verglichen wird wortweise, kleingeschrieben und ohne Interpunktion:
    /// derselbe Wortlaut kommt beim zweiten Mal groß oder mit Komma wieder.
    public static func join(
        _ head: String,
        _ tail: String,
        maximumOverlapWords: Int = Options().maximumOverlapWords
    ) -> String {
        let left = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let leftWords = words(of: left)
        let rightWords = words(of: right)
        var shared = overlap(head: leftWords, tail: rightWords, limit: maximumOverlapWords)

        guard shared < rightWords.count else {
            // Der zweite Teil geht vollständig im ersten auf – eindeutig eine
            // Wiederholung, egal wie kurz er ist.
            return withTerminator(of: right, on: left)
        }
        // Ein **einzelnes** gemeinsames Wort ist nur dann eine Wiederholung des
        // Erkenners, wenn es ein Inhaltswort ist. „Wie lange dauert eine
        // vollständige“ + „vollständige Neuindizierung …“ gehört
        // zusammengezogen; „Wir machen das“ + „Das ist der Plan“ nicht – dort
        // stehen zwei verschiedene „das“, und ein Abzug machte daraus das
        // sinnentstellende „Wir machen das ist der Plan“. Funktionswörter und
        // sehr kurze Wörter wiederholen sich über eine Satzgrenze hinweg
        // ständig von selbst, Inhaltswörter praktisch nie.
        if shared == 1 {
            let word = rightWords[0].key
            if word.count < 4 || TextUtilities.isContinuationWord(word) { shared = 0 }
        }
        let rest = shared == 0
            ? right
            : String(right[rightWords[shared].start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return withTerminator(of: right, on: left) }
        return left + " " + rest
    }

    /// Ein Wort samt seiner Position im Ursprungstext.
    private struct Word {
        /// Kleingeschrieben und ohne Interpunktion – nur zum Vergleichen.
        let key: String
        let start: String.Index
    }

    private static func words(of text: String) -> [Word] {
        var result: [Word] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            let key = text[start..<index]
                .lowercased()
                .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            result.append(Word(key: key, start: start))
        }
        return result
    }

    /// Längste Wortfolge, die zugleich Ende des ersten und Anfang des zweiten
    /// Stücks ist. Wörter, von denen nach dem Abziehen der Interpunktion
    /// nichts übrig bleibt (ein einzelner Gedankenstrich etwa), zählen nie mit
    /// – sonst wäre jedes Rauschzeichen eine Überlappung.
    private static func overlap(head: [Word], tail: [Word], limit: Int) -> Int {
        let maximum = min(head.count, tail.count, limit)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            var matches = true
            for offset in 0..<length {
                let a = head[head.count - length + offset].key
                let b = tail[offset].key
                if a.isEmpty || b.isEmpty || a != b {
                    matches = false
                    break
                }
            }
            if matches { return length }
        }
        return 0
    }

    private static let terminators: Set<Character> = [".", "?", "!", "…"]

    /// Hängt das Satzzeichen des zweiten Stücks an das erste, falls dieses noch
    /// keines hat.
    private static func withTerminator(of tail: String, on head: String) -> String {
        guard let last = head.last, !terminators.contains(last) else { return head }
        guard let mark = tail.last, terminators.contains(mark) else { return head }
        return head + String(mark)
    }
}

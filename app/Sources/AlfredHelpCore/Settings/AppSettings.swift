import Foundation

/// Everything the user can configure. Persisted as JSON in `UserDefaults`.
public struct AppSettings: Codable, Sendable, Equatable {

    /// Wie der Systemton erfasst wird.
    public enum SystemAudioBackend: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Apples dokumentierter Weg. Unabhängig vom Ausgabegerät, eine klar
        /// benannte Berechtigung, die macOS zuverlässig abfragt.
        case screenCapture
        /// Core-Audio-Prozess-Tap. Sparsamer, aber abhängig davon, dass sich das
        /// aktuelle Ausgabegerät in ein privates Aggregat einbinden lässt.
        case processTap

        public var id: String { rawValue }

        public var germanName: String {
            switch self {
            case .screenCapture: return "ScreenCaptureKit (empfohlen)"
            case .processTap: return "Core-Audio-Tap (sparsamer)"
            }
        }
    }

    // MARK: Audio
    public var systemAudioBackend: SystemAudioBackend = .screenCapture
    public var captureSystemAudio: Bool = true
    public var captureMicrophone: Bool = true
    /// Silence gate – keeps the recognizer idle while nobody is speaking.
    public var powerSaving: Bool = true

    // MARK: Languages
    /// Language spoken by the other side (system audio).
    public var systemAudioLocale: String = "en-US"
    /// Language the user speaks into the microphone.
    public var microphoneLocale: String = "de-DE"

    // MARK: Models
    /// Small model: live translation and question detection. Derived from the
    /// chosen answer model – the user never picks this one.
    public var fastModel: String = ""
    /// The one model the user chooses. Writes the answers.
    public var qualityModel: String = ""
    /// Start listening on launch only when the user opted in.
    public var autoStartSession: Bool = false
    /// Fehlende Voraussetzungen beim Start selbst nachinstallieren: Ollama, ein
    /// Sprachmodell, die Erkennungsdaten. Standardmäßig an – wer die App
    /// weitergibt, kann nicht voraussetzen, dass der Empfänger irgendetwas
    /// davon schon hat.
    public var installMissingDependencies: Bool = true
    /// How long Ollama keeps models resident between utterances.
    public var keepAlive: String = "30m"
    public var contextTokens: Int = 8192
    public var maxAnswerTokens: Int = 320

    // MARK: Behaviour
    public var translationEnabled: Bool = true
    public var autoAnswerEnabled: Bool = true
    public var answerLanguage: Prompts.AnswerLanguage = .german
    /// Only questions coming from the other side trigger an answer.
    public var answerOnlySystemAudio: Bool = true
    /// Heuristic score an utterance needs before the classifier is asked at all.
    public var questionHeuristicThreshold: Double = 0.3
    /// Above this the utterance is treated as a question without asking the
    /// classifier – saves a round trip on the obvious cases.
    ///
    /// 0,78 statt der früheren 0,95, gemessen mit dem Schwellen-Sweep in
    /// `QuestionBenchmarkTests` über beide Datensätze (423 Beispiele).
    ///
    /// Warum die 0,95 nicht zu halten waren: sie waren nie ein Messwert,
    /// sondern ein Sicherheitsabstand gegen einen Datensatz, der nichts
    /// beweisen konnte. `frageerkennung.json` ist der Satz, an dem die
    /// Heuristik entwickelt wurde – dort erreichen von 76 Nicht-Fragen fünf
    /// überhaupt die Stufe „Frage“, und keine davon kommt über 0,4. „Null
    /// Fehlalarme bei 0,75“ war auf diesen Daten eine Tautologie.
    ///
    /// Warum es 0,78 wurde und nicht 0,60: `frageerkennung-holdout.json`
    /// (182 Beispiele, 115 davon Nicht-Fragen, geschrieben ohne Blick in
    /// `TextUtilities`) zeigt eine sehr scharfe Kante, die im Abstimmsatz
    /// unsichtbar war. Auf beiden Sätzen zusammen:
    ///
    ///     Stufe 0,95 · 0,90 · 0,80   96 Beispiele, davon  1 Nicht-Frage
    ///     Stufe 0,75                 72 Beispiele, davon 20 Nicht-Fragen
    ///
    /// Die 0,75-Sprosse liegt bei 28 % Fehlalarm. Sie ist auch strukturell
    /// eine andere Klasse: von den 72 Beispielen dort endet **keines** auf
    /// einem Fragezeichen. Das sind Aussagesätze, die nur nach ihrem Bau als
    /// Frage gelesen werden – verbfirste Zusagen („Können wir gerne so
    /// machen“), höfliche Konjunktive („Wäre schön, wenn wir das bis Freitag
    /// hätten“), Konditionalsätze („Sollte das schiefgehen, rollen wir
    /// zurück“) und Ausrufe mit Fragewort („Was für ein Chaos war das
    /// gestern“). Genau diese Sprache füllt eine Besprechung. Eine Schwelle
    /// von 0,75 hätte 17 % aller Nicht-Fragen sofort beantwortet.
    ///
    /// 0,78 liegt bewusst *zwischen* den Sprossen der Konfidenzleiter und
    /// nicht auf 0,80: jeder Wert aus (0,75; 0,80] wirkt identisch, und ein
    /// Wert auf der Kante wäre ein Wert ohne Abstand. Sicherheitsabstand nach
    /// unten: 0,03 zur nächsten Stufe mit Fehlalarmen. In Beispielen
    /// ausgedrückt liegen zwischen 0,78 und 1,0 auf beiden Datensätzen
    /// zusammen 96 Beispiele mit genau einer Nicht-Frage darunter.
    ///
    /// Was das Absenken kostet: nach der Messung nichts – die Menge der
    /// sofortigen Fehlalarme ist bei 0,78 dieselbe wie bei 0,95 (ein Fall,
    /// „Es wäre gut, das nochmal gegenzulesen“, der über das zu breite Muster
    /// `"das nochmal"` in `repeatRequests` läuft und bei *jeder* Schwelle
    /// auftritt – er ist ein Defekt der Musterliste, nicht der Schwelle).
    /// Was es bringt: 95 statt 77 sofort beantwortete Fragen, die graue Zone
    /// schrumpft von 116 auf 98. Rund 18 Fragen sparen die Modellrunde von
    /// ~300 ms Median.
    ///
    /// Die Abwägung dahinter: ein sofortiger Fehlalarm ist keine bleibende
    /// Falschantwort. `verifyInBackground` lässt den Klassifikator
    /// weiterlaufen und verwirft die Antwort (`answerDiscarded`) – sichtbar
    /// bleibt eine kurz aufblitzende Karte. Der Preis eines Fehlalarms ist
    /// deshalb klein, der Preis des Wartens trifft dagegen jede Frage. Das
    /// rechtfertigt aber nur den Schritt bis an die Kante, nicht darüber
    /// hinaus: bei 0,75 flackerte die Karte bei jeder sechsten Nicht-Frage,
    /// und Nicht-Fragen sind in einer Besprechung die überwältigende Mehrheit
    /// der Äußerungen.
    ///
    /// Der Abstand ist eine einzige Sprosse breit. Hebt eine künftige Regel
    /// eine der 20 Formulierungen von 0,75 auf 0,80, kippt der Wert sofort –
    /// deshalb hängt am Sweep-Test eine Zusicherung, die genau das bemerkt.
    public var questionCertaintyShortcut: Double = 0.78
    public var summarizeEveryUtterances: Int = 14
    public var verbatimTurns: Int = 12
    /// Free-form background about the user; folded into the answer prompt.
    public var userProfile: String = ""

    // MARK: Interface
    public var overlayHiddenFromScreenSharing: Bool = true
    public var overlayOpacity: Double = 1.0
    public var showOriginalText: Bool = true
    public var overlayFontSize: Double = 14
    public var storeTranscripts: Bool = true
    public var launchOverlayOnStart: Bool = true
    /// Wurde der Systemton schon einmal mit echten Samples verifiziert?
    public var systemAudioVerified: Bool = false
    /// Welcher Aufnahmeweg wurde dabei tatsächlich geprüft?
    public var verifiedSystemAudioBackend: SystemAudioBackend? = nil
    /// Code-Signatur, unter der die Verifikation gelang. Ändert sie sich, ist
    /// die macOS-Freigabe hinfällig und muss erneut erteilt werden.
    public var verifiedCodeHash: String = ""

    public init() {}

    /// Jedes Feld einzeln, jedes optional.
    ///
    /// Das synthetische `Codable`-Decoding scheitert komplett, sobald der
    /// gespeicherten Fassung auch nur ein Feld fehlt – und ein Update, das ein
    /// Feld ergänzt, macht damit stillschweigend **alle** Einstellungen des
    /// Nutzers zunichte. Genau das ist in der Entwicklung zweimal passiert
    /// (Modellwahl weg, Sichtbarkeits-Schalter umgesprungen). Fehlende Felder
    /// bekommen deshalb ihren Standardwert, vorhandene bleiben erhalten.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // `try?` faltet das doppelte Optional schon zusammen; ein `as? T`
            // stand hier zusätzlich und tat nachweislich nichts (Compilerwarnung
            // „conditional downcast … does nothing").
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }

        systemAudioBackend = value(.systemAudioBackend, defaults.systemAudioBackend)
        captureSystemAudio = value(.captureSystemAudio, defaults.captureSystemAudio)
        captureMicrophone = value(.captureMicrophone, defaults.captureMicrophone)
        powerSaving = value(.powerSaving, defaults.powerSaving)
        systemAudioLocale = value(.systemAudioLocale, defaults.systemAudioLocale)
        microphoneLocale = value(.microphoneLocale, defaults.microphoneLocale)
        fastModel = value(.fastModel, defaults.fastModel)
        qualityModel = value(.qualityModel, defaults.qualityModel)
        autoStartSession = value(.autoStartSession, defaults.autoStartSession)
        installMissingDependencies = value(.installMissingDependencies, defaults.installMissingDependencies)
        keepAlive = value(.keepAlive, defaults.keepAlive)
        contextTokens = value(.contextTokens, defaults.contextTokens)
        maxAnswerTokens = value(.maxAnswerTokens, defaults.maxAnswerTokens)
        translationEnabled = value(.translationEnabled, defaults.translationEnabled)
        autoAnswerEnabled = value(.autoAnswerEnabled, defaults.autoAnswerEnabled)
        answerLanguage = value(.answerLanguage, defaults.answerLanguage)
        answerOnlySystemAudio = value(.answerOnlySystemAudio, defaults.answerOnlySystemAudio)
        questionHeuristicThreshold = value(.questionHeuristicThreshold, defaults.questionHeuristicThreshold)
        questionCertaintyShortcut = value(.questionCertaintyShortcut, defaults.questionCertaintyShortcut)
        summarizeEveryUtterances = value(.summarizeEveryUtterances, defaults.summarizeEveryUtterances)
        verbatimTurns = value(.verbatimTurns, defaults.verbatimTurns)
        userProfile = value(.userProfile, defaults.userProfile)
        overlayHiddenFromScreenSharing = value(.overlayHiddenFromScreenSharing, defaults.overlayHiddenFromScreenSharing)
        overlayOpacity = value(.overlayOpacity, defaults.overlayOpacity)
        showOriginalText = value(.showOriginalText, defaults.showOriginalText)
        overlayFontSize = value(.overlayFontSize, defaults.overlayFontSize)
        storeTranscripts = value(.storeTranscripts, defaults.storeTranscripts)
        launchOverlayOnStart = value(.launchOverlayOnStart, defaults.launchOverlayOnStart)
        systemAudioVerified = value(.systemAudioVerified, defaults.systemAudioVerified)
        verifiedSystemAudioBackend = value(.verifiedSystemAudioBackend, defaults.verifiedSystemAudioBackend)
        verifiedCodeHash = value(.verifiedCodeHash, defaults.verifiedCodeHash)
    }

    public var systemLocale: Locale { Locale(identifier: systemAudioLocale) }
    public var microphoneLocaleValue: Locale { Locale(identifier: microphoneLocale) }

    /// Human-readable name of the conversation language, used inside prompts.
    public var conversationLanguageName: String {
        let locale = Locale(identifier: systemAudioLocale)
        guard let code = locale.language.languageCode?.identifier else { return systemAudioLocale }
        return Locale(identifier: "de_DE").localizedString(forLanguageCode: code) ?? systemAudioLocale
    }

    /// True when the other side already speaks German – translation is skipped.
    public var systemAudioIsGerman: Bool {
        Locale(identifier: systemAudioLocale).language.languageCode?.identifier == "de"
    }
}

/// Persists `AppSettings`. Reads are cheap; writes are debounced by the caller.
public final class SettingsStore: @unchecked Sendable {

    private static let key = "io.github.PalescoDev.alfredhelp.settings.v1"
    private static let legacyKey = "io.github.fvulcan.alfredhelp.settings.v1"
    private static let autoStartOptInMigrationKey = "io.github.PalescoDev.alfredhelp.autoStartOptInMigration.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cached: AppSettings

    public convenience init() {
        self.init(defaults: .standard, legacyDefaults: nil)
    }

    public convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, legacyDefaults: nil)
    }

    init(defaults: UserDefaults, legacyDefaults: UserDefaults?) {
        self.defaults = defaults
        let currentData = defaults.data(forKey: Self.key)
        let legacyData: Data?
        if currentData == nil {
            legacyData = defaults.data(forKey: Self.legacyKey)
                ?? legacyDefaults?.data(forKey: Self.legacyKey)
        } else {
            legacyData = nil
        }
        let savedData = currentData ?? legacyData
        if let data = savedData,
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.cached = decoded
        } else {
            self.cached = AppSettings()
        }

        if currentData == nil, legacyData != nil,
           let data = try? JSONEncoder().encode(self.cached) {
            defaults.set(data, forKey: Self.key)
        }

        // Früher war automatisches Zuhören standardmäßig eingeschaltet. Die
        // erste Version mit Opt-in schaltet diesen alten Standard einmalig aus;
        // eine bewusste spätere Auswahl des Nutzers bleibt erhalten.
        if !defaults.bool(forKey: Self.autoStartOptInMigrationKey) {
            if savedData != nil {
                self.cached.autoStartSession = false
                if let data = try? JSONEncoder().encode(self.cached) {
                    defaults.set(data, forKey: Self.key)
                }
            }
            defaults.set(true, forKey: Self.autoStartOptInMigrationKey)
        }
    }

    public var settings: AppSettings {
        get { lock.withLock { cached } }
        set {
            lock.withLock { cached = newValue }
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
    }
}

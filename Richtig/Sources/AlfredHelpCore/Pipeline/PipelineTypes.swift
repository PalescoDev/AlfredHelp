import Foundation

/// Validated, model-independent answer shape. The local model is asked for
/// exactly this structure; parsing still has a conservative fallback because
/// an interrupted stream or an older Ollama version can return free text.
public struct StructuredAnswer: Sendable, Equatable, Codable {
    public enum Confidence: String, Sendable, Equatable, Codable, CaseIterable {
        case high, medium, low
    }

    public var spoken: String
    public var details: String
    public var confidence: Confidence
    public var missingContext: [String]

    public init(
        spoken: String,
        details: String = "",
        confidence: Confidence = .low,
        missingContext: [String] = []
    ) {
        self.spoken = spoken
        self.details = details
        self.confidence = confidence
        self.missingContext = missingContext
    }
}

/// A detected question together with the answer being written for it.
public struct AnswerCard: Sendable, Identifiable, Equatable {
    public let id: UUID
    /// The question, resolved against the conversation so it stands on its own.
    public var question: String
    /// What was literally said, in the original language.
    public let spoken: String
    /// The two or three sentences the user reads out loud.
    public var text: String
    /// The background behind the disclosure triangle. May stay empty.
    public var details: String
    /// How strongly the answer is supported by the supplied conversation.
    public var confidence: StructuredAnswer.Confidence
    /// Facts the model says it would need for a definitive answer.
    public var missingContext: [String]
    public var isComplete: Bool
    public var errorMessage: String?
    public let createdAt: Date
    /// Milliseconds from "speaker finished the sentence" to "first word of the
    /// answer on screen" – the number that decides whether this is usable live.
    public var timeToFirstWordMilliseconds: Int?
    public var totalMilliseconds: Int?
    public var tokensPerSecond: Double?
    public var wasManuallyTriggered: Bool

    public init(
        id: UUID = UUID(),
        question: String,
        spoken: String,
        text: String = "",
        details: String = "",
        confidence: StructuredAnswer.Confidence = .low,
        missingContext: [String] = [],
        isComplete: Bool = false,
        errorMessage: String? = nil,
        createdAt: Date = Date(),
        timeToFirstWordMilliseconds: Int? = nil,
        totalMilliseconds: Int? = nil,
        tokensPerSecond: Double? = nil,
        wasManuallyTriggered: Bool = false
    ) {
        self.id = id
        self.question = question
        self.spoken = spoken
        self.text = text
        self.details = details
        self.confidence = confidence
        self.missingContext = missingContext
        self.isComplete = isComplete
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.timeToFirstWordMilliseconds = timeToFirstWordMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.tokensPerSecond = tokensPerSecond
        self.wasManuallyTriggered = wasManuallyTriggered
    }
}

public enum PipelineEvent: Sendable {
    /// Words that are still being spoken – replaced on every update.
    case partialTranscript(source: AudioSourceKind, text: String)
    case utteranceAdded(Utterance)
    case translation(id: UUID, german: String, isFinal: Bool)
    case answerStarted(AnswerCard)
    /// The classifier finished resolving the question against the context.
    case answerQuestionRefined(id: UUID, question: String)
    case answerDelta(id: UUID, text: String, details: String)
    case answerFinished(AnswerCard)
    /// Die Antwort wurde fallengelassen, bevor sie fertig war – die Frage hat
    /// sich erledigt, etwa weil der Sprecher sie selbst beantwortet hat.
    ///
    /// Eigenes Ereignis statt einer `answerFinished`-Karte mit dem Text
    /// „verworfen" im Fehlerfeld: dieser Text wurde auf der anderen Seite der
    /// Modulgrenze wieder verglichen, und ein Tippfehler auf einer der beiden
    /// Seiten hätte verworfene Karten stehen lassen, ohne dass ein Test das
    /// bemerkt.
    case answerDiscarded(id: UUID)
    case memory(MemorySnapshot)
    /// Der Systemaudio-Tap läuft, bekommt aber keine Daten – das passiert
    /// ausschließlich, wenn die Berechtigung „Audioaufnahme“ fehlt.
    case audioPermissionNeeded
    case notice(String)
    case failure(String)
}

public struct PipelineHealth: Sendable, Equatable {
    public var ollamaReachable: Bool = false
    public var ollamaVersion: String = ""
    public var fastModelReady: Bool = false
    public var qualityModelReady: Bool = false
    public var lastTranslationMilliseconds: Int?
    public var lastAnswerMilliseconds: Int?

    public init() {}
}

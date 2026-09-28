import Foundation

/// One finished thing somebody said.
public struct Utterance: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let source: AudioSourceKind
    /// What was actually said, in the original language.
    public var original: String
    /// German rendering; equals `original` when the source language is German.
    public var german: String?
    public let startSeconds: Double
    public let endSeconds: Double
    public let createdAt: Date
    /// Monotonic timestamp used for latency accounting.
    public let capturedAt: Double
    public var confidence: Double?

    public init(
        id: UUID = UUID(),
        source: AudioSourceKind,
        original: String,
        german: String? = nil,
        startSeconds: Double,
        endSeconds: Double,
        createdAt: Date = Date(),
        capturedAt: Double = Clock.now(),
        confidence: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.original = original
        self.german = german
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.createdAt = createdAt
        self.capturedAt = capturedAt
        self.confidence = confidence
    }

    /// Preferred text for prompts: German if available, original otherwise.
    public var displayText: String { german ?? original }
}

/// Turns a stream of final recognizer results into whole utterances.
///
/// Emitting on sentence boundaries is what makes the assistant feel immediate:
/// a question is handed to the pipeline the moment the question mark lands, not
/// when the speaker eventually stops talking.
public final class UtteranceAssembler {

    public struct Options: Sendable {
        /// Emit a pending fragment after this much silence even without a
        /// sentence terminator.
        public var silenceFlushSeconds: Double = 1.1
        /// When the fragment visibly stops mid-thought ("… und dann"), wait
        /// this long instead – answering into a half sentence is worse than
        /// showing the line a second later.
        public var continuationFlushSeconds: Double = 2.6
        /// Emit unconditionally once a fragment gets this long.
        public var maxPendingCharacters: Int = 320
        /// Ignore fragments shorter than this – recognizer noise.
        public var minimumCharacters: Int = 2

        public init() {}
    }

    private let source: AudioSourceKind
    private let options: Options
    private var pending = ""
    private var pendingStart: Double?
    private var pendingEnd: Double = 0
    private var pendingConfidence: [Double] = []
    private var lastAppendAt: Double = Clock.now()

    public init(source: AudioSourceKind, options: Options = Options()) {
        self.source = source
        self.options = options
    }

    /// Feeds a final recognizer result. Returns every utterance that just became
    /// complete.
    public func append(_ event: TranscriptEvent) -> [Utterance] {
        guard event.isFinal else { return [] }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        if pending.isEmpty {
            pendingStart = event.startSeconds
        }
        // Über `join` statt über `+ " " +`: der Erkenner liefert beim
        // Finalisieren Wörter erneut, die im Ergebnis davor schon standen.
        // Hier ist die früheste Stelle, an der sich das entfernen lässt – was
        // hier hängen bleibt, steht später im Transkript, im Gedächtnis und im
        // Prompt. `join` zieht nur echte Wiederholungen ab, keine
        // Funktionswörter an einer Satzgrenze.
        pending = UtteranceStitcher.join(pending, text)
        pendingEnd = event.endSeconds
        lastAppendAt = event.capturedAt
        if let confidence = event.confidence { pendingConfidence.append(confidence) }

        var produced: [Utterance] = []
        let split = TextUtilities.splitSentences(pending)
        for sentence in split.complete {
            if let utterance = makeUtterance(sentence) { produced.append(utterance) }
        }
        pending = split.remainder

        if pending.count >= options.maxPendingCharacters {
            if let utterance = makeUtterance(pending) { produced.append(utterance) }
            pending = ""
        }
        if pending.isEmpty {
            pendingStart = nil
            pendingConfidence.removeAll()
        }
        return produced
    }

    /// Emits a pending fragment once the speaker has paused long enough.
    /// Fragments that visibly stop mid-thought get a longer grace period.
    public func flushIfIdle(now: Double = Clock.now()) -> Utterance? {
        guard !pending.isEmpty else { return nil }
        let deadline = TextUtilities.endsIncomplete(pending)
            ? options.continuationFlushSeconds
            : options.silenceFlushSeconds
        guard now - lastAppendAt >= deadline else { return nil }
        let utterance = makeUtterance(pending)
        pending = ""
        pendingStart = nil
        pendingConfidence.removeAll()
        return utterance
    }

    /// Emits whatever is left, e.g. when the session stops.
    public func flush() -> Utterance? {
        guard !pending.isEmpty else { return nil }
        let utterance = makeUtterance(pending)
        pending = ""
        pendingStart = nil
        pendingConfidence.removeAll()
        return utterance
    }

    public var pendingText: String { pending }

    private func makeUtterance(_ text: String) -> Utterance? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= options.minimumCharacters else { return nil }
        let confidence = pendingConfidence.isEmpty
            ? nil
            : pendingConfidence.reduce(0, +) / Double(pendingConfidence.count)
        return Utterance(
            source: source,
            original: trimmed,
            startSeconds: pendingStart ?? 0,
            endSeconds: pendingEnd,
            capturedAt: lastAppendAt,
            confidence: confidence
        )
    }
}

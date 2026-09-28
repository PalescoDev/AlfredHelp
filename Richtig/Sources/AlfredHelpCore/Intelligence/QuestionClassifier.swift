import Foundation

/// Second stage of question detection: the local model reads the utterance in
/// its conversational context and returns one of three verdicts. Lives outside
/// the pipeline actor so the benchmark exercises exactly the shipped code path.
public struct QuestionClassifier: Sendable {

    public static let minimumASRConfidenceForHeuristicFallback = 0.65

    /// A low recognizer score must never take the heuristic shortcut. The
    /// wording may still be a question, but the model first has to confirm the
    /// noisy transcript. `nil` means the recognizer supplied no score and
    /// preserves the existing behaviour.
    public static func mayUseHeuristicShortcut(
        questionConfidence: Double,
        certaintyShortcut: Double,
        asrConfidence: Double?,
        minimumASRConfidence: Double = minimumASRConfidenceForHeuristicFallback
    ) -> Bool {
        guard questionConfidence >= certaintyShortcut else { return false }
        guard let asrConfidence else { return true }
        return asrConfidence >= minimumASRConfidence
    }

    /// Monotonic tickets let the pipeline reject a slow verdict after a newer
    /// utterance has already entered classification.
    public struct Sequence: Sendable {
        private var latest: UInt64 = 0

        public init() {}

        public mutating func register() -> UInt64 {
            latest &+= 1
            return latest
        }

        public func isCurrent(_ ticket: UInt64) -> Bool { ticket == latest }
    }

    public enum Verdict: Sendable, Equatable {
        case question(standalone: String)
        case notQuestion
        case incomplete
        /// The classifier itself failed (model missing, server down). Callers
        /// must fall back to the heuristic instead of dropping the question.
        case failed
    }

    /// Reads the streamed JSON prefix and decides as soon as the `status`
    /// value's first letter is visible: `f`(rage) / `k`(eine_frage) /
    /// `u`(nvollstaendig). This is what makes mid-confidence questions answer
    /// after a dozen tokens instead of sixty.
    public static func earlyDecision(in partialJSON: String) -> Bool? {
        guard let keyRange = partialJSON.range(of: "\"status\"") else { return nil }
        var index = keyRange.upperBound
        var seenColon = false
        var seenQuote = false
        while index < partialJSON.endIndex {
            let character = partialJSON[index]
            if !seenColon {
                if character == ":" { seenColon = true }
            } else if !seenQuote {
                if character == "\"" { seenQuote = true }
            } else {
                switch character {
                case "f": return true          // "frage"
                case "k", "u": return false    // "keine_frage" / "unvollstaendig"
                default: return nil            // unexpected – wait for full JSON
                }
            }
            index = partialJSON.index(after: index)
        }
        return nil
    }

    /// Runs the classifier. `onEarlyDecision` fires once, the moment the
    /// verdict's first token arrives; the returned verdict carries the full
    /// result including the context-resolved standalone question.
    public static func classify(
        client: OllamaClient,
        model: String,
        context: String,
        utterance: String,
        keepAlive: String = "30m",
        onEarlyDecision: (@Sendable (Bool) -> Void)? = nil
    ) async -> Verdict? {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed
        }
        var accumulated = ""
        var reportedDecision: Bool?
        do {
            for try await chunk in client.chatStream(
                model: model,
                messages: [
                    .system(Prompts.classifySystem),
                    .user(Prompts.classifyUser(
                        context: contextExcludingCurrentUtterance(context, utterance: utterance),
                        utterance: utterance
                    ))
                ],
                options: GenerationOptions(temperature: 0, numPredict: 220, numCtx: 4096),
                format: Prompts.classifySchema,
                think: modelSupportsThinking(model) ? false : nil,
                keepAlive: keepAlive
            ) {
                if Task.isCancelled { return nil }
                accumulated += chunk.text
                if reportedDecision == nil, let early = earlyDecision(in: accumulated) {
                    reportedDecision = early
                    onEarlyDecision?(early)
                }
            }
        } catch is CancellationError {
            return nil
        } catch {
            Log.pipeline.error("Classification failed: \(String(describing: error), privacy: .public)")
            if !accumulated.isEmpty {
                return parse(accumulated, earlyDecision: reportedDecision)
            }
            return .failed
        }

        return parse(accumulated, earlyDecision: reportedDecision)
    }

    /// Parses the complete model output into a verdict.
    static func parse(_ text: String, earlyDecision: Bool? = nil) -> Verdict? {
        guard let data = ConversationMemory.extractJSON(from: TextUtilities.stripThinking(text)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // The enum's first letters are unique. Preserve a recognizable
            // status even when the remaining JSON stream is interrupted.
            if let statusStart = earlyStatusStart(in: text) {
                switch statusStart {
                case "f": return .question(standalone: "")
                case "k": return .notQuestion
                case "u": return .incomplete
                default: break
                }
            }
            return earlyDecision == true ? .question(standalone: "") : .failed
        }
        let status = (object["status"] as? String ?? "").lowercased()
        let standalone = (object["eigenstaendig"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case "frage": return .question(standalone: standalone)
        case "unvollstaendig": return .incomplete
        case "keine_frage": return .notQuestion
        default: return .failed
        }
    }

    private static func earlyStatusStart(in partialJSON: String) -> Character? {
        guard let keyRange = partialJSON.range(of: "\"status\"") else { return nil }
        let suffix = partialJSON[keyRange.upperBound...]
        guard let colon = suffix.firstIndex(of: ":") else { return nil }
        let value = suffix[suffix.index(after: colon)...]
        guard let quote = value.firstIndex(of: "\"") else { return nil }
        return value[value.index(after: quote)...].first
    }

    /// `recentTranscript` already contains the just-ingested utterance. Keeping
    /// that final line would present it once as context and once as the target,
    /// which overweights it and makes short follow-ups especially unstable.
    static func contextExcludingCurrentUtterance(_ context: String, utterance: String) -> String {
        let target = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return context }

        var lines = context.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let last = lines.last,
              let separator = last.firstIndex(of: ":") else { return context }
        let transcriptText = last[last.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcriptText == target else { return context }
        lines.removeLast()
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import Foundation

/// What the assistant remembers about the conversation so far.
public struct MemorySnapshot: Sendable, Equatable {
    public var summary: String = ""
    public var keyPoints: [String] = []
    public var openPoints: [String] = []
    public var summarizedUtterances: Int = 0

    public init() {}

    public var isEmpty: Bool {
        summary.isEmpty && keyPoints.isEmpty && openPoints.isEmpty
    }

    /// Compact rendering for the answer prompt.
    public var promptText: String {
        var parts: [String] = []
        if !summary.isEmpty { parts.append(summary) }
        if !keyPoints.isEmpty {
            parts.append("Kernpunkte:\n" + keyPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !openPoints.isEmpty {
            parts.append("Offen:\n" + openPoints.map { "- \($0)" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Keeps long conversations usable: the last turns stay verbatim, everything
/// older is folded into a rolling summary by the fast model in the background.
public actor ConversationMemory {

    private let client: OllamaClient
    private var utterances: [Utterance] = []
    private var snapshot = MemorySnapshot()
    private var summarizeTask: Task<Void, Never>?
    private var summarizeTaskID: UUID?
    private var lastSummarizedIndex = 0

    public private(set) var isSummarizing = false

    public init(client: OllamaClient) {
        self.client = client
    }

    public func reset() {
        summarizeTask?.cancel()
        summarizeTask = nil
        summarizeTaskID = nil
        isSummarizing = false
        utterances.removeAll()
        snapshot = MemorySnapshot()
        lastSummarizedIndex = 0
    }

    public func add(_ utterance: Utterance) {
        utterances.append(utterance)
    }

    public func update(_ utterance: Utterance) {
        guard let index = utterances.firstIndex(where: { $0.id == utterance.id }) else { return }
        utterances[index] = utterance
    }

    public func current() -> MemorySnapshot { snapshot }

    public func allUtterances() -> [Utterance] { utterances }

    /// The last `count` turns, rendered for a prompt.
    public func recentTranscript(
        turns: Int,
        tokenBudget: Int,
        excludingUtteranceIDs: Set<UUID> = []
    ) -> String {
        var lines: [String] = []
        var tokens = 0
        for utterance in utterances.filter({ !excludingUtteranceIDs.contains($0.id) }).suffix(turns).reversed() {
            let line = "\(utterance.source.speakerLabel): \(utterance.displayText)"
            let cost = TextUtilities.estimatedTokens(line)
            if tokens + cost > tokenBudget { break }
            tokens += cost
            lines.insert(line, at: 0)
        }
        return lines.joined(separator: "\n")
    }

    /// Context for classifying a possibly stitched utterance. Besides the
    /// current segment, immediately preceding fragments that were folded into
    /// `target` are removed so the classifier never sees the same words twice.
    public func classificationContext(
        target: String,
        currentUtteranceID: UUID,
        turns: Int,
        tokenBudget: Int
    ) -> String {
        var excluded: Set<UUID> = [currentUtteranceID]
        if let currentIndex = utterances.firstIndex(where: { $0.id == currentUtteranceID }) {
            let normalizedTarget = Self.normalizedText(target)
            let current = utterances[currentIndex]
            var laterStart = current.startSeconds
            for candidate in utterances[..<currentIndex].reversed().prefix(3) {
                let normalizedCandidate = Self.normalizedText(candidate.displayText)
                let closeEnough = laterStart - candidate.endSeconds <= 2.6
                guard candidate.source == current.source,
                      closeEnough,
                      !normalizedCandidate.isEmpty,
                      normalizedTarget.contains(normalizedCandidate) else { break }
                excluded.insert(candidate.id)
                laterStart = candidate.startSeconds
            }
        }
        return recentTranscript(
            turns: turns,
            tokenBudget: tokenBudget,
            excludingUtteranceIDs: excluded
        )
    }

    /// Context for answering a specific question. Besides the most recent
    /// turns, this brings older statements back when they share distinctive
    /// terms, names or numbers with the question.
    ///
    /// The question itself is omitted when it is already the newest transcript
    /// entry; callers normally add it separately to the answer prompt.
    public func relevantTranscript(
        for question: String,
        recentTurns: Int,
        tokenBudget: Int,
        maximumOlderTurns: Int = 6,
        excludingUtteranceIDs: Set<UUID> = []
    ) -> String {
        guard tokenBudget > 0, !utterances.isEmpty else { return "" }

        let candidates = utterances.enumerated().filter {
            !excludingUtteranceIDs.contains($0.element.id)
        }
        guard !candidates.isEmpty else { return "" }

        let recentCount = max(0, recentTurns)
        let recent = Array(candidates.suffix(recentCount))
        let recentIndexes = Set(recent.map(\.offset))
        let queryTerms = Self.relevanceTerms(in: question)
        let older = candidates
            .filter { !recentIndexes.contains($0.offset) }
            .compactMap { candidate -> (index: Int, utterance: Utterance, score: Int)? in
                let score = Self.relevanceScore(
                    text: candidate.element.displayText,
                    queryTerms: queryTerms
                )
                guard score > 0 else { return nil }
                return (candidate.offset, candidate.element, score)
            }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index > $1.index
            }

        var selected: Set<Int> = []
        var usedTokens = 0

        func add(_ index: Int, _ utterance: Utterance, limit: Int) {
            guard !selected.contains(index) else { return }
            let cost = Self.promptLine(for: utterance).tokens
            guard usedTokens + cost <= limit else { return }
            selected.insert(index)
            usedTokens += cost
        }

        // Keep enough space for facts outside the recent window. If none are
        // relevant, the second recent pass naturally consumes the full budget.
        let initialRecentLimit = older.isEmpty ? tokenBudget : max(1, tokenBudget * 2 / 3)
        for item in recent.reversed() {
            add(item.offset, item.element, limit: initialRecentLimit)
        }
        for item in older.prefix(max(0, maximumOlderTurns)) {
            add(item.index, item.utterance, limit: tokenBudget)
        }
        for item in recent.reversed() {
            add(item.offset, item.element, limit: tokenBudget)
        }

        return candidates
            .filter { selected.contains($0.offset) }
            .map { Self.promptLine(for: $0.element).text }
            .joined(separator: "\n")
    }

    /// Short context string handed to the translator so pronouns and
    /// terminology stay consistent across sentences.
    public func translationContext(maxCharacters: Int = 400) -> String {
        var text = ""
        for utterance in utterances.suffix(4).reversed() {
            let candidate = utterance.original + " " + text
            if candidate.count > maxCharacters { break }
            text = candidate
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Kicks off a background summarisation when enough new material piled up.
    public func summarizeIfNeeded(
        model: String,
        every interval: Int,
        keepVerbatim: Int,
        onUpdate: @escaping @Sendable (MemorySnapshot) -> Void
    ) {
        guard summarizeTask == nil else { return }
        let newSinceLast = utterances.count - lastSummarizedIndex
        guard newSinceLast >= interval else { return }

        let upperBound = max(0, utterances.count - keepVerbatim)
        guard upperBound > lastSummarizedIndex else { return }

        let slice = utterances[lastSummarizedIndex..<upperBound]
        let transcript = slice
            .map { "\($0.source.speakerLabel): \($0.displayText)" }
            .joined(separator: "\n")
        guard !transcript.isEmpty else { return }

        let previous = snapshot.promptText
        let newIndex = upperBound
        let taskID = UUID()
        isSummarizing = true
        summarizeTaskID = taskID

        summarizeTask = Task { [client] in
            do {
                let (text, _) = try await client.chat(
                    model: model,
                    messages: [
                        .system(Prompts.summarySystem),
                        .user(Prompts.summaryUser(previous: previous, transcript: transcript))
                    ],
                    options: GenerationOptions(
                        temperature: 0.1,
                        numPredict: 600,
                        numCtx: 8192
                    ),
                    format: Prompts.summarySchema,
                    think: modelSupportsThinking(model) ? false : nil
                )
                guard !Task.isCancelled else { return }
                if let parsed = Self.parseSummary(text) {
                    self.applySummary(parsed, upTo: newIndex, taskID: taskID)
                    if self.summarizeTaskID == taskID {
                        onUpdate(self.current())
                    }
                }
            } catch is CancellationError {
                // Session ended.
            } catch {
                Log.pipeline.error("Summary failed: \(String(describing: error), privacy: .public)")
            }
            self.finishSummarizing(taskID: taskID)
        }
    }

    private func finishSummarizing(taskID: UUID) {
        guard summarizeTaskID == taskID else { return }
        summarizeTask = nil
        summarizeTaskID = nil
        isSummarizing = false
    }

    private func applySummary(_ parsed: MemorySnapshot, upTo index: Int, taskID: UUID) {
        guard summarizeTaskID == taskID else { return }
        snapshot.summary = parsed.summary.isEmpty ? snapshot.summary : parsed.summary
        snapshot.keyPoints = Self.updatedList(parsed.keyPoints, limit: 14)
        snapshot.openPoints = Self.updatedList(parsed.openPoints, limit: 10)
        snapshot.summarizedUtterances = index
        lastSummarizedIndex = index
    }

    static func updatedList(_ incoming: [String], limit: Int) -> [String] {
        // The summary model receives the previous snapshot and returns the new
        // authoritative view. Re-adding omitted entries would revive corrected
        // or explicitly closed facts.
        var seen = Set<String>()
        return incoming.compactMap { entry in
            let cleaned = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(cleaned.lowercased()).inserted else { return nil }
            return cleaned
        }.prefix(limit).map { $0 }
    }

    private static let relevanceStopWords: Set<String> = [
        "aber", "also", "auf", "aus", "bei", "bin", "bis", "das", "dass", "dem", "den",
        "der", "des", "die", "ein", "eine", "einer", "einem", "einen", "er", "es", "für",
        "hat", "haben", "ich", "im", "in", "ist", "kann", "können", "man", "mit", "nach",
        "noch", "oder", "sein", "sind", "sie", "über", "um", "und", "uns", "von", "vor",
        "wann", "warum", "was", "welche", "welcher", "welches", "wer", "wie", "wir", "wo",
        "wurde", "werden", "zu", "zum", "zur",
        "a", "an", "and", "are", "can", "do", "does", "for", "from", "how", "is", "of",
        "or", "the", "to", "was", "what", "when", "where", "which", "who", "why", "will"
    ]

    private static func promptLine(for utterance: Utterance) -> (text: String, tokens: Int) {
        let text = "\(utterance.source.speakerLabel): \(utterance.displayText)"
        return (text, TextUtilities.estimatedTokens(text))
    }

    private static func normalizedText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ")
    }

    private static func relevanceTerms(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { term in
                (term.allSatisfy(\.isNumber) || term.count >= 3)
                    && !relevanceStopWords.contains(term)
            }
    }

    private static func relevanceScore(text: String, queryTerms: [String]) -> Int {
        guard !queryTerms.isEmpty else { return 0 }
        let textTerms = relevanceTerms(in: text)
        var score = 0
        for query in Set(queryTerms) {
            guard textTerms.contains(where: { termsAreRelated(query, $0) }) else { continue }
            if query.allSatisfy(\.isNumber) {
                score += 8
            } else if query.count >= 7 {
                score += 4
            } else {
                score += 2
            }
        }
        return score
    }

    private static func termsAreRelated(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard lhs.count >= 5, rhs.count >= 5 else { return false }
        return lhs.prefix(5) == rhs.prefix(5)
    }

    static func parseSummary(_ text: String) -> MemorySnapshot? {
        let cleaned = TextUtilities.stripThinking(text)
        guard let data = extractJSON(from: cleaned),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["zusammenfassung"] is String,
              object["kernpunkte"] is [Any],
              object["offene_punkte"] is [Any] else {
            return nil
        }
        var snapshot = MemorySnapshot()
        snapshot.summary = (object["zusammenfassung"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        snapshot.keyPoints = (object["kernpunkte"] as? [Any] ?? []).compactMap { $0 as? String }
        snapshot.openPoints = (object["offene_punkte"] as? [Any] ?? []).compactMap { $0 as? String }
        return snapshot
    }

    /// Pulls the first balanced JSON object out of a model response.
    static func extractJSON(from text: String) -> Data? {
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if character == "\\" && inString {
                escaped = true
            } else if character == "\"" {
                inString.toggle()
            } else if !inString {
                if character == "{" { depth += 1 }
                if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        let slice = text[start...index]
                        return String(slice).data(using: .utf8)
                    }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

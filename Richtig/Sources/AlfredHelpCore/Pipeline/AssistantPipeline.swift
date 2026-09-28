import Foundation

/// Turns finished utterances into German text, detected questions and streamed
/// answers – entirely against the local Ollama instance.
public actor AssistantPipeline {

    private let client: OllamaClient
    private let memory: ConversationMemory
    private let translationQueue = SerialQueue()
    /// Session generation captured by queued work. Besides cancelling the
    /// queue, this prevents a transport that completes despite cancellation
    /// from publishing an event into the next conversation.
    private var generation: UInt64 = 0

    private var settings: AppSettings
    private var emit: (@Sendable (PipelineEvent, UInt64) -> Void)?
    private var answerTask: Task<Void, Never>?
    private var classifyTasks: [UUID: Task<Void, Never>] = [:]
    /// Every detected question gets a monotonic ticket. A slow classifier may
    /// finish later, but it must never revive or refine an older question.
    private var classificationSequence = QuestionClassifier.Sequence()
    /// Highest ticket that actually started an answer. Mere candidates do not
    /// invalidate older useful verdicts until they themselves become questions.
    private var latestCommittedQuestionTicket: UInt64 = 0
    private var currentAnswerID: UUID?
    /// Setzt zerfallene Sätze wieder zusammen, bevor über sie geurteilt wird.
    /// Der ganze Zustand dazu – was gerade auf seine Fortsetzung wartet, seit
    /// wann und aus wie vielen Teilen – liegt dort und ist ohne laufende
    /// Spracherkennung prüfbar.
    private var stitcher = UtteranceStitcher()
    /// Recently answered questions as normalized word sets – blocks duplicates
    /// from recognizer repeats and from people literally asking twice.
    private var answeredQuestions: [(words: Set<String>, at: Double)] = []
    /// When the current answer started and for which question text – used to
    /// merge rapid follow-up questions instead of discarding one of them.
    private var currentQuestionText = ""
    private var currentAnswerStartedAt: Double = 0
    /// Whether the running answer was requested by hand (click or hotkey).
    /// Manual answers are never dismissed as self-answered rhetoric.
    private var currentAnswerIsManual = false
    /// Everything needed to restart a speculative generation when the
    /// classifier finishes rewriting a context-dependent question. The first
    /// generation still starts on the early verdict, so this adds no waiting;
    /// only the uncommon rewrite replaces the in-flight request.
    private struct ActiveAnswer: Sendable {
        let card: AnswerCard
        let model: String
        let settings: AppSettings
        let capturedAt: Double
        let contextUtteranceIDs: Set<UUID>
    }
    private var activeAnswer: ActiveAnswer?

    public init(client: OllamaClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
        self.memory = ConversationMemory(client: client)
    }

    public func setEmitter(_ emit: @escaping @Sendable (PipelineEvent, UInt64) -> Void) {
        self.emit = emit
    }

    public func update(settings: AppSettings) {
        self.settings = settings
    }

    public func reset() async {
        generation &+= 1
        answerTask?.cancel()
        answerTask = nil
        currentAnswerID = nil
        activeAnswer = nil
        for task in classifyTasks.values { task.cancel() }
        classifyTasks.removeAll()
        classificationSequence = QuestionClassifier.Sequence()
        latestCommittedQuestionTicket = 0
        stitcher.removeAll()
        answeredQuestions.removeAll()
        refinedQuestions.removeAll()
        currentQuestionText = ""
        currentAnswerIsManual = false
        let translationsStopped = await translationQueue.cancelAll()
        await memory.reset()
        if !translationsStopped {
            publish(.failure("Eine alte Modellanfrage reagiert nicht; neue Übersetzungen warten, damit das Sprachmodell nicht doppelt belastet wird."))
        }
    }

    public func snapshot() async -> MemorySnapshot {
        await memory.current()
    }

    public func transcript() async -> [Utterance] {
        await memory.allUtterances()
    }

    /// Warms both models so the first real utterance does not pay the load cost.
    ///
    /// Order matters and must not be left to a `Set`: the answer model is the
    /// one whose load time the user actually feels, so it goes in first and
    /// keeps its place in memory. The small model follows and is cheap enough
    /// to reload if the system ever evicts it.
    public func warmUp() async {
        var models: [String] = []
        for candidate in [settings.qualityModel, settings.fastModel]
        where !candidate.isEmpty && !models.contains(candidate) {
            models.append(candidate)
        }
        for model in models {
            do {
                try await client.warmUp(model: model, keepAlive: settings.keepAlive)
            } catch is CancellationError {
                return
            } catch {
                // Nicht verschlucken. Ein Modell, das hier nicht lädt – weil es
                // nicht da ist oder der Dienst nicht läuft –, fällt sonst erst
                // bei der ersten echten Frage auf, und zwar mitten im Gespräch.
                Log.pipeline.error(
                    "Warm-up für \(model, privacy: .public) fehlgeschlagen: \(String(describing: error), privacy: .public)"
                )
                publishFailure("Modell „\(model)“ ist nicht bereit: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Ingest

    public func ingest(_ utterance: Utterance) async {
        var stored = utterance
        if settings.systemAudioIsGerman && utterance.source == .system {
            stored.german = utterance.original
        }
        if utterance.source == .microphone,
           settings.microphoneLocaleValue.language.languageCode?.identifier == "de" {
            stored.german = utterance.original
        }

        await memory.add(stored)
        publish(.utteranceAdded(stored))

        if settings.translationEnabled && stored.german == nil {
            await scheduleTranslation(for: stored)
        }

        let shouldConsider = settings.autoAnswerEnabled
            && (!settings.answerOnlySystemAudio || stored.source == .system)
        if shouldConsider {
            considerQuestion(stored)
        }

        await memory.summarizeIfNeeded(
            model: summaryModel,
            every: settings.summarizeEveryUtterances,
            keepVerbatim: settings.verbatimTurns
        ) { [weak self] snapshot in
            Task { await self?.publish(.memory(snapshot)) }
        }
    }

    private func publish(_ event: PipelineEvent) {
        emit?(event, generation)
    }

    private var lastFailureNoticeAt: Double = 0

    // Shrinking `num_ctx` to fit the prompt looked like free VRAM, so it was
    // tried and measured against the real answer model (`Benchmarks/ctx_ab.py`,
    // identical prompts, gemma3:12b): coverage stayed at 100 %, but the first
    // token arrived 654 → 777 ms later and throughput dropped 13.7 → 12.4 tok/s,
    // for all of 0.4 GB saved. Gemma's sliding-window attention simply does not
    // pay for a smaller window. The configured value is used unchanged.

    /// Rate-limited failure notice so a missing model does not spam the UI.
    private func publishFailure(_ message: String) {
        let now = Clock.now()
        guard now - lastFailureNoticeAt > 60 else { return }
        lastFailureNoticeAt = now
        publish(.failure(message))
    }

    // MARK: - Translation

    private func scheduleTranslation(for utterance: Utterance) async {
        let model = settings.fastModel
        guard !model.isEmpty else { return }
        let languageHint = settings.conversationLanguageName
        let keepAlive = settings.keepAlive
        let contextTokens = settings.contextTokens
        let scheduledGeneration = generation

        // Register the work before `ingest` returns. A detached intermediary
        // could otherwise enqueue an old translation only after `reset` had
        // already cancelled the queue.
        await translationQueue.enqueue { [self] in
            await runTranslation(
                utterance: utterance,
                model: model,
                languageHint: languageHint,
                keepAlive: keepAlive,
                contextTokens: contextTokens,
                generation: scheduledGeneration
            )
        }
    }

    private func runTranslation(
        utterance: Utterance,
        model: String,
        languageHint: String,
        keepAlive: String,
        contextTokens: Int,
        generation scheduledGeneration: UInt64
    ) async {
        guard scheduledGeneration == generation else { return }
        let context = await memory.translationContext()
        guard scheduledGeneration == generation else { return }
        let messages: [ChatMessage] = [
            .system(Prompts.translateSystem),
            .user(Prompts.translateUser(
                context: context,
                utterance: utterance.original,
                languageHint: languageHint
            ))
        ]
        let started = Clock.now()
        var accumulated = ""
        var lastEmitAt: Double = 0

        do {
            for try await chunk in client.chatStream(
                model: model,
                messages: messages,
                options: GenerationOptions(
                    temperature: 0.1,
                    numPredict: 320,
                    numCtx: min(contextTokens, 4096)
                ),
                think: modelSupportsThinking(model) ? false : nil,
                keepAlive: keepAlive
            ) {
                if Task.isCancelled || scheduledGeneration != generation { return }
                accumulated += chunk.text
                let now = Clock.now()
                if !chunk.text.isEmpty, now - lastEmitAt >= Self.deltaEmitInterval {
                    lastEmitAt = now
                    publish(.translation(
                        id: utterance.id,
                        german: TextUtilities.cleanModelText(accumulated),
                        isFinal: false
                    ))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard scheduledGeneration == generation else { return }
            publish(.translation(id: utterance.id, german: utterance.original, isFinal: true))
            publish(.failure("Übersetzung fehlgeschlagen: \(error.localizedDescription)"))
            return
        }

        let german = TextUtilities.cleanModelText(accumulated)
        guard !german.isEmpty, scheduledGeneration == generation else { return }

        var updated = utterance
        updated.german = german
        await memory.update(updated)
        guard scheduledGeneration == generation else { return }
        publish(.translation(id: utterance.id, german: german, isFinal: true))
        Log.pipeline.debug("Translation in \(Clock.millis(since: started), privacy: .public) ms")
    }

    // MARK: - Question detection

    private func considerQuestion(_ utterance: Utterance) {
        let now = Clock.now()

        // Self-answered rhetoric across utterance boundaries: "Warum?" –
        // answer starts – "Weil …" from the same speaker kills it again.
        if currentAnswerID != nil,
           !currentAnswerIsManual,
           now - currentAnswerStartedAt < 4,
           TextUtilities.answersPreviousQuestion(utterance.original) {
            if let id = currentAnswerID { cancelAnswerIfStillRunning(for: id) }
            return
        }

        // Zerfallene Sätze zusammenführen, bevor geurteilt wird. Das passiert
        // ohne jede Wartezeit: bewertet wird sofort, nur der zusammengesetzte
        // statt des angekommenen Textes.
        switch stitcher.offer(utterance, now: now) {
        case .nothing:
            return

        case .waiting:
            // Für sich genommen trägt der Text keine Antwort – Festhalten
            // kostet also nichts, was schon beantwortbar wäre.
            Log.pipeline.info("Fragment held, waiting for its continuation")
            return

        case .question(let assessed, let question, let confidence):
            guard confidence >= settings.questionHeuristicThreshold else { return }
            guard !isDuplicateQuestion(question, now: now) else {
                Log.pipeline.info("Question suppressed as duplicate")
                return
            }
            // Timings and decisions only – conversation text never goes to the log.
            Log.pipeline.info(
                "Question detected, confidence \(confidence, format: .fixed(precision: 2), privacy: .public)"
            )
            let classificationTicket = classificationSequence.register()
            let allowsHeuristicFallback = utterance.confidence.map {
                $0 >= QuestionClassifier.minimumASRConfidenceForHeuristicFallback
            } ?? true

            if QuestionClassifier.mayUseHeuristicShortcut(
                questionConfidence: confidence,
                certaintyShortcut: settings.questionCertaintyShortcut,
                asrConfidence: utterance.confidence
            ) {
                // Unambiguous: answer immediately, classifier runs as veto only.
                commitAutomaticAnswer(
                    question: question,
                    utterance: utterance,
                    classificationTicket: classificationTicket
                )
                verifyInBackground(
                    utterance,
                    assessedText: assessed,
                    classificationTicket: classificationTicket
                )
            } else {
                classify(
                    utterance,
                    assessedText: assessed,
                    question: question,
                    confidence: confidence,
                    classificationTicket: classificationTicket,
                    allowsHeuristicFallback: allowsHeuristicFallback
                )
            }
        }
    }

    /// Normalized-word-set similarity against recently answered questions.
    private func isDuplicateQuestion(_ text: String, now: Double) -> Bool {
        let words = Self.questionFingerprint(text)
        guard !words.isEmpty else { return false }
        answeredQuestions.removeAll { now - $0.at > 120 }
        return answeredQuestions.contains { Self.questionsSimilar(words, $0.words) }
    }

    /// Jaccard similarity over normalized word sets – recognizer repeats and
    /// literally re-asked questions land well above the threshold, while a
    /// genuinely new question about the same topic stays below it.
    static func questionsSimilar(_ a: Set<String>, _ b: Set<String>) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let overlap = Double(a.intersection(b).count)
        let union = Double(a.union(b).count)
        return union > 0 && overlap / union >= 0.72
    }

    static func questionFingerprint(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 1 }
        )
    }

    /// Runs the classifier and cancels the speculative answer if the utterance
    /// turns out not to be a question after all.
    private func verifyInBackground(
        _ utterance: Utterance,
        assessedText: String,
        classificationTicket: UInt64
    ) {
        let classificationGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }
            let verdict = await self.runClassifier(
                assessedText,
                currentUtteranceID: utterance.id
            )
            defer { Task { await self.forgetClassification(utterance.id) } }
            guard !Task.isCancelled else { return }
            await self.applyVerificationVerdict(
                verdict,
                to: utterance,
                generation: classificationGeneration,
                classificationTicket: classificationTicket
            )
        }
        classifyTasks[utterance.id] = task
    }

    private func forgetClassification(_ id: UUID) {
        classifyTasks.removeValue(forKey: id)
    }

    /// `assessedText` ist der volle zusammengesetzte Text – er geht an den
    /// Klassifikator, der aus ihm heraus urteilt. `question` ist der auf die
    /// eigentliche Frage eingedampfte Teil davon; nur er wird beantwortet.
    private func classify(
        _ utterance: Utterance,
        assessedText: String,
        question: String,
        confidence: Double,
        classificationTicket: UInt64,
        allowsHeuristicFallback: Bool
    ) {
        let classificationGeneration = generation
        let task = Task { [weak self] in
            guard let self else { return }

            // Time guard: when the local model is starved (VRAM contention,
            // model still loading), a likely question must not wait forever.
            // After 8 s the heuristic verdict answers; the classifier keeps
            // running and may still veto or refine.
            let fallback: Task<Void, Never>? = confidence >= 0.6 && allowsHeuristicFallback
                ? Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    await self?.startAnswerIfCurrent(
                        question: question,
                        utterance: utterance,
                        generation: classificationGeneration,
                        classificationTicket: classificationTicket
                    )
                }
                : nil
            defer { fallback?.cancel() }

            // The early decision fires after roughly a dozen tokens, long
            // before the rewritten question is finished – that is what keeps an
            // ambiguous utterance from costing seconds.
            let verdict = await self.runClassifier(
                assessedText,
                currentUtteranceID: utterance.id
            ) { isQuestion in
                fallback?.cancel()
                guard isQuestion else { return }
                Task { await self.startAnswerIfCurrent(
                    question: question,
                    utterance: utterance,
                    generation: classificationGeneration,
                    classificationTicket: classificationTicket
                ) }
            }
            defer { Task { await self.forgetClassification(utterance.id) } }
            guard !Task.isCancelled else { return }
            await self.applyClassificationVerdict(
                verdict,
                to: utterance,
                assessedText: assessedText,
                fallbackQuestion: question,
                generation: classificationGeneration,
                classificationTicket: classificationTicket,
                allowsHeuristicFallback: allowsHeuristicFallback
            )
        }
        classifyTasks[utterance.id] = task
    }

    /// Der Klassifikator kann zu demselben Urteil kommen wie die Heuristik:
    /// die Äußerung ist abgerissen. Dann gilt dasselbe – festhalten und auf
    /// die Fortsetzung warten.
    private func rememberFragment(_ utterance: Utterance, text: String) {
        stitcher.hold(text, from: utterance)
    }

    /// Prüfung und Zustandsänderung geschehen in demselben Actor-Zug.
    /// Andernfalls kann `reset()` genau zwischen Generationstest und Mutation
    /// laufen und ein altes Klassifikatorresultat in das neue Gespräch tragen.
    private func applyVerificationVerdict(
        _ verdict: QuestionClassifier.Verdict?,
        to utterance: Utterance,
        generation expectedGeneration: UInt64,
        classificationTicket: UInt64
    ) {
        guard expectedGeneration == generation,
              classificationTicket >= latestCommittedQuestionTicket,
              let verdict else { return }
        switch verdict {
        case .notQuestion, .incomplete:
            cancelAnswerIfStillRunning(for: utterance.id)
        case .question(let standalone):
            if !standalone.isEmpty {
                refineQuestionText(for: utterance.id, to: standalone)
            }
        case .failed:
            break
        }
    }

    private func applyClassificationVerdict(
        _ verdict: QuestionClassifier.Verdict?,
        to utterance: Utterance,
        assessedText: String,
        fallbackQuestion: String,
        generation expectedGeneration: UInt64,
        classificationTicket: UInt64,
        allowsHeuristicFallback: Bool
    ) {
        guard expectedGeneration == generation,
              classificationTicket >= latestCommittedQuestionTicket,
              let verdict else { return }
        switch verdict {
        case .question(let standalone):
            if currentAnswerID != utterance.id {
                commitAutomaticAnswer(
                    question: fallbackQuestion,
                    utterance: utterance,
                    classificationTicket: classificationTicket
                )
            }
            if !standalone.isEmpty {
                refineQuestionText(for: utterance.id, to: standalone)
            }
        case .incomplete:
            if classificationTicket >= latestCommittedQuestionTicket {
                rememberFragment(utterance, text: assessedText)
            }
            cancelAnswerIfStillRunning(for: utterance.id)
        case .notQuestion:
            cancelAnswerIfStillRunning(for: utterance.id)
        case .failed:
            // A missing model must degrade to "answer likely questions",
            // never to silently ignoring the other side.
            if allowsHeuristicFallback {
                commitAutomaticAnswer(
                    question: fallbackQuestion,
                    utterance: utterance,
                    classificationTicket: classificationTicket
                )
            }
            publishFailure("Frageerkennung ohne Sprachmodell – prüfe die Modellauswahl in den Einstellungen.")
        }
    }

    private func runClassifier(
        _ text: String,
        currentUtteranceID: UUID,
        onEarlyDecision: (@Sendable (Bool) -> Void)? = nil
    ) async -> QuestionClassifier.Verdict? {
        let model = settings.fastModel
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed
        }
        // Mehr Verlauf als früher (6/400): Kurzfragen wie „Und dann?“ oder
        // „Wie genau?“ sind ohne die Wortmeldungen davor nicht zu beurteilen,
        // und das kleine Modell liest die paar hundert Token in Millisekunden.
        let context = await memory.classificationContext(
            target: text,
            currentUtteranceID: currentUtteranceID,
            turns: 8,
            tokenBudget: 600
        )
        return await QuestionClassifier.classify(
            client: client,
            model: model,
            context: context,
            utterance: text,
            keepAlive: settings.keepAlive,
            onEarlyDecision: onEarlyDecision
        )
    }

    private func cancelAnswerIfStillRunning(for utteranceID: UUID) {
        guard currentAnswerID == utteranceID else { return }
        answerTask?.cancel()
        answerTask = nil
        currentAnswerID = nil
        activeAnswer = nil
        // Eine verworfene Antwort läuft nie durch `clearAnswer`; ohne diese
        // Zeile bliebe ihre umformulierte Frage bis zum Programmende liegen.
        refinedQuestions.removeValue(forKey: utteranceID)
        publish(.answerDiscarded(id: utteranceID))
    }

    // Internal so the request-restart contract can be exercised with a held
    // loopback transport; callers outside the module still only reach this
    // through the classifier.
    func refineQuestionText(for utteranceID: UUID, to question: String) {
        guard currentAnswerID == utteranceID,
              let activeAnswer else { return }
        guard refinedQuestions[utteranceID] != question else { return }
        guard activeAnswer.card.question != question else { return }
        refinedQuestions[utteranceID] = question
        publish(.answerQuestionRefined(id: utteranceID, question: question))

        // An early positive classifier verdict deliberately starts generation
        // before `eigenstaendig` has finished streaming. Once that rewrite is
        // available, replace the speculative request instead of updating only
        // the card while Ollama continues answering the stale wording.
        answerTask?.cancel()
        launchAnswer(activeAnswer)
    }

    private var refinedQuestions: [UUID: String] = [:]

    private func startAnswerFromTask(question: String, utterance: Utterance) {
        startAnswer(question: question, utterance: utterance, manual: false)
    }

    private func startAnswerIfCurrent(
        question: String,
        utterance: Utterance,
        generation expectedGeneration: UInt64,
        classificationTicket: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        commitAutomaticAnswer(
            question: question,
            utterance: utterance,
            classificationTicket: classificationTicket
        )
    }

    private func commitAutomaticAnswer(
        question: String,
        utterance: Utterance,
        classificationTicket: UInt64
    ) {
        guard classificationTicket > latestCommittedQuestionTicket else { return }
        latestCommittedQuestionTicket = classificationTicket
        startAnswerFromTask(question: question, utterance: utterance)
    }

    private func isCurrentGeneration(_ expectedGeneration: UInt64) -> Bool {
        generation == expectedGeneration
    }

    // MARK: - Answering

    /// Answers the most recent utterance from the other side on demand.
    public func answerLatest() async {
        let utterances = await memory.allUtterances()
        guard let latest = utterances.last(where: { $0.source == .system }) ?? utterances.last else {
            publish(.notice("Noch nichts gehört, worauf sich antworten ließe."))
            return
        }
        startAnswer(question: latest.displayText, utterance: latest, manual: true)
    }

    /// Answers one specific utterance the user clicked in the transcript.
    /// The click IS the verdict: heuristic and classifier get no veto here –
    /// this is the escape hatch for questions the detection missed.
    public func answer(utteranceID: UUID) async {
        await answer(question: nil, utteranceID: utteranceID)
    }

    /// Retries an answer with the exact question shown on its card. This keeps
    /// contextual rewrites and rapidly combined follow-ups intact.
    public func answer(question: String?, utteranceID: UUID) async {
        let utterances = await memory.allUtterances()
        guard let utterance = utterances.last(where: { $0.id == utteranceID }) else {
            publish(.notice("Diese Äußerung ist nicht mehr im Gesprächsverlauf."))
            return
        }
        let requested = question?.trimmingCharacters(in: .whitespacesAndNewlines)
        startAnswer(
            question: requested.flatMap { $0.isEmpty ? nil : $0 } ?? utterance.displayText,
            utterance: utterance,
            manual: true
        )
    }

    private func startAnswer(question: String, utterance: Utterance, manual: Bool) {
        let model = settings.qualityModel
        guard !model.isEmpty else {
            publish(.failure("Kein Antwortmodell ausgewählt."))
            return
        }

        if manual {
            // A click is newer and authoritative. Any slower automatic verdict
            // from another utterance must not replace this manual answer.
            let manualTicket = classificationSequence.register()
            latestCommittedQuestionTicket = manualTicket
            // The user decided this is a question. A still-running automatic
            // classification for the same utterance must not veto the answer
            // afterwards, and a fragment hold for it is obsolete too.
            for task in classifyTasks.values { task.cancel() }
            classifyTasks.removeAll()
            stitcher.forget(utteranceID: utterance.id)
        }

        // A newer question always wins – nobody wants yesterday's answer.
        // But a question arriving seconds after the previous one is usually
        // part two of the same thought: answer both together.
        var effectiveQuestion = question
        var contextUtteranceIDs: Set<UUID> = [utterance.id]
        let now = Clock.now()
        if !manual,
           currentAnswerID != nil,
           now - currentAnswerStartedAt < 5,
           !currentQuestionText.isEmpty,
           currentQuestionText != question {
            // Über `join`, nicht über `+ " " +`: die zweite Frage wiederholt
            // die erste oft in Teilen („Und wie lange dauert das“ nach „Wie
            // lange dauert das ungefähr“), und die Verdopplung landete bisher
            // ungefiltert im Prompt.
            effectiveQuestion = UtteranceStitcher.join(currentQuestionText, question)
            if let activeAnswer {
                contextUtteranceIDs.formUnion(activeAnswer.contextUtteranceIDs)
            }
        }
        answerTask?.cancel()

        // Die abgelöste Karte muss ausdrücklich weg. Ihr Strom ist eben
        // abgebrochen worden, sie bekommt also nie ein `answerFinished` und
        // bliebe sonst bis zum Sitzungsende als halb geschriebene Antwort
        // stehen. Auffällig wird das erst, seit ein zerfallener Satz
        // nachträglich vollständig beantwortet wird: dann löst die
        // vollständige Frage regelmäßig die Antwort auf ihr Bruchstück ab.
        if let superseded = currentAnswerID, superseded != utterance.id {
            classifyTasks.removeValue(forKey: superseded)?.cancel()
            refinedQuestions.removeValue(forKey: superseded)
            publish(.answerDiscarded(id: superseded))
        }

        currentQuestionText = effectiveQuestion
        currentAnswerStartedAt = now
        currentAnswerIsManual = manual

        let card = AnswerCard(
            id: utterance.id,
            question: effectiveQuestion,
            spoken: utterance.original,
            wasManuallyTriggered: manual
        )
        currentAnswerID = utterance.id
        Log.pipeline.info("Answer started on \(model, privacy: .public)")
        publish(.answerStarted(card))

        let active = ActiveAnswer(
            card: card,
            model: model,
            settings: settings,
            capturedAt: utterance.capturedAt,
            contextUtteranceIDs: contextUtteranceIDs
        )
        activeAnswer = active
        launchAnswer(active)
    }

    private func launchAnswer(_ active: ActiveAnswer) {
        answerTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnswer(
                card: active.card,
                model: active.model,
                settings: active.settings,
                capturedAt: active.capturedAt,
                contextUtteranceIDs: active.contextUtteranceIDs
            )
        }
    }

    private func runAnswer(
        card: AnswerCard,
        model: String,
        settings: AppSettings,
        capturedAt: Double,
        contextUtteranceIDs: Set<UUID>
    ) async {
        let snapshot = await memory.current()
        let question = refinedQuestions[card.id] ?? card.question
        let recent = await memory.relevantTranscript(
            for: question,
            recentTurns: settings.verbatimTurns,
            tokenBudget: max(600, settings.contextTokens / 3),
            excludingUtteranceIDs: contextUtteranceIDs
        )

        let groundingEvidence = [snapshot.promptText, recent, question, settings.userProfile]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")

        let messages: [ChatMessage] = [
            .system(Prompts.answerSystem(
                language: settings.answerLanguage,
                conversationLanguage: settings.conversationLanguageName,
                profile: settings.userProfile
            )),
            .user(Prompts.answerUser(
                memory: snapshot.promptText,
                recent: recent,
                question: question
            ))
        ]

        var stream = TextUtilities.StructuredAnswerStreamFormatter()
        var firstTokenAt: Double?
        var finalMetrics: GenerationMetrics?
        var lastEmitAt: Double = 0

        do {
            for try await chunk in client.chatStream(
                model: model,
                messages: messages,
                options: GenerationOptions(
                    temperature: 0.35,
                    topP: 0.9,
                    numPredict: settings.maxAnswerTokens,
                    numCtx: settings.contextTokens
                ),
                format: Prompts.answerSchema,
                think: modelSupportsThinking(model) ? false : nil,
                keepAlive: settings.keepAlive
            ) {
                if Task.isCancelled { return }
                guard !chunk.text.isEmpty || chunk.isDone else { continue }
                stream.append(chunk.text)
                // Nicht bei jedem Token melden. Jedes `emit` löst in der
                // Oberfläche einen eigenen Sprung auf den MainActor samt
                // SwiftUI-Neuzeichnung aus; bei 24 Token pro Sekunde ist das
                // Arbeit, die niemand sieht. Ein Bild alle 50 ms liest sich
                // identisch flüssig.
                let now = Clock.now()
                if !chunk.text.isEmpty, now - lastEmitAt >= Self.deltaEmitInterval {
                    lastEmitAt = now
                    let parts = stream.current
                    // Concrete numbers remain hidden until the complete answer
                    // can be checked against its supplied evidence.
                    if !parts.spoken.contains(where: \.isNumber),
                       !parts.details.contains(where: \.isNumber) {
                        if firstTokenAt == nil, !parts.spoken.isEmpty { firstTokenAt = now }
                        publish(.answerDelta(
                            id: card.id, text: parts.spoken, details: parts.details
                        ))
                    }
                }
                if let metrics = chunk.metrics { finalMetrics = metrics }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            var failed = card
            failed.question = question
            if !stream.current.spoken.isEmpty {
                let partial = TextUtilities.groundStructuredAnswer(
                    stream.finish(),
                    evidence: groundingEvidence
                )
                failed.text = partial.spoken
                failed.details = partial.details
                failed.confidence = .low
                failed.missingContext = partial.missingContext
            }
            failed.isComplete = true
            failed.errorMessage = error.localizedDescription
            publish(.answerFinished(failed))
            clearAnswer(card.id)
            return
        }

        guard !Task.isCancelled else { return }
        var finished = card
        finished.question = question
        let result = TextUtilities.groundStructuredAnswer(
            stream.finish(),
            evidence: groundingEvidence
        )
        finished.text = result.spoken
        finished.details = result.details
        finished.confidence = result.confidence
        finished.missingContext = result.missingContext
        finished.isComplete = true
        if let firstTokenAt {
            finished.timeToFirstWordMilliseconds = Int(((firstTokenAt - capturedAt) * 1000).rounded())
        }
        finished.totalMilliseconds = Clock.millis(since: capturedAt)
        finished.tokensPerSecond = finalMetrics?.tokensPerSecond
        Log.pipeline.info(
            "Answer finished: \(finished.timeToFirstWordMilliseconds ?? -1, privacy: .public) ms to first word, \(Int(finalMetrics?.tokensPerSecond ?? 0), privacy: .public) tok/s"
        )
        // Duplicate suppression follows the heard wording, not the classifier's
        // contextual rewrite: recognizer repeats reproduce the former.
        markAnswered(card.question)
        publish(.answerFinished(finished))
        clearAnswer(card.id)
    }

    private func markAnswered(_ question: String) {
        let words = Self.questionFingerprint(question)
        guard !words.isEmpty else { return }
        answeredQuestions.append((words, Clock.now()))
        if answeredQuestions.count > 12 { answeredQuestions.removeFirst() }
    }

    private func clearAnswer(_ id: UUID) {
        if currentAnswerID == id {
            currentAnswerID = nil
            answerTask = nil
            activeAnswer = nil
        }
        refinedQuestions.removeValue(forKey: id)
        classifyTasks.removeValue(forKey: id)
    }

    /// Wie oft ein wachsender Text höchstens gemeldet wird. 50 ms sind unter
    /// der Schwelle, ab der ein Mensch Einzelbilder auseinanderhält, und weit
    /// über der Token-Rate der Modelle.
    private static let deltaEmitInterval: Double = 0.05

    private var summaryModel: String {
        settings.fastModel.isEmpty ? settings.qualityModel : settings.fastModel
    }
}

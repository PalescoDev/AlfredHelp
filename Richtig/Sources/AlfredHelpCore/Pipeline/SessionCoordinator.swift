import Foundation
import AVFoundation

public struct SessionState: Sendable, Equatable {
    public var isRunning = false
    public var isStarting = false
    public var systemAudioActive = false
    public var microphoneActive = false
    public var systemLevel: Float = 0
    public var microphoneLevel: Float = 0
    public var tappedDevice = ""
    public var statusMessage = ""

    public init() {}
}

public enum SessionError: LocalizedError, Equatable {
    case noAudioSourceEnabled
    case microphonePermissionDenied
    case lifecycleTimedOut

    public var errorDescription: String? {
        switch self {
        case .noAudioSourceEnabled:
            return "Aktiviere Systemaudio oder Mikrofon, bevor du die Sitzung startest."
        case .microphonePermissionDenied:
            return "Der Mikrofonzugriff wurde nicht erteilt; es ist keine Audioquelle aktiv."
        case .lifecycleTimedOut:
            return "Der vorherige Aufnahmevorgang wurde nicht rechtzeitig beendet. Bitte versuche es erneut."
        }
    }
}

/// Serialisiert die Übergabe an die Pipeline und versieht jede Lieferung mit
/// einer Sitzungsgeneration. Ein Reset kann damit bereits eingeplante, aber noch
/// nicht ausgeführte Arbeit sicher verwerfen.
final class OrderedUtteranceDelivery: @unchecked Sendable {
    typealias Sink = @Sendable (Utterance) async -> Void

    private let lock = NSLock()
    private let sink: Sink
    private var generation: UInt64 = 0
    private var tail: Task<Void, Never>?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    var currentGeneration: UInt64 {
        lock.withLock { generation }
    }

    func enqueue(_ utterance: Utterance, generation expectedGeneration: UInt64) {
        lock.withLock {
            guard expectedGeneration == generation else { return }
            let predecessor = tail
            let sink = self.sink
            tail = Task { [weak self] in
                await predecessor?.value
                guard self?.isCurrent(expectedGeneration) == true else { return }
                await sink(utterance)
            }
        }
    }

    /// Invalidiert alte Lieferungen und setzt eine Barriere an den Anfang der
    /// neuen Generation. Neue Transkripte können damit nicht vor dem Reset in
    /// die Pipeline gelangen und anschließend versehentlich gelöscht werden.
    func advanceGeneration(barrier: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            generation &+= 1
            let predecessor = tail
            let task = Task {
                await predecessor?.value
                await barrier()
            }
            tail = task
            return task
        }
    }

    func drain() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        lock.withLock { generation == expectedGeneration }
    }
}

/// Wires capture → transcription → assistant together and exposes one switch
/// for the UI.
public final class SessionCoordinator: @unchecked Sendable {

    public let client: OllamaClient
    public let pipeline: AssistantPipeline

    private let settingsStore: SettingsStore
    private let microphone = MicrophoneCapture()
    private let assemblerQueue = DispatchQueue(label: "de.alfredhelp.assembler")
    private let stateLock = NSLock()
    private let delivery: OrderedUtteranceDelivery

    // MARK: Unter `stateLock`
    //
    // Alles ab hier wird aus mehreren Threads angefasst – dem Audio-Callback,
    // der `assemblerQueue`, dem Pegel-Timer und der Main-Queue. Die Klasse ist
    // `@unchecked Sendable`, der Compiler prüft hier also nichts; ein
    // ungesicherter Zugriff auf eine der Objektreferenzen unten ist kein
    // veralteter Wert, sondern eine überzählige Freigabe.
    private var systemCapture: (any SystemAudioCapturing)?
    private var systemTranscriber: SourceTranscriber?
    private var microphoneTranscriber: SourceTranscriber?
    /// Läuft gerade ein Startvorgang? `isRunning` allein genügt als Wächter
    /// nicht: es wird erst am Ende von `bringUp()` gesetzt, also erst nach
    /// Modellbeschaffung und Erfassungsaufbau – Sekunden später.
    private var isStarting = false
    /// Verhindert, dass zwei parallele Stop-Aufrufe dieselbe Sitzung zweimal
    /// abbauen oder archivieren.
    private var isStopping = false
    /// Reset und Stop/Archivierung dürfen nicht ineinandergreifen: ein Archiv
    /// muss Transcript und Gedächtnis aus derselben Generation lesen.
    private var isResetting = false
    /// Kam während des Aufbaus ein Stopp-Wunsch? Er kann dort nicht sofort
    /// ausgeführt werden – abzubauen ist erst etwas, wenn der Aufbau steht –,
    /// darf aber auch nicht verlorengehen.
    private var stopRequested = false
    /// Owns the asynchronous setup so `stop()` can cancel a slow model install
    /// instead of leaving the UI waiting for it to finish.
    private var startupTask: Task<Void, Error>?
    private var systemAssembler = UtteranceAssembler(source: .system)
    private var microphoneAssembler = UtteranceAssembler(source: .microphone)
    private var idleTimer: DispatchSourceTimer?
    private var levelTimer: DispatchSourceTimer?
    private var permissionWatchdog: DispatchWorkItem?
    private var state = SessionState()
    private var pendingSystemLevel: Float = 0
    /// Latest volatile hypothesis per source – whether there is anything
    /// waiting to be finalised at all.
    private var volatileState: [AudioSourceKind: String] = [:]
    /// Last moment audio from this source was loud enough to be speech.
    private var lastSpeechAt: [AudioSourceKind: Double] = [:]
    private var lastForcedFinalize: [AudioSourceKind: Double] = [:]
    private var maxSystemPeak: Float = 0
    private var silenceWatchdog: DispatchWorkItem?
    private var pendingMicrophoneLevel: Float = 0
    private var activeCaptureSettings: AppSettings?

    /// The generation lets UI clients discard late events from a reset
    /// conversation without dropping the first events of the new one.
    public var onEvent: (@Sendable (PipelineEvent, UInt64) -> Void)?
    public var onState: (@Sendable (SessionState) -> Void)?

    public init(settingsStore: SettingsStore, client: OllamaClient = OllamaClient()) {
        self.settingsStore = settingsStore
        self.client = client
        let pipeline = AssistantPipeline(client: client, settings: settingsStore.settings)
        self.pipeline = pipeline
        self.delivery = OrderedUtteranceDelivery { utterance in
            await pipeline.ingest(utterance)
        }

    }

    /// Baut die Systemton-Erfassung passend zur Einstellung auf.
    ///
    /// Die Wahl des Verfahrens liegt bei der Einstellung selbst – dieselbe
    /// Fabrik benutzt auch die Freigabeprüfung, damit beide dasselbe prüfen.
    private func makeSystemCapture(_ settings: AppSettings) -> any SystemAudioCapturing {
        let capture = settings.systemAudioBackend.makeCapture()
        capture.onStatusChange = { [weak self] message in
            self?.emit(.notice(message))
        }
        if let capture = capture as? ScreenCaptureAudio {
            capture.onCaptureFailure = { [weak self] message in
                guard let self else { return }
                self.emit(.failure(message))
                Task { await self.stop() }
            }
        }
        return capture
    }

    /// Wie viele Rahmen die Systemton-Erfassung bisher geliefert hat.
    /// Wird aus dem Berechtigungs-Wächter auf der Main-Queue gelesen, während
    /// `stop()` das Feld nebenher leert – deshalb über das Lock.
    private var systemFramesDelivered: Int {
        stateLock.withLock { systemCapture }?.deliveredFrameCount ?? 0
    }

    private static func deviceName(of capture: (any SystemAudioCapturing)?) -> String {
        (capture as? SystemAudioTap)?.tappedDeviceName ?? "Systemmischung"
    }

    public var currentState: SessionState {
        stateLock.withLock { state }
    }

    public var currentCaptureSettings: AppSettings? {
        stateLock.withLock { activeCaptureSettings }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Der Wächter muss die Absicht sofort festhalten, nicht erst das
        // Ergebnis. Sonst bauen zwei überlappende Aufrufe – etwa `bootstrap()`
        // und die Freigabeprüfung, die beide `autoStartIfReady()` anstoßen –
        // zwei vollständige Aufnahmeketten auf; die erste wird von der zweiten
        // überschrieben, ist danach unerreichbar und hält Sprachmodell-
        // Reservierung und Audio-Engine bis zum Programmende fest.
        let startUpdate = stateLock.withLock { () -> SessionState? in
            guard !state.isRunning, !isStarting, !isStopping, !isResetting else { return nil }
            isStarting = true
            stopRequested = false
            state.isStarting = true
            return state
        }
        guard let startUpdate else { return }
        onState?(startUpdate)

        let setupTask = Task { [self] in
            try await bringUp()
        }
        let cancelSetup = stateLock.withLock { () -> Bool in
            startupTask = setupTask
            return stopRequested && !state.isRunning
        }
        if cancelSetup { setupTask.cancel() }

        do {
            try await setupTask.value
        } catch {
            // Keep the start guard held through cleanup. Releasing it first
            // lets a new start populate the shared capture slots, which this
            // old rollback would then tear down.
            await rollBack()
            let (failedState, wasStopped) = stateLock.withLock { () -> (SessionState, Bool) in
                let wasStopped = stopRequested
                startupTask = nil
                isStarting = false
                stopRequested = false
                state.isStarting = false
                return (state, wasStopped)
            }
            onState?(failedState)
            // Ein Start kann auf halber Strecke scheitern – etwa wenn die
            // Systemton-Erfassung nicht aufgeht, nachdem die Erkenner schon
            // laufen. Ohne Aufräumen bleiben die stehen: `isRunning` wurde nie
            // gesetzt, also steigt `stop()` sofort wieder aus, und jeder weitere
            // Versuch legt einen zusätzlichen Erkenner daneben. Sie halten
            // Sprachmodell-Reservierungen und die Audio-Engine fest.
            if wasStopped && error is CancellationError { return }
            throw error
        }

        // Wer während des Aufbaus gestoppt hat, hat es ernst gemeint. Der
        // Wunsch wird hier eingelöst – vorher lief der Aufbau ungestört zu Ende
        // und die Sitzung stand trotz ausdrücklichem Stopp.
        let completion = stateLock.withLock { () -> (Bool, SessionState) in
            startupTask = nil
            isStarting = false
            let value = stopRequested
            stopRequested = false
            state.isStarting = false
            return (value, state)
        }
        onState?(completion.1)
        if completion.0 { await stop(archive: false) }
    }

    private func bringUp() async throws {
        try Task.checkCancellation()
        let settings = settingsStore.settings

        guard settings.captureSystemAudio || settings.captureMicrophone else {
            throw SessionError.noAudioSourceEnabled
        }

        await pipeline.update(settings: settings)
        try Task.checkCancellation()
        await pipeline.setEmitter { [weak self] event, generation in
            self?.onEvent?(event, generation)
        }

        var gate = SilenceGateOptions()
        gate.enabled = settings.powerSaving

        // Speech models first – without them nothing downstream works.
        if settings.captureSystemAudio {
            let locale = settings.systemLocale
            try await ensureSpeechModel(for: locale) { [weak self] fraction in
                self?.emit(.notice("Sprachmodell wird geladen … \(Int(fraction * 100)) %"))
            }
            let transcriber = SourceTranscriber(source: .system, locale: locale, gate: gate)
            do {
                try await transcriber.start(
                    onEvent: { [weak self] event in self?.handle(event) },
                    onFailure: { [weak self] error in
                        self?.emit(.failure("Systemaudio-Erkennung gestoppt: \(error.localizedDescription)"))
                    }
                )
                try Task.checkCancellation()
            } catch {
                await transcriber.stop()
                await SpeechAssets.release(locale)
                throw error
            }
            stateLock.withLock { systemTranscriber = transcriber }
        }

        if settings.captureMicrophone {
            try Task.checkCancellation()
            let granted = await MicrophoneCapture.requestAccess()
            try Task.checkCancellation()
            if granted {
                let locale = settings.microphoneLocaleValue
                try await ensureSpeechModel(for: locale)
                let transcriber = SourceTranscriber(source: .microphone, locale: locale, gate: gate)
                do {
                    try await transcriber.start(
                        onEvent: { [weak self] event in self?.handle(event) },
                        onFailure: { [weak self] error in
                            self?.emit(.failure("Mikrofon-Erkennung gestoppt: \(error.localizedDescription)"))
                        }
                    )
                    try Task.checkCancellation()
                } catch {
                    await transcriber.stop()
                    await SpeechAssets.release(locale)
                    throw error
                }
                stateLock.withLock { microphoneTranscriber = transcriber }
            } else {
                if settings.captureSystemAudio {
                    emit(.notice("Ohne Mikrofonzugriff wird nur die Gegenseite transkribiert."))
                } else {
                    throw SessionError.microphonePermissionDenied
                }
            }
        }

        // Then the audio taps.
        //
        // Der Erkenner wird bewusst **ins Closure gefasst** statt im Callback
        // aus dem Feld gelesen: der Callback läuft auf dem Audio-Thread, und
        // ein Feldzugriff dort wäre genau der Zugriff, den `stop()` nebenher
        // auf nil setzt. So sieht der Audio-Thread nur noch eine unveränderliche
        // lokale Referenz – schwach gehalten, damit `stop()` weiterhin das
        // letzte Wort hat und die Einspeisung danach ins Leere läuft.
        let (systemSide, microphoneSide) = stateLock.withLock {
            (systemTranscriber, microphoneTranscriber)
        }

        if settings.captureSystemAudio {
            try Task.checkCancellation()
            let capture = makeSystemCapture(settings)
            try capture.start { [weak self, weak systemSide] chunk in
                systemSide?.feed(chunk)
                self?.noteLevel(chunk)
            }
            let name = Self.deviceName(of: capture)
            let installed = stateLock.withLock { () -> Bool in
                guard !Task.isCancelled else { return false }
                systemCapture = capture
                return true
            }
            guard installed else {
                capture.stop()
                throw CancellationError()
            }
            if let screenCapture = capture as? ScreenCaptureAudio {
                try await screenCapture.waitUntilStarted()
                try Task.checkCancellation()
            }
            updateState { $0.systemAudioActive = true; $0.tappedDevice = name }
        }
        if let microphoneSide {
            do {
                try Task.checkCancellation()
                try microphone.start { [weak self, weak microphoneSide] chunk in
                    microphoneSide?.feed(chunk)
                    self?.noteLevel(chunk)
                }
                updateState { $0.microphoneActive = true }
            } catch {
                if settings.captureSystemAudio {
                    emit(.notice(error.localizedDescription))
                } else {
                    throw error
                }
            }
        }

        stateLock.withLock {
            maxSystemPeak = 0
            volatileState.removeAll()
            lastSpeechAt.removeAll()
            lastForcedFinalize.removeAll()
        }
        startTimers()
        if settings.captureSystemAudio { startPermissionWatchdog() }
        updateState { $0.isRunning = true; $0.statusMessage = "Aktiv" }
        stateLock.withLock { activeCaptureSettings = settings }

        Task { [pipeline] in await pipeline.warmUp() }
    }

    private func ensureSpeechModel(
        for locale: Locale,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        do {
            try await SpeechAssets.ensureModel(for: locale, progress: progress)
            try Task.checkCancellation()
        } catch {
            // `ensureModel` may have reserved a locale just before cancellation
            // reached this caller. Release it on every unsuccessful setup path.
            await SpeechAssets.release(locale)
            throw error
        }
    }

    public func stop() async {
        await stop(archive: true)
    }

    /// Räumt einen halb aufgebauten Start ab.
    ///
    /// Bewusst ohne den `isRunning`-Wächter aus `stop()` – genau der greift hier
    /// ja nicht – und ohne Archivierung: es gab noch keine Sitzung, die sich zu
    /// sichern lohnte.
    private func rollBack() async {
        await tearDownCapture()
        updateState {
            $0.isRunning = false
            $0.systemAudioActive = false
            $0.microphoneActive = false
            $0.systemLevel = 0
            $0.microphoneLevel = 0
        }
    }

    private func stop(archive: Bool) async {
        let setupToCancel = stateLock.withLock { () -> Task<Void, Error>? in
            guard isStarting, !state.isRunning else { return nil }
            stopRequested = true
            return startupTask
        }
        setupToCancel?.cancel()

        enum StopDecision { case proceed, wait, done }
        while true {
            let decision = stateLock.withLock { () -> StopDecision in
                // Steht der Aufbau noch, gibt es nichts abzubauen – aber `start()`
                // soll die Sitzung anschließend nicht hochkommen lassen.
                if isStarting { stopRequested = true }
                if isStopping || isResetting { return .wait }
                guard state.isRunning else { return .done }
                isStopping = true
                return .proceed
            }
            switch decision {
            case .proceed: break
            case .done: return
            case .wait:
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    return
                }
                continue
            }
            break
        }

        await tearDownCapture()

        // Direkt awaiten statt über `deliver` zu gehen: das feuert einen
        // losgelösten Task, und das Archiv unten liest den Verlauf womöglich,
        // bevor die letzte halbe Äußerung angekommen ist – sie fehlte dann im
        // gesicherten Protokoll.
        var trailing: [Utterance] = []
        let generation = delivery.currentGeneration
        assemblerQueue.sync {
            if let utterance = systemAssembler.flush() { trailing.append(utterance) }
            if let utterance = microphoneAssembler.flush() { trailing.append(utterance) }
        }
        for utterance in trailing {
            delivery.enqueue(utterance, generation: generation)
        }
        await delivery.drain()

        updateState {
            $0.isRunning = false
            $0.systemAudioActive = false
            $0.microphoneActive = false
            $0.systemLevel = 0
            $0.microphoneLevel = 0
            $0.statusMessage = "Gestoppt"
        }

        let settings = settingsStore.settings
        if archive && settings.storeTranscripts {
            let utterances = await pipeline.transcript()
            let memory = await pipeline.snapshot()
            if let url = SessionArchive.save(
                utterances: utterances,
                memory: memory,
                sourceLanguage: settings.systemAudioLocale
            ) {
                emit(.notice("Protokoll gesichert: \(url.lastPathComponent)"))
            }
        }
        stateLock.withLock { isStopping = false }
    }

    /// Nimmt Erfassung und Erkennung zurück. Die Referenzen werden **erst unter
    /// dem Lock herausgenommen und dann** bedient: solange sie noch im Feld
    /// stehen, könnte ein zweiter Aufruf sie ein zweites Mal stoppen.
    private func tearDownCapture() async {
        stopTimers()
        let (capture, systemSide, microphoneSide) = stateLock.withLock {
            () -> ((any SystemAudioCapturing)?, SourceTranscriber?, SourceTranscriber?) in
            let values = (systemCapture, systemTranscriber, microphoneTranscriber)
            systemCapture = nil
            systemTranscriber = nil
            microphoneTranscriber = nil
            return values
        }
        capture?.stop()
        microphone.stop()
        await systemSide?.stop()
        if let locale = systemSide?.locale { await SpeechAssets.release(locale) }
        await microphoneSide?.stop()
        if let locale = microphoneSide?.locale { await SpeechAssets.release(locale) }
    }

    /// Reißt die Audio-Hardware ohne jedes Warten ab.
    ///
    /// Nur für den Fall, dass das Programm verschwindet, ohne dass der
    /// geordnete Weg über `stop()` zum Zuge kam. Ein Aggregatgerät oder ein
    /// laufender `SCStream` überlebt den Prozess sonst sichtbar – die
    /// Aufnahmeanzeige in der Menüleiste bleibt stehen. Idempotent.
    public func shutdownAudioNow() {
        stopTimers()
        let capture = stateLock.withLock { () -> (any SystemAudioCapturing)? in
            let value = systemCapture
            systemCapture = nil
            return value
        }
        capture?.stop()
        microphone.stop()
    }

    @discardableResult
    public func resetConversation() async -> UInt64 {
        while true {
            let acquired = stateLock.withLock { () -> Bool in
                guard !isStopping, !isResetting else { return false }
                isResetting = true
                return true
            }
            if acquired { break }
            guard !Task.isCancelled else { return delivery.currentGeneration }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return delivery.currentGeneration
            }
        }

        // Generation und Assembler wechseln auf derselben Queue. Dadurch kann
        // ein gerade laufender Idle-Flush nicht versehentlich schon der neuen
        // Generation zugerechnet werden.
        var resetBarrier: Task<Void, Never>!
        assemblerQueue.sync {
            resetBarrier = delivery.advanceGeneration { [pipeline] in
                await pipeline.reset()
            }
            systemAssembler = UtteranceAssembler(source: .system)
            microphoneAssembler = UtteranceAssembler(source: .microphone)
        }
        stateLock.withLock {
            volatileState.removeAll()
            lastSpeechAt.removeAll()
            lastForcedFinalize.removeAll()
        }
        await resetBarrier.value
        stateLock.withLock { isResetting = false }
        return delivery.currentGeneration
    }

    public func applySettings(_ settings: AppSettings) async {
        settingsStore.settings = settings
        await pipeline.update(settings: settings)
    }

    /// Restarts capture so a changed language or audio source takes effect.
    public func restart() async throws {
        // Auch ein noch laufender Aufbau zählt als „war aktiv": ein Sprach- oder
        // Backend-Wechsel in genau diesem Moment ging sonst spurlos verloren.
        let wasActive = stateLock.withLock { state.isRunning || isStarting }
        // A restart is not the end of the conversation – archiving here would
        // write a partial protocol and duplicate it on the real stop.
        await stop(archive: false)
        guard await waitUntilIdle() else {
            if Task.isCancelled { throw CancellationError() }
            throw SessionError.lifecycleTimedOut
        }
        if wasActive {
            guard !Task.isCancelled else { throw CancellationError() }
            try await start()
        }
    }

    /// Wartet, bis ein laufender Aufbau sich selbst abgeräumt hat.
    ///
    /// Ohne das käme der Neustart auf einen noch besetzten `isStarting`-Wächter
    /// und stiege sofort wieder aus – der Nutzer hätte gestoppt bekommen, aber
    /// keinen Neustart. Die Obergrenze ist eine Notbremse, keine Erwartung.
    private func waitUntilIdle(timeout: Double = 180) async -> Bool {
        let deadline = Clock.now() + timeout
        while stateLock.withLock({ isStarting || isStopping || isResetting || state.isRunning }),
              Clock.now() < deadline {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !stateLock.withLock { isStarting || isStopping || isResetting || state.isRunning }
    }

    public func answerNow() async {
        await pipeline.answerLatest()
    }

    /// Beantwortet eine im Transkript angeklickte Äußerung.
    public func answer(utteranceID: UUID) async {
        await pipeline.answer(utteranceID: utteranceID)
    }

    public func answer(question: String, utteranceID: UUID) async {
        await pipeline.answer(question: question, utteranceID: utteranceID)
    }

    // MARK: - Audio → transcription

    /// Buchführung über Pegel und Sprechzeitpunkte. Läuft auf dem Audio-Thread;
    /// die Einspeisung in den Erkenner erledigt das Erfassungs-Closure selbst.
    private func noteLevel(_ chunk: AudioChunk) {
        let speaking = chunk.peak >= Self.speechLevelThreshold
        stateLock.withLock {
            switch chunk.source {
            case .system:
                pendingSystemLevel = max(pendingSystemLevel, chunk.peak)
                maxSystemPeak = max(maxSystemPeak, chunk.peak)
                if speaking { lastSpeechAt[.system] = Clock.now() }
            case .microphone:
                pendingMicrophoneLevel = max(pendingMicrophoneLevel, chunk.peak)
                if speaking { lastSpeechAt[.microphone] = Clock.now() }
            }
        }
    }

    private func handle(_ event: TranscriptEvent) {
        if !event.isFinal {
            emit(.partialTranscript(source: event.source, text: event.text))
            noteVolatile(event)
            return
        }
        stateLock.withLock {
            volatileState[event.source] = nil
        }
        let generation = delivery.currentGeneration
        assemblerQueue.async { [weak self] in
            guard let self, generation == delivery.currentGeneration else { return }
            let produced = event.source == .system
                ? systemAssembler.append(event)
                : microphoneAssembler.append(event)
            for utterance in produced { deliver(utterance, generation: generation) }
        }
    }

    private func deliver(_ utterance: Utterance, generation: UInt64? = nil) {
        delivery.enqueue(utterance, generation: generation ?? delivery.currentGeneration)
    }

    // MARK: - Erzwungene Finalisierung

    /// Remembers the current hypothesis so the idle check can tell whether the
    /// speaker has actually stopped.
    private func noteVolatile(_ event: TranscriptEvent) {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        stateLock.withLock { volatileState[event.source] = text }
    }

    /// Asks the recognizer to finish once the speaker has actually stopped.
    ///
    /// The trigger is the audio, not the text. Text stability was tried first
    /// and measured: a hypothesis stands still between words often enough that
    /// forcing on it chopped one spoken question into three finalised fragments
    /// ("Wie lange dauert eine vollständige" / "Eine neue Indizierung auf" /
    /// "Produktivsystem"). A gap of silence is what actually ends a sentence.
    private func finalizeAfterSpeechPause() {
        let now = Clock.now()
        let snapshot = stateLock.withLock {
            (volatile: volatileState, speech: lastSpeechAt, forced: lastForcedFinalize)
        }

        for (source, text) in snapshot.volatile where !text.isEmpty {
            guard let spokeAt = snapshot.speech[source] else { continue }
            let quietFor = now - spokeAt
            guard quietFor >= Self.speechPauseSeconds else { continue }
            if let last = snapshot.forced[source], now - last < 1.0 { continue }

            // Läuft auf der `assemblerQueue`, während `stop()` die Felder auf
            // der Aufruferseite leert – also unter dem Lock lesen.
            let transcriber = stateLock.withLock { () -> SourceTranscriber? in
                let value = source == .system ? systemTranscriber : microphoneTranscriber
                if value != nil { lastForcedFinalize[source] = now }
                return value
            }
            guard let transcriber else { continue }
            Log.speech.info(
                "Speech pause of \(Int(quietFor * 1000), privacy: .public) ms – finalizing \(source.rawValue, privacy: .public)"
            )
            Task { await transcriber.finalizeNow() }
        }
    }

    /// A pause this long ends a sentence. Shorter, and normal gaps between
    /// words would cut utterances apart; much longer and the wait returns.
    private static let speechPauseSeconds = 0.6
    /// Amplitude above which audio counts as someone speaking (≈ −40 dBFS).
    private static let speechLevelThreshold: Float = 0.01

    // MARK: - Timers

    private func startTimers() {
        let idle = DispatchSource.makeTimerSource(queue: assemblerQueue)
        idle.schedule(deadline: .now() + 0.25, repeating: 0.25)
        idle.setEventHandler { [weak self] in
            guard let self else { return }
            finalizeAfterSpeechPause()
            if let utterance = systemAssembler.flushIfIdle() { deliver(utterance) }
            if let utterance = microphoneAssembler.flushIfIdle() { deliver(utterance) }
        }
        idle.resume()
        idleTimer = idle

        let levels = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        levels.schedule(deadline: .now() + 0.08, repeating: 0.08)
        levels.setEventHandler { [weak self] in
            guard let self else { return }
            let (system, microphone) = stateLock.withLock { () -> (Float, Float) in
                let values = (pendingSystemLevel, pendingMicrophoneLevel)
                // Decay so the meter falls smoothly instead of snapping to zero.
                pendingSystemLevel *= 0.55
                pendingMicrophoneLevel *= 0.55
                return values
            }
            updateState { $0.systemLevel = system; $0.microphoneLevel = microphone }
        }
        levels.resume()
        levelTimer = levels
    }

    /// Ein Tap ohne Berechtigung wirft keinen Fehler – er bleibt einfach stumm.
    /// Statt den Nutzer raten zu lassen, wird das nach wenigen Sekunden gemeldet.
    private func startPermissionWatchdog() {
        permissionWatchdog?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, currentState.isRunning else { return }
            guard systemFramesDelivered == 0 else { return }
            Log.audio.error("No system audio frames after 6 s")
            emit(.audioPermissionNeeded)
        }
        permissionWatchdog = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)

        // Ein TCC-Eintrag mit veralteter Prüfsumme lässt den Stream laufen und
        // liefert trotzdem nur Nullen – von echter Stille aus der Ferne nicht
        // zu unterscheiden. Deshalb nach 30 s ohne jeden Pegel genau EIN
        // Hinweis; kommt später Ton an, räumt die Oberfläche ihn selbst weg
        // (siehe AppModel, utteranceAdded).
        silenceWatchdog?.cancel()
        let silenceItem = DispatchWorkItem { [weak self] in
            guard let self, currentState.isRunning else { return }
            let peak = stateLock.withLock { maxSystemPeak }
            guard peak == 0 else { return }
            Log.audio.error("30 s without any signal level – stale permission or simply nothing playing")
            emit(.audioPermissionNeeded)
        }
        silenceWatchdog = silenceItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: silenceItem)
    }

    private func stopTimers() {
        permissionWatchdog?.cancel()
        permissionWatchdog = nil
        silenceWatchdog?.cancel()
        silenceWatchdog = nil
        idleTimer?.cancel()
        idleTimer = nil
        levelTimer?.cancel()
        levelTimer = nil
    }

    // MARK: - Helpers

    private func updateState(_ mutate: (inout SessionState) -> Void) {
        let updated: SessionState = stateLock.withLock {
            mutate(&state)
            return state
        }
        onState?(updated)
    }

    private func emit(_ event: PipelineEvent) {
        onEvent?(event, delivery.currentGeneration)
    }
}

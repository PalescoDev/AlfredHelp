import Foundation
import Observation
import SwiftUI
import AVFoundation
import AppKit
import AlfredHelpCore

/// Preserves the synchronous callback order while hopping to MainActor. A
/// separate `Task { @MainActor ... }` per event has no FIFO guarantee.
private final class OrderedPipelineEventRelay: @unchecked Sendable {
    typealias Sink = @MainActor @Sendable (PipelineEvent, UInt64) -> Void

    private let lock = NSLock()
    private let sink: Sink
    private var tail: Task<Void, Never>?

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    func enqueue(_ event: PipelineEvent, generation: UInt64) {
        lock.withLock {
            let previous = tail
            let sink = self.sink
            tail = Task { @MainActor in
                await previous?.value
                sink(event, generation)
            }
        }
    }
}

/// A transcript line as the overlay shows it.
struct TranscriptRow: Identifiable, Equatable {
    let id: UUID
    let source: AudioSourceKind
    var original: String
    var german: String?
    var isTranslating: Bool
    let timestamp: Date
}

struct Notice: Identifiable, Equatable {
    enum Kind { case info, problem }
    let id = UUID()
    let kind: Kind
    let text: String
    let date = Date()
}

/// Der für die Oberfläche relevante Lebenszyklus einer Antwort. Die Pipeline
/// bleibt Eigentümerin der eigentlichen Arbeit; dieses kleine Abbild verhindert
/// lediglich, dass Zeilenknöpfe mehrfach ausgelöst werden oder eine laufende
/// Verfeinerung wie ein Stillstand aussieht.
enum AnswerPhase: Sendable, Equatable {
    case generating
    case refining
    case complete
    case failed
}

@MainActor
@Observable
final class AppModel {

    // MARK: Observable state
    var sessionState = SessionState()
    var rows: [TranscriptRow] = []
    var partials: [AudioSourceKind: String] = [:]
    var answers: [AnswerCard] = []
    var answerPhases: [UUID: AnswerPhase] = [:]
    var requestedAnswerIDs: Set<UUID> = []
    var memory = MemorySnapshot()
    var notices: [Notice] = []

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            store.settings = settings
            if oldValue.overlayHiddenFromScreenSharing != settings.overlayHiddenFromScreenSharing {
                WindowPrivacy.apply(hidden: settings.overlayHiddenFromScreenSharing)
            }
            let snapshot = settings
            settingsUpdateTask?.cancel()
            settingsUpdateTask = Task { [weak self] in
                // Ein kurzer Debounce fasst Slider- und Textänderungen zusammen.
                // Der letzte Snapshot gewinnt immer; ältere Tasks schreiben
                // danach keine Einstellungen mehr zurück.
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                let previousApplied = appliedSettings
                await coordinator.applySettings(snapshot)
                guard !Task.isCancelled else { return }
                let captureState = coordinator.currentState
                if captureState.isRunning || captureState.isStarting {
                    if capturesDiffer(previousApplied, snapshot) {
                        scheduleCaptureReconciliation()
                    } else if captureReconciliationTask == nil {
                        appliedSettings = snapshot
                    }
                } else {
                    appliedSettings = snapshot
                }
            }
        }
    }

    /// Changes that only take effect by rebuilding the capture chain.
    private func capturesDiffer(_ lhs: AppSettings, _ rhs: AppSettings) -> Bool {
        lhs.captureSystemAudio != rhs.captureSystemAudio
            || lhs.captureMicrophone != rhs.captureMicrophone
            || (rhs.captureSystemAudio && lhs.systemAudioBackend != rhs.systemAudioBackend)
            || (rhs.captureSystemAudio && lhs.systemAudioLocale != rhs.systemAudioLocale)
            || (rhs.captureMicrophone && lhs.microphoneLocale != rhs.microphoneLocale)
            || lhs.powerSaving != rhs.powerSaving
    }

    var installedModels: [OllamaModel] = []
    var availableLocales: [SpeechAssets.LocaleInfo] = []
    var ollamaReachable = false
    var ollamaVersion = ""
    var isBusy = false
    var isBootstrapping = false
    var overlayVisible = false
    var isStartPending: Bool {
        wantsSessionRunning && !sessionState.isRunning && !sessionState.isStarting
    }
    var pullStatus: String?
    var pullFraction: Double = 0
    /// Läuft gerade die Ersteinrichtung? Trägt den aktuellen Schritt.
    var setupProgress: SetupProgress?
    /// Short status while a model is being loaded into memory.
    var modelStatus: String?
    /// Systemton wurde angefordert, kommt aber nicht an – nur der Nutzer kann
    /// das in den Systemeinstellungen freigeben.
    var needsAudioPermission = false
    var systemAudioPermission: PermissionState = .unknown
    var microphonePermission: PermissionState = .unknown
    var isVerifyingAudio = false
    var isRecoveringModel = false

    /// Rolling median of the answer latency, shown in the header.
    var recentAnswerLatencies: [Int] = []

    private let store: SettingsStore
    let coordinator: SessionCoordinator
    private var overlayController: OverlayWindowController?
    private var onboardingController: OnboardingWindowController?
    private var settingsUpdateTask: Task<Void, Never>?
    /// Once capture reconciliation starts it is never cancelled by a newer
    /// debounce. It loops to the newest snapshot before releasing this slot.
    private var captureReconciliationTask: Task<Void, Never>?
    private var sessionIntentEpoch: UInt64 = 0
    private var wantsSessionRunning = false
    private var eventRelay: OrderedPipelineEventRelay?
    private var appliedSettings: AppSettings
    private var isResettingConversation = false
    private var conversationGeneration: UInt64 = 0
    private var bufferedConversationEvents: [(PipelineEvent, UInt64)] = []
    private let maximumRows = 500

    /// IDs, für die gerade tatsächlich eine Antwort erzeugt oder nach einer
    /// präziseren Frage neu angesetzt wird.
    var pendingAnswerIDs: Set<UUID> {
        requestedAnswerIDs.union(answerPhases.compactMap { id, phase in
            switch phase {
            case .generating, .refining: id
            case .complete, .failed: nil
            }
        })
    }

    init() {
        let store = SettingsStore()
        LegacyMigration.run(into: store)
        self.store = store
        let initialSettings = store.settings
        self.settings = initialSettings
        self.appliedSettings = initialSettings
        self.coordinator = SessionCoordinator(settingsStore: store)

        let relay = OrderedPipelineEventRelay { @MainActor [weak self] event, generation in
            self?.apply(event, generation: generation)
        }
        self.eventRelay = relay
        coordinator.onEvent = { [weak relay] event, generation in
            relay?.enqueue(event, generation: generation)
        }
        coordinator.onState = { [weak self] state in
            Task { @MainActor in self?.sessionState = state }
        }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        isBusy = true
        defer {
            isBusy = false
            isBootstrapping = false
        }

        // Auf einem fremden Mac fehlt in aller Regel alles: Ollama, ein Modell,
        // die Erkennungsdaten. Das wird hier beschafft, bevor irgendetwas
        // anderes geprüft wird – und wer schon alles hat, merkt davon nichts.
        let report = await runDependencySetup()

        ollamaReachable = report.ollamaRunning
        if report.ollamaRunning {
            ollamaVersion = (try? await coordinator.client.version()) ?? ""
            await refreshModels()
            if report.installedOllama {
                push(.info, "Ollama wurde eingerichtet – AlfredHelp ist startklar.")
            }
        } else if OllamaSupervisor.isInstalledAnywhere {
            push(.problem, "Ollama konnte nicht gestartet werden.")
        } else {
            push(.problem, "Ollama ist nicht installiert. Ohne Ollama gibt es keine lokalen Antworten.")
        }
        for problem in report.problems { push(.problem, problem) }

        refreshPermissionStates()

        // ScreenCaptureKit hat eine echte Vorabfrage. Ein Prozess-Tap hat sie
        // nicht; ein Teststart würde deshalb schon beim App-Start den macOS-
        // Dialog auslösen. Den Tap prüft der Nutzer bewusst über „Ton prüfen“.
        if settings.captureSystemAudio,
           settings.systemAudioBackend == .screenCapture {
            if systemAudioPermission == .granted {
                settings.systemAudioVerified = true
                settings.verifiedSystemAudioBackend = .screenCapture
                settings.verifiedCodeHash = await currentCodeHash()
            } else {
                if settings.systemAudioVerified {
                    push(.problem, "Die Freigabe für den Systemton fehlt. Bitte in den Systemeinstellungen erneut erlauben.")
                }
                showOnboarding()
            }
        } else if settings.captureSystemAudio,
                  settings.systemAudioBackend == .processTap {
            // Ein früherer erfolgreicher Test reicht nur für dieselbe
            // Programmsignatur. Ohne passenden Nachweis bleibt der Tap bis zu
            // einer bewussten Prüfung aus, damit der Start keinen Dialog öffnet.
            let codeHash = await currentCodeHash()
            if !codeHash.isEmpty,
               settings.systemAudioVerified,
               settings.verifiedSystemAudioBackend == .processTap,
               settings.verifiedCodeHash == codeHash {
                systemAudioPermission = .granted
            }
        }

        availableLocales = await SpeechAssets.availableLocales()
        if !SpeechAssets.isAvailable {
            push(.problem, "Die lokale Spracherkennung ist auf diesem Mac nicht verfügbar.")
        }

        // Gilt ab jetzt für jedes Fenster der App, auch für später erzeugte.
        WindowPrivacy.apply(hidden: settings.overlayHiddenFromScreenSharing)

        if settings.launchOverlayOnStart { showOverlay() }

        // Everything the user needs is now in place – start listening without
        // making them press anything.
        if settings.autoStartSession { await autoStartIfReady() }
    }

    // MARK: - Ersteinrichtung

    /// Beschafft, was auf diesem Mac fehlt, und spiegelt den Fortschritt in die
    /// Oberfläche.
    ///
    /// Sichtbar ist das aus zwei Gründen und nicht wirklich „im Hintergrund":
    /// Es werden Gigabyte über die Leitung geholt, und der Nutzer soll sehen,
    /// woran es liegt, wenn die App noch nicht antwortet. Klicken muss er
    /// nichts – die Einrichtung läuft von selbst durch.
    private func runDependencySetup() async -> DependencySetup.Report {
        let plan = await makeSetupPlan()

        // Fehlt Ollama, dauert das mehrere Minuten. Dann gehört das Fenster auf
        // den Schirm, sonst sitzt jemand vor einer Menüleiste, die nichts tut.
        if !OllamaSupervisor.isInstalledAnywhere && plan.installsOllama {
            showOnboarding()
        }

        return await DependencySetup.run(client: coordinator.client, plan: plan) { [weak self] progress in
            Task { @MainActor in self?.setupProgress = progress }
        }
    }

    private func makeSetupPlan() async -> DependencySetup.Plan {
        guard settings.installMissingDependencies else {
            return DependencySetup.Plan(installsOllama: false, pullsModel: nil, speechLocales: [])
        }
        // Erkennungsdaten nur für Sprachen, die wirklich fehlen.
        let known = await SpeechAssets.availableLocales()
        let wanted = [settings.systemAudioLocale, settings.microphoneLocale]
        let missing = Set(wanted).filter { identifier in
            guard let entry = known.first(where: { $0.identifier == identifier }) else { return false }
            return !entry.isInstalled
        }
        return DependencySetup.Plan(
            installsOllama: true,
            pullsModel: ModelCatalog.preferredHelper.name,
            speechLocales: wanted.filter { missing.contains($0) }
        )
    }

    /// Erneuter Anlauf, wenn beim ersten etwas schiefging.
    func retryDependencySetup() {
        guard setupProgress == nil else { return }
        Task { await bootstrap() }
    }

    /// True when the app can start on its own: a model is installed and macOS
    /// lets us hear the system.
    var isReadyToListen: Bool {
        ollamaReachable
            && !settings.qualityModel.isEmpty
            && installedModels.contains { $0.name == settings.qualityModel }
            && (settings.captureSystemAudio || settings.captureMicrophone)
            && (!settings.captureSystemAudio || systemAudioIsReady)
    }

    private var systemAudioIsReady: Bool {
        if let granted = SystemAudioPermission.isGranted(backend: settings.systemAudioBackend) {
            return granted
        }
        return systemAudioPermission.isUsable
    }

    private func autoStartIfReady() async {
        guard !sessionState.isRunning else { return }
        guard isReadyToListen else { return }
        await start()
    }

    private func currentCodeHash() async -> String {
        await Task.detached(priority: .utility) {
            SystemAudioPermission.codeHash
        }.value
    }

    func refreshModels() async {
        guard let models = try? await coordinator.client.installedModels() else { return }
        installedModels = models

        // The user picks one model; the small helper follows from it.
        if settings.qualityModel.isEmpty
            || !models.contains(where: { $0.name == settings.qualityModel }) {
            settings.qualityModel = ModelCatalog.autoSelect(from: models).quality
        }
        if !settings.qualityModel.isEmpty {
            settings.fastModel = ModelCatalog.helperModel(
                for: settings.qualityModel, installed: models
            )
        }
    }

    // MARK: - Modellauswahl

    /// The single choice the user makes. Everything else follows: download if
    /// needed, load into memory, and start listening.
    func selectModel(_ name: String) {
        Task {
            let installed = installedModels.contains { $0.name == name }
            if !installed {
                guard await pullAndWait(name) else { return }
            }

            settings.qualityModel = name
            settings.fastModel = ModelCatalog.helperModel(for: name, installed: installedModels)
            await applySettingsImmediately()

            // Ohne kleines Hilfsmodell laufen Übersetzung und Frageerkennung auf
            // dem großen Modell. Das funktioniert, ist aber langsamer – deshalb
            // wird es angeboten, nicht ungefragt heruntergeladen. Wer nur ein
            // Modell auf der Platte haben will, soll auch nur eines bekommen.
            modelStatus = "Modell wird geladen …"
            await coordinator.pipeline.warmUp()
            modelStatus = nil

            if settings.autoStartSession {
                if !sessionState.isRunning && !sessionState.isStarting {
                    await autoStartIfReady()
                }
            }
        }
    }

    /// True, wenn Übersetzung und Frageerkennung mangels kleinem Modell auf
    /// dem großen Antwortmodell mitlaufen.
    var helperIsMissing: Bool {
        !settings.qualityModel.isEmpty
            && settings.fastModel == settings.qualityModel
            && (ModelCatalog.profile(for: settings.qualityModel)?.approximateGigabytes ?? 0) > 4
            && !installedModels.contains { $0.name == ModelCatalog.preferredHelper.name }
    }

    /// Lädt das kleine Hilfsmodell – ausschließlich auf ausdrücklichen Wunsch.
    func installHelperModel() {
        Task {
            guard await pullAndWait(ModelCatalog.preferredHelper.name) else { return }
            settings.fastModel = ModelCatalog.helperModel(
                for: settings.qualityModel, installed: installedModels
            )
            await applySettingsImmediately()
            modelStatus = "Modell wird geladen …"
            await coordinator.pipeline.warmUp()
            modelStatus = nil
        }
    }

    /// Downloads a model and reports progress; returns whether it is ready.
    private func pullAndWait(_ name: String) async -> Bool {
        pullStatus = "Lade \(name) …"
        pullFraction = 0
        do {
            for try await progress in coordinator.client.pull(model: name) {
                pullStatus = "\(name): \(progress.status)"
                pullFraction = progress.fraction
            }
            pullStatus = nil
            await refreshModels()
            return true
        } catch {
            pullStatus = nil
            push(.problem, "Download von \(name) fehlgeschlagen: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Session control

    func toggleSession() {
        Task {
            if wantsSessionRunning || sessionState.isRunning || sessionState.isStarting {
                await stop()
            } else {
                await start()
            }
        }
    }

    /// Öffnet den Bereich, in dem die Audio-Berechtigung erteilt wird.
    func openAudioPrivacySettings() {
        SystemAudioPermission.openSettings(backend: settings.systemAudioBackend)
    }

    func start() async {
        guard !sessionState.isRunning, !sessionState.isStarting, !wantsSessionRunning else { return }
        guard settings.captureSystemAudio || settings.captureMicrophone else {
            push(.problem, "Aktiviere mindestens eine Audioquelle: Systemaudio oder Mikrofon.")
            return
        }
        needsAudioPermission = false

        // Record this intent before the first suspension. A Stop during Ollama
        // recovery must invalidate the in-flight start just like a Stop during
        // audio setup does.
        sessionIntentEpoch &+= 1
        let intent = sessionIntentEpoch
        wantsSessionRunning = true

        if !ollamaReachable {
            let recovered = await recoverOllama()
            guard isCurrentStartIntent(intent) else {
                abandonStartIntent(ifCurrent: intent)
                return
            }
            guard recovered else {
                abandonStartIntent(ifCurrent: intent)
                return
            }
        }
        guard !settings.fastModel.isEmpty, !settings.qualityModel.isEmpty else {
            abandonStartIntent(ifCurrent: intent)
            push(.problem, "Es ist noch kein Modell gewählt. Einstellungen › Modelle – dort ein Antwort- und ein Schnellmodell auswählen.")
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            // A pending debounce must not restart an expensive start that is
            // already using the newest store values.
            settingsUpdateTask?.cancel()
            let snapshot = settings
            await coordinator.applySettings(snapshot)
            guard isCurrentStartIntent(intent) else {
                abandonStartIntent(ifCurrent: intent)
                return
            }
            appliedSettings = snapshot
            try await coordinator.start()
            guard isCurrentStartIntent(intent), coordinator.currentState.isRunning else {
                abandonStartIntent(ifCurrent: intent)
                return
            }
            showOverlay()
        } catch is CancellationError {
            abandonStartIntent(ifCurrent: intent)
        } catch {
            guard isCurrentStartIntent(intent) else {
                abandonStartIntent(ifCurrent: intent)
                return
            }
            wantsSessionRunning = false
            push(.problem, Self.actionable("Das Zuhören ließ sich nicht starten", error))
        }
    }

    private func isCurrentStartIntent(_ intent: UInt64) -> Bool {
        wantsSessionRunning && sessionIntentEpoch == intent && !Task.isCancelled
    }

    private func abandonStartIntent(ifCurrent intent: UInt64) {
        guard sessionIntentEpoch == intent else { return }
        wantsSessionRunning = false
    }

    func stop() async {
        sessionIntentEpoch &+= 1
        wantsSessionRunning = false
        captureReconciliationTask?.cancel()
        await coordinator.stop()
    }

    /// Setzt zuerst die Pipeline-Grenze und leert danach die dazugehörige UI.
    /// Der Coordinator wartet dabei alte Zustellungen ab bzw. verwirft sie
    /// generationsgebunden; nach seiner Rückkehr gehören neue Events sicher
    /// zum neuen Gespräch.
    func clearConversation() {
        guard !isResettingConversation else { return }
        isResettingConversation = true
        bufferedConversationEvents.removeAll()
        rows.removeAll()
        answers.removeAll()
        answerPhases.removeAll()
        requestedAnswerIDs.removeAll()
        partials.removeAll()
        memory = MemorySnapshot()
        recentAnswerLatencies.removeAll()
        Task {
            let generation = await coordinator.resetConversation()
            // Remove only the old generation, then replay any new-generation
            // events that arrived while the reset continuation was suspended.
            rows.removeAll()
            answers.removeAll()
            answerPhases.removeAll()
            requestedAnswerIDs.removeAll()
            partials.removeAll()
            memory = MemorySnapshot()
            recentAnswerLatencies.removeAll()
            conversationGeneration = generation
            let buffered = bufferedConversationEvents
                .filter { $0.1 == generation }
            bufferedConversationEvents.removeAll()
            isResettingConversation = false
            for (event, eventGeneration) in buffered {
                apply(event, generation: eventGeneration)
            }
        }
    }

    /// Kann gerade überhaupt geantwortet werden?
    ///
    /// Ohne laufende Sitzung gibt es keine letzte Äußerung, auf die sich eine
    /// Antwort beziehen könnte, und ohne erreichbares Ollama niemanden, der
    /// sie schreibt.
    var canAnswerNow: Bool {
        sessionState.isRunning && ollamaReachable && !rows.isEmpty && pendingAnswerIDs.isEmpty
    }

    /// Erzwingt eine Antwort auf die letzte Äußerung.
    ///
    /// Geht das gerade nicht, wird das **gesagt**. Vorher passierte sichtbar
    /// nichts: der Knopf im Overlay war im Gegensatz zum Menüpunkt nie
    /// deaktiviert, und das globale Kürzel ⌥⌘A ist ohnehin immer scharf. Wer es
    /// mitten im Gespräch drückt, soll nicht raten müssen, ob die App ihn
    /// gehört hat.
    func answerNow() {
        guard canAnswerNow else {
            if !sessionState.isRunning {
                push(.problem, "AlfredHelp hört gerade nicht zu – mit ⌥⌘L starten.")
            } else if rows.isEmpty {
                push(.info, "Noch nichts gehört – sobald eine Äußerung erkannt wurde, kann AlfredHelp antworten.")
            } else if !pendingAnswerIDs.isEmpty {
                push(.info, "Eine Antwort wird bereits erstellt.")
            } else if !ollamaReachable {
                Task { await recoverOllama() }
            }
            return
        }
        guard let latest = rows.last(where: { $0.source == .system }) ?? rows.last else { return }
        requestAnswer(id: latest.id, question: nil)
    }

    /// Beantwortet die angeklickte Transkriptzeile – der Rettungsanker, wenn
    /// die automatische Erkennung eine Frage übersehen hat.
    func answerUtterance(_ id: UUID) {
        requestAnswer(id: id, question: nil)
    }

    func retryAnswer(_ answer: AnswerCard) {
        requestAnswer(id: answer.id, question: answer.question)
    }

    private func requestAnswer(id: UUID, question: String?) {
        guard pendingAnswerIDs.isEmpty else { return }
        requestedAnswerIDs.insert(id)
        Task {
            if !ollamaReachable, !(await recoverOllama()) {
                requestedAnswerIDs.remove(id)
                return
            }
            if let question {
                await coordinator.answer(question: question, utteranceID: id)
            } else {
                await coordinator.answer(utteranceID: id)
            }
            // Normal success removes this ID in `answerStarted`. If the
            // utterance vanished or the model is not configured, no card can
            // start; release the optimistic lock after the ordered relay had
            // ample time to deliver either event.
            Task {
                try? await Task.sleep(for: .seconds(2))
                // `answerStarted` removes this earlier. If it never arrived,
                // any existing phase belongs to the old card and must not keep
                // the optimistic request lock alive forever.
                requestedAnswerIDs.remove(id)
            }
        }
    }

    func restartCapture() {
        Task { await restartCaptureNow() }
    }

    @discardableResult
    private func restartCaptureNow(reportCancellation: Bool = true) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            try await coordinator.restart()
            return true
        } catch is CancellationError {
            if reportCancellation {
                push(.problem, "Der Neustart der Aufnahme wurde abgebrochen.")
            }
            return false
        } catch {
            push(.problem, Self.actionable("Die Aufnahme ließ sich nicht neu starten", error))
            return false
        }
    }

    /// Rebuilds capture outside the cancellable debounce task. If settings
    /// change again during stop/start, another loop applies the newest capture
    /// snapshot; no intermediate cancellation can strand the session stopped.
    private func scheduleCaptureReconciliation() {
        guard captureReconciliationTask == nil else { return }
        guard wantsSessionRunning else { return }
        let intentEpoch = sessionIntentEpoch
        captureReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer { captureReconciliationTask = nil }

            while true {
                let target = settings
                await coordinator.applySettings(target)
                guard !Task.isCancelled,
                      wantsSessionRunning,
                      sessionIntentEpoch == intentEpoch else { return }
                let succeeded: Bool
                let stopsForMissingSources = !target.captureSystemAudio
                    && !target.captureMicrophone
                if stopsForMissingSources {
                    await coordinator.stop()
                    succeeded = true
                } else if coordinator.currentState.isRunning
                            || coordinator.currentState.isStarting {
                    succeeded = await restartCaptureNow(reportCancellation: false)
                } else {
                    do {
                        try await coordinator.start()
                        succeeded = true
                    } catch is CancellationError {
                        succeeded = false
                    } catch {
                        push(.problem, Self.actionable("Die Aufnahme ließ sich nicht neu starten", error))
                        succeeded = false
                    }
                }
                guard succeeded else { return }
                guard !Task.isCancelled,
                      wantsSessionRunning,
                      sessionIntentEpoch == intentEpoch else {
                    // A newer explicit Start owns the session now; only a
                    // newer Stop intent may tear down what just came up.
                    if !wantsSessionRunning { await coordinator.stop() }
                    return
                }
                if coordinator.currentState.isRunning { showOverlay() }
                // `restart()` reads SettingsStore at bring-up time. If a newer
                // edit arrived during teardown, this tells us which snapshot
                // was actually built and avoids rebuilding it a second time.
                let actuallyApplied = stopsForMissingSources
                    ? target
                    : (coordinator.currentCaptureSettings ?? target)
                appliedSettings = actuallyApplied
                guard capturesDiffer(actuallyApplied, settings) else { return }
            }
        }
    }

    private func applySettingsImmediately() async {
        settingsUpdateTask?.cancel()
        let previousApplied = appliedSettings
        let snapshot = settings
        await coordinator.applySettings(snapshot)
        let captureState = coordinator.currentState
        if captureState.isRunning || captureState.isStarting {
            if capturesDiffer(previousApplied, snapshot) {
                scheduleCaptureReconciliation()
            } else if captureReconciliationTask == nil {
                appliedSettings = snapshot
            }
        } else {
            appliedSettings = snapshot
        }
    }

    // MARK: - Berechtigungen

    func refreshPermissionStates() {
        if let granted = SystemAudioPermission.isGranted(backend: settings.systemAudioBackend) {
            systemAudioPermission = granted ? .granted : (SystemAudioPermission.hasRequested ? .denied : .unknown)
        } else {
            // Core Audio process taps expose no reliable permission preflight.
            systemAudioPermission = .unknown
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphonePermission = .granted
        case .notDetermined: microphonePermission = .unknown
        default: microphonePermission = .denied
        }
    }

    func showOnboarding() {
        if onboardingController == nil {
            onboardingController = OnboardingWindowController(model: self)
        }
        refreshPermissionStates()
        onboardingController?.show()
    }

    func requestSystemAudioPermission() {
        if settings.systemAudioBackend == .screenCapture,
           SystemAudioPermission.hasRequested {
            openAudioPrivacySettings()
            return
        }

        if settings.systemAudioBackend == .processTap {
            verifySystemAudio()
            return
        }

        // Zeigt den macOS-Dialog. Danach ist ein Neustart der Anwendung nötig,
        // weil macOS die Entscheidung erst dem nächsten Prozessstart mitgibt.
        let granted = SystemAudioPermission.request()
        if granted {
            verifySystemAudio()
        } else {
            systemAudioPermission = .denied
            push(.info, "Bitte „AlfredHelp“ in den Systemeinstellungen aktivieren und die App neu starten.")
        }
    }

    func requestMicrophonePermission() {
        Task {
            _ = await MicrophoneCapture.requestAccess()
            refreshPermissionStates()
        }
    }

    /// Prüft, ob die Aufnahme läuft.
    ///
    /// Ausschlaggebend ist, dass überhaupt Puffer ankommen – nicht, ob gerade
    /// jemand spricht. Wer die Freigabe in einem stillen Moment erteilt, soll
    /// nicht vor einem gesperrten „Fertig“-Knopf sitzen und raten, was fehlt.
    /// Der Pegel wird zusätzlich gemeldet, wenn zufällig Ton lief.
    func verifySystemAudio() {
        guard !isVerifyingAudio else { return }
        isVerifyingAudio = true
        Task {
            let result = await SystemAudioPermission.check(backend: settings.systemAudioBackend, timeout: 4)
            isVerifyingAudio = false

            switch result {
            case .working(let peak):
                systemAudioPermission = .working(peak: peak)
                needsAudioPermission = false
                settings.systemAudioVerified = true
                settings.verifiedSystemAudioBackend = settings.systemAudioBackend
                settings.verifiedCodeHash = await currentCodeHash()
                if settings.autoStartSession { await autoStartIfReady() }

            case .silent:
                if SystemAudioPermission.isGranted(backend: settings.systemAudioBackend) == true {
                    // Vorabfrage bestätigt; nur ein hörbares Signal fehlt.
                    systemAudioPermission = .granted
                    needsAudioPermission = false
                    settings.systemAudioVerified = true
                    settings.verifiedSystemAudioBackend = settings.systemAudioBackend
                    settings.verifiedCodeHash = await currentCodeHash()
                    if settings.autoStartSession { await autoStartIfReady() }
                } else {
                    systemAudioPermission = .silent
                    needsAudioPermission = settings.systemAudioBackend == .processTap
                    push(.info, "Kein Systemton erkannt. Spiele Ton ab und prüfe erneut.")
                }

            case .denied:
                systemAudioPermission = .denied
                needsAudioPermission = true
                push(.problem, "Die Freigabe für Systemaudio fehlt. Bitte in den Systemeinstellungen erlauben.")

            case .undetermined:
                systemAudioPermission = .unknown
                needsAudioPermission = settings.systemAudioBackend == .processTap
                push(.info, "Die Freigabe lässt sich noch nicht bestätigen. Spiele Systemton ab und prüfe erneut.")
            }
        }
    }

    // MARK: - Overlay

    func showOverlay() {
        if overlayController == nil {
            overlayController = OverlayWindowController(model: self)
        }
        overlayController?.show()
        overlayVisible = true
    }

    func hideOverlay() {
        overlayController?.hide()
        overlayVisible = false
    }

    func toggleOverlay() {
        overlayVisible ? hideOverlay() : showOverlay()
    }

    func applyOverlayPreferences() {
        overlayController?.applyPreferences()
        WindowPrivacy.apply(hidden: settings.overlayHiddenFromScreenSharing)
    }

    // MARK: - Models

    func pull(model name: String) {
        Task {
            pullStatus = "Lade \(name) …"
            pullFraction = 0
            do {
                for try await progress in coordinator.client.pull(model: name) {
                    pullStatus = "\(name): \(progress.status)"
                    pullFraction = progress.fraction
                }
                pullStatus = nil
                await refreshModels()
                push(.info, "\(name) ist bereit.")
            } catch {
                pullStatus = nil
                push(.problem, Self.actionable("\(name) ließ sich nicht laden", error))
            }
        }
    }

    // MARK: - Export

    func transcriptMarkdown() -> String {
        var lines = ["# Gesprächsprotokoll", "", "_\(Branding.signature)_", ""]
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        for row in rows {
            let time = formatter.string(from: row.timestamp)
            lines.append("**\(time) · \(row.source.speakerLabel)**")
            if let german = row.german, german != row.original {
                lines.append(german)
                lines.append("<sub>\(row.original)</sub>")
            } else {
                lines.append(row.original)
            }
            lines.append("")
        }
        if !answers.isEmpty {
            lines.append("## Antwortvorschläge")
            lines.append("")
            for answer in answers.reversed() {
                lines.append("**\(answer.question)**")
                lines.append("")
                lines.append(answer.text)
                lines.append("")
            }
        }
        lines.append("")
        lines.append("---")
        lines.append("_Erstellt mit \(Branding.signature) – vollständig lokal._")
        return lines.joined(separator: "\n")
    }

    // MARK: - Events

    private func apply(_ event: PipelineEvent, generation: UInt64) {
        switch event {
        case .partialTranscript, .utteranceAdded, .translation, .answerStarted,
             .answerDelta, .answerQuestionRefined, .answerFinished,
             .answerDiscarded, .memory:
            if isResettingConversation {
                bufferedConversationEvents.append((event, generation))
                return
            }
            guard generation == conversationGeneration else { return }
        case .notice, .failure, .audioPermissionNeeded:
            break
        }
        switch event {
        case .partialTranscript(let source, let text):
            partials[source] = text

        case .utteranceAdded(let utterance):
            // Es kommt Text an – die Aufnahmekette funktioniert also. Ein noch
            // stehendes Berechtigungs-Banner (etwa vom Stille-Wächter, der in
            // einem ruhigen Meeting angeschlagen hat) wäre ab jetzt falsch.
            if utterance.source == .system {
                needsAudioPermission = false
                systemAudioPermission = .granted
                if !settings.systemAudioVerified
                    || settings.verifiedSystemAudioBackend != settings.systemAudioBackend
                    || settings.verifiedCodeHash.isEmpty {
                    settings.systemAudioVerified = true
                    settings.verifiedSystemAudioBackend = settings.systemAudioBackend
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.settings.verifiedCodeHash = await self.currentCodeHash()
                    }
                }
            }
            partials[utterance.source] = ""
            rows.append(TranscriptRow(
                id: utterance.id,
                source: utterance.source,
                original: utterance.original,
                german: utterance.german,
                isTranslating: utterance.german == nil && settings.translationEnabled
                    && !settings.systemAudioIsGerman,
                timestamp: utterance.createdAt
            ))
            if rows.count > maximumRows { rows.removeFirst(rows.count - maximumRows) }

        case .translation(let id, let german, let isFinal):
            guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
            rows[index].german = german
            rows[index].isTranslating = !isFinal

        case .answerStarted(let card):
            requestedAnswerIDs.remove(card.id)
            answers.removeAll { $0.id == card.id }
            answers.insert(card, at: 0)
            answerPhases[card.id] = .generating
            if answers.count > 40 {
                let removedIDs = answers.suffix(from: 40).map(\.id)
                answers.removeLast(answers.count - 40)
                for id in removedIDs { answerPhases.removeValue(forKey: id) }
            }

        case .answerQuestionRefined(let id, let question):
            guard let index = answers.firstIndex(where: { $0.id == id }), !question.isEmpty else { return }
            answerPhases[id] = .refining
            answers[index].question = question
            // The visible text belonged to the speculative wording. The
            // pipeline restarts generation for the refined question, so keep
            // no stale answer underneath the new heading.
            answers[index].text = ""
            answers[index].details = ""
            answers[index].confidence = .low
            answers[index].missingContext = []

        case .answerDelta(let id, let text, let details):
            guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
            answerPhases[id] = .generating
            if !text.isEmpty { answers[index].text = text }
            answers[index].details = details

        case .answerDiscarded(let id):
            answers.removeAll { $0.id == id }
            answerPhases.removeValue(forKey: id)

        case .answerFinished(let card):
            guard let index = answers.firstIndex(where: { $0.id == card.id }) else { return }
            answers[index] = card
            answerPhases[card.id] = card.errorMessage == nil ? .complete : .failed
            if let latency = card.timeToFirstWordMilliseconds {
                recentAnswerLatencies.append(latency)
                if recentAnswerLatencies.count > 20 { recentAnswerLatencies.removeFirst() }
            }
            announceForAccessibility(
                card.errorMessage == nil ? "Neue Antwort verfügbar." : "Antwort fehlgeschlagen."
            )

        case .memory(let snapshot):
            memory = snapshot

        case .audioPermissionNeeded:
            // Ein stummer Ausgang liefert dieselben Nullpuffer wie eine
            // entzogene Freigabe. Das ist aber kein Berechtigungsproblem, also
            // wird auch nicht die Einrichtung aufgerissen.
            if let reason = OutputVolume.current.explanation {
                needsAudioPermission = false
                push(.info, "Kein Systemton: \(reason)")
            } else {
                let preflight = SystemAudioPermission.isGranted(backend: settings.systemAudioBackend)
                if preflight == false {
                    needsAudioPermission = true
                    systemAudioPermission = SystemAudioPermission.hasRequested ? .denied : .unknown
                    push(.problem, "Kein Systemton – Freigabe für Systemaudioaufnahme prüfen.")
                } else {
                    // nil bedeutet: Core Audio kann eine verweigerte Freigabe
                    // nicht von einem stillen Ausgang unterscheiden.
                    needsAudioPermission = preflight == nil
                    systemAudioPermission = preflight == nil ? .unknown : .silent
                    push(.info, "Kein Systemton erkannt. Spiele Ton ab oder prüfe die Freigabe in den Systemeinstellungen.")
                }
            }

        case .notice(let text):
            push(.info, text)

        case .failure(let text):
            push(.problem, text)
        }
    }

    /// Setzt eine Systemmeldung in einen Satz, der sagt, **was** nicht ging.
    ///
    /// `error.localizedDescription` allein ist eine Systemformulierung: sie
    /// beschreibt den technischen Zustand, nennt aber weder den Vorgang, an dem
    /// es lag, noch einen nächsten Schritt. Wer mitten in einer Besprechung
    /// „The operation couldn’t be completed" liest, weiß danach genauso viel
    /// wie davor.
    private static func actionable(_ what: String, _ error: Error) -> String {
        let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fehler aus dem eigenen Code tragen ihren Rat schon in sich – die
        // Audio-Fehler etwa nennen den Bereich in den Systemeinstellungen
        // beim Namen. Solche Texte werden nicht verwässert.
        if error is LocalizedError, !detail.isEmpty {
            return "\(what): \(detail)"
        }
        return "\(what): \(detail) – erneut versuchen; bleibt es dabei, hilft ein Neustart von AlfredHelp."
    }

    /// Versucht, den lokalen Dienst selbst wieder ans Laufen zu bringen.
    ///
    /// Vorher stand hier „Ollama ist nicht erreichbar – bitte zuerst starten."
    /// Das widersprach der eigenen Zusage in den Einstellungen, dass AlfredHelp
    /// Ollama selbst startet – und verlangte vom Nutzer eine Handlung, für die
    /// es mit `OllamaSupervisor.ensureRunning` längst einen Weg gibt. Jetzt
    /// wird der Weg gegangen, statt ihn zu verlangen.
    @discardableResult
    private func recoverOllama() async -> Bool {
        isRecoveringModel = true
        defer { isRecoveringModel = false }
        push(.info, "Ollama antwortet nicht – wird gestartet …")
        let running = await OllamaSupervisor.ensureRunning(
            client: coordinator.client, timeout: .seconds(15)
        )
        ollamaReachable = running
        guard running else {
            push(.problem, OllamaSupervisor.isInstalledAnywhere
                 ? "Ollama ließ sich nicht starten. Einstellungen › Modelle › „Erneut prüfen“ – hilft das nicht, Ollama einmal von Hand beenden und neu öffnen."
                 : "Ollama fehlt auf diesem Mac. Einstellungen › Modelle › „Erneut prüfen“ holt es nach.")
            return false
        }
        ollamaVersion = (try? await coordinator.client.version()) ?? ""
        await refreshModels()
        notices.removeAll {
            $0.kind == .problem
                && ($0.text.localizedCaseInsensitiveContains("Ollama")
                    || $0.text.localizedCaseInsensitiveContains("Antwortmodell"))
        }
        push(.info, "Ollama läuft wieder.")
        return true
    }

    private func push(_ kind: Notice.Kind, _ text: String) {
        notices.append(Notice(kind: kind, text: text))
        if kind == .problem { announceForAccessibility(text, priority: .high) }
        // Nur flüchtige Hinweise begrenzen. Probleme dürfen weder durch einen
        // Timer noch durch nachfolgende Meldungen aus der Liste gedrängt werden.
        let infoIDs = notices.filter { $0.kind == .info }.map(\.id)
        if infoIDs.count > 6 {
            let obsolete = Set(infoIDs.dropLast(6))
            notices.removeAll { obsolete.contains($0.id) }
        }
        // Probleme bleiben stehen, bis der Nutzer sie schließt oder die
        // zugrunde liegende Aktion erneut versucht. Ein Fehler, der nach zwölf
        // Sekunden verschwindet, wirkt fälschlich wie eine Selbstheilung.
        guard kind == .info else { return }
        let notice = notices.last!
        Task {
            try? await Task.sleep(for: .seconds(6))
            notices.removeAll { $0.id == notice.id }
        }
    }

    func dismissNotice(id: UUID) {
        notices.removeAll { $0.id == id }
    }

    func retryModelConnection() {
        guard !isRecoveringModel else { return }
        isRecoveringModel = true
        Task { await recoverOllama() }
    }

    private func announceForAccessibility(
        _ message: String,
        priority: NSAccessibilityPriorityLevel = .medium
    ) {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue
            ]
        )
    }

    var medianAnswerLatency: Int? {
        guard !recentAnswerLatencies.isEmpty else { return nil }
        let sorted = recentAnswerLatencies.sorted()
        return sorted[sorted.count / 2]
    }
}

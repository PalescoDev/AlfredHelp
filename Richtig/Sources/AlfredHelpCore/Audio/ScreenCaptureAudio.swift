import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Accelerate

/// Begrenzt den asynchronen Start auf eine bestätigte Antwort von ScreenCaptureKit.
/// Mehrere gleichzeitige Aufrufer erhalten dasselbe Ergebnis; nur die erste
/// Auflösung entscheidet.
final class ScreenCaptureStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var timeoutTask: Task<Void, Never>?

    init(timeout: Duration = .seconds(20)) {
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.resolve(.failure(TimeoutError()))
            } catch is CancellationError {
                // Das Gate wurde vorher aufgelöst.
            } catch {
                self?.resolve(.failure(error))
            }
        }
    }

    @discardableResult
    func resolve(_ result: Result<Void, Error>) -> Bool {
        let (accepted, waiters, timeout) = lock.withLock {
            () -> (Bool, [CheckedContinuation<Void, Error>], Task<Void, Never>?) in
            guard outcome == nil else { return (false, [], nil) }
            outcome = result
            let pending = Array(waiters.values)
            waiters.removeAll()
            let timer = timeoutTask
            timeoutTask = nil
            return (true, pending, timer)
        }
        guard accepted else { return false }
        timeout?.cancel()
        for waiter in waiters { waiter.resume(with: result) }
        return true
    }

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let completed = lock.withLock { () -> Result<Void, Error>? in
                    if let outcome { return outcome }
                    guard !Task.isCancelled else { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let completed { continuation.resume(with: completed) }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(throwing: CancellationError())
    }

    private struct TimeoutError: LocalizedError {
        var errorDescription: String? {
            "ScreenCaptureKit hat den Aufnahmestart nicht rechtzeitig bestätigt."
        }
    }
}

/// Captures everything the Mac plays back through ScreenCaptureKit.
///
/// ## Why this and not the Core Audio process tap
///
/// The process tap is leaner on paper, but it depends on an aggregate device
/// that binds the current output device. Measured on this machine
/// (`--audio-diagnose`, eight configurations, reproducible across runs): every
/// aggregate containing the USB output device refuses to start, and every
/// tap-only aggregate starts but delivers pure silence. ScreenCaptureKit taps
/// the system mix itself — it never touches the output device, so a USB DAC, a
/// DisplayPort monitor or a virtual driver like "Microsoft Teams Audio" makes no
/// difference to it.
///
/// The video side is reduced to the bare minimum the API allows (2×2 pixels at
/// one frame every two seconds) and those frames are never read.
public final class ScreenCaptureAudio: NSObject, SystemAudioCapturing, @unchecked Sendable {

    enum RecoveryPolicy {
        enum Decision: Equatable {
            case deferFailure
            case scheduleAttempt(Int)
            case exhausted
        }

        static let maximumAttempts = 2
        static let stabilityWindowSeconds = 30.0
        static let maximumBufferGapSeconds = 2.0

        struct AudioStability: Equatable {
            private(set) var stableSince: Double?
            private(set) var lastBufferAt: Double?

            mutating func recordValidBuffer(at timestamp: Double) -> Bool {
                if let lastBufferAt,
                   timestamp - lastBufferAt > RecoveryPolicy.maximumBufferGapSeconds {
                    stableSince = timestamp
                } else if stableSince == nil {
                    stableSince = timestamp
                }
                lastBufferAt = timestamp

                guard let stableSince,
                      timestamp - stableSince >= RecoveryPolicy.stabilityWindowSeconds else {
                    return false
                }
                self.stableSince = timestamp
                return true
            }

            mutating func reset() {
                stableSince = nil
                lastBufferAt = nil
            }
        }

        static func decision(recoveryInProgress: Bool, attempts: Int) -> Decision {
            if recoveryInProgress { return .deferFailure }
            guard let attempt = nextAttempt(after: attempts) else { return .exhausted }
            return .scheduleAttempt(attempt)
        }

        static func nextAttempt(after current: Int) -> Int? {
            let next = current + 1
            return next <= maximumAttempts ? next : nil
        }
    }

    public let source: AudioSourceKind = .system

    private let sampleQueue = DispatchQueue(label: "de.alfredhelp.sck.samples", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var startingStream: SCStream?
    private var pendingStartGate: ScreenCaptureStartGate?
    private var streamStartRequest: (gate: ScreenCaptureStartGate, task: Task<Void, Never>)?
    private var handler: (@Sendable (AudioChunk) -> Void)?
    private var monoFormat: AVAudioFormat?
    private var deliveredFrames = 0
    private var callbackCount = 0
    private var bufferReports: [String] = []
    /// Nach den ersten drei Berichten nie wieder true.
    private var reportsRemaining = true
    /// Zählt jeden Start hoch. Ein Stream, dessen Generation nicht mehr die
    /// aktuelle ist, gehört zu einem `start()`, das inzwischen überholt wurde.
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryToken: UUID?
    private var recoveryAttempts = 0
    private var audioStability = RecoveryPolicy.AudioStability()
    /// Preserves a stop signal received while a recovery task is bringing up
    /// its replacement stream. The active token must not make that failure vanish.
    private var pendingRecoveryError: Error?

    /// The rate we ask ScreenCaptureKit for. It honours 48 kHz on every Mac.
    private let sampleRate = 48_000

    public var onStatusChange: (@Sendable (String) -> Void)?
    /// Fatal asynchronous capture errors must also end the owning session.
    var onCaptureFailure: (@Sendable (String) -> Void)?

    public override init() {
        super.init()
    }

    public var captureFormat: AVAudioFormat? {
        lock.withLock { monoFormat }
    }

    public struct Diagnostics: Sendable {
        public var callbacks: Int
        public var deliveredFrames: Int
        public var sampleRate: Double
        public var isStreaming: Bool
        /// Rohbeschreibung der ersten Pufferlisten – zeigt, ob die Daten
        /// tatsächlich Nullen sind oder nur falsch gelesen werden.
        public var bufferReports: [String]
    }

    public var deliveredFrameCount: Int {
        lock.withLock { deliveredFrames }
    }

    public var diagnostics: Diagnostics {
        lock.withLock {
            Diagnostics(
                callbacks: callbackCount,
                deliveredFrames: deliveredFrames,
                sampleRate: monoFormat?.sampleRate ?? 0,
                isStreaming: stream != nil,
                bufferReports: bufferReports
            )
        }
    }

    /// Whether macOS has granted screen recording access. ScreenCaptureKit
    /// reports this by refusing to hand out shareable content.
    public static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            return true
        } catch {
            return false
        }
    }

    /// Triggers the macOS permission prompt if access was never decided.
    /// Returns whether access is granted afterwards.
    @discardableResult
    public static func requestPermission() async -> Bool {
        // Route through the shared gate to avoid asking macOS more than once.
        let granted = SystemAudioPermission.request()
        if granted { return true }
        return await hasPermission()
    }

    // MARK: - AudioCapturing

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        let gate = ScreenCaptureStartGate()
        let previous = lock.withLock {
            () -> (
                Int, ScreenCaptureStartGate?, SCStream?, SCStream?, Task<Void, Never>?,
                Task<Void, Never>?, Task<Void, Never>?
            ) in
            let previous = (
                generation + 1,
                pendingStartGate,
                stream,
                startingStream,
                streamStartRequest?.task,
                startTask,
                recoveryTask
            )
            handler = onChunk
            deliveredFrames = 0
            callbackCount = 0
            recoveryAttempts = 0
            audioStability.reset()
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryToken = nil
            pendingRecoveryError = nil
            generation += 1
            stream = nil
            startingStream = nil
            pendingStartGate = gate
            streamStartRequest = nil
            startTask = nil
            return previous
        }
        let (mine, oldGate, oldStream, oldStartingStream, oldRequest, oldStartTask, oldRecoveryTask) = previous
        oldGate?.resolve(.failure(CancellationError()))
        oldRequest?.cancel()
        oldStartTask?.cancel()
        oldRecoveryTask?.cancel()
        if let oldStream { SCStreamStopHandle(oldStream).stopLater() }
        if let oldStartingStream, oldStartingStream !== oldStream {
            SCStreamStopHandle(oldStartingStream).stopLater()
        }
        // SCStream setup is async; the protocol is not. Kick it off and report
        // problems through `onStatusChange`.
        let task = Task { [weak self] in
            do {
                try await self?.startStream(generation: mine, gate: gate)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.isCurrent(generation: mine) else { return }
                self.failCapture(generation: mine, error: error)
            }
        }
        let accepted = lock.withLock { () -> Bool in
            guard generation == mine, pendingStartGate === gate else { return false }
            startTask = task
            return true
        }
        if !accepted { task.cancel() }
    }

    /// Wartet auf die bestätigte Bereitschaft des aktuellen ScreenCaptureKit-Streams.
    func waitUntilStarted() async throws {
        let (gate, active, mine) = lock.withLock {
            (pendingStartGate, stream != nil, generation)
        }
        if active { return }
        guard let gate else { throw CancellationError() }
        do {
            try await gate.wait()
        } catch {
            if !(error is CancellationError) {
                failCapture(generation: mine, error: error)
            }
            throw error
        }
    }

    private func startStream(generation mine: Int, gate: ScreenCaptureStartGate) async throws {
        try Task.checkCancellation()
        guard isCurrent(generation: mine), isPending(gate: gate) else { throw CancellationError() }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        try Task.checkCancellation()
        guard isCurrent(generation: mine), isPending(gate: gate) else { throw CancellationError() }
        guard let display = content.displays.first else {
            throw AudioCaptureError.microphoneUnavailable("kein Bildschirm gefunden")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = sampleRate
        configuration.channelCount = 2
        // Never record our own output – the assistant must not hear itself.
        configuration.excludesCurrentProcessAudio = true
        // The video path cannot be switched off, so make it as cheap as the API
        // allows. These frames are never read.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // Ein Stream ohne abgenommenen Bildschirm-Output liefert auf manchen
        // macOS-Versionen keinen Ton. Die Frames werden verworfen, sie sind hier
        // nur der Preis dafür, dass die Audiospur überhaupt läuft.
        try newStream.addStreamOutput(
            self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "de.alfredhelp.sck.screen")
        )
        let accepted = lock.withLock { () -> Bool in
            guard generation == mine, pendingStartGate === gate else { return false }
            startingStream = newStream
            return true
        }
        guard accepted else { throw CancellationError() }

        let startHandle = SCStreamStartHandle(newStream)
        let request = Task { [weak self, gate, startHandle] in
            do {
                // Dieser Abschluss bestätigt den erfolgreichen Start durch SCK.
                try await startHandle.start()
                guard let self else {
                    gate.resolve(.failure(CancellationError()))
                    return
                }
                self.confirmStart(startHandle.stream, generation: mine, gate: gate)
            } catch {
                gate.resolve(.failure(error))
            }
        }
        let requestAccepted = lock.withLock { () -> Bool in
            guard generation == mine, startingStream === newStream, pendingStartGate === gate else {
                return false
            }
            streamStartRequest = (gate, request)
            return true
        }
        guard requestAccepted else {
            request.cancel()
            throw CancellationError()
        }

        do {
            try await gate.wait()
            lock.withLock {
                if streamStartRequest?.gate === gate { streamStartRequest = nil }
            }
        } catch {
            let (orphanedStream, request) = lock.withLock {
                () -> (SCStream?, Task<Void, Never>?) in
                guard generation == mine, pendingStartGate === gate else { return (nil, nil) }
                _ = gate.resolve(.failure(error))
                let stream = startingStream
                startingStream = nil
                let request = streamStartRequest?.gate === gate ? streamStartRequest?.task : nil
                if streamStartRequest?.gate === gate { streamStartRequest = nil }
                return (stream, request)
            }
            request?.cancel()
            if let orphanedStream { SCStreamStopHandle(orphanedStream).stopLater() }
            gate.resolve(.failure(error))
            throw error
        }
    }

    private func confirmStart(_ newStream: SCStream, generation mine: Int, gate: ScreenCaptureStartGate) {
        let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        )
        let accepted = lock.withLock { () -> Bool in
            guard generation == mine,
                  startingStream === newStream,
                  pendingStartGate === gate,
                  handler != nil,
                  gate.resolve(.success(())) else { return false }
            startingStream = nil
            stream = newStream
            monoFormat = mono
            pendingStartGate = nil
            audioStability.reset()
            return true
        }
        if !accepted {
            gate.resolve(.failure(CancellationError()))
            SCStreamStopHandle(newStream).stopLater()
        } else {
            Log.audio.info("SCStream capturing system audio at \(self.sampleRate, privacy: .public) Hz")
        }
    }

    private func isPending(gate: ScreenCaptureStartGate) -> Bool {
        lock.withLock { pendingStartGate === gate }
    }

    /// Jeder Wiederherstellungsversuch erhält dasselbe begrenzte Startprotokoll
    /// wie der erste Aufruf. Die laufende Sitzung wartet hier nicht erneut.
    private func startStream(generation mine: Int) async throws {
        let gate = ScreenCaptureStartGate()
        let accepted = lock.withLock { () -> Bool in
            guard generation == mine, handler != nil, pendingStartGate == nil else { return false }
            pendingStartGate = gate
            return true
        }
        guard accepted else { throw CancellationError() }
        do {
            try await startStream(generation: mine, gate: gate)
        } catch {
            lock.withLock {
                if pendingStartGate === gate { pendingStartGate = nil }
            }
            gate.resolve(.failure(error))
            throw error
        }
    }

    public func stop() {
        let (current, starting, gate, startRequest, pending, recovery) = lock.withLock {
            () -> (
                SCStream?, SCStream?, ScreenCaptureStartGate?, Task<Void, Never>?,
                Task<Void, Never>?, Task<Void, Never>?
            ) in
            let value = stream
            let inProgress = startingStream
            let gate = pendingStartGate
            let request = streamStartRequest?.task
            let task = startTask
            let pendingRecovery = recoveryTask
            stream = nil
            startingStream = nil
            pendingStartGate = nil
            streamStartRequest = nil
            handler = nil
            monoFormat = nil
            startTask = nil
            recoveryTask = nil
            recoveryToken = nil
            recoveryAttempts = 0
            audioStability.reset()
            pendingRecoveryError = nil
            // Hochzählen entwertet jeden noch laufenden Aufbau.
            generation += 1
            return (value, inProgress, gate, request, task, pendingRecovery)
        }
        gate?.resolve(.failure(CancellationError()))
        startRequest?.cancel()
        pending?.cancel()
        recovery?.cancel()
        if let current {
            let stopHandle = SCStreamStopHandle(current)
            Task { await stopHandle.stop() }
        }
        if let starting, starting !== current {
            let stopHandle = SCStreamStopHandle(starting)
            Task { await stopHandle.stop() }
        }
    }

    private func isCurrent(generation expected: Int) -> Bool {
        lock.withLock { generation == expected && handler != nil }
    }

    private func failCapture(generation mine: Int, error: Error) {
        let stopped = lock.withLock {
            () -> (SCStream?, SCStream?, ScreenCaptureStartGate?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard generation == mine, handler != nil else { return nil }
            let stopped = (stream, startingStream)
            let gate = pendingStartGate
            let request = streamStartRequest?.task
            let setup = startTask
            stream = nil
            startingStream = nil
            streamStartRequest = nil
            handler = nil
            monoFormat = nil
            startTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryToken = nil
            pendingRecoveryError = nil
            audioStability.reset()
            generation += 1
            return (stopped.0, stopped.1, gate, request, setup)
        }
        guard let (current, starting, gate, request, setup) = stopped else { return }
        gate?.resolve(.failure(error))
        request?.cancel()
        setup?.cancel()
        if let current {
            let stopHandle = SCStreamStopHandle(current)
            Task { await stopHandle.stop() }
        }
        if let starting, starting !== current {
            let stopHandle = SCStreamStopHandle(starting)
            Task { await stopHandle.stop() }
        }
        let message = "Systemton-Erfassung wurde beendet. Bitte Sitzung neu starten. "
            + Self.describe(error)
        onStatusChange?(message)
        onCaptureFailure?(message)
        Log.audio.error("SCStream capture failed: \(String(describing: error), privacy: .public)")
    }

    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain {
            switch nsError.code {
            case -3801: // userDeclined
                return "Kein Zugriff auf den Systemton. Bitte „AlfredHelp“ in den "
                    + "Systemeinstellungen unter „Datenschutz & Sicherheit › "
                    + "Bildschirm- & Systemaudioaufnahme“ aktivieren."
            default:
                return "Systemton konnte nicht erfasst werden (Fehler \(nsError.code))."
            }
        }
        return error.localizedDescription
    }
}

/// `SCStream` is not declared `Sendable`, while the asynchronous stop must run
/// independently of this synchronous protocol method. This handle confines
/// the unchecked transfer to the one operation used to stop a retained stream.
private final class SCStreamStopHandle: @unchecked Sendable {
    private let stream: SCStream

    init(_ stream: SCStream) {
        self.stream = stream
    }

    func stop() async {
        try? await stream.stopCapture()
    }

    func stopLater() {
        Task { await stop() }
    }
}

/// Confines the unchecked transfer required to call SCStream's async start API
/// from the independent request task.
private final class SCStreamStartHandle: @unchecked Sendable {
    let stream: SCStream

    init(_ stream: SCStream) {
        self.stream = stream
    }

    func start() async throws {
        try await stream.startCapture()
    }
}

// MARK: - Sample handling

extension ScreenCaptureAudio: SCStreamOutput {

    public func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let (format, callback, wantsReport) = lock.withLock {
            () -> (AVAudioFormat?, (@Sendable (AudioChunk) -> Void)?, Bool) in
            guard self.stream === stream else { return (nil, nil, false) }
            callbackCount += 1
            return (monoFormat, handler, reportsRemaining)
        }
        guard let format, let callback else { return }

        // ScreenCaptureKit hands over deinterleaved float32, one buffer per channel.
        let mixed: AVAudioPCMBuffer?? = try? sampleBuffer.withAudioBufferList(
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            body: { list, _ -> AVAudioPCMBuffer? in
                mixdown(list, into: format, report: wantsReport)
            }
        )
        guard let output = mixed ?? nil else { return }

        lock.withLock {
            guard self.stream === stream else { return }
            deliveredFrames += Int(output.frameLength)
            if audioStability.recordValidBuffer(at: Clock.now()) {
                recoveryAttempts = 0
            }
        }

        let time = AVAudioTime(
            sampleTime: AVAudioFramePosition(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value
            ),
            atRate: format.sampleRate
        )
        callback(AudioChunk(source: .system, buffer: output, time: time, peak: output.peakAmplitude))
    }

    private func mixdown(
        _ list: UnsafeMutableAudioBufferListPointer,
        into format: AVAudioFormat,
        report: Bool
    ) -> AVAudioPCMBuffer? {
        // Die ersten Pufferlisten roh protokollieren. Ob noch einer aussteht,
        // kommt aus demselben Lock-Zugriff wie die Zähler – bei 50 Callbacks
        // pro Sekunde lohnt es nicht, zweimal zu sperren, und ein ungesperrtes
        // Lesen wäre auch bei einem `Bool` ein Datenrennen.
        if report {
            var description = "Puffer: \(list.count)"
            var rawPeak: Float = 0
            for (index, buffer) in list.enumerated() {
                description += " | [\(index)] ch=\(buffer.mNumberChannels) bytes=\(buffer.mDataByteSize)"
                if let raw = buffer.mData {
                    let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let samples = raw.assumingMemoryBound(to: Float.self)
                    var bufferPeak: Float = 0
                    vDSP_maxmgv(samples, 1, &bufferPeak, vDSP_Length(count))
                    rawPeak = max(rawPeak, bufferPeak)
                } else {
                    description += " (mData=nil)"
                }
            }
            description += " | Rohspitze=\(String(format: "%.5f", rawPeak))"
            lock.withLock {
                bufferReports.append(description)
                if bufferReports.count >= 3 { reportsRemaining = false }
            }
        }

        guard let first = list.first, first.mDataByteSize > 0 else { return nil }
        let frameCount = AVAudioFrameCount(Int(first.mDataByteSize) / MemoryLayout<Float>.size)
        guard frameCount > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = output.floatChannelData?[0] else { return nil }
        output.frameLength = frameCount

        vDSP_vclr(destination, 1, vDSP_Length(frameCount))
        var channels = 0
        for buffer in list {
            guard let raw = buffer.mData else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let available = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let usable = min(available, Int(frameCount))
            vDSP_vadd(destination, 1, samples, 1, destination, 1, vDSP_Length(usable))
            channels += 1
        }
        if channels > 1 {
            var scale = 1 / Float(channels)
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frameCount))
        }
        return output
    }
}

// MARK: - Stream lifecycle

extension ScreenCaptureAudio: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.audio.error("SCStream stopped: \(String(describing: error), privacy: .public)")
        enum StopKind {
            case startup(generation: Int)
            case active(generation: Int)
        }
        let stopped = lock.withLock { () -> StopKind? in
            guard self.stream === stream || startingStream === stream else { return nil }
            let stoppedGeneration = generation
            if startingStream === stream, let pendingStartGate {
                _ = pendingStartGate.resolve(.failure(error))
                return .startup(generation: stoppedGeneration)
            }
            self.stream = nil
            startingStream = nil
            monoFormat = nil
            audioStability.reset()
            return .active(generation: stoppedGeneration)
        }
        guard let stopped else { return }
        switch stopped {
        case .startup(let stoppedGeneration):
            failCapture(generation: stoppedGeneration, error: error)
        case .active(let stoppedGeneration):
            scheduleRecovery(generation: stoppedGeneration, after: error)
        }
    }

    private func scheduleRecovery(generation mine: Int, after error: Error) {
        let next = lock.withLock { () -> (Int, UUID)? in
            guard generation == mine, handler != nil else {
                return nil
            }
            let decision = RecoveryPolicy.decision(
                recoveryInProgress: recoveryToken != nil,
                attempts: recoveryAttempts
            )
            if decision == .deferFailure {
                pendingRecoveryError = error
                return nil
            }
            guard case .scheduleAttempt(let attempt) = decision else { return nil }
            recoveryAttempts = attempt
            let token = UUID()
            recoveryToken = token
            return (attempt, token)
        }

        guard let (attempt, token) = next else {
            let exhausted = lock.withLock { () -> Bool in
                guard generation == mine, handler != nil, recoveryToken == nil else { return false }
                return recoveryAttempts >= RecoveryPolicy.maximumAttempts
            }
            if exhausted { failCapture(generation: mine, error: error) }
            return
        }

        onStatusChange?(
            "Systemton unterbrochen – Wiederherstellung \(attempt) von "
            + "\(RecoveryPolicy.maximumAttempts) läuft …"
        )
        let delay = Duration.milliseconds(Int64(attempt * 500))
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                guard let self, self.isCurrent(generation: mine) else { return }
                try await self.startStream(generation: mine)
                if let pendingError = self.finishRecovery(token: token) {
                    self.scheduleRecovery(generation: mine, after: pendingError)
                }
            } catch is CancellationError {
                if let pendingError = self?.finishRecovery(token: token) {
                    self?.scheduleRecovery(generation: mine, after: pendingError)
                }
            } catch {
                let pendingError = self?.finishRecovery(token: token)
                self?.scheduleRecovery(generation: mine, after: pendingError ?? error)
            }
        }
        let accepted = lock.withLock { () -> Bool in
            guard generation == mine, recoveryToken == token else { return false }
            recoveryTask = task
            return true
        }
        if !accepted { task.cancel() }
    }

    private func finishRecovery(token: UUID) -> Error? {
        lock.withLock {
            guard recoveryToken == token else { return nil }
            recoveryTask = nil
            recoveryToken = nil
            let pending = pendingRecoveryError
            pendingRecoveryError = nil
            return pending
        }
    }
}

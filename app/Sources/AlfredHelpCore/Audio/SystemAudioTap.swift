import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate

/// Captures **everything the Mac plays back**, regardless of which application
/// produced it, using a Core Audio process tap.
///
/// Why a process tap and not ScreenCaptureKit: the tap needs no screen
/// recording permission, carries no video pipeline, adds well under a
/// millisecond of latency and costs a fraction of the CPU. The tap is created
/// unmuted, so the user keeps hearing their call normally.
///
/// ## The part that is not in the usual recipe
///
/// The aggregate device carrying the tap only starts when the real output
/// device's audio engine is already running. Measured on this machine's USB DAC
/// with `--audio-diagnose`: building the aggregate while nothing plays makes
/// Core Audio tear the I/O workloop down again ~95 ms after `AudioDeviceStart`
/// returned `noErr`, and it never recovers on its own — not even once playback
/// starts later. Building the identical aggregate *while* audio plays captures
/// immediately (peak 0.86 on a test tone).
///
/// A tap-only aggregate without the output device is not the answer either: it
/// runs reliably but delivers pure silence.
///
/// So this class does not build once and hope. It watches
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the output device and
/// (re)builds whenever playback is live but capture is not. All of that happens
/// on a private serial queue — rebuilding aggregate devices from the main thread
/// deadlocks the HAL.
public final class SystemAudioTap: SystemAudioCapturing, @unchecked Sendable {

    public let source: AudioSourceKind = .system

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "de.alfredhelp.systemtap.io", qos: .userInitiated)
    private let controlQueue = DispatchQueue(label: "de.alfredhelp.systemtap.control")

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var monoFormat: AVAudioFormat?
    private var handler: (@Sendable (AudioChunk) -> Void)?
    private var isRunning = false

    private var defaultDeviceListener: AudioPropertyListener?
    private var engineListener: AudioPropertyListener?
    private var watchdog: DispatchSourceTimer?
    private var observedOutputDevice = AudioObjectID(kAudioObjectUnknown)
    private var lastBuildAttempt: Double = 0
    private var lastFrameAt: Double = 0
    private var buildCount = 0

    private var callbackCount = 0
    private var deliveredFrames = 0

    /// Called when capture came up or had to be rebuilt. Never on the audio thread.
    public var onStatusChange: (@Sendable (String) -> Void)?

    public init() {}

    public var captureFormat: AVAudioFormat? {
        lock.withLock { monoFormat }
    }

    /// Name of the output device currently being tapped, for the UI.
    public var tappedDeviceName: String {
        guard let deviceID = try? AudioObject.defaultOutputDeviceID,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return "—" }
        return AudioObject.deviceName(deviceID)
    }

    /// Snapshot of what the audio callback has actually seen so far.
    public struct Diagnostics: Sendable {
        public var callbacks: Int
        public var deliveredFrames: Int
        public var inputChannels: Int
        public var sampleRate: Double
        /// Whether Core Audio reports our aggregate as actually running.
        public var deviceIsRunning: Bool
        /// Whether any process is currently playing through the output device.
        public var outputEngineRunning: Bool
        /// How often the capture chain had to be built.
        public var buildCount: Int
    }

    public var deliveredFrameCount: Int { diagnostics.deliveredFrames }

    public var diagnostics: Diagnostics {
        let (callbacks, frames, rate, aggregate, builds) = lock.withLock {
            (callbackCount, deliveredFrames, monoFormat?.sampleRate ?? 0, aggregateID, buildCount)
        }
        let channels = aggregate == AudioObjectID(kAudioObjectUnknown)
            ? 0
            : AudioObject.channelCount(aggregate, scope: kAudioObjectPropertyScopeInput)
        return Diagnostics(
            callbacks: callbacks,
            deliveredFrames: frames,
            inputChannels: channels,
            sampleRate: rate,
            deviceIsRunning: Self.isRunning(device: aggregate),
            outputEngineRunning: Self.outputEngineIsRunning(),
            buildCount: builds
        )
    }

    // MARK: - Lifecycle

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        let alreadyRunning: Bool = lock.withLock {
            if isRunning { return true }
            handler = onChunk
            isRunning = true
            callbackCount = 0
            deliveredFrames = 0
            buildCount = 0
            return false
        }
        guard !alreadyRunning else { return }

        installDefaultDeviceListener()
        controlQueue.async { [weak self] in
            guard let self else { return }
            observeOutputEngine()
            ensureCapturing()
        }
        startWatchdog()
    }

    public func stop() {
        lock.withLock {
            isRunning = false
            handler = nil
            defaultDeviceListener = nil
            engineListener = nil
        }
        watchdog?.cancel()
        watchdog = nil
        controlQueue.sync { teardown() }
    }

    // MARK: - Supervision

    /// Rebuilds capture whenever playback is live but no samples are arriving.
    /// Runs on `controlQueue` only.
    ///
    /// Supervision keys off actually delivered frames, not off
    /// `kAudioDevicePropertyDeviceIsRunning`. That flag stays `0` for a moment
    /// after a successful `AudioDeviceStart`, and tearing the aggregate down on
    /// it produces an endless rebuild loop that never captures anything.
    private func ensureCapturing() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        let (running, aggregate, framesSeen) = lock.withLock {
            (isRunning, aggregateID, lastFrameAt)
        }
        guard running else { return }

        let now = Clock.now()
        let haveAggregate = aggregate != AudioObjectID(kAudioObjectUnknown)

        // Samples arrived recently – nothing to do.
        if haveAggregate && now - framesSeen < Self.staleAfterSeconds { return }

        guard Self.outputEngineIsRunning() else {
            // Nothing is playing, so there is nothing to capture. Release the
            // aggregate and let the audio hardware idle down.
            if haveAggregate { teardown() }
            return
        }

        // Give a fresh build time to spin up before judging it.
        guard now - lastBuildAttempt > Self.rebuildCooldownSeconds else { return }
        lastBuildAttempt = now

        teardown()
        do {
            try build()
            lock.withLock { lastFrameAt = Clock.now() }
            let builds = lock.withLock { buildCount }
            Log.audio.info("System tap built (attempt \(builds, privacy: .public))")
            if builds > 1 {
                onStatusChange?("Systemton erkannt – Aufnahme läuft auf „\(tappedDeviceName)“.")
            }
        } catch {
            Log.audio.error("Tap build failed: \(String(describing: error), privacy: .public)")
            onStatusChange?("Systemaudio konnte nicht gestartet werden: \(statusMessage(for: error))")
        }
    }

    /// `kAudioHardwareIllegalOperationError` also covers HAL/configuration
    /// failures. It does not prove that AudioCapture permission was denied.
    /// Keep that generic failure from being shown as a privacy denial.
    private func statusMessage(for error: Error) -> String {
        guard let captureError = error as? AudioCaptureError,
              case .tapCreationFailed(let status) = captureError,
              status == kAudioHardwareIllegalOperationError else {
            return error.localizedDescription
        }
        return "Core Audio konnte den Systemaudio-Tap nicht erstellen (\(AudioObject.Error.describe(status)))."
    }

    /// How long capture may go quiet before it counts as broken. Comfortably
    /// above the time a fresh aggregate needs to produce its first buffer.
    private static let staleAfterSeconds = 2.0
    private static let rebuildCooldownSeconds = 3.0

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.ensureCapturing() }
        timer.resume()
        watchdog = timer
    }

    /// Listens for the output device starting or stopping playback.
    private func observeOutputEngine() {
        dispatchPrecondition(condition: .onQueue(controlQueue))
        guard let deviceID = try? AudioObject.defaultOutputDeviceID,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return }
        let hasListener = lock.withLock { engineListener != nil }
        guard deviceID != observedOutputDevice || !hasListener else { return }
        observedOutputDevice = deviceID

        let listener = try? AudioPropertyListener(
            objectID: deviceID,
            address: AudioObject.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
            queue: controlQueue
        ) { [weak self] in
            self?.ensureCapturing()
        }
        lock.withLock { engineListener = listener }
    }

    private func installDefaultDeviceListener() {
        let listener = try? AudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: AudioObject.address(kAudioHardwarePropertyDefaultOutputDevice),
            queue: controlQueue
        ) { [weak self] in
            guard let self else { return }
            // The aggregate references the old device by UID – it has to go.
            teardown()
            observeOutputEngine()
            ensureCapturing()
        }
        lock.withLock { defaultDeviceListener = listener }
    }

    private static func isRunning(device: AudioObjectID) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        let value: UInt32 = (try? AudioObject.value(
            device,
            AudioObject.address(kAudioDevicePropertyDeviceIsRunning),
            defaultValue: UInt32(0),
            operation: "read device running"
        )) ?? 0
        return value != 0
    }

    private static func outputEngineIsRunning() -> Bool {
        guard let deviceID = try? AudioObject.defaultOutputDeviceID,
              deviceID != AudioObjectID(kAudioObjectUnknown) else { return false }
        let value: UInt32 = (try? AudioObject.value(
            deviceID,
            AudioObject.address(kAudioDevicePropertyDeviceIsRunningSomewhere),
            defaultValue: UInt32(0),
            operation: "read device running somewhere"
        )) ?? 0
        return value != 0
    }

    // MARK: - Build / teardown

    private func build() throws {
        dispatchPrecondition(condition: .onQueue(controlQueue))

        let outputDeviceID = (try? AudioObject.defaultOutputDeviceID) ?? AudioObjectID(kAudioObjectUnknown)
        guard outputDeviceID != AudioObjectID(kAudioObjectUnknown),
              let outputUID = try? AudioObject.deviceUID(outputDeviceID) else {
            throw AudioCaptureError.aggregateDeviceFailed(kAudioHardwareBadDeviceError)
        }

        // A mono mixdown of every process. Speech recognition wants mono anyway,
        // so mixing down here halves everything downstream.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        description.name = "AlfredHelp Systemaudio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw AudioCaptureError.tapCreationFailed(tapStatus)
        }

        let tapUID: String
        let asbd: AudioStreamBasicDescription
        do {
            tapUID = try AudioObject.string(
                newTapID, AudioObject.address(kAudioTapPropertyUID), operation: "read tap UID"
            )
            asbd = try AudioObject.value(
                newTapID,
                AudioObject.address(kAudioTapPropertyFormat),
                defaultValue: AudioStreamBasicDescription(),
                operation: "read tap format"
            )
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }

        var mutableASBD = asbd
        // The mixdown maths below reads the buffers as 32-bit float, so verify
        // rather than assume.
        guard let format = AVAudioFormat(streamDescription: &mutableASBD),
              format.sampleRate > 0,
              format.commonFormat == .pcmFormatFloat32,
              let mono = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: 1,
                interleaved: false
              ) else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.unsupportedTapFormat
        }

        // The output device has to be part of the aggregate; a tap-only
        // aggregate starts happily but delivers pure silence.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AlfredHelp Aufnahme",
            kAudioAggregateDeviceUIDKey: "de.alfredhelp.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggregateStatus == noErr, newAggregateID != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.aggregateDeviceFailed(aggregateStatus)
        }

        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, newAggregateID, ioQueue
        ) { [weak self] _, inputData, inputTime, _, _ in
            self?.handleInput(inputData, timestamp: inputTime)
        }
        guard procStatus == noErr, let newProcID else {
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.ioProcFailed(procStatus)
        }

        let startStatus = AudioDeviceStart(newAggregateID, newProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(newAggregateID, newProcID)
            AudioHardwareDestroyAggregateDevice(newAggregateID)
            AudioHardwareDestroyProcessTap(newTapID)
            throw AudioCaptureError.ioProcFailed(startStatus)
        }

        lock.withLock {
            tapID = newTapID
            aggregateID = newAggregateID
            ioProcID = newProcID
            tapFormat = format
            monoFormat = mono
            buildCount += 1
        }
    }

    private func teardown() {
        let (currentAggregate, currentProc, currentTap) = lock.withLock {
            let values = (aggregateID, ioProcID, tapID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            ioProcID = nil
            tapID = AudioObjectID(kAudioObjectUnknown)
            return values
        }

        if currentAggregate != AudioObjectID(kAudioObjectUnknown), let currentProc {
            AudioDeviceStop(currentAggregate, currentProc)
            AudioDeviceDestroyIOProcID(currentAggregate, currentProc)
        }
        if currentAggregate != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(currentAggregate)
        }
        if currentTap != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(currentTap)
        }
    }

    // MARK: - Audio thread

    private func handleInput(
        _ bufferList: UnsafePointer<AudioBufferList>,
        timestamp: UnsafePointer<AudioTimeStamp>
    ) {
        let (format, callback) = lock.withLock { () -> (AVAudioFormat?, (@Sendable (AudioChunk) -> Void)?) in
            callbackCount += 1
            return (monoFormat, handler)
        }
        guard let format, let callback else { return }

        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard list.count > 0 else { return }

        let first = list[0]
        guard first.mDataByteSize > 0, first.mNumberChannels > 0 else { return }
        let bytesPerChannelFrame = UInt32(MemoryLayout<Float>.size)
        let frameCount = first.mDataByteSize / (bytesPerChannelFrame * first.mNumberChannels)
        guard frameCount > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let destination = output.floatChannelData?[0] else { return }
        output.frameLength = frameCount

        // Mix everything down to one channel. Vektorisiert, weil das hier auf
        // dem Audio-Thread liegt: `vDSP_vadd` für einkanalige Puffer,
        // `vDSP_vswsum`-frei über einen Schrittzugriff für verschachtelte.
        var channelsMixed: UInt32 = 0
        vDSP_vclr(destination, 1, vDSP_Length(frameCount))

        for buffer in list {
            guard let raw = buffer.mData else { continue }
            let channels = buffer.mNumberChannels
            guard channels > 0 else { continue }
            let samples = raw.assumingMemoryBound(to: Float.self)
            let available = buffer.mDataByteSize / (bytesPerChannelFrame * channels)
            let usable = vDSP_Length(min(available, frameCount))
            if channels == 1 {
                vDSP_vadd(destination, 1, samples, 1, destination, 1, usable)
            } else {
                // Verschachtelt: jede Spur mit ihrem Schritt lesen und bereits
                // geteilt aufaddieren. `vDSP_vsma` rechnet D = A·b + C, der
                // Faktor trifft also nur den neuen Beitrag – ein Skalieren des
                // Ziels am Ende würde auch die Puffer davor mit erwischen.
                let step = vDSP_Stride(channels)
                var inverse = 1 / Float(channels)
                for channel in 0..<Int(channels) {
                    vDSP_vsma(
                        samples.advanced(by: channel), step,
                        &inverse,
                        destination, 1,
                        destination, 1,
                        usable
                    )
                }
            }
            channelsMixed += 1
        }

        if channelsMixed > 1 {
            var scale = 1 / Float(channelsMixed)
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(frameCount))
        }

        lock.withLock {
            deliveredFrames += Int(frameCount)
            lastFrameAt = Clock.now()
        }

        let time = AVAudioTime(
            hostTime: timestamp.pointee.mHostTime,
            sampleTime: AVAudioFramePosition(timestamp.pointee.mSampleTime),
            atRate: format.sampleRate
        )
        callback(AudioChunk(source: .system, buffer: output, time: time, peak: output.peakAmplitude))
    }

    deinit {
        watchdog?.cancel()
        teardown()
    }
}

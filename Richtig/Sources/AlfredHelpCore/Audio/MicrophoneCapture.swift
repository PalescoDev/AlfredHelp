import Foundation
import AVFoundation

/// Captures the user's own voice. Optional, but having both sides of the
/// conversation transcribed is what makes the answers actually fit the thread –
/// and it keeps the assistant from reacting to questions the user asked
/// themselves.
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {

    public let source: AudioSourceKind = .microphone

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var isRunning = false

    public init() {}

    public var captureFormat: AVAudioFormat? {
        lock.lock(); defer { lock.unlock() }
        return monoFormat
    }

    public var deviceName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "Standardmikrofon"
    }

    /// Asks for microphone access; returns the granted state.
    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    public static var hasAccess: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        lock.lock()
        if isRunning { lock.unlock(); return }
        lock.unlock()

        guard Self.hasAccess else { throw AudioCaptureError.microphonePermissionDenied }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable("kein gültiges Eingabeformat")
        }

        guard let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioCaptureError.microphoneUnavailable("Mono-Format nicht erstellbar")
        }

        let needsConversion = inputFormat.channelCount != 1
            || inputFormat.commonFormat != .pcmFormatFloat32
        let localConverter = needsConversion ? AVAudioConverter(from: inputFormat, to: mono) : nil
        if needsConversion && localConverter == nil {
            throw AudioCaptureError.microphoneUnavailable("Konverter nicht erstellbar")
        }

        lock.lock()
        monoFormat = mono
        converter = localConverter
        lock.unlock()

        // ~100 ms of audio per callback keeps wakeups rare without adding
        // meaningful latency – the analyzer buffers internally anyway.
        let bufferSize = AVAudioFrameCount(max(1024, inputFormat.sampleRate / 10))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, time in
            guard let self else { return }
            guard let converted = self.convert(buffer, to: mono) else { return }
            onChunk(AudioChunk(
                source: .microphone,
                buffer: converted,
                time: time,
                peak: converted.peakAmplitude
            ))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.microphoneUnavailable(error.localizedDescription)
        }

        lock.lock(); isRunning = true; lock.unlock()
        Log.audio.info("Microphone running at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        converter = nil
        monoFormat = nil
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        lock.lock()
        let localConverter = converter
        lock.unlock()

        guard let localConverter else {
            // Already mono float32 – hand out a private copy so the engine can
            // recycle its buffer immediately.
            guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
                  let destination = copy.floatChannelData?[0],
                  let sourceData = buffer.floatChannelData?[0] else { return nil }
            copy.frameLength = buffer.frameLength
            destination.update(from: sourceData, count: Int(buffer.frameLength))
            return copy
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        let input = ConverterInput(buffer)
        var conversionError: NSError?
        let status = localConverter.convert(to: output, error: &conversionError) { _, statusPointer in
            input.next(statusPointer)
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    deinit {
        stop()
    }
}

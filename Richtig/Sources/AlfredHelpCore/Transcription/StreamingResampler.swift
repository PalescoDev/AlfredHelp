import Foundation
import AVFoundation

/// Stateful sample-rate/format conversion from a capture format to the format
/// the speech analyzer wants. One instance per audio source – the converter
/// keeps filter state across buffers, so it must not be shared.
final class StreamingResampler {
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        self.ratio = outputFormat.sampleRate / inputFormat.sampleRate

        if inputFormat == outputFormat {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                return nil
            }
            // Mastering-grade sample rate conversion costs almost nothing at
            // these buffer sizes and keeps consonants crisp for the recognizer.
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        guard buffer.frameLength > 0 else { return nil }

        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        let input = ConverterInput(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPointer in
            input.next(statusPointer)
        }

        if let error {
            Log.audio.error("Resampling failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Silence in the analyzer's own format, used to keep the timeline
    /// contiguous when the pre-roll buffer is flushed.
    func makeSilence(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(outputFormat.channelCount) {
            data[channel].update(repeating: 0, count: Int(frames))
        }
        return buffer
    }
}

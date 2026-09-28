import AppKit
import AVFoundation
import Foundation
import AlfredHelpCore

/// `AlfredHelp --recognition-latency <datei.wav> [sprache]`
///
/// Spielt nichts ab. Die Datei wird in Echtzeit durch genau denselben
/// `SourceTranscriber` geschoben, den die App im Betrieb nutzt, und protokolliert
/// für jede Äußerung:
///
///   • wann das Zwischenergebnis erstmals eine fertige Frage enthielt
///   • wann das finale Ergebnis eintraf
///
/// Die Differenz ist die Zeit, die der Nutzer wartet – und der Grund, warum eine
/// Antwort scheinbar erst mit der nächsten Frage erscheint.
@MainActor
enum RecognitionLatencyProbe {

    private final class Delegate: NSObject, NSApplicationDelegate {
        let url: URL
        let locale: Locale
        private let lock = NSLock()
        private var start = Clock.now()
        private var questionReadyAt: Double?
        private var questionText = ""
        private var lines: [String] = []
        private var volatileText = ""
        private var lastSpeechAt = Clock.now()
        private var lastForced: Double = 0
        /// Ende der letzten Sprachaktivität im Audio, in Sekunden ab Dateibeginn.
        private var speechEndedAtAudioPosition: Double = 0
        private var audioPosition: Double = 0
        /// Mit `--force` wird dieselbe erzwungene Finalisierung nachgebildet,
        /// die der Koordinator im Betrieb anwendet.
        var forcesFinalization = CommandLine.arguments.contains("--force")

        init(url: URL, locale: Locale) {
            self.url = url
            self.locale = locale
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.accessory)
            Task { await self.run() }
        }

        private func run() async {
            guard let file = try? AVAudioFile(forReading: url) else {
                print("Datei nicht lesbar: \(url.path)")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }
            do {
                try await SpeechAssets.ensureModel(for: locale)
            } catch {
                print("Sprachmodell: \(error.localizedDescription)")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }

            var gate = SilenceGateOptions()
            gate.enabled = false
            let transcriber = SourceTranscriber(source: .system, locale: locale, gate: gate)
            do {
                try await transcriber.start(
                    onEvent: { [weak self] event in self?.record(event) },
                    onFailure: { error in print("Erkennung: \(error.localizedDescription)") }
                )
            } catch {
                print("Start: \(error.localizedDescription)")
                await MainActor.run { NSApp.terminate(nil) }
                return
            }

            print("Datei: \(url.lastPathComponent) · Sprache: \(locale.identifier)")
            print("Zeit    Art     Text")
            print(String(repeating: "─", count: 76))
            start = Clock.now()

            // In Echtzeit einspeisen – sonst sagt die Messung nichts über den
            // Live-Betrieb aus.
            let format = file.processingFormat
            let chunkFrames = AVAudioFrameCount(format.sampleRate / 10)   // 100 ms
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: chunkFrames
                ) else { break }
                try? file.read(into: buffer, frameCount: chunkFrames)
                guard buffer.frameLength > 0 else { break }
                let mono = Self.monoCopy(of: buffer) ?? buffer
                let peak = mono.peakAmplitude
                lock.withLock {
                    audioPosition += Double(mono.frameLength) / format.sampleRate
                    if peak >= 0.01 {
                        lastSpeechAt = Clock.now()
                        speechEndedAtAudioPosition = audioPosition
                    }
                }
                transcriber.feed(AudioChunk(
                    source: .system, buffer: mono, time: nil, peak: peak
                ))
                try? await Task.sleep(for: .milliseconds(100))
                if forcesFinalization { await settleCheck(transcriber) }
            }

            // Nachlauf, damit späte Finalisierungen noch ankommen.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(100))
                if forcesFinalization { await settleCheck(transcriber) }
            }
            await transcriber.stop()
            report()
            await MainActor.run { NSApp.terminate(nil) }
        }

        private static func monoCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let source = buffer.floatChannelData else { return nil }
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: buffer.format.sampleRate,
                channels: 1, interleaved: false
            ), let output = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: buffer.frameLength
            ), let destination = output.floatChannelData?[0] else { return nil }
            output.frameLength = buffer.frameLength
            let channels = Int(buffer.format.channelCount)
            for index in 0..<Int(buffer.frameLength) {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][index] }
                destination[index] = sum / Float(channels)
            }
            return output
        }

        /// Spiegelt den Koordinator: nach einer echten Sprechpause finalisieren.
        private func settleCheck(_ transcriber: SourceTranscriber) async {
            let now = Clock.now()
            let (text, spokeAt, forced) = lock.withLock {
                (volatileText, lastSpeechAt, lastForced)
            }
            guard !text.isEmpty, now - forced >= 1.0 else { return }
            guard now - spokeAt >= 0.6 else { return }
            lock.withLock { lastForced = now }
            await transcriber.finalizeNow()
        }

        private func record(_ event: TranscriptEvent) {
            let elapsed = (Clock.now() - start) * 1000
            lock.withLock {
                if !event.isFinal {
                    let trimmed = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    volatileText = trimmed
                    // Enthält das Zwischenergebnis bereits eine fertige Frage?
                    if questionReadyAt == nil,
                       case .question(let confidence) = TextUtilities.assessQuestion(event.text),
                       confidence >= 0.9 {
                        questionReadyAt = elapsed
                        questionText = event.text
                        lines.append(String(
                            format: "%6.0f  ZWISCH  ✱ fertige Frage erkennbar: %@",
                            elapsed, event.text as NSString
                        ))
                    }
                } else {
                    volatileText = ""
                    var note = ""
                    if let ready = questionReadyAt {
                        note = String(format: "  (⏱ %.0f ms nach dem Zwischenergebnis)", elapsed - ready)
                        questionReadyAt = nil
                    }
                    let afterSpeech = elapsed - speechEndedAtAudioPosition * 1000
                    lines.append(String(
                        format: "%6.0f  FINAL   %@%@  [%.0f ms nach Sprechende]",
                        elapsed, event.text as NSString, note as NSString, max(0, afterSpeech)
                    ))
                }
            }
        }

        private func report() {
            let output = lock.withLock { lines }
            for line in output { print(line) }
        }
    }

    static func run(url: URL, locale: Locale) -> Never {
        let application = NSApplication.shared
        let delegate = Delegate(url: url, locale: locale)
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

import AppKit
import Foundation
import AlfredHelpCore

/// `AlfredHelp --transcribe-test [Sekunden] [Sprache]`
///
/// Der vollständige Nachweis der Kette: Systemton → PCM → Spracherkennung →
/// Text. Läuft als echter GUI-Prozess, damit macOS die Freigabe zuordnen kann,
/// und schreibt das Ergebnis nach
/// `~/Library/Application Support/AlfredHelp/transkriptionstest.txt`.
@MainActor
enum TranscribeProbe {

    private final class Delegate: NSObject, NSApplicationDelegate {
        let seconds: Int
        let locale: Locale
        private let capture = ScreenCaptureAudio()
        private var transcriber: SourceTranscriber?
        private let lock = NSLock()
        private var frames = 0
        private var peak: Float = 0
        private var finals: [String] = []
        private var volatileText = ""

        init(seconds: Int, locale: Locale) {
            self.seconds = seconds
            self.locale = locale
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.accessory)
            Task { await self.start() }
        }

        private func start() async {
            print("Sprache: \(locale.identifier) · Dauer: \(seconds) s")
            if !SystemAudioPermission.isGranted {
                _ = SystemAudioPermission.request()
                print("Berechtigung angefordert – bitte im Dialog erlauben.")
            }

            do {
                try await SpeechAssets.ensureModel(for: locale) { fraction in
                    if fraction < 1 { print("  Sprachmodell \(Int(fraction * 100)) %") }
                }
            } catch {
                finish(error: "Sprachmodell: \(error.localizedDescription)")
                return
            }

            var gate = SilenceGateOptions()
            gate.enabled = false   // im Test nichts wegfiltern
            let source = SourceTranscriber(source: .system, locale: locale, gate: gate)
            do {
                try await source.start(
                    onEvent: { [weak self] event in
                        guard let self else { return }
                        self.lock.withLock {
                            if event.isFinal {
                                self.finals.append(event.text)
                                self.volatileText = ""
                            } else {
                                self.volatileText = event.text
                            }
                        }
                        if event.isFinal { print("  ▸ \(event.text)") }
                    },
                    onFailure: { error in
                        print("  Erkennung: \(error.localizedDescription)")
                    }
                )
            } catch {
                finish(error: "Spracherkennung: \(error.localizedDescription)")
                return
            }
            transcriber = source

            capture.onStatusChange = { message in print("  \(message)") }
            do {
                try capture.start { [weak self] chunk in
                    guard let self else { return }
                    self.lock.withLock {
                        self.frames += Int(chunk.buffer.frameLength)
                        self.peak = max(self.peak, chunk.peak)
                    }
                    source.feed(chunk)
                }
            } catch {
                finish(error: "Systemton: \(error.localizedDescription)")
                return
            }

            print("Höre \(seconds) s mit …")
            try? await Task.sleep(for: .seconds(Double(seconds)))
            capture.stop()
            try? await Task.sleep(for: .seconds(1.5))
            await source.stop()
            finish(error: nil)
        }

        private func finish(error: String?) {
            let (frames, peak, finals, volatileText) = lock.withLock {
                (self.frames, self.peak, self.finals, self.volatileText)
            }
            let rate = capture.captureFormat?.sampleRate ?? 48_000
            let transcript = (finals + [volatileText])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: " ")

            let output = OutputVolume.current
            let volumeText: String
            if output.isMuted {
                volumeText = "stummgeschaltet"
            } else if let level = output.volume {
                volumeText = "\(Int((level * 100).rounded())) %"
            } else {
                volumeText = "keine Softwareregelung"
            }

            var report = """
                Systemton → Spracherkennung
                ────────────────────────────────────────────────
                Rahmen        : \(frames)
                Sekunden      : \(String(format: "%.2f", Double(frames) / rate))
                Spitzenpegel  : \(String(format: "%.4f", peak))
                Ausgabe       : \(output.deviceName), \(volumeText)
                Freigabe      : \(SystemAudioPermission.isGranted ? "erteilt" : "fehlt")
                Signatur      : \(SystemAudioPermission.isAdHocSigned ? "ad-hoc" : "zertifiziert")
                Prüfsumme     : \(SystemAudioPermission.codeHash.prefix(16))
                ────────────────────────────────────────────────
                Transkript    : \(transcript.isEmpty ? "(leer)" : transcript)
                """
            if let error { report += "\n\nFehler: \(error)" }

            let verdict: String
            if frames == 0 {
                verdict = "FEHLGESCHLAGEN – keine Rahmen empfangen."
            } else if peak <= 0.002, let reason = output.explanation {
                verdict = "FEHLGESCHLAGEN – nur Stille. \(reason)"
            } else if peak <= 0.002 {
                verdict = "FEHLGESCHLAGEN – nur Stille. Freigabe fehlt oder es lief kein Ton."
            } else if transcript.isEmpty {
                verdict = "TEILWEISE – echtes PCM empfangen, aber keine Sprache erkannt."
            } else {
                verdict = "ERFOLGREICH – echtes PCM und Transkription."
            }
            report += "\n\nErgebnis: \(verdict)"

            print("\n" + report)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AlfredHelp", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? report.write(
                to: base.appendingPathComponent("transkriptionstest.txt"),
                atomically: true, encoding: .utf8
            )
            // AppKit gehört auf den Hauptthread; `finish` läuft aus einem
            // losgelösten Task heraus.
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func run(seconds: Int, locale: Locale) -> Never {
        let application = NSApplication.shared
        let delegate = Delegate(seconds: seconds, locale: locale)
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

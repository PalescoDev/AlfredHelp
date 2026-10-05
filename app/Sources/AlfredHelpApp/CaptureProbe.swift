import AppKit
import CoreGraphics
import AlfredHelpCore

/// `AlfredHelp --capture-probe` – startet eine echte NSApplication, hört 15 s
/// Systemton mit und schreibt das Ergebnis nach
/// `~/Library/Application Support/AlfredHelp/capture-probe.txt`.
///
/// Der Unterschied zum Selbsttest: hier läuft ein vollwertiger GUI-Prozess mit
/// Ereignisschleife. Nur so kann macOS den Berechtigungsdialog für die
/// Audioaufnahme überhaupt anzeigen.
@MainActor
enum CaptureProbe {

    // Die Zähler werden aus dem Audio-Rückruf beschrieben und im Bericht
    // gelesen; abgesichert ist das von Hand über `lock` – wie überall sonst im
    // Projekt, wo ein Audio-Thread beteiligt ist.
    private final class Delegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
        let useScreenCapture: Bool
        let tap: any AudioCapturing

        init(useScreenCapture: Bool) {
            self.useScreenCapture = useScreenCapture
            self.tap = useScreenCapture ? ScreenCaptureAudio() : SystemAudioTap()
        }

        private let lock = NSLock()
        private var frames = 0
        private var peak: Float = 0

        func applicationDidFinishLaunching(_ notification: Notification) {
            NSApp.setActivationPolicy(.accessory)
            if useScreenCapture {
                let granted = CGPreflightScreenCaptureAccess()
                if !granted {
                    // Zeigt den Systemdialog. Erfordert einen GUI-Prozess.
                    _ = SystemAudioPermission.request()
                }
                (tap as? ScreenCaptureAudio)?.onStatusChange = { [weak self] message in
                    self?.write("Status: \(message)")
                }
            }
            do {
                try tap.start { [weak self] chunk in
                    guard let self else { return }
                    self.lock.withLock {
                        self.frames += Int(chunk.buffer.frameLength)
                        self.peak = max(self.peak, chunk.peak)
                    }
                }
            } catch {
                write("start fehlgeschlagen: \(error.localizedDescription)")
                NSApp.terminate(nil)
                return
            }
            Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let (frames, peak) = self.lock.withLock { (self.frames, self.peak) }
                    let rate = self.tap.captureFormat?.sampleRate ?? 0
                    var report = """
                        Verfahren     : \(self.useScreenCapture ? "ScreenCaptureKit" : "Core-Audio-Tap")
                        Rahmen        : \(frames)
                        Sekunden      : \(rate > 0 ? String(format: "%.2f", Double(frames) / rate) : "—")
                        Spitzenpegel  : \(String(format: "%.4f", peak))
                        Abtastrate    : \(Int(rate))
                        """
                    if let sck = self.tap as? ScreenCaptureAudio {
                        let d = sck.diagnostics
                        report += """
                            \nCallbacks     : \(d.callbacks)
                            Stream aktiv  : \(d.isStreaming)
                            Bildschirmzugriff: \(CGPreflightScreenCaptureAccess())
                            \(d.bufferReports.joined(separator: "\n"))
                            """
                    } else if let coreTap = self.tap as? SystemAudioTap {
                        let d = coreTap.diagnostics
                        report += """
                            \nCallbacks     : \(d.callbacks)
                            Aufbauten     : \(d.buildCount)
                            Aggregat läuft: \(d.deviceIsRunning)
                            """
                    }
                    self.write(report)
                    self.tap.stop()
                    NSApp.terminate(nil)
                }
            }
        }

        private func write(_ text: String) {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AlfredHelp", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try? text.write(
                to: base.appendingPathComponent("capture-probe.txt"),
                atomically: true, encoding: .utf8
            )
        }
    }

    static func run(useScreenCapture: Bool) -> Never {
        let application = NSApplication.shared
        let delegate = Delegate(useScreenCapture: useScreenCapture)
        application.delegate = delegate
        application.run()
        exit(0)
    }
}

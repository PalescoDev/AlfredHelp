import Foundation
import AVFoundation
import AlfredHelpCore

/// `AlfredHelp --selftest` – prüft ohne Oberfläche, ob alle Bausteine
/// tatsächlich funktionieren. Gedacht für die Fehlersuche bei Berechtigungen.
enum SelfTest {

    private static var transcript = ""

    static func run() async -> Int32 {
        var failures = 0
        emit("AlfredHelp – Selbsttest\n" + String(repeating: "─", count: 60))

        failures += await checkOllama()
        failures += await checkSpeech()
        failures += checkMicrophonePermission()
        failures += await checkSystemAudio()

        emit(String(repeating: "─", count: 60))
        emit(failures == 0 ? "Alles bereit." : "\(failures) Punkt(e) benötigen Aufmerksamkeit.")
        writeReport()
        return failures == 0 ? 0 : 1
    }

    // MARK: - Einzelprüfungen

    private static func checkOllama() async -> Int {
        let client = OllamaClient()
        let running = await OllamaSupervisor.ensureRunning(client: client)
        guard running, let version = try? await client.version() else {
            fail("Ollama", OllamaSupervisor.isInstalled
                 ? "Dienst nicht erreichbar. „ollama serve“ manuell starten."
                 : "Nicht installiert – von ollama.com laden.")
            return 1
        }
        ok("Ollama", "Version \(version) auf 127.0.0.1:11434")

        guard let models = try? await client.installedModels(), !models.isEmpty else {
            fail("Modelle", "Keine Modelle installiert.")
            return 1
        }
        let choice = ModelCatalog.autoSelect(from: models)
        ok("Modelle", "\(models.count) installiert · schnell: \(choice.fast) · Antwort: \(choice.quality)")

        // Ein gelöschtes, aber noch konfiguriertes Modell fällt sonst erst im
        // Gespräch auf – als stumme Frageerkennung.
        let configured = SettingsStore().settings
        let names = Set(models.map(\.name))
        for (role, name) in [("Schnellmodell", configured.fastModel), ("Antwortmodell", configured.qualityModel)] {
            if !name.isEmpty && !names.contains(name) {
                fail(role, "„\(name)“ ist konfiguriert, aber nicht mehr installiert – ollama pull \(name)")
                return 1
            }
        }

        guard !choice.quality.isEmpty else {
            fail("Modelle", "Kein geeignetes Antwortmodell gefunden.")
            return 1
        }
        let started = Clock.now()
        do {
            let (text, metrics) = try await client.chat(
                model: choice.quality,
                messages: [.system("Antworte mit genau einem Wort."), .user("Funktionierst du?")],
                options: GenerationOptions(temperature: 0, numPredict: 8),
                think: modelSupportsThinking(choice.quality) ? false : nil
            )
            let clean = TextUtilities.cleanModelText(text)
            ok("Antworttest", "„\(clean.prefix(40))“ nach \(Clock.millis(since: started)) ms, "
               + String(format: "%.0f Tok/s", metrics.tokensPerSecond))
        } catch {
            fail("Antworttest", error.localizedDescription)
            return 1
        }
        return 0
    }

    private static func checkSpeech() async -> Int {
        guard SpeechAssets.isAvailable else {
            fail("Spracherkennung", "Auf diesem Mac nicht verfügbar.")
            return 1
        }
        let locales = await SpeechAssets.availableLocales()
        let installed = locales.filter(\.isInstalled)
        ok("Spracherkennung",
           "\(locales.count) Sprachen unterstützt, \(installed.count) bereits geladen")
        return 0
    }

    private static func checkMicrophonePermission() -> Int {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            ok("Mikrofon", "Zugriff erteilt")
            return 0
        case .notDetermined:
            info("Mikrofon", "Noch nicht angefragt – wird beim ersten Start abgefragt")
            return 0
        default:
            info("Mikrofon", "Kein Zugriff. Optional; ohne ihn fehlt die eigene Gesprächsseite.")
            return 0
        }
    }

    private static func checkSystemAudio() async -> Int {
        final class StartStatus: @unchecked Sendable {
            let lock = NSLock()
            var failure: String?

            func record(_ message: String) {
                guard message.contains("konnte nicht gestartet werden")
                    || message.hasPrefix("Systemton-Erfassung wurde beendet.") else { return }
                lock.withLock {
                    if failure == nil { failure = message }
                }
            }

            var capturedFailure: String? { lock.withLock { failure } }
        }

        let backend = SettingsStore().settings.systemAudioBackend
        let capture = backend.makeCapture()
        let status = StartStatus()
        capture.onStatusChange = { status.record($0) }
        let counter = FrameCounter()
        do {
            try capture.start { chunk in
                counter.add(frames: Int(chunk.buffer.frameLength), peak: chunk.peak)
            }
        } catch {
            capture.stop()
            fail("Systemaudio", "\(backend.germanName): Startfehler – \(error.localizedDescription)")
            return 1
        }
        defer { capture.stop() }

        emit("  … prüfe \(backend.germanName) bis zu 8 Sekunden (jetzt Ton abspielen)")
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            if counter.snapshot().peak > 0.001 { break }
        }
        let result = counter.snapshot()
        let rate = capture.captureFormat?.sampleRate ?? 0

        if result.frames == 0, let failure = status.capturedFailure {
            fail("Systemaudio", "\(backend.germanName): Startfehler – \(failure)")
            return 1
        }

        guard result.frames > 0 else {
            if let tap = capture as? SystemAudioTap, tap.diagnostics.outputEngineRunning {
                let diagnostics = tap.diagnostics
                fail("Systemaudio",
                     "\(backend.germanName): Audio läuft, aber es kamen keine PCM-Rahmen an. "
                     + "Aufbauversuche: \(diagnostics.buildCount), Callbacks: \(diagnostics.callbacks), "
                     + "Aggregat läuft: \(diagnostics.deviceIsRunning ? "ja" : "nein"), "
                     + "Eingangskanäle: \(diagnostics.inputChannels).")
                return 1
            }
            if let screenCapture = capture as? ScreenCaptureAudio,
               !screenCapture.diagnostics.isStreaming {
                fail("Systemaudio", "\(backend.germanName): Der Erfassungsstream wurde nicht aktiv.")
                return 1
            }
            info("Systemaudio",
                 "\(backend.germanName): Keine PCM-Rahmen empfangen. Während der Messung kam möglicherweise kein Ton an; bitte Ton abspielen und erneut prüfen.")
            return 0
        }

        let seconds = rate > 0 ? Double(result.frames) / rate : 0
        let detail = String(
            format: "%.2f s PCM bei %.0f Hz, Spitzenpegel %.3f, %d Rahmen",
            seconds, rate, result.peak, result.frames
        )
        if result.peak > 0.001 {
            ok("Systemaudio", "\(backend.germanName): \(detail)")
        } else {
            info("Systemaudio", "\(backend.germanName): Rahmen kommen an, aber nur Stille – \(detail).")
        }
        return 0
    }

    // MARK: - Ausgabe

    private static func ok(_ area: String, _ detail: String) {
        emit("  ✓ \(area.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)")
    }

    private static func info(_ area: String, _ detail: String) {
        emit("  · \(area.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)")
    }

    private static func fail(_ area: String, _ detail: String) {
        emit("  ✗ \(area.padding(toLength: 16, withPad: " ", startingAt: 0)) \(detail)")
    }

    private static func emit(_ line: String) {
        print(line)
        transcript += line + "\n"
    }

    /// Also writes the report to disk so the test can be run through
    /// LaunchServices (`open -a AlfredHelp --args --selftest`), which is the only
    /// way macOS shows the permission prompt.
    private static func writeReport() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AlfredHelp", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("selbsttest.txt")
        try? transcript.write(to: url, atomically: true, encoding: .utf8)
        print("Bericht: \(url.path)")
    }
}

/// Sammelt Messwerte aus dem Audio-Callback.
private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var peak: Float = 0

    func add(frames count: Int, peak value: Float) {
        lock.withLock {
            frames += count
            peak = max(peak, value)
        }
    }

    func snapshot() -> (frames: Int, peak: Float) {
        lock.withLock { (frames, peak) }
    }
}

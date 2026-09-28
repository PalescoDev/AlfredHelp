import SwiftUI
import AppKit
import AlfredHelpCore

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    /// Läuft der geordnete Abbau schon? Ein zweiter `Beenden`-Befehl darf ihn
    /// nicht ein zweites Mal anstoßen.
    private var isTerminating = false
    private var didReplyToTermination = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no window stealing focus from the call.
        NSApp.setActivationPolicy(.accessory)

        guard let model else { return }
        HotKeyCenter.shared.install(
            toggleSession: { model.toggleSession() },
            toggleOverlay: { model.toggleOverlay() },
            answerNow: { model.answerNow() }
        )
        Task { await model.bootstrap() }
    }

    /// Beendet die Sitzung geordnet, **bevor** das Programm verschwindet.
    ///
    /// Der naheliegende Weg – in `applicationWillTerminate` einen Task starten
    /// und auf einer Semaphore warten – kann nicht funktionieren: `AppModel` ist
    /// `@MainActor`, `applicationWillTerminate` läuft auf dem Main-Thread, und
    /// das Warten blockiert genau den Actor, auf den der Task springen müsste.
    /// Das Ergebnis war eine feste Wartezeit ohne jede Wirkung – die Erfassung
    /// wurde nie abgebaut und das Sitzungsprotokoll nie geschrieben.
    ///
    /// `.terminateLater` ist der von AppKit dafür vorgesehene Weg: die
    /// Ereignisschleife läuft weiter, der Task kommt auf dem MainActor dran,
    /// und erst `reply(toApplicationShouldTerminate:)` lässt das Programm gehen.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }

        // Ein zweiter Beenden-Befehl – nochmal ⌘Q, ein `quit` per AppleScript,
        // eine Systemabmeldung – darf hier **nicht** mit `.terminateNow`
        // antworten. Das hieße „sofort schließen" und risse genau den Abbau ab,
        // für den diese Konstruktion überhaupt da ist. Der laufende Abbau samt
        // seiner Rückfalllage bedient die Anfrage bereits; hier ist nichts zu
        // tun außer erneut zu warten.
        guard !isTerminating else { return .terminateLater }
        isTerminating = true

        Task { @MainActor in
            await model.stop()
            // Beendet werden nur die exakten Prozess-/App-Handles, die
            // AlfredHelp selbst neu gestartet hat. Ein bereits laufendes
            // Ollama bleibt Eigentum des Nutzers und wird nicht angerührt.
            _ = await OllamaSupervisor.stopManagedOllama()
            replyToTermination()
        }

        // Rückfalllage: hängt der Abbau – etwa weil ein Erkenner nicht
        // zurückkommt –, darf das Programm trotzdem nicht stehen bleiben.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.replyToTermination()
        }
        return .terminateLater
    }

    private func replyToTermination() {
        guard !didReplyToTermination else { return }
        didReplyToTermination = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Letzte Rettung für Wege, die an `applicationShouldTerminate` vorbeigehen
    /// (`exit()`, erzwungenes Beenden durch das System). Rein synchron – hier
    /// darf nichts mehr warten. Der Aufruf ist idempotent.
    func applicationWillTerminate(_ notification: Notification) {
        model?.coordinator.shutdownAudioNow()
        // Der geordnete asynchrone Weg liegt oben. Kommt AppKit hierher, weil
        // dessen Fünf-Sekunden-Notbremse ausgelöst hat, bleibt nur noch das
        // idempotente Sofortsignal an einen eindeutig verwalteten Kindprozess.
        OllamaSupervisor.signalManagedOllamaNow()
    }
}

struct AlfredHelpApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Image(systemName: model.sessionState.isRunning
                  ? "waveform.badge.mic"
                  : "waveform")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.menu)
        .onChange(of: model.sessionState.isRunning, initial: true) { _, _ in
            delegate.model = model
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

// SwiftUI's `@main` attribute is unavailable in a file named `main.swift`,
// so the app is started explicitly.
if let index = CommandLine.arguments.firstIndex(of: "--audio-watch") {
    let seconds = Int(CommandLine.arguments[safe: index + 1] ?? "") ?? 10
    let renderSilence = CommandLine.arguments.contains("--render-silence")
    let status = await AudioDiagnose.watch(seconds: seconds, renderSilence: renderSilence)
    exit(status)
} else if let index = CommandLine.arguments.firstIndex(of: "--recognition-latency") {
    let path = CommandLine.arguments[safe: index + 1] ?? ""
    let language = CommandLine.arguments[safe: index + 2] ?? "de-DE"
    RecognitionLatencyProbe.run(
        url: URL(fileURLWithPath: path), locale: Locale(identifier: language)
    )
} else if let index = CommandLine.arguments.firstIndex(of: "--transcribe-test") {
    let seconds = Int(CommandLine.arguments[safe: index + 1] ?? "") ?? 20
    let language = CommandLine.arguments[safe: index + 2] ?? "de-DE"
    TranscribeProbe.run(seconds: seconds, locale: Locale(identifier: language))
} else if CommandLine.arguments.contains("--capture-probe") {
    CaptureProbe.run(useScreenCapture: !CommandLine.arguments.contains("--tap"))
} else if CommandLine.arguments.contains("--privacy-check") {
    exit(await PrivacyProbe.run())
} else if CommandLine.arguments.contains("--audio-devices") {
    exit(AudioDiagnose.devices())
} else if CommandLine.arguments.contains("--audio-diagnose") {
    let status = await AudioDiagnose.run()
    exit(status)
} else if CommandLine.arguments.contains("--selftest") {
    let status = await SelfTest.run()
    // Der Selftest kann denselben verwalteten `ollama serve`-Fallback starten
    // wie die App. Vor `exit` bekommt er deshalb denselben geordneten Abbau;
    // ein vorher laufender fremder Ollama-Dienst bleibt unangetastet.
    _ = await OllamaSupervisor.stopManagedOllama()
    exit(status)
} else {
    AlfredHelpApp.main()
}

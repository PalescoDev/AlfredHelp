import SwiftUI
import AlfredHelpCore

struct MenuBarContent: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button(
                (model.sessionState.isStarting || model.isStartPending)
                    ? "Start abbrechen"
                    : (model.sessionState.isRunning ? "Mithören stoppen" : "Mithören starten")
            ) {
                model.toggleSession()
            }
            .keyboardShortcut("l", modifiers: [.option, .command])

            Button(model.overlayVisible ? "Overlay ausblenden" : "Overlay einblenden") {
                model.toggleOverlay()
            }
            .keyboardShortcut("o", modifiers: [.option, .command])

            Button("Jetzt antworten") { model.answerNow() }
                .keyboardShortcut("a", modifiers: [.option, .command])
                .disabled(!model.canAnswerNow)

            Divider()

            Menu("Sprache der Gegenseite") {
                ForEach(preferredLocales) { locale in
                    Button {
                        model.settings.systemAudioLocale = locale.identifier
                    } label: {
                        HStack {
                            Text(locale.displayName)
                            if locale.identifier == model.settings.systemAudioLocale {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Menu("Sprachmodell") {
                // Nur was wirklich auf diesem Mac liegt – ein Menüeintrag darf
                // nicht heimlich ein Gigabyte-Download auslösen.
                ForEach(selectableModels, id: \.name) { installed in
                    Button {
                        model.selectModel(installed.name)
                    } label: {
                        HStack {
                            Text(label(for: installed))
                            if installed.name == model.settings.qualityModel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if selectableModels.isEmpty {
                    Text("Kein Modell installiert")
                }
                Divider()
                Button("Weitere laden …") { openSettings.bringToFront() }
            }

            Toggle("Automatisch antworten", isOn: $model.settings.autoAnswerEnabled)
            Toggle("Ins Deutsche übersetzen", isOn: $model.settings.translationEnabled)

            Divider()

            Text(statusLine)
            if let latency = model.medianAnswerLatency {
                Text("Antwortlatenz (Median): \(latency) ms")
            }

            Divider()

            Button("Gespräch zurücksetzen", action: model.clearConversation)
            Button("Protokoll kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.transcriptMarkdown(), forType: .string)
            }
            Button("Einstellungen …") { openSettings.bringToFront() }
                .keyboardShortcut(",", modifiers: .command)

            Divider()
            Text("\(Branding.appName) \(Branding.version) · \(Branding.watermark)")
            Button("AlfredHelp beenden") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }

    private var selectableModels: [OllamaModel] {
        model.installedModels.filter { !ModelCatalog.isKnownUnsuitable($0.name) }
    }

    private func label(for installed: OllamaModel) -> String {
        guard let profile = ModelCatalog.profile(for: installed.name) else {
            return installed.name
        }
        return profile.compactLabel
    }

    private var statusLine: String {
        if let progress = model.setupProgress { return progress.menuLine }
        guard model.ollamaReachable else { return "Ollama wird gestartet …" }
        guard !model.settings.qualityModel.isEmpty else { return "Kein Modell gewählt" }
        if let profile = ModelCatalog.profile(for: model.settings.qualityModel) {
            return "\(profile.name) · \(profile.qualityLabel)"
        }
        return model.settings.qualityModel
    }

    /// The languages most likely wanted, kept short so the menu stays usable.
    private var preferredLocales: [SpeechAssets.LocaleInfo] {
        let wanted = ["en-US", "en-GB", "de-DE", "fr-FR", "es-ES", "it-IT", "pt-BR", "nl-NL"]
        let installed = model.availableLocales
        var result = wanted.compactMap { identifier in
            installed.first { $0.identifier == identifier }
        }
        if !result.contains(where: { $0.identifier == model.settings.systemAudioLocale }),
           let current = installed.first(where: { $0.identifier == model.settings.systemAudioLocale }) {
            result.insert(current, at: 0)
        }
        return result
    }
}

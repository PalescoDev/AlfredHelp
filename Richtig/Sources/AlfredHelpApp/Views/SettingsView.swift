import SwiftUI
import AlfredHelpCore

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            AudioSettings(model: model)
                .tabItem { Label("Audio", systemImage: "waveform") }
            ModelSettings(model: model)
                .tabItem { Label("Modelle", systemImage: "cpu") }
            AnswerSettings(model: model)
                .tabItem { Label("Antworten", systemImage: "sparkles") }
            AppearanceSettings(model: model)
                .tabItem { Label("Darstellung", systemImage: "rectangle.on.rectangle") }
            PrivacyInfo()
                .tabItem { Label("Datenschutz", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - Audio

private struct AudioSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Quellen") {
                Toggle("Systemaudio mithören", isOn: $model.settings.captureSystemAudio)
                Text("Erfasst alles, was der Mac abspielt – Teams, Zoom, Browser, Discord. Der Ton bleibt für den Nutzer unverändert hörbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Eigenes Mikrofon mithören", isOn: $model.settings.captureMicrophone)
                Text("Nur für den Gesprächskontext. Auf eigene Fragen wird nicht geantwortet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sprachen") {
                LocalePicker(
                    title: "Gegenseite spricht",
                    selection: $model.settings.systemAudioLocale,
                    locales: model.availableLocales
                )
                LocalePicker(
                    title: "Ich spreche",
                    selection: $model.settings.microphoneLocale,
                    locales: model.availableLocales
                )
                Text("Sprachmodelle werden bei Bedarf einmalig von Apple geladen und laufen danach vollständig offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Leistung") {
                Toggle("Stromsparmodus (Erkennung pausiert bei Stille)", isOn: $model.settings.powerSaving)
                Text("Spart bei langen Meetings spürbar Energie. Ein Vorlauf von einer halben Sekunde verhindert, dass Wortanfänge verloren gehen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Erfassung neu starten") { model.restartCapture() }
                    Spacer()
                    if model.sessionState.systemAudioActive {
                        Text("Gerät: \(model.sessionState.tappedDevice)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LocalePicker: View {
    let title: String
    @Binding var selection: String
    let locales: [SpeechAssets.LocaleInfo]

    var body: some View {
        Picker(title, selection: $selection) {
            if locales.isEmpty {
                Text(selection).tag(selection)
            }
            ForEach(locales) { locale in
                HStack {
                    Text(locale.displayName)
                    if !locale.isInstalled {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .tag(locale.identifier)
            }
        }
    }
}

// MARK: - Models

private struct ModelSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                ModelPickerView(model: model)
            }

            Section("Dienst") {
                if let progress = model.setupProgress {
                    SetupProgressCard(progress: progress)
                }
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.ollamaReachable ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.ollamaReachable
                         ? "Ollama läuft lokal (Version \(model.ollamaVersion))"
                         : "Ollama nicht erreichbar")
                    Spacer()
                    Button(model.isBootstrapping ? "Prüfe …" : "Erneut prüfen") {
                        model.retryDependencySetup()
                    }
                    .disabled(model.isBootstrapping || model.setupProgress != nil)
                }
                Text("AlfredHelp startet Ollama beim Programmstart selbst. Es muss nichts von Hand gestartet werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Beim Start automatisch zuhören", isOn: $model.settings.autoStartSession)

                Toggle("Fehlendes selbst nachinstallieren",
                       isOn: $model.settings.installMissingDependencies)
                Text("Fehlt auf diesem Mac Ollama, ein Sprachmodell oder die Erkennungssprache, holt AlfredHelp das beim Start selbst nach – geprüft gegen die Signatur des Herstellers. Vorhandenes bleibt unangetastet. Abgeschaltet meldet die App nur noch, was fehlt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Feineinstellungen") {
                    Picker("Kontextfenster", selection: $model.settings.contextTokens) {
                        Text("4 096 Token").tag(4096)
                        Text("8 192 Token").tag(8192)
                        Text("16 384 Token").tag(16384)
                    }
                    Stepper(
                        "Maximale Antwortlänge: \(model.settings.maxAnswerTokens) Token",
                        value: $model.settings.maxAnswerTokens,
                        in: 120...800,
                        step: 20
                    )
                    Text("Ein kleineres Kontextfenster spart kaum Speicher, kostet aber messbar Tempo – Standard ist bewusst 8 192.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.refreshModels() }
    }
}

// MARK: - Answers

private struct AnswerSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Verhalten") {
                Toggle("Fragen automatisch beantworten", isOn: $model.settings.autoAnswerEnabled)
                Toggle("Nur auf Fragen der Gegenseite reagieren", isOn: $model.settings.answerOnlySystemAudio)
                Picker("Antwortsprache", selection: $model.settings.answerLanguage) {
                    ForEach(Prompts.AnswerLanguage.allCases) { language in
                        Text(language.germanName).tag(language)
                    }
                }
                Text("„Gesprächssprache“ formuliert die Antwort so, dass sie direkt ausgesprochen werden kann.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Empfindlichkeit") {
                VStack(alignment: .leading, spacing: 4) {
                    Slider(
                        value: $model.settings.questionHeuristicThreshold,
                        in: 0.15...0.80,
                        step: 0.05
                    ) {
                        Text("Auslöseschwelle")
                    } minimumValueLabel: {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                            .help("Schaut genauer hin")
                    } maximumValueLabel: {
                        Image(systemName: "eye.slash")
                            .font(.system(size: 10))
                            .help("Nur eindeutige Fragen")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(String(format: "%.2f", model.settings.questionHeuristicThreshold))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        Text(sensitivityDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Stepper(
                    "Zusammenfassen alle \(model.settings.summarizeEveryUtterances) Wortmeldungen",
                    value: $model.settings.summarizeEveryUtterances,
                    in: 6...40,
                    step: 2
                )
                Stepper(
                    "Wörtlicher Kontext: \(model.settings.verbatimTurns) Wortmeldungen",
                    value: $model.settings.verbatimTurns,
                    in: 4...30,
                    step: 2
                )
            }

            Section("Hintergrund") {
                Text("Wird jeder Antwort als Kontext mitgegeben – Rolle, Fachgebiet, Produktnamen, Abkürzungen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.settings.userProfile)
                    .font(.system(size: 12))
                    .frame(height: 90)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
            }
        }
        .formStyle(.grouped)
    }

    /// Sagt in Worten, was der eingestellte Wert im Betrieb bedeutet – die
    /// nackte Zahl allein hilft beim Einstellen nicht weiter.
    private var sensitivityDescription: String {
        switch model.settings.questionHeuristicThreshold {
        case ..<0.30:
            return "Schaut am genauesten hin: auch Aussagen, die an dich gerichtet sind („Ich bin gespannt, wie ihr das macht“), lässt das kleine Modell prüfen. Etwas mehr Rechenlast."
        case ..<0.50:
            return "Ausgewogen: indirekte Bitten, Kurzfragen und Fragen ohne Fragezeichen werden geprüft."
        case ..<0.70:
            return "Zurückhaltend: nur klar fragende Formulierungen lösen aus."
        default:
            return "Streng: praktisch nur eindeutige Fragen mit Fragewort oder Fragezeichen."
        }
    }
}


// MARK: - Appearance

private struct AppearanceSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Vor Bildschirmfreigabe verbergen", isOn: Binding(
                    get: { model.settings.overlayHiddenFromScreenSharing },
                    set: { model.settings.overlayHiddenFromScreenSharing = $0
                           model.applyOverlayPreferences() }
                ))
                Text("Das Fenster erscheint dann nicht in geteilten Bildschirmen oder Aufnahmen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Originaltext unter der Übersetzung zeigen", isOn: $model.settings.showOriginalText)
                Toggle("Overlay beim Start einblenden", isOn: $model.settings.launchOverlayOnStart)

                VStack(alignment: .leading) {
                    Slider(value: Binding(
                        get: { model.settings.overlayOpacity },
                        set: { model.settings.overlayOpacity = $0; model.applyOverlayPreferences() }
                    ), in: 0.5...1.0) {
                        Text("Deckkraft")
                    }
                }
            }

            Section("Protokolle") {
                Toggle("Gespräche beim Stoppen lokal sichern", isOn: $model.settings.storeTranscripts)
                HStack {
                    Text("\(SessionArchive.listSessions().count) gesicherte Gespräche")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Im Finder zeigen") {
                        try? FileManager.default.createDirectory(
                            at: SessionArchive.directory, withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(SessionArchive.directory)
                    }
                }
            }

            Section("Tastenkürzel") {
                LabeledContent("Mithören an/aus", value: "⌥⌘L")
                LabeledContent("Overlay ein/aus", value: "⌥⌘O")
                LabeledContent("Jetzt antworten", value: "⌥⌘A")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Privacy

private struct PrivacyInfo: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Alles bleibt auf diesem Mac", systemImage: "lock.shield")
                    .font(.headline)

                bullet("Der Ton wird je nach Auswahl über ScreenCaptureKit oder einen Core-Audio-Tap direkt im System abgegriffen und nie auf die Festplatte geschrieben.")
                bullet("Die Spracherkennung läuft mit Apples geräteinternen Modellen – ohne Netzwerkverbindung.")
                bullet("Übersetzung, Frageerkennung und Antworten laufen über Ollama auf 127.0.0.1. Es gibt in dieser App keinen Code, der Gesprächsinhalte an eine andere Adresse sendet.")
                bullet("Ohne Internetverbindung funktioniert die App vollständig, sobald die Modelle einmal geladen sind.")
                bullet("Das Protokoll bleibt im Arbeitsspeicher; beim Stoppen wird es – sofern aktiviert – ausschließlich lokal in „Application Support/AlfredHelp/Protokolle“ abgelegt.")

                Divider()
                Text("Benötigte Berechtigungen")
                    .font(.headline)
                bullet("Audioaufnahme – für das Mithören des Systemtons.")
                bullet("Mikrofon – optional, nur für die eigene Gesprächsseite.")

                Divider()
                HStack(spacing: 6) {
                    Watermark(size: 11, opacity: 0.75)
                    Text("· \(Branding.appName) \(Branding.version)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·").foregroundStyle(.secondary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

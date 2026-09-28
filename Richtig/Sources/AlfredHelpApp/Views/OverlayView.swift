import SwiftUI
import AlfredHelpCore

struct OverlayView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        VStack(spacing: 0) {
            OverlayHeader(model: model)
            Divider().opacity(0.5)
            AdaptiveOverlayContent(model: model)
            if let status = model.pullStatus {
                ProgressView(status, value: model.pullFraction)
                    .progressViewStyle(.linear)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            if model.needsAudioPermission {
                PermissionBanner(model: model)
            }
            NoticeBar(model: model)
        }
        // An opaque base under the material: a live transcript has to stay
        // readable over whatever the meeting window is showing.
        .background {
            if reduceTransparency {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.80))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                )
        )
        .frame(minWidth: 380, minHeight: 280)
    }
}

private enum OverlayPane: String, CaseIterable, Identifiable {
    case transcript = "Gespräch"
    case answers = "Antworten"

    var id: Self { self }
}

/// At meeting-friendly widths both streams stay visible. As a narrow side
/// panel the overlay switches to one focused pane instead of squeezing both
/// until neither transcript nor answer remains readable.
private struct AdaptiveOverlayContent: View {
    @Bindable var model: AppModel
    @State private var selectedPane: OverlayPane = .answers
    @State private var hasUnseenAnswer = false
    @State private var transcriptFollowsLive = true
    @State private var transcriptHasUnseenContent = false
    @State private var answerBrowsingHistory = false
    @State private var answerPaneHasUnseenContent = false
    @State private var transcriptScrollPosition: TranscriptScrollTarget?
    @State private var answerScrollPosition: UUID?

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 700 {
                HSplitView {
                    PaneSection(
                        title: "Gespräch",
                        count: model.rows.count,
                        status: model.sessionState.isRunning ? "Live" : nil
                    ) {
                        TranscriptPane(
                            model: model,
                            isFollowingLive: $transcriptFollowsLive,
                            hasUnseenContent: $transcriptHasUnseenContent,
                            scrollPosition: $transcriptScrollPosition
                        )
                    }
                    .frame(minWidth: 300)

                    PaneSection(
                        title: "Antwortvorschläge",
                        count: model.answers.count,
                        status: model.answers.first.map { $0.isComplete ? nil : "Wird erstellt" } ?? nil
                    ) {
                        AnswerPane(
                            model: model,
                            isBrowsingHistory: $answerBrowsingHistory,
                            hasUnseenAnswer: $answerPaneHasUnseenContent,
                            scrollPosition: $answerScrollPosition
                        )
                    }
                    .frame(minWidth: 320)
                }
            } else {
                VStack(spacing: 0) {
                    Picker("Ansicht", selection: $selectedPane) {
                        Text("Gespräch (\(model.rows.count))").tag(OverlayPane.transcript)
                        Text(answerTabTitle).tag(OverlayPane.answers)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider().opacity(0.5)
                    if selectedPane == .transcript {
                        TranscriptPane(
                            model: model,
                            isFollowingLive: $transcriptFollowsLive,
                            hasUnseenContent: $transcriptHasUnseenContent,
                            scrollPosition: $transcriptScrollPosition
                        )
                    } else {
                        AnswerPane(
                            model: model,
                            isBrowsingHistory: $answerBrowsingHistory,
                            hasUnseenAnswer: $answerPaneHasUnseenContent,
                            scrollPosition: $answerScrollPosition
                        )
                    }
                }
            }
        }
        .onChange(of: model.answers.first?.id) { _, newValue in
            guard newValue != nil else {
                hasUnseenAnswer = false
                return
            }
            hasUnseenAnswer = selectedPane != .answers
        }
        .onChange(of: selectedPane) { _, pane in
            if pane == .answers { hasUnseenAnswer = false }
        }
    }

    private var answerTabTitle: String {
        let marker = hasUnseenAnswer ? " •" : ""
        return "Antworten (\(model.answers.count))\(marker)"
    }
}

private struct PaneSection<Content: View>: View {
    let title: String
    let count: Int
    let status: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.headline)
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let status {
                    Label(status, systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.bar.opacity(0.55))
            Divider().opacity(0.35)
            content
        }
    }
}

private struct OverlayHeader: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var confirmsReset = false
    @State private var copiedTranscript = false

    var body: some View {
        GeometryReader { geometry in
            controls(showTechnicalStatus: geometry.size.width >= 820)
        }
        .frame(height: 42)
        .confirmationDialog(
            "Gespräch wirklich zurücksetzen?",
            isPresented: $confirmsReset
        ) {
            Button("Gespräch zurücksetzen", role: .destructive, action: model.clearConversation)
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Transkript, Antworten und Gesprächsgedächtnis werden aus der aktuellen Ansicht entfernt.")
        }
    }

    private func controls(showTechnicalStatus: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                model.toggleSession()
            } label: {
                Label(
                    (model.sessionState.isStarting || model.isStartPending)
                        ? "Abbrechen"
                        : (model.sessionState.isRunning ? "Stopp" : "Start"),
                    systemImage: (model.sessionState.isRunning
                        || model.sessionState.isStarting
                        || model.isStartPending)
                        ? "stop.fill" : "play.fill"
                )
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint((model.sessionState.isRunning || model.sessionState.isStarting || model.isStartPending)
                ? .red : .accentColor)
            .disabled(model.isBusy && !(model.sessionState.isStarting || model.isStartPending))

            Pill(tint: sessionTint) {
                Image(systemName: sessionIcon)
                Text(sessionLabel)
            }
            .accessibilityLabel("Sitzungsstatus: \(sessionLabel)")

            if showTechnicalStatus, model.sessionState.systemAudioActive {
                Pill(tint: Theme.sourceColor(.system)) {
                    Image(systemName: "speaker.wave.2.fill")
                    LevelMeter(level: model.sessionState.systemLevel, tint: Theme.sourceColor(.system))
                }
                .help("Systemaudio von „\(model.sessionState.tappedDevice)“")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Systemaudio aktiv")
                .accessibilityValue("Pegel \(Int(model.sessionState.systemLevel * 100)) Prozent")
            }
            if showTechnicalStatus, model.sessionState.microphoneActive {
                Pill(tint: Theme.sourceColor(.microphone)) {
                    Image(systemName: "mic.fill")
                    LevelMeter(level: model.sessionState.microphoneLevel, tint: Theme.sourceColor(.microphone))
                }
                .help("Mikrofon")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Mikrofon aktiv")
                .accessibilityValue("Pegel \(Int(model.sessionState.microphoneLevel * 100)) Prozent")
            }

            Spacer(minLength: 8)

            if showTechnicalStatus { Watermark() }

            if showTechnicalStatus, let latency = model.medianAnswerLatency {
                Pill(tint: Theme.latencyColor(latency)) {
                    Image(systemName: "bolt.fill")
                    Text("\(latency) ms")
                }
                .help("Median: gesprochenes Satzende bis erstes Antwortwort")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Median-Antwortlatenz")
                .accessibilityValue("\(latency) Millisekunden")
            }

            if showTechnicalStatus {
                Pill(tint: model.ollamaReachable ? .secondary : .orange) {
                    Image(systemName: model.ollamaReachable ? "cpu" : "exclamationmark.triangle.fill")
                    Text(model.settings.qualityModel.isEmpty ? "kein Modell" : model.settings.qualityModel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 150)
                .help("Antwortmodell – läuft lokal über Ollama")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Antwortmodell")
                .accessibilityValue(model.settings.qualityModel.isEmpty
                                    ? "Kein Modell ausgewählt"
                                    : model.settings.qualityModel)
            }

            Button {
                model.answerNow()
            } label: {
                Image(systemName: "sparkles")
            }
            .buttonStyle(.borderless)
            // Derselbe Zustand wie der gleichnamige Menüpunkt. Dass beide
            // dasselbe auslösen, aber unterschiedlich aussahen, war für den
            // Nutzer nicht zu erklären.
            .disabled(!model.canAnswerNow)
            .help(answerButtonHelp)
            .accessibilityLabel("Antwort zur letzten Äußerung erzeugen")

            Menu {
                Button("Gespräch zurücksetzen") { confirmsReset = true }
                    .disabled(model.rows.isEmpty && model.answers.isEmpty)
                Button(copiedTranscript ? "Protokoll kopiert" : "Protokoll kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.transcriptMarkdown(), forType: .string)
                    copiedTranscript = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copiedTranscript = false
                    }
                }
                .disabled(model.rows.isEmpty)
                Divider()
                Toggle("Originaltext anzeigen", isOn: $model.settings.showOriginalText)
                Toggle("Vor Bildschirmfreigabe verbergen", isOn: Binding(
                    get: { model.settings.overlayHiddenFromScreenSharing },
                    set: { model.settings.overlayHiddenFromScreenSharing = $0; model.applyOverlayPreferences() }
                ))
                Divider()
                Button("Einstellungen …") { openSettings.bringToFront() }
                Button("Overlay ausblenden") { model.hideOverlay() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Weitere Aktionen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var sessionLabel: String {
        if model.sessionState.isStarting { return "Startet …" }
        if model.sessionState.isRunning { return "Hört zu" }
        return "Bereit"
    }

    private var sessionIcon: String {
        if model.sessionState.isStarting { return "hourglass" }
        if model.sessionState.isRunning { return "waveform" }
        return "pause.fill"
    }

    private var sessionTint: Color {
        if model.sessionState.isStarting { return .orange }
        if model.sessionState.isRunning { return .green }
        return .secondary
    }

    private var answerButtonHelp: String {
        if model.canAnswerNow { return "Antwort zur letzten Äußerung erzeugen (⌥⌘A)" }
        if !model.pendingAnswerIDs.isEmpty { return "Eine Antwort wird bereits erstellt" }
        if !model.sessionState.isRunning { return "Zuhören starten (⌥⌘L)" }
        if model.rows.isEmpty { return "Noch keine Äußerung erkannt" }
        if !model.ollamaReachable { return "Antwortmodell nicht erreichbar" }
        return "Antwort ist gerade nicht verfügbar"
    }
}

/// Erscheint, wenn der Tap läuft, aber stumm bleibt – der einzige Fall, in dem
/// der Nutzer selbst etwas tun muss.
private struct PermissionBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.slash")
            VStack(alignment: .leading, spacing: 1) {
                Text("Kein Systemton")
                    .font(.system(size: 12, weight: .semibold))
                Text(model.settings.systemAudioBackend == .processTap
                     ? "Spiele Systemton ab und prüfe die Freigabe unter Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme."
                     : "„AlfredHelp“ unter Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme aktivieren, danach neu starten.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Einrichten") { model.showOnboarding() }
                .controlSize(.small)
            Button("Erneut versuchen") { model.restartCapture() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.14))
    }
}

private struct NoticeBar: View {
    @Bindable var model: AppModel

    /// Was angezeigt wird, wenn mehreres ansteht.
    ///
    /// Nicht einfach das Jüngste: ein ungelöstes Problem – „Kein Systemton,
    /// Freigabe prüfen" – verschwand sonst, sobald irgendeine belanglose
    /// Meldung nachrückte. Der Nutzer saß dann im Gespräch vor einer stummen
    /// App ohne jeden Hinweis. Probleme haben deshalb Vorrang, solange sie
    /// stehen; unter gleichrangigen gewinnt weiterhin das Jüngste.
    private var current: Notice? {
        model.notices.last { $0.kind == .problem } ?? model.notices.last
    }

    var body: some View {
        if let notice = current {
            HStack(spacing: 6) {
                Image(systemName: notice.kind == .problem
                      ? "exclamationmark.triangle.fill" : "info.circle")
                Text(notice.text)
                    .lineLimit(2)
                Spacer()
                if notice.kind == .problem,
                   notice.text.localizedCaseInsensitiveContains("Ollama")
                    || notice.text.localizedCaseInsensitiveContains("Antwortmodell") {
                    Button("Erneut verbinden", action: model.retryModelConnection)
                        .controlSize(.small)
                        .disabled(model.isRecoveringModel)
                }
                Button {
                    model.dismissNotice(id: notice.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Hinweis schließen")
            }
            .font(.system(size: 11))
            .foregroundStyle(notice.kind == .problem ? Color.orange : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(notice.kind == .problem ? Color.orange.opacity(0.1) : Color.clear)
            .transition(.opacity)
        }
    }
}

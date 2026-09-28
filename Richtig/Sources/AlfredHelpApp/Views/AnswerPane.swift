import SwiftUI
import AlfredHelpCore

struct AnswerPane: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Binding var isBrowsingHistory: Bool
    @Binding var hasUnseenAnswer: Bool
    @Binding var scrollPosition: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.answers.isEmpty { emptyState.padding(.top, 34) }

                    ForEach(model.answers) { answer in
                        // Nur die oberste Karte darf sich melden. Wäre das an
                        // „ist neu" statt an der Position festgemacht, blitzte beim
                        // Zurückscrollen jede Karte erneut auf.
                        AnswerCardView(
                            answer: answer,
                            isNewest: answer.id == model.answers.first?.id,
                            phase: model.answerPhases[answer.id] ?? .complete,
                            retryDisabled: !model.pendingAnswerIDs.isEmpty,
                            onRetry: { model.retryAnswer(answer) }
                        )
                        .id(answer.id)
                    }

                    if !model.memory.isEmpty {
                        MemoryCard(memory: model.memory)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: model.answers.map(\.id))
            }
            .scrollPosition(id: $scrollPosition)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { isBrowsingHistory = true }
            }
            .onChange(of: model.answers.first?.id) { _, id in
                guard id != nil else {
                    hasUnseenAnswer = false
                    scrollPosition = nil
                    return
                }
                if isBrowsingHistory || voiceOverEnabled {
                    hasUnseenAnswer = true
                } else {
                    showNewest(proxy)
                }
            }
            .overlay(alignment: .topTrailing) {
                if hasUnseenAnswer {
                    Button("Neue Antwort") { showNewest(proxy) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(10)
                        .accessibilityHint("Springt zur neuesten Antwort")
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 10) {
            EmptyHint(icon: emptyIcon, title: emptyTitle, detail: emptyDetail)
            if !model.sessionState.isRunning && !model.sessionState.isStarting {
                Button("Zuhören starten", action: model.toggleSession)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
            } else if !model.ollamaReachable {
                Button("Antwortmodell erneut verbinden", action: model.retryModelConnection)
                    .buttonStyle(.bordered)
                    .disabled(model.isRecoveringModel)
            } else if model.canAnswerNow {
                Button("Letzte Äußerung beantworten", action: model.answerNow)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var emptyIcon: String {
        if model.sessionState.isStarting { return "hourglass" }
        if !model.sessionState.isRunning { return "pause.circle" }
        if !model.ollamaReachable { return "exclamationmark.triangle" }
        return "waveform.badge.magnifyingglass"
    }

    private var emptyTitle: String {
        if model.sessionState.isStarting { return "Zuhören wird gestartet" }
        if !model.sessionState.isRunning { return "Bereit für das Gespräch" }
        if !model.ollamaReachable { return "Antwortmodell nicht erreichbar" }
        return "Warte auf eine Frage"
    }

    private var emptyDetail: String {
        if model.sessionState.isStarting { return "Audioquellen und lokale Modelle werden vorbereitet." }
        if !model.sessionState.isRunning { return "Nach dem Start erscheinen erkannte Fragen und Antwortvorschläge hier." }
        if !model.ollamaReachable { return "Die Transkription läuft weiter. Verbinde das lokale Modell erneut, um Antworten zu erzeugen." }
        return "Erkannte Fragen erscheinen automatisch. Eine übersehene Frage lässt sich links an der Sprechblase beantworten."
    }

    private func showNewest(_ proxy: ScrollViewProxy) {
        guard let newest = model.answers.first else { return }
        hasUnseenAnswer = false
        isBrowsingHistory = false
        if reduceMotion {
            proxy.scrollTo(newest.id, anchor: .top)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(newest.id, anchor: .top)
            }
        }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(newest.id, anchor: .top)
        }
    }
}

private struct AnswerCardView: View {
    let answer: AnswerCard
    /// Steht diese Karte gerade oben? Nur dann wird sie kurz hervorgehoben.
    var isNewest = false
    let phase: AnswerPhase
    let retryDisabled: Bool
    let onRetry: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var showsDetails = false
    /// Blendet nach kurzer Zeit von selbst wieder ab. Ein Rahmen, der bleibt,
    /// wäre nach der dritten Frage nur noch Dekoration.
    @State private var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: answer.wasManuallyTriggered ? "hand.tap.fill" : "questionmark.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
                Text(answer.question)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if let latency = answer.timeToFirstWordMilliseconds {
                    Text("\(latency) ms")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.latencyColor(latency))
                        .help("Vom Satzende bis zum ersten Antwortwort")
                }
            }

            if answer.text.isEmpty && !answer.isComplete {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(phase == .refining
                         ? "Frage präzisiert – Antwort wird neu erstellt …"
                         : "Antwort wird erstellt …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                // Der Satz zum Vorlesen – bewusst größer als alles andere auf
                // der Karte, weil er im Gespräch abgelesen wird.
                Text(answer.text)
                    .font(.system(size: 15, weight: .medium))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if answer.isComplete && answer.confidence == .low {
                Label("Unsichere Grundlage", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .help("Für eine sichere Antwort fehlen Angaben aus dem Gespräch oder Nutzerprofil.")
            }

            if !answer.details.isEmpty || !answer.missingContext.isEmpty {
                DisclosureGroup(isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !answer.details.isEmpty {
                            Text(answer.details)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !answer.missingContext.isEmpty {
                            Text("Fehlende Angaben")
                                .font(.caption.weight(.semibold))
                            ForEach(answer.missingContext, id: \.self) { item in
                                Text("• \(item)")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(showsDetails ? "Weniger" : "Details & fehlende Angaben")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)
            }

            if let error = answer.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Erneut versuchen", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(retryDisabled)
                        .help(retryDisabled
                              ? "Zuerst die laufende Antwort abwarten"
                              : "Diese Frage erneut beantworten")
                }
            }

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    // Kopiert wird der vorlesbare Satz, nicht der Hintergrund.
                    NSPasteboard.general.setString(answer.text, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Kopiert" : "Antwort kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(answer.text.isEmpty)

                if let speed = answer.tokensPerSecond, speed > 0 {
                    Text("\(Int(speed)) Tok/s")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("Original: \(answer.spoken)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .cardBackground()
        // Ein Akzentrahmen für zwei Sekunden. Kein Ton, kein Aufblitzen: die
        // App läuft während einer Besprechung und darf den Nutzer nicht
        // erschrecken – sie muss ihn nur darauf stoßen, dass etwas Neues da ist.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .opacity(highlighted ? 1 : 0)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.45), value: highlighted)
        .task(id: answer.id) {
            guard isNewest else { return }
            highlighted = true
            try? await Task.sleep(for: .seconds(2))
            highlighted = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Antwortvorschlag")
    }

}

private struct MemoryCard: View {
    let memory: MemorySnapshot
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if reduceMotion {
                    expanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain")
                        .font(.system(size: 11))
                    Text("Gesprächsgedächtnis")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            if expanded {
                if !memory.summary.isEmpty {
                    Text(memory.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !memory.keyPoints.isEmpty {
                    BulletList(title: "Kernpunkte", items: memory.keyPoints)
                }
                if !memory.openPoints.isEmpty {
                    BulletList(title: "Offen", items: memory.openPoints)
                }
            } else if !memory.openPoints.isEmpty {
                Text("\(memory.openPoints.count) offene Punkte")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .cardBackground()
    }
}

private struct BulletList: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 4) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(item)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

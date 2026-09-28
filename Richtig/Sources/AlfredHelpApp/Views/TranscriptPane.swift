import SwiftUI
import AlfredHelpCore

enum TranscriptScrollTarget: Hashable {
    case row(UUID)
    case liveEnd
}

struct TranscriptPane: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Live-Folgen ist ein ausdrücklicher Zustand. Sobald der Nutzer scrollt
    /// oder neue Inhalte während einer Interaktion eintreffen, bleibt seine
    /// Position stabil, bis er selbst wieder ans Ende springt.
    @Binding var isFollowingLive: Bool
    @Binding var hasUnseenContent: Bool
    @Binding var scrollPosition: TranscriptScrollTarget?

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.rows.isEmpty && livePartials.isEmpty {
                            EmptyHint(
                                icon: "waveform",
                                title: "Noch nichts gehört",
                                detail: model.sessionState.isRunning
                                    ? "Sobald jemand spricht, erscheint hier die Transkription."
                                    : "Auf Start drücken, dann läuft alles mit – egal aus welcher App der Ton kommt."
                            )
                            .padding(.top, 40)
                        }

                        ForEach(model.rows) { row in
                            TranscriptRowView(
                                row: row,
                                showOriginal: model.settings.showOriginalText,
                                isAnswerPending: model.pendingAnswerIDs.contains(row.id),
                                isAnswerBlocked: !model.pendingAnswerIDs.isEmpty,
                                // Nur die Gegenseite: ein Klick behandelt die Zeile
                                // als Frage, falls die Erkennung sie übersehen hat.
                                onAnswer: row.source == .system
                                    ? { model.answerUtterance(row.id) }
                                    : nil
                            )
                            .id(TranscriptScrollTarget.row(row.id))
                        }

                        // Systemaudio und Mikrofon können gleichzeitig volatile
                        // Texte liefern. Beide bleiben sichtbar, statt dass die
                        // feste Quellenreihenfolge einen davon verschluckt.
                        ForEach(livePartials, id: \.source) { partial in
                            LivePartialView(text: partial.text, source: partial.source)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(TranscriptScrollTarget.liveEnd)
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 10)
                }
                .scrollPosition(id: $scrollPosition)
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting {
                        isFollowingLive = false
                    }
                }

                if !isFollowingLive {
                    Button {
                        isFollowingLive = true
                        hasUnseenContent = false
                        scrollToEndAfterLayout(proxy, animated: true)
                    } label: {
                        Label(
                            hasUnseenContent ? "Neue Inhalte – zum Live-Gespräch" : "Zum Live-Gespräch",
                            systemImage: hasUnseenContent ? "arrow.down.circle.fill" : "arrow.down.circle"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(10)
                    .help("Ans Ende springen und neuen Aussagen wieder automatisch folgen")
                    .accessibilityLabel(hasUnseenContent
                        ? "Neue Gesprächsinhalte. Zum Live-Gespräch springen"
                        : "Zum Live-Gespräch springen")
                }
            }
            .onChange(of: model.rows.count) { previous, current in
                if current == 0 {
                    isFollowingLive = true
                    hasUnseenContent = false
                    scrollPosition = nil
                    return
                }
                guard current > previous else { return }
                handleNewContent(proxy, animated: true)
                // Der neue untere Anker nimmt seine Position erst in der
                // nächsten Layoutrunde ein. Der zweite Sprung verhindert, dass
                // gerade die neueste Zeile knapp unter dem Fenster bleibt.
                if isFollowingLive {
                    scrollToEndAfterLayout(proxy, animated: true)
                }
            }
            .onChange(of: livePartialTexts) { previous, current in
                // Teilerkennung ändert sich mehrmals pro Sekunde. Laufendes
                // Folgen bleibt deshalb ohne Animation; Reduce Motion gilt
                // zusätzlich für alle ausdrücklichen Sprünge.
                guard current.contains(where: { !$0.isEmpty }) else { return }
                handleNewContent(proxy, animated: false)
                if previous.allSatisfy(\.isEmpty), current.contains(where: { !$0.isEmpty }), isFollowingLive {
                    scrollToEndAfterLayout(proxy, animated: false)
                }
            }
        }
        .background(.clear)
    }

    private var livePartials: [(source: AudioSourceKind, text: String)] {
        AudioSourceKind.allCases.compactMap { source in
            guard let text = model.partials[source], !text.isEmpty else { return nil }
            return (source, text)
        }
    }

    private var livePartialTexts: [String] {
        AudioSourceKind.allCases.map { model.partials[$0] ?? "" }
    }

    private func handleNewContent(_ proxy: ScrollViewProxy, animated: Bool) {
        if voiceOverEnabled {
            isFollowingLive = false
            hasUnseenContent = true
            return
        }
        guard isFollowingLive else {
            isFollowingLive = false
            hasUnseenContent = true
            return
        }
        scrollToEnd(proxy, animated: animated)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        let scroll = { proxy.scrollTo(TranscriptScrollTarget.liveEnd, anchor: .bottom) }
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.18), scroll)
        } else {
            scroll()
        }
    }

    /// Dasselbe eine Layoutrunde später – für Inhalte, die es im Moment des
    /// `onChange` noch gar nicht auf dem Bildschirm gibt.
    private func scrollToEndAfterLayout(_ proxy: ScrollViewProxy, animated: Bool) {
        Task { @MainActor in
            await Task.yield()
            guard isFollowingLive else { return }
            scrollToEnd(proxy, animated: animated)
        }
    }
}

private struct TranscriptRowView: View {
    let row: TranscriptRow
    let showOriginal: Bool
    let isAnswerPending: Bool
    let isAnswerBlocked: Bool
    /// Vorhanden bei Zeilen der Gegenseite: beantwortet die Äußerung auf Klick
    /// als Frage – ohne Veto durch Heuristik oder Klassifikator.
    let onAnswer: (() -> Void)?

    @State private var hovering = false
    @State private var asked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.sourceColor(row.source))
                    .frame(width: 6, height: 6)
                Text(row.source.speakerLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.sourceColor(row.source))
                Text(row.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if row.isTranslating {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .accessibilityLabel("Übersetzung wird erstellt")
                }
                if onAnswer != nil {
                    Spacer(minLength: 4)
                    Button(action: triggerAnswer) {
                        Group {
                            if isAnswerPending {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: asked ? "checkmark.circle.fill" : "questionmark.bubble")
                                    .foregroundStyle(askButtonColor)
                            }
                        }
                        .font(.body)
                        // Das Symbol ist als Ziel zu klein, wenn der Verlauf
                        // mitläuft. Die Trefferfläche bleibt deshalb größer.
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isAnswerBlocked || asked)
                    .help(isAnswerPending
                        ? "Für diese Äußerung wird bereits eine Antwort erstellt"
                        : (isAnswerBlocked
                           ? "Zuerst die laufende Antwort abwarten"
                        : "Als Frage beantworten – falls die automatische Erkennung sie übersehen hat")
                    )
                    .accessibilityLabel(isAnswerPending
                        ? "Antwort wird bereits erstellt"
                        : (isAnswerBlocked ? "Eine andere Antwort wird gerade erstellt"
                        : "Diese Äußerung als Frage beantworten")
                    )
                }
            }

            Text(row.german ?? row.original)
                .font(.body)
                .textSelection(.enabled)
                .foregroundStyle(.primary)

            if showOriginal, let german = row.german, german != row.original {
                Text(row.original)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            (hovering && onAnswer != nil) ? Color.primary.opacity(0.05) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if let onAnswer {
                Button("Als Frage beantworten", action: { triggerAnswer(onAnswer) })
                    .disabled(isAnswerBlocked)
            }
            Button("Text kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.german ?? row.original, forType: .string)
            }
        }
    }

    private var askButtonColor: Color {
        if asked { return .green }
        return hovering ? Color.accentColor : Color.secondary.opacity(0.45)
    }

    private func triggerAnswer() {
        guard let onAnswer else { return }
        triggerAnswer(onAnswer)
    }

    /// Kurze Bestätigung am Knopf – die Antwortkarte selbst erscheint rechts.
    private func triggerAnswer(_ action: () -> Void) {
        guard !isAnswerBlocked, !asked else { return }
        action()
        asked = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            asked = false
        }
    }
}

private struct LivePartialView: View {
    let text: String
    let source: AudioSourceKind

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(Theme.sourceColor(source))
                .frame(width: 6, height: 6)
                .padding(.top, 6)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .italic()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vorläufig, \(source.speakerLabel): \(text)")
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

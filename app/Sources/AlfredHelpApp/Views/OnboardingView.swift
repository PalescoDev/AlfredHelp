import SwiftUI
import AppKit
import AVFoundation
import AlfredHelpCore

/// First-run flow. AlfredHelp cannot capture a single sample until macOS has been
/// asked, and macOS only shows that dialog to a running app with a window — so
/// this screen exists, and it verifies the result instead of assuming it.
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                // Ganz oben, weil es das Einzige ist, worauf gerade gewartet
                // wird: ohne Ollama und Modell nützt jede Freigabe nichts.
                if let progress = model.setupProgress {
                    SetupProgressCard(progress: progress)
                }

                PermissionRow(
                    icon: "speaker.wave.3.fill",
                    title: "Systemton mitschneiden",
                    detail: model.settings.systemAudioBackend == .screenCapture
                        ? "Damit AlfredHelp den Ton aus Teams, Zoom, dem Browser und anderen Apps hört. macOS verwaltet die Freigabe unter „Bildschirm- & Systemaudioaufnahme“."
                        : "Damit AlfredHelp den Ton anderer Apps hört. Core Audio kann die Freigabe nicht vorab prüfen; spiele für den Test Systemton ab.",
                    state: model.systemAudioPermission,
                    actionTitle: model.settings.systemAudioBackend == .screenCapture
                        && SystemAudioPermission.hasRequested
                        ? "Systemeinstellungen"
                        : model.settings.systemAudioBackend == .processTap ? "Ton prüfen" : "Erlauben",
                    action: { model.requestSystemAudioPermission() },
                    settingsAction: { model.openAudioPrivacySettings() }
                )

                PermissionRow(
                    icon: "mic.fill",
                    title: "Mikrofon (optional)",
                    detail: "Nur für die eigene Gesprächsseite. Auf eigene Fragen antwortet AlfredHelp nicht.",
                    state: model.microphonePermission,
                    action: { model.requestMicrophonePermission() },
                    settingsAction: nil
                )

                Divider()
                ModelPickerView(model: model, showsHeader: true)

                if SystemAudioPermission.isAdHocSigned {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "signature")
                        Text("Diese Ausgabe ist ohne Entwicklerzertifikat signiert. macOS bindet die Freigabe an die Prüfsumme des Programms – nach jedem Neubau muss sie erneut erteilt werden. Wie sich das dauerhaft lösen lässt, steht in der README.")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .cardBackground()
                }

                if case .silent = model.systemAudioPermission {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                        Text("Es wurde kein Systemton erkannt. Spiele Ton ab und prüfe erneut. Beim Core-Audio-Tap kann AlfredHelp die Freigabe nicht vorab bestätigen.")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .cardBackground()
                }
              }
              .padding(16)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 720)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AlfredHelp einrichten")
                    .font(.system(size: 15, weight: .semibold))
                Text("Freigabe erteilen, Modell wählen – danach läuft alles von selbst und vollständig lokal.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            Watermark(size: 10, opacity: 0.5)
            Divider().frame(height: 12)
            Button("Erneut prüfen") { model.verifySystemAudio() }
                .disabled(model.isVerifyingAudio)
            if model.isVerifyingAudio {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("höre 4 Sekunden mit …")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Was noch fehlt, steht direkt neben dem grauen Knopf. Vorher war
            // nur der Knopf grau, und der Grund dafür stand – wenn überhaupt –
            // weiter oben in einer der Zeilen. Wer die Freigabe gerade erteilt
            // hatte und auf den Neustart wartete, sah bloß, dass es nicht
            // weitergeht.
            if let missing = blockingStep {
                Text(missing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Button("Später") { dismiss() }
            Button("Fertig") { dismiss() }
                .buttonStyle(.borderedProminent)
                .disabled(blockingStep != nil)
                .accessibilityHint(blockingStep ?? "")
        }
        .padding(16)
    }

    /// Der eine Schritt, der „Fertig“ gerade noch im Weg steht – oder `nil`,
    /// wenn alles beisammen ist. Reihenfolge nach Aufwand: die Freigabe
    /// zuerst, weil sie ohne die App gar nicht zu erteilen ist.
    private var blockingStep: String? {
        if !model.systemAudioPermission.isUsable {
            return model.settings.systemAudioBackend == .processTap
                ? "Noch offen: Systemton abspielen und prüfen"
                : "Noch offen: Freigabe für den Systemton"
        }
        if model.settings.qualityModel.isEmpty {
            return "Noch offen: ein Antwortmodell auswählen"
        }
        return nil
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let state: PermissionState
    var actionTitle = "Erlauben"
    let action: () -> Void
    let settingsAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(state.tint)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(state.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(state.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(state.tint)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            VStack(spacing: 4) {
                if !state.isUsable {
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
                if let settingsAction, !state.isUsable, actionTitle != "Systemeinstellungen" {
                    Button("Einstellungen", action: settingsAction)
                        .controlSize(.small)
                        .buttonStyle(.link)
                }
            }
        }
        .padding(12)
        .cardBackground()
    }
}

/// Display state for one permission.
enum PermissionState: Equatable {
    case unknown
    case granted
    case working(peak: Float)
    case silent
    case denied

    var isUsable: Bool {
        switch self {
        case .granted, .working: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .unknown: return "ungeprüft"
        case .granted: return "Freigabe erteilt"
        case .working(let peak): return String(format: "geprüft · Pegel %.2f", peak)
        case .silent: return "Kein Signal erkannt"
        case .denied: return "fehlt"
        }
    }

    var tint: Color {
        switch self {
        case .working, .granted: return .green
        case .silent: return .orange
        case .denied: return .red
        case .unknown: return .secondary
        }
    }
}

@MainActor
final class OnboardingWindowController {
    private let panel: NSPanel

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 720),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "AlfredHelp einrichten"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.contentView = NSHostingView(rootView: OnboardingView(model: model))
    }

    func show() {
        // Auch das Einrichtungsfenster gehört niemandem außer dem Nutzer.
        panel.sharingType = .none
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel.orderOut(nil)
    }
}

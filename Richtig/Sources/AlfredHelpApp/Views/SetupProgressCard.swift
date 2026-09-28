import SwiftUI
import AlfredHelpCore

/// Zeigt, was die Ersteinrichtung gerade beschafft.
///
/// Der Nutzer muss dafür nichts tun – die Karte ist reine Auskunft. Sie
/// erscheint nur, solange wirklich etwas läuft, und verschwindet danach
/// rückstandslos.
struct SetupProgressCard: View {
    let progress: SetupProgress

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(progress.title)
                        .font(.system(size: 12, weight: .medium))
                    Text("Schritt \(progress.step) von \(progress.stepCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                if progress.hasFraction {
                    ProgressView(value: min(max(progress.fraction, 0), 1))
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                if !progress.detail.isEmpty {
                    Text(progress.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .cardBackground()
    }
}

/// Einzeiler für Menüs und Fußzeilen.
extension SetupProgress {
    var menuLine: String {
        let percent = hasFraction ? " \(Int((fraction * 100).rounded())) %" : ""
        return detail.isEmpty ? "\(title)\(percent) …" : "\(title)\(percent) – \(detail)"
    }
}

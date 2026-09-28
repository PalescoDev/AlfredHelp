import SwiftUI
import AlfredHelpCore

enum Theme {
    static let corner: CGFloat = 14
    static let cardCorner: CGFloat = 11

    static func sourceColor(_ source: AudioSourceKind) -> Color {
        switch source {
        case .system: return Color(nsColor: .systemTeal)
        case .microphone: return Color(nsColor: .systemPurple)
        }
    }

    static func latencyColor(_ milliseconds: Int) -> Color {
        switch milliseconds {
        case ..<1200: return .green
        case ..<2500: return .yellow
        default: return .orange
        }
    }
}

/// A small rounded label used for status in the overlay header.
struct Pill<Content: View>: View {
    var tint: Color = .secondary
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 5) { content }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(pillBackground, in: Capsule())
            .overlay {
                if colorSchemeContrast == .increased {
                    Capsule().strokeBorder(tint, lineWidth: 1)
                }
            }
            .foregroundStyle(tint)
    }

    private var pillBackground: Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        return tint.opacity(colorSchemeContrast == .increased ? 0.28 : 0.14)
    }
}

/// Horizontal audio level meter.
struct LevelMeter: View {
    let level: Float
    let tint: Color
    var width: CGFloat = 46
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(colorSchemeContrast == .increased ? 0.38 : 0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * CGFloat(scaled))
            }
        }
        .frame(width: width, height: 4)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
    }

    /// Amplitude is perceptually useless on a linear axis – map to decibels.
    private var scaled: Double {
        guard level > 0.0005 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(1, max(0, (decibels + 60) / 60))
    }
}

extension View {
    func cardBackground(_ corner: CGFloat = Theme.cardCorner) -> some View {
        modifier(CardBackgroundModifier(corner: corner))
    }
}

private struct CardBackgroundModifier: ViewModifier {
    let corner: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        content
            .background(background, in: RoundedRectangle(cornerRadius: corner))
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .strokeBorder(
                        Color(nsColor: .separatorColor),
                        lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
                    )
            )
    }

    private var background: Color {
        if reduceTransparency {
            return Color(nsColor: .controlBackgroundColor)
        }
        return .primary.opacity(colorSchemeContrast == .increased ? 0.12 : 0.06)
    }
}

/// Das Wasserzeichen. Bewusst zurückhaltend: es soll die Herkunft zeigen,
/// nicht vom Gespräch ablenken.
struct Watermark: View {
    var size: CGFloat = 9
    var opacity: Double = 0.38
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: size - 1, weight: .semibold))
            Text(Branding.watermark)
                .font(.system(size: size, weight: .medium, design: .rounded))
                .kerning(0.2)
        }
        .foregroundStyle(.secondary)
        .opacity(colorSchemeContrast == .increased ? max(opacity, 0.72) : opacity)
        .accessibilityLabel("Erstellt von \(Branding.watermark)")
    }
}

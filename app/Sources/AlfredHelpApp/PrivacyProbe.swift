import AppKit
import ScreenCaptureKit
import AlfredHelpCore

/// `AlfredHelp --privacy-check`
///
/// Beantwortet mit Pixeln statt mit Zusicherungen: **landet ein Fenster von
/// AlfredHelp in einer Bildschirmaufnahme?**
///
/// Aufgenommen wird über ScreenCaptureKit – der Weg, den Teams, Zoom, Discord
/// und jede Aufnahmesoftware unter aktuellem macOS gehen.
///
/// Der Test hat bewusst zwei Durchgänge. Zuerst mit einem normalen Fenster:
/// erscheint es nicht in der Aufnahme, taugt der Test nichts und würde alles
/// durchwinken. Erst wenn die Gegenprobe anschlägt, ist der zweite Durchgang mit
/// `sharingType = .none` aussagekräftig.
///
/// Dass `SCShareableContent` ein Fenster *auflistet*, sagt übrigens nichts – erst
/// der Bildinhalt entscheidet. Genau deshalb wird hier gerechnet und nicht
/// aufgezählt.
@MainActor
enum PrivacyProbe {

    private static let probeFrame = NSRect(x: 120, y: 120, width: 620, height: 420)

    static func run() async -> Int32 {
        print("AlfredHelp – Prüfung der Bildschirmfreigabe")
        print(String(repeating: "═", count: 72))

        let store = SettingsStore()
        print("Einstellung „Vor Bildschirmfreigabe verbergen“: "
              + (store.settings.overlayHiddenFromScreenSharing ? "an" : "aus"))

        reportRunningWindows()

        guard let display = try? await firstDisplay() else {
            print("\nKein Bildschirm über ScreenCaptureKit erreichbar – ist die "
                  + "Bildschirmaufnahme für AlfredHelp freigegeben?")
            return 1
        }

        let window = makeProbeWindow()
        defer { window.orderOut(nil) }

        // Ausgangsbild ohne Prüffenster.
        window.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(600))
        guard let baseline = await capture(display) else {
            print("\nAufnahme fehlgeschlagen.")
            return 1
        }

        print("\n" + String(repeating: "─", count: 72))
        print("Durchgang 1 – Gegenprobe: normales Fenster, muss sichtbar sein")
        window.sharingType = .readOnly
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(700))
        let controlDifference = await differenceAgainst(baseline, display: display)
        print(String(format: "  Abweichung im Fensterbereich: %.2f %%", controlDifference * 100))

        guard controlDifference >= 0.10 else {
            print("\n  Die Gegenprobe schlägt nicht an – die Aufnahme sieht selbst ein")
            print("  normales Fenster nicht. Damit ist keine Aussage möglich.")
            return 1
        }
        print("  ✓ Die Aufnahme sieht normale Fenster. Der Test funktioniert.")

        print("\nDurchgang 2 – dieselbe Stelle mit sharingType = .none")
        window.sharingType = .none
        try? await Task.sleep(for: .milliseconds(700))
        let protectedDifference = await differenceAgainst(baseline, display: display)
        print(String(format: "  Abweichung im Fensterbereich: %.2f %%", protectedDifference * 100))

        print(String(repeating: "═", count: 72))
        if protectedDifference < 0.01 {
            print("ERGEBNIS: Nur du siehst es.")
            print("Das Fenster stand während der Aufnahme auf dem Bildschirm; die")
            print("Aufnahme zeigt an dieser Stelle exakt dasselbe wie ohne das Fenster.")
            print("Dasselbe Verfahren schützt jedes Fenster von AlfredHelp, solange")
            print("„Vor Bildschirmfreigabe verbergen“ aktiv ist.")
            return 0
        }
        print("ERGEBNIS: Das Fenster wäre in einer Aufnahme sichtbar.")
        return 1
    }

    // MARK: - Prüffenster

    private static func makeProbeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: probeFrame,
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = .floating
        window.isOpaque = true
        // Kräftige Farbe: eine Abweichung wäre unübersehbar.
        window.backgroundColor = NSColor(calibratedRed: 1, green: 0, blue: 0.6, alpha: 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return window
    }

    /// Zeigt, wie die tatsächlich laufenden Fenster eingestellt sind.
    private static func reportRunningWindows() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }
        let mine = list.filter {
            ($0[kCGWindowOwnerName as String] as? String)?.contains("AlfredHelp") == true
        }
        guard !mine.isEmpty else {
            print("\nGerade kein AlfredHelp-Fenster offen – geprüft wird nur der Mechanismus.")
            return
        }
        print("\nOffene Fenster von AlfredHelp:")
        for entry in mine {
            let name = (entry[kCGWindowName as String] as? String) ?? "Overlay"
            let sharing = entry[kCGWindowSharingState as String] as? Int ?? -1
            print("  · \(name.isEmpty ? "Overlay" : name): sharingType=\(sharing) "
                  + (sharing == 0 ? "(geschützt)" : "(NICHT geschützt)"))
        }
    }

    // MARK: - Aufnahme und Vergleich

    private static func firstDisplay() async throws -> SCDisplay? {
        try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        ).displays.first
    }

    private static func capture(_ display: SCDisplay) async -> CGImage? {
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        return try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
    }

    private static func differenceAgainst(_ baseline: CGImage, display: SCDisplay) async -> Double {
        guard let current = await capture(display) else { return 1 }
        return differingPixelShare(baseline, current, display: display)
    }

    /// Anteil abweichender Bildpunkte im Bereich des Prüffensters.
    private static func differingPixelShare(
        _ first: CGImage, _ second: CGImage, display: SCDisplay
    ) -> Double {
        let scale = Double(first.width) / Double(display.width)
        // Fensterkoordinaten zählen von unten, Bildkoordinaten von oben.
        let flippedY = Double(display.height) - Double(probeFrame.maxY)
        let cropped = CGRect(
            x: Double(probeFrame.origin.x) * scale,
            y: flippedY * scale,
            width: Double(probeFrame.width) * scale,
            height: Double(probeFrame.height) * scale
        ).intersection(CGRect(x: 0, y: 0, width: first.width, height: first.height))

        guard cropped.width > 4, cropped.height > 4,
              let a = first.cropping(to: cropped), let b = second.cropping(to: cropped),
              let pixelsA = pixels(of: a), let pixelsB = pixels(of: b),
              pixelsA.count == pixelsB.count, !pixelsA.isEmpty else { return 1 }

        var differing = 0, total = 0, index = 0
        while index + 3 < pixelsA.count {
            let delta = abs(Int(pixelsA[index]) - Int(pixelsB[index]))
                + abs(Int(pixelsA[index + 1]) - Int(pixelsB[index + 1]))
                + abs(Int(pixelsA[index + 2]) - Int(pixelsB[index + 2]))
            if delta > 24 { differing += 1 }
            total += 1
            index += 16
        }
        return total == 0 ? 1 : Double(differing) / Double(total)
    }

    private static func pixels(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

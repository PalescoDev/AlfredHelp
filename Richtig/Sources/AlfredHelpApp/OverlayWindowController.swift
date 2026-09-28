import AppKit
import SwiftUI

/// A floating panel that stays above the meeting window without ever taking
/// focus away from it.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayWindowController: NSObject {

    private let panel: OverlayPanel
    private let model: AppModel
    private static let frameKey = "io.github.fvulcan.alfredhelp.overlay.frame"

    init(model: AppModel) {
        self.model = model

        panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AlfredHelp"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .managed]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.minSize = NSSize(width: 380, height: 280)

        super.init()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting

        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            panel.setFrame(clampedFrame(NSRectFromString(saved)), display: false)
        } else {
            positionAtBottomRight()
        }
        applyPreferences()
    }

    func show() {
        panel.setFrame(clampedFrame(panel.frame), display: false)
        panel.orderFrontRegardless()
        applyPreferences()
    }

    func hide() {
        saveFrame()
        panel.orderOut(nil)
    }

    /// Applies the settings that affect the window itself rather than its
    /// contents.
    func applyPreferences() {
        panel.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            ? 1
            : CGFloat(model.settings.overlayOpacity)
        // Keeping the assistant out of screen shares is the whole point of a
        // panel like this during a Teams or Zoom call.
        panel.sharingType = model.settings.overlayHiddenFromScreenSharing ? .none : .readOnly
    }

    private func positionAtBottomRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.minY + 24
        ))
    }

    /// Restores a useful frame even after a monitor was disconnected or its
    /// resolution changed. Prefer the screen containing most of the old frame;
    /// if it is entirely off-screen, use the current main screen.
    private func clampedFrame(_ frame: NSRect) -> NSRect {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite,
              frame.width > 0, frame.height > 0,
              !NSScreen.screens.isEmpty
        else {
            return panel.frame
        }

        let bestIntersectingScreen = NSScreen.screens.max { left, right in
            intersectionArea(frame, left.visibleFrame) < intersectionArea(frame, right.visibleFrame)
        }
        let targetScreen: NSScreen
        if let bestIntersectingScreen,
           intersectionArea(frame, bestIntersectingScreen.visibleFrame) > 0 {
            targetScreen = bestIntersectingScreen
        } else {
            targetScreen = NSScreen.main ?? NSScreen.screens[0]
        }
        let visible = targetScreen.visibleFrame
        let width = min(max(frame.width, panel.minSize.width), visible.width)
        let height = min(max(frame.height, panel.minSize.height), visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        applyPreferences()
    }

    @objc private func screenParametersDidChange() {
        panel.setFrame(clampedFrame(panel.frame), display: true)
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }
}

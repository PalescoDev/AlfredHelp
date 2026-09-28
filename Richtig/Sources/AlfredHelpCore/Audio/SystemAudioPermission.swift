import Foundation
import CoreGraphics
import AVFoundation
import Security

/// Persists whether the app has already called macOS's ScreenCapture request API.
/// The OS owns the actual decision; this gate prevents repeated requests and
/// remains testable without opening a system dialog.
final class ScreenCapturePermissionRequestGate: @unchecked Sendable {
    // Several UI actions may race (and tests deliberately create several gate
    // instances). UserDefaults has no compare-and-set operation, so serialize
    // the read/write pair across every gate in this process.
    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "io.github.PalescoDev.alfredhelp.screenCaptureRequestAttempted.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    var hasRequested: Bool {
        Self.lock.withLock { defaults.bool(forKey: key) }
    }

    func request(_ action: () -> Bool) -> Bool {
        let firstAttempt = Self.lock.withLock { () -> Bool in
            guard !defaults.bool(forKey: key) else { return false }
            defaults.set(true, forKey: key)
            return true
        }
        guard firstAttempt else { return false }
        return action()
    }

    func markAlreadyGranted() {
        Self.lock.withLock { defaults.set(true, forKey: key) }
    }
}

/// Everything the app needs to know and do about system audio capture access.
public enum SystemAudioPermission {

    private static let screenCaptureRequestGate = ScreenCapturePermissionRequestGate()

    public enum State: Sendable, Equatable {
        /// This check cannot determine the permission state, for example
        /// because the backend has no preflight or capture failed to start.
        case undetermined
        /// Capture delivered audible samples.
        case working(peak: Float)
        /// No audible samples arrived. This is not proof of a denied grant:
        /// the output may be silent, idle, or blocked by AudioCapture privacy.
        case silent
        /// ScreenCaptureKit preflight explicitly reports no grant.
        case denied
    }

    /// The running binary's code directory hash.
    ///
    /// TCC keys an ad-hoc signed app on exactly this value, so it changes with
    /// every rebuild — and with it, every permission the user granted. Storing
    /// it lets the app say "you have to grant this again" instead of silently
    /// recording nothing but zeros.
    public static var codeHash: String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return "" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: 0), &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let hash = dictionary[kSecCodeInfoUnique as String] as? Data else { return "" }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// True when the app is only ad-hoc signed, i.e. its identity — and every
    /// permission tied to it — changes on the next build.
    public static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: 2), &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return false }
        let flags = dictionary[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        return flags & 0x2 != 0   // kSecCodeSignatureAdhoc
    }

    /// Whether macOS has already recorded a decision for this app.
    ///
    /// Gilt nur für die Bildschirmaufnahme. Der Core-Audio-Tap hängt an der
    /// Kategorie *Audioaufnahme*, für die es keine Vorabfrage gibt – dort ist
    /// der Versuch selbst die einzige Auskunft (siehe `canCapture`).
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Whether this backend's permission can be checked before capture starts.
    /// Core Audio process taps have no public preflight API; starting the tap
    /// asks macOS when no AudioCapture decision exists yet.
    public static func isGranted(backend: AppSettings.SystemAudioBackend) -> Bool? {
        switch backend {
        case .screenCapture: return isGranted
        case .processTap: return nil
        }
    }

    /// Whether AlfredHelp has already asked macOS for ScreenCapture access.
    public static var hasRequested: Bool {
        screenCaptureRequestGate.hasRequested
    }

    /// Puts the macOS permission dialog on screen at most once. Only works from
    /// a running GUI application; returns immediately.
    @discardableResult
    public static func request() -> Bool {
        if isGranted {
            screenCaptureRequestGate.markAlreadyGranted()
            return true
        }
        return screenCaptureRequestGate.request { CGRequestScreenCaptureAccess() }
    }

    /// Opens the exact settings pane where the user can grant access.
    /// Welcher Bereich das ist, hängt am Verfahren – der Tap steht unter
    /// *Audioaufnahme*, nicht unter *Bildschirmaufnahme*.
    public static func openSettings(
        backend: AppSettings.SystemAudioBackend = .screenCapture
    ) {
        NSWorkspaceOpen(settingsURL(backend: backend))
    }

    static func settingsURL(backend: AppSettings.SystemAudioBackend) -> URL {
        // Process taps use TCC's AudioCapture service. On current macOS this
        // is listed under "Screen & System Audio Recording", not Microphone.
        let anchor = backend == .processTap ? "Privacy_AudioCapture" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Kann die App den Systemton gerade wirklich aufnehmen?
    ///
    /// Das ist die einzige Prüfung, die beim Programmstart zählt – und sie
    /// fragt bewusst **nicht** nach einem Pegel. Ob gerade jemand spricht, hat
    /// mit der Berechtigung nichts zu tun; wer den Nutzer nur deshalb erneut
    /// nach einer Freigabe fragt, die längst erteilt ist, nervt ihn bei jedem
    /// Start.
    ///
    /// Prüft stattdessen zwei Dinge, die beide nur bei erteilter Freigabe
    /// zutreffen: der Stream startet ohne Fehler, und es kommen Puffer an.
    /// Ohne Freigabe wirft ScreenCaptureKit `-3801`.
    /// `backend` muss dasselbe sein, das die Sitzung später benutzt. Sonst
    /// prüft die App eine andere Berechtigung, als sie braucht.
    public static func canCapture(
        backend: AppSettings.SystemAudioBackend = .screenCapture,
        timeout: Double = 3
    ) async -> Bool {
        if backend == .screenCapture, !isGranted { return false }

        let capture = backend.makeCapture()
        do {
            try capture.start { _ in }
        } catch {
            return false
        }
        defer { capture.stop() }

        let deadline = Clock.now() + timeout
        while Clock.now() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            if capture.deliveredFrameCount > 0 { return true }
        }
        return false
    }

    /// Checks the selected capture path without treating silence as a denied
    /// permission. Core Audio has no preflight; its only honest result when a
    /// tap produces no audible samples is `.silent`.
    public static func check(
        backend: AppSettings.SystemAudioBackend = .screenCapture,
        timeout: Double = 3
    ) async -> State {
        if backend == .screenCapture, !isGranted {
            return hasRequested ? .denied : .undetermined
        }

        let capture = backend.makeCapture()
        let result = CaptureCheckBox()

        do {
            try capture.start { chunk in
                result.record(peak: chunk.peak)
            }
        } catch {
            // Start errors can also be device or aggregate failures. Don't
            // present an unclassified runtime error as a privacy denial.
            return .undetermined
        }
        defer { capture.stop() }

        let deadline = Clock.now() + timeout
        while Clock.now() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            let peak = result.snapshot()
            if peak > 0.002 { return .working(peak: peak) }
            // Frames can be valid silence. Continue for a moment in case sound
            // begins during the check, then report silence without an access
            // inference.
        }
        return .silent
    }

    private final class CaptureCheckBox: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: Float = 0

        func record(peak value: Float) {
            lock.withLock { peak = max(peak, value) }
        }

        func snapshot() -> Float {
            lock.withLock { peak }
        }
    }

    /// Listens for `seconds` and reports the frames and peak that arrived.
    public static func verify(
        backend: AppSettings.SystemAudioBackend = .screenCapture,
        seconds: Double = 4
    ) async -> (frames: Int, peak: Float) {
        let capture = backend.makeCapture()
        let box = Box()
        do {
            try capture.start { chunk in
                box.record(frames: Int(chunk.buffer.frameLength), peak: chunk.peak)
            }
        } catch {
            return (0, 0)
        }
        // Stop early once real sound has been seen.
        let steps = Int(seconds * 4)
        for _ in 0..<max(1, steps) {
            try? await Task.sleep(for: .milliseconds(250))
            if box.snapshot().peak > 0.002 { break }
        }
        capture.stop()
        return box.snapshot()
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var frames = 0
        private var peak: Float = 0

        func record(frames count: Int, peak value: Float) {
            lock.withLock {
                frames += count
                peak = max(peak, value)
            }
        }

        func snapshot() -> (frames: Int, peak: Float) {
            lock.withLock { (frames, peak) }
        }
    }
}

/// Small shim so this file does not have to import AppKit.
private func NSWorkspaceOpen(_ url: URL) {
    guard let workspaceClass = NSClassFromString("NSWorkspace") as? NSObject.Type else { return }
    let shared = workspaceClass.value(forKey: "sharedWorkspace") as? NSObject
    _ = shared?.perform(NSSelectorFromString("openURL:"), with: url)
}

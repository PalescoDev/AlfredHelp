import Foundation
import Testing
@testable import AlfredHelpCore

@Suite("ScreenCapture-Berechtigung nur einmal")
struct PermissionRequestGateTests {

    @Test("Ein erfolgreicher Request kann nicht erneut ausgeführt werden")
    func requestsOnceAfterSuccess() {
        let suite = "AlfredHelp.PermissionGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = ScreenCapturePermissionRequestGate(defaults: defaults, key: "requested")
        var calls = 0

        let first = gate.request {
            calls += 1
            return true
        }
        let second = gate.request {
            calls += 1
            return true
        }

        #expect(first)
        #expect(!second)
        #expect(calls == 1)
        #expect(gate.hasRequested)
    }

    @Test("Auch eine abgelehnte Abfrage bleibt über Neustarts gesperrt")
    func persistsAttemptAfterDenial() {
        let suite = "AlfredHelp.PermissionGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0

        let firstGate = ScreenCapturePermissionRequestGate(defaults: defaults, key: "requested")
        let first = firstGate.request {
            calls += 1
            return false
        }
        let gateAfterRestart = ScreenCapturePermissionRequestGate(defaults: defaults, key: "requested")
        let second = gateAfterRestart.request {
            calls += 1
            return true
        }

        #expect(!first)
        #expect(!second)
        #expect(calls == 1)
        #expect(gateAfterRestart.hasRequested)
    }

    @Test("Parallele Aufrufe über getrennte Gates lösen nur einen Request aus")
    func serializesConcurrentGateInstances() {
        let suite = "AlfredHelp.PermissionGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let gates = (0..<64).map { _ in
            ScreenCapturePermissionRequestGate(defaults: defaults, key: "requested")
        }
        let calls = LockedCallCounter()

        DispatchQueue.concurrentPerform(iterations: gates.count) { index in
            _ = gates[index].request {
                calls.increment()
                return true
            }
        }

        #expect(calls.value == 1)
        #expect(gates.allSatisfy { $0.hasRequested })
    }

    @Test("Core-Audio-Tap verweist auf Audioaufnahme, nicht auf Mikrofon")
    func opensAudioCapturePrivacyPane() {
        let url = SystemAudioPermission.settingsURL(backend: .processTap)

        #expect(url.query == "Privacy_AudioCapture")
        #expect(!url.query!.contains("Microphone"))
    }

    @Test("ScreenCapture behält den eigenen Einstellungsbereich")
    func opensScreenCapturePrivacyPane() {
        let url = SystemAudioPermission.settingsURL(backend: .screenCapture)

        #expect(url.query == "Privacy_ScreenCapture")
    }

    @Test("Core-Audio-Tap behauptet keinen ScreenCapture-Vorabstatus")
    func processTapHasNoScreenCapturePreflight() {
        #expect(SystemAudioPermission.isGranted(backend: .processTap) == nil)
        #expect(SystemAudioPermission.isGranted(backend: .screenCapture) == SystemAudioPermission.isGranted)
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

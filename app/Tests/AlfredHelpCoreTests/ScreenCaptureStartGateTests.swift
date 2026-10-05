import Foundation
import Testing
@testable import AlfredHelpCore

@Suite("ScreenCapture-Start-Handshake")
struct ScreenCaptureStartGateTests {
    @Test("Bereits bestätigter Start wird auch bei späterem Warten gemeldet")
    func successBeforeWait() async throws {
        let gate = ScreenCaptureStartGate(timeout: .seconds(1))

        #expect(gate.resolve(.success(())))
        try await gate.wait()
        #expect(!gate.resolve(.failure(CancellationError())))
    }

    @Test("Der erste Fehler löst das Gate genau einmal auf")
    func failureWinsOnce() async {
        let gate = ScreenCaptureStartGate(timeout: .seconds(1))

        #expect(gate.resolve(.failure(GateTestError.startFailed)))
        #expect(!gate.resolve(.success(())))
        await #expect(throws: GateTestError.self) {
            try await gate.wait()
        }
    }

    @Test("Stop beendet wartende Aufrufer mit Abbruch")
    func stopCancelsWaiter() async {
        let gate = ScreenCaptureStartGate(timeout: .seconds(1))
        let waiter = Task { try await gate.wait() }

        #expect(gate.resolve(.failure(CancellationError())))
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(!gate.resolve(.success(())))
    }

    @Test("Timeout beendet das Warten begrenzt")
    func timeoutIsBounded() async {
        let gate = ScreenCaptureStartGate(timeout: .milliseconds(20))

        do {
            try await gate.wait()
            Issue.record("Das Start-Gate hätte wegen des Timeouts fehlschlagen müssen.")
        } catch {
            #expect(error.localizedDescription.contains("nicht rechtzeitig"))
        }
    }

    @Test("Abbruch eines Wartenden löst den Stream-Start nicht auf")
    func cancelledWaiterDoesNotCancelGate() async throws {
        let gate = ScreenCaptureStartGate(timeout: .seconds(1))
        let waiter = Task { try await gate.wait() }
        waiter.cancel()

        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
        #expect(gate.resolve(.success(())))
        try await gate.wait()
    }
}

private enum GateTestError: Error {
    case startFailed
}

import Foundation
import Testing
@testable import AlfredHelpCore

@Suite("Abbruch des Sprachasset-Downloads")
struct SpeechAssetCancellationTests {
    @Test("Stop kehrt zurück, auch wenn der Installer Abbruch ignoriert")
    func cancellationDoesNotWaitForInstaller() async throws {
        let gate = UncooperativeInstallGate()
        let waiter = Task<Void, Error> {
            try await SpeechAssetInstallWait.run(
                operation: { await gate.wait() },
                onCancel: {}
            )
        }
        let observer = Task<Void, Never> {
            _ = try? await waiter.value
        }

        await gate.waitUntilStarted()
        waiter.cancel()
        let returnedPromptly = await TaskTimeout.wait(for: observer, timeout: .seconds(1))
        await gate.finish()
        await gate.waitUntilFinished()

        #expect(returnedPromptly)
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }
}

private actor UncooperativeInstallGate {
    private var started = false
    private var finished = false
    private var installation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            installation = continuation
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        finished = true
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() {
        installation?.resume()
        installation = nil
    }

    func waitUntilFinished() async {
        guard !finished else { return }
        await withCheckedContinuation { finishWaiters.append($0) }
    }
}

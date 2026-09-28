import Foundation
import Testing
@testable import AlfredHelpCore

@Suite("Ollama-Prozesslebenszyklus", .serialized)
struct OllamaLifecycleTests {
    @Test("Ein bereits erreichbarer Server wird nie übernommen")
    func reachableServerIsNotOwned() async {
        OllamaSupervisor.discardManagedHandlesForTesting()
        ReachableOllamaTransport.reset()
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [ReachableOllamaTransport.self]
        )

        #expect(await OllamaSupervisor.ensureRunning(client: client, timeout: .seconds(1)))
        let stopped = await OllamaSupervisor.stopManagedOllama(timeout: .milliseconds(10))
        #expect(!stopped.stoppedAnything)
    }

    @Test("Das Zeitlimit begrenzt auch den ersten Supervisor-Aufruf")
    func firstCallerHasHardWaitLimit() async {
        let slowLaunch = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return true
        }

        let result = await OllamaSupervisorWait.wait(for: slowLaunch, timeout: .milliseconds(100))
        slowLaunch.cancel()

        #expect(result == .timedOut)
    }

    @Test("Abbruch löst einen wartenden Continuation-Aufruf sofort")
    func cancelledWaiterReturnsPromptly() async {
        let slowLaunch = Task<Bool, Never> {
            try? await Task.sleep(for: .seconds(30))
            return true
        }
        let waiter = Task<Bool, Never> {
            await OllamaSupervisorWait.wait(for: slowLaunch, timeout: .seconds(30)) == .cancelled
        }
        let observer = Task<Void, Never> { _ = await waiter.value }

        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        let returnedPromptly = await TaskTimeout.wait(for: observer, timeout: .seconds(1))
        slowLaunch.cancel()

        #expect(returnedPromptly)
        #expect(await waiter.value)
    }

    @Test("Ein Zeitlimit von null startet nach Shutdown keinen Health-Request")
    func zeroTimeoutNeverFallsBackToSessionDefault() async {
        OllamaSupervisor.discardManagedHandlesForTesting()
        _ = await OllamaSupervisor.stopManagedOllama(timeout: .zero)
        ReachableOllamaTransport.reset()
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [ReachableOllamaTransport.self]
        )

        let reachable = await OllamaSupervisor.ensureRunning(client: client, timeout: .zero)

        #expect(!reachable)
        #expect(ReachableOllamaTransport.requestCount == 0)
    }

    @Test("Ein ungültiges Request-Timeout startet keinen URLSession-Request")
    func zeroRequestTimeoutNeverUsesSessionDefault() async {
        ReachableOllamaTransport.reset()
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [ReachableOllamaTransport.self]
        )

        #expect(!(await client.isReachable(timeout: 0)))
        #expect(ReachableOllamaTransport.requestCount == 0)
    }

    @Test("Der Health-Check übernimmt das Timeout des Supervisors")
    func healthCheckUsesSupervisorTimeout() async {
        OllamaSupervisor.discardManagedHandlesForTesting()
        ReachableOllamaTransport.reset()
        let client = OllamaClient(
            baseURL: URL(string: "http://127.0.0.1:11434")!,
            transport: [ReachableOllamaTransport.self]
        )

        #expect(await OllamaSupervisor.ensureRunning(client: client, timeout: .seconds(2)))

        let requestTimeout = ReachableOllamaTransport.lastTimeout
        #expect(requestTimeout != nil)
        #expect((requestTimeout ?? 120) <= 2)
        #expect((requestTimeout ?? 0) > 0)
        _ = await OllamaSupervisor.stopManagedOllama(timeout: .milliseconds(10))
    }

    @Test("Der geordnete Stop beendet exakt den gehaltenen Serve-Prozess")
    func asyncStopTerminatesRetainedProcess() async throws {
        OllamaSupervisor.discardManagedHandlesForTesting()
        let process = try sleepingProcess()
        OllamaSupervisor.registerManagedServeForTesting(process)

        let result = await OllamaSupervisor.stopManagedOllama(timeout: .seconds(1))

        #expect(result.signalledServe)
        #expect(await eventually { !process.isRunning })
        let repeated = await OllamaSupervisor.stopManagedOllama(timeout: .milliseconds(10))
        #expect(!repeated.stoppedAnything)
    }

    @Test("Der synchrone Rettungsweg ist idempotent")
    func emergencySignalIsIdempotent() async throws {
        OllamaSupervisor.discardManagedHandlesForTesting()
        let process = try sleepingProcess()
        OllamaSupervisor.registerManagedServeForTesting(process)

        OllamaSupervisor.signalManagedOllamaNow()
        OllamaSupervisor.signalManagedOllamaNow()

        #expect(await eventually { !process.isRunning })
        let result = await OllamaSupervisor.stopManagedOllama(timeout: .milliseconds(10))
        #expect(!result.stoppedAnything)
    }

    @Test("Ein nach Shutdown verspätet registrierter Prozess wird sofort abgewiesen")
    func lateRegistrationCannotLeak() async throws {
        OllamaSupervisor.discardManagedHandlesForTesting()
        OllamaSupervisor.signalManagedOllamaNow()
        let process = try sleepingProcess()

        OllamaSupervisor.registerManagedServeForTesting(process)

        #expect(await eventually { !process.isRunning })
        let result = await OllamaSupervisor.stopManagedOllama(timeout: .milliseconds(10))
        #expect(!result.stoppedAnything)
    }

    @Test("Ollama wird direkt über bekannte Pfade und PATH gesucht")
    func executableLookupUsesPathsWithoutStartingAShell() {
        let found = OllamaSupervisor.resolveExecutableURL(
            knownPaths: ["/missing/ollama"],
            pathEnvironment: "/missing:/tools/ollama/bin",
            isExecutable: { $0 == "/tools/ollama/bin/ollama" }
        )

        #expect(found?.path == "/tools/ollama/bin/ollama")
    }

    @Test("Nur eine neu gestartete Instanz aus dem erwarteten Bundle gehört uns")
    func applicationOwnershipRequiresNewMatchingInstance() {
        let expected = URL(fileURLWithPath: "/Applications/Ollama.app")
        #expect(OllamaSupervisor.shouldOwnLaunchedApplication(
            previousPIDs: [], launchedPID: 42,
            requestedBundleURL: expected, launchedBundleURL: expected
        ))
        #expect(!OllamaSupervisor.shouldOwnLaunchedApplication(
            previousPIDs: [42], launchedPID: 42,
            requestedBundleURL: expected, launchedBundleURL: expected
        ))
        #expect(!OllamaSupervisor.shouldOwnLaunchedApplication(
            previousPIDs: [], launchedPID: 42,
            requestedBundleURL: expected,
            launchedBundleURL: URL(fileURLWithPath: "/tmp/Fremd.app")
        ))
    }

    private func sleepingProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func eventually(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private final class ReachableOllamaTransport: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedTimeout: TimeInterval?
    nonisolated(unsafe) private static var recordedRequestCount = 0

    static var lastTimeout: TimeInterval? { lock.withLock { recordedTimeout } }
    static var requestCount: Int { lock.withLock { recordedRequestCount } }

    static func reset() {
        lock.withLock {
            recordedTimeout = nil
            recordedRequestCount = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock {
            Self.recordedTimeout = request.timeoutInterval
            Self.recordedRequestCount += 1
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"version":"test"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

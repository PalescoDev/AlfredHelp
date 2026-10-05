import AppKit
import Foundation

/// Starts a local Ollama server and retains only process instances started here.
public struct OllamaSupervisor: Sendable {
    public struct StopResult: Sendable, Equatable {
        public var signalledServe = false
        public var signalledApplication = false
        public var forcedApplication = false
        public var stoppedAnything: Bool { signalledServe || signalledApplication }
    }

    public static var applicationPaths: [String] {
        [
            "/Applications/Ollama.app",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/Ollama.app").path
        ]
    }

    private static var searchPaths: [String] {
        applicationPaths.map { "\($0)/Contents/Resources/ollama" } + [
            "/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/usr/bin/ollama"
        ]
    }

    private static let handles = ManagedOllamaHandles()
    private static let lifecycle = OllamaLifecycle(handles: handles)

    public static func executableURL() -> URL? {
        resolveExecutableURL(
            knownPaths: searchPaths,
            pathEnvironment: ProcessInfo.processInfo.environment["PATH"]
        ) { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isInstalled: Bool { executableURL() != nil }

    public static var applicationURL: URL? {
        applicationPaths
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public static var hasApplication: Bool { applicationURL != nil }

    /// Concurrent callers share one launch attempt. A server that answers this
    /// initial probe is considered user-owned and is never adopted.
    @discardableResult
    public static func ensureRunning(
        client: OllamaClient,
        timeout: Duration = .seconds(30)
    ) async -> Bool {
        await lifecycle.ensureRunning(client: client, timeout: timeout)
    }

    /// Gracefully stops only exact app/process handles launched by this process.
    @discardableResult
    public static func stopManagedOllama(
        timeout: Duration = .seconds(2)
    ) async -> StopResult {
        await lifecycle.stopManaged(timeout: timeout)
    }

    /// Synchronous, non-waiting rescue path for `applicationWillTerminate`.
    /// Taking the retained handles makes repeated calls idempotent.
    public static func signalManagedOllamaNow() {
        handles.signalAndDiscard()
    }

    public static var isInstalledAnywhere: Bool { hasApplication || isInstalled }

    // MARK: Internal test seams

    static func resolveExecutableURL(
        knownPaths: [String],
        pathEnvironment: String?,
        isExecutable: (String) -> Bool
    ) -> URL? {
        let pathCandidates = (pathEnvironment ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("ollama").path }
        var visited = Set<String>()
        for path in knownPaths + pathCandidates {
            let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard visited.insert(normalizedPath).inserted,
                  isExecutable(normalizedPath) else { continue }
            return URL(fileURLWithPath: normalizedPath)
        }
        return nil
    }

    static func shouldOwnLaunchedApplication(
        previousPIDs: Set<pid_t>,
        launchedPID: pid_t,
        requestedBundleURL: URL,
        launchedBundleURL: URL?
    ) -> Bool {
        guard !previousPIDs.contains(launchedPID), let launchedBundleURL else { return false }
        return canonical(requestedBundleURL) == canonical(launchedBundleURL)
    }

    static func registerManagedServeForTesting(_ process: Process) {
        handles.replaceServe(process)
    }

    static func discardManagedHandlesForTesting() { handles.resetForTesting() }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private actor OllamaLifecycle {
    private let handles: ManagedOllamaHandles
    private var launchTask: Task<Bool, Never>?
    private var launchToken: UUID?

    init(handles: ManagedOllamaHandles) { self.handles = handles }

    func ensureRunning(client: OllamaClient, timeout: Duration) async -> Bool {
        guard handles.mayLaunch else {
            guard let requestTimeout = Self.timeoutSeconds(timeout) else { return false }
            return await client.isReachable(timeout: requestTimeout)
        }
        if let launchTask {
            switch await OllamaSupervisorWait.wait(for: launchTask, timeout: timeout) {
            case .completed(let result): return result
            case .timedOut: return false
            case .cancelled: return false
            }
        }
        let token = UUID()
        let task = Task { [handles] in
            await Self.performEnsureRunning(client: client, timeout: timeout, handles: handles)
        }
        launchTask = task
        launchToken = token
        Task.detached { [weak self] in
            _ = await task.value
            await self?.finishLaunch(token: token)
        }
        switch await OllamaSupervisorWait.wait(for: task, timeout: timeout) {
        case .completed(let result):
            finishLaunch(token: token)
            return result
        case .timedOut:
            task.cancel()
            return false
        case .cancelled:
            task.cancel()
            return false
        }
    }

    private func finishLaunch(token: UUID) {
        guard launchToken == token else { return }
        launchTask = nil
        launchToken = nil
    }

    func stopManaged(timeout: Duration) async -> OllamaSupervisor.StopResult {
        // Close the ownership gate before cancelling the launch. AppKit's open
        // completion itself is not cancellable; should it arrive late, the
        // registry rejects and immediately terminates that exact instance.
        let owned = handles.beginShutdownAndTake()
        launchTask?.cancel()
        launchTask = nil
        launchToken = nil
        var result = OllamaSupervisor.StopResult()
        if let serve = owned.serve, serve.isRunning {
            serve.terminate()
            result.signalledServe = true
        }
        if let application = owned.application, !application.isTerminated {
            application.terminate()
            result.signalledApplication = true
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let serveDone = owned.serve.map { !$0.isRunning } ?? true
            let appDone = owned.application?.isTerminated ?? true
            if serveDone && appDone { return result }
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Do not escalate a raw child with kill(pid): between an isRunning check
        // and the signal the child could exit and macOS could reuse its PID.
        // SIGTERM above is the strongest safe operation on the retained Process.
        if let application = owned.application, !application.isTerminated {
            application.forceTerminate()
            result.forcedApplication = true
        }
        return result
    }

    private static func performEnsureRunning(
        client: OllamaClient,
        timeout: Duration,
        handles: ManagedOllamaHandles
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        guard handles.mayLaunch, !Task.isCancelled else { return false }
        guard let initialTimeout = timeoutSeconds(until: deadline) else { return false }
        if await client.isReachable(timeout: initialTimeout) { return true }

        var launchedApplication = false
        if let application = OllamaSupervisor.applicationURL {
            guard let launchTimeout = duration(until: deadline) else { return false }
            let applicationTask = Task {
                await launchApplication(application, handles: handles)
            }
            switch await OllamaSupervisorWait.wait(for: applicationTask, timeout: launchTimeout) {
            case .completed(let result): launchedApplication = result
            case .timedOut:
                applicationTask.cancel()
                return false
            case .cancelled:
                applicationTask.cancel()
                return false
            }
        }
        guard handles.mayLaunch, !Task.isCancelled else { return false }
        if launchedApplication,
           await waitForServer(
                client: client,
                until: min(deadline, ContinuousClock.now.advanced(by: .seconds(10)))
           ) {
            return true
        }

        guard handles.mayLaunch, !Task.isCancelled else { return false }
        guard let probeTimeout = timeoutSeconds(until: deadline) else { return false }
        if let executable = OllamaSupervisor.executableURL(),
           await !client.isReachable(timeout: probeTimeout) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["serve"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                guard try handles.runAndReplaceServe(process) else {
                    // Either shutdown won the race, or an earlier managed serve
                    // is still alive. Never overwrite and lose that exact handle.
                    return await waitForServer(client: client, until: deadline)
                }
                Log.ollama.info("Started managed ollama serve (pid \(process.processIdentifier, privacy: .public))")
            } catch {
                Log.ollama.error("Could not start server: \(String(describing: error), privacy: .public)")
                return launchedApplication
                    ? await waitForServer(client: client, until: deadline)
                    : false
            }
        } else if !launchedApplication {
            return false
        }
        return await waitForServer(client: client, until: deadline)
    }

    @MainActor
    private static func openApplication(
        _ application: URL,
        previousPIDs: Set<pid_t>
    ) async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        let race = ApplicationOpenRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                guard !Task.isCancelled else {
                    race.finish(nil)
                    return
                }
                NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
                    if let error {
                        Log.ollama.error("Could not launch Ollama.app: \(error.localizedDescription, privacy: .public)")
                    }
                    let accepted = race.finish(app)
                    if !accepted, let app,
                       OllamaSupervisor.shouldOwnLaunchedApplication(
                           previousPIDs: previousPIDs,
                           launchedPID: app.processIdentifier,
                           requestedBundleURL: application,
                           launchedBundleURL: app.bundleURL
                       ), !app.isTerminated {
                        // The caller timed out or was cancelled while LaunchServices
                        // was opening the app. Do not leave behind an instance this
                        // launch attempt would otherwise have registered as managed.
                        app.terminate()
                    }
                }
            }
        } onCancel: {
            race.finish(nil)
        }
    }

    private static func launchApplication(
        _ application: URL,
        handles: ManagedOllamaHandles
    ) async -> Bool {
        guard let identifier = Bundle(url: application)?.bundleIdentifier else {
            Log.ollama.error("Ollama.app has no bundle identifier")
            return false
        }
        let previousApplications = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        }
        let previousPIDs = Set(previousApplications.map(\.processIdentifier))
        guard let running = await openApplication(application, previousPIDs: previousPIDs) else { return false }
        let owns = OllamaSupervisor.shouldOwnLaunchedApplication(
            previousPIDs: previousPIDs,
            launchedPID: running.processIdentifier,
            requestedBundleURL: application,
            launchedBundleURL: running.bundleURL
        )
        guard !Task.isCancelled else {
            if owns, !running.isTerminated { running.terminate() }
            return false
        }
        if owns {
            if handles.replaceApplication(running) {
                Log.ollama.info("Launched managed Ollama.app (pid \(running.processIdentifier, privacy: .public))")
            } else {
                Log.ollama.info("Terminated Ollama.app that completed launch during shutdown")
            }
        } else {
            Log.ollama.info("Opened an existing Ollama.app without adopting it")
        }
        return true
    }

    private static func waitForServer(
        client: OllamaClient,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            guard let remaining = timeoutSeconds(until: deadline) else { return false }
            if await client.isReachable(timeout: remaining) { return true }
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return false
            }
        }
        return false
    }

    private static func timeoutSeconds(until deadline: ContinuousClock.Instant) -> TimeInterval? {
        timeoutSeconds(ContinuousClock.now.duration(to: deadline))
    }

    private static func duration(until deadline: ContinuousClock.Instant) -> Duration? {
        let remaining = ContinuousClock.now.duration(to: deadline)
        return remaining > .zero ? remaining : nil
    }

    private static func timeoutSeconds(_ duration: Duration) -> TimeInterval? {
        let components = duration.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

}

enum OllamaLaunchWaitResult: Sendable, Equatable {
    case completed(Bool)
    case timedOut
    case cancelled
}

enum OllamaSupervisorWait {
    static func wait(
        for task: Task<Bool, Never>,
        timeout: Duration
    ) async -> OllamaLaunchWaitResult {
        guard timeout > .zero else { return .timedOut }
        let race = LaunchWaitRace()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                guard !Task.isCancelled else {
                    race.finish(.cancelled)
                    return
                }
                Task.detached {
                    race.finish(.completed(await task.value))
                }
                let timer = Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        race.finish(.timedOut)
                    } catch {
                        // The launch completed or the waiter was cancelled first.
                    }
                }
                race.setTimer(timer)
            }
        } onCancel: {
            race.finish(.cancelled)
        }
    }
}

private final class LaunchWaitRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OllamaLaunchWaitResult, Never>?
    private var timer: Task<Void, Never>?
    private var pendingResult: OllamaLaunchWaitResult?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<OllamaLaunchWaitResult, Never>) {
        let pending = lock.withLock { () -> OllamaLaunchWaitResult? in
            if isFinished {
                let result = pendingResult ?? .cancelled
                pendingResult = nil
                return result
            }
            if let pendingResult {
                self.pendingResult = nil
                isFinished = true
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending { continuation.resume(returning: pending) }
    }

    func setTimer(_ timer: Task<Void, Never>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            guard !isFinished else { return true }
            self.timer = timer
            return false
        }
        if cancelImmediately { timer.cancel() }
    }

    func finish(_ result: OllamaLaunchWaitResult) {
        let (pending, timer) = lock.withLock {
            () -> (CheckedContinuation<OllamaLaunchWaitResult, Never>?, Task<Void, Never>?) in
            guard !isFinished else { return (nil, nil) }
            let pending = continuation
            isFinished = true
            if pending == nil {
                pendingResult = result
            } else {
                continuation = nil
            }
            let timer = self.timer
            self.timer = nil
            return (pending, timer)
        }
        timer?.cancel()
        pending?.resume(returning: result)
    }
}

/// Makes the non-cancellable LaunchServices callback return promptly when its
/// caller is cancelled. A late callback can still clean up a newly opened app.
private final class ApplicationOpenRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NSRunningApplication?, Never>?
    private var pendingApplication: NSRunningApplication?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<NSRunningApplication?, Never>) {
        let result = lock.withLock { () -> (Bool, NSRunningApplication?) in
            guard !isFinished else { return (true, pendingApplication) }
            self.continuation = continuation
            return (false, nil)
        }
        if result.0 { continuation.resume(returning: result.1) }
    }

    @discardableResult
    func finish(_ application: NSRunningApplication?) -> Bool {
        let (continuation, accepted) = lock.withLock {
            () -> (CheckedContinuation<NSRunningApplication?, Never>?, Bool) in
            guard !isFinished else { return (nil, false) }
            isFinished = true
            guard let continuation else {
                pendingApplication = application
                return (nil, true)
            }
            self.continuation = nil
            return (continuation, true)
        }
        continuation?.resume(returning: application)
        return accepted
    }
}

private final class ManagedOllamaHandles: @unchecked Sendable {
    struct Snapshot {
        var serve: Process?
        var application: NSRunningApplication?
    }

    private let lock = NSLock()
    private var serve: Process?
    private var application: NSRunningApplication?
    private var isShuttingDown = false

    var mayLaunch: Bool { lock.withLock { !isShuttingDown } }

    /// Testing seam for an already-running process. Production starts use
    /// `runAndReplaceServe`, which closes the run/register gap atomically.
    func replaceServe(_ process: Process) {
        let accepted = lock.withLock {
            guard !isShuttingDown else { return false }
            serve = process
            return true
        }
        if !accepted, process.isRunning { process.terminate() }
    }

    /// Holds the lock across `run()`: shutdown can observe either no process at
    /// all or a retained running process, never the unsafe state in between.
    func runAndReplaceServe(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isShuttingDown else { return false }
        if let serve, serve.isRunning { return false }
        serve = nil
        try process.run()
        serve = process
        return true
    }

    @discardableResult
    func replaceApplication(_ app: NSRunningApplication) -> Bool {
        let accepted = lock.withLock {
            guard !isShuttingDown else { return false }
            application = app
            return true
        }
        if !accepted, !app.isTerminated { app.terminate() }
        return accepted
    }

    func take() -> Snapshot {
        lock.withLock {
            let snapshot = Snapshot(serve: serve, application: application)
            serve = nil
            application = nil
            return snapshot
        }
    }

    func signalAndDiscard() {
        let owned = beginShutdownAndTake()
        if let serve = owned.serve, serve.isRunning { serve.terminate() }
        if let application = owned.application, !application.isTerminated { application.terminate() }
    }

    func beginShutdownAndTake() -> Snapshot {
        lock.withLock {
            isShuttingDown = true
            let snapshot = Snapshot(serve: serve, application: application)
            serve = nil
            application = nil
            return snapshot
        }
    }

    func resetForTesting() {
        lock.withLock {
            serve = nil
            application = nil
            isShuttingDown = false
        }
    }
}

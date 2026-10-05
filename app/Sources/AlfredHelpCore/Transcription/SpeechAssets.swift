import Foundation
import Speech

/// Manages the on-device speech models. Everything here downloads Apple's
/// system speech assets once and then runs offline; no audio ever leaves the
/// Mac.
public enum SpeechAssets {

    public struct LocaleInfo: Sendable, Identifiable, Hashable {
        public let identifier: String
        public let displayName: String
        public let isInstalled: Bool

        public var id: String { identifier }
        public var locale: Locale { Locale(identifier: identifier) }
    }

    public enum AssetState: Sendable, Equatable {
        case unsupported
        case notInstalled
        case downloading(Double)
        case ready
    }

    public static var isAvailable: Bool {
        SpeechTranscriber.isAvailable
    }

    /// All locales the on-device transcriber can handle, marked with whether
    /// their model is already on disk.
    public static func availableLocales() async -> [LocaleInfo] {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set(await SpeechTranscriber.installedLocales.map(\.identifier))
        let uiLocale = Locale.current
        return supported
            .map { locale in
                let identifier = locale.identifier(.bcp47)
                let name = uiLocale.localizedString(forIdentifier: locale.identifier)
                    ?? locale.identifier
                return LocaleInfo(
                    identifier: identifier,
                    displayName: name.prefix(1).uppercased() + name.dropFirst(),
                    isInstalled: installed.contains(locale.identifier)
                        || installed.contains(identifier)
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Resolves a user-picked locale to one the transcriber actually supports
    /// (e.g. `en` → `en-US`).
    public static func resolve(_ locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // `volatileResults` gives us words while they are still being spoken;
            // `fastResults` shortens the wait before a hypothesis appears at all.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
    }

    /// Downloads the model for `locale` if needed. `progress` is reported on an
    /// arbitrary thread.
    public static func ensureModel(
        for locale: Locale,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        let transcriber = makeTranscriber(locale: locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        try Task.checkCancellation()
        switch status {
        case .installed:
            try await reserve(locale: locale)
            return
        case .unsupported:
            throw SpeechAssetError.unsupportedLocale(locale.identifier)
        case .supported, .downloading:
            break
        @unknown default:
            break
        }

        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else {
            try Task.checkCancellation()
            try await reserve(locale: locale)
            return
        }

        let observation: NSKeyValueObservation?
        if let progress {
            observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { object, _ in
                progress(object.fractionCompleted)
            }
        } else {
            observation = nil
        }
        defer { observation?.invalidate() }

        do {
            try await SpeechAssetInstallWait.run(
                operation: { try await request.downloadAndInstall() },
                onCancel: {
                    // AssetInstallationRequest has no cancel method. Its Progress is
                    // the framework's cancellation hook.
                    request.progress.cancel()
                }
            )
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        try await reserve(locale: locale)
    }

    private static func reserve(locale: Locale) async throws {
        // Reservation is best-effort when the inventory has already changed,
        // but cancellation must never be swallowed by this cleanup path.
        try Task.checkCancellation()
        do {
            _ = try await AssetInventory.reserve(locale: locale)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
        if Task.isCancelled {
            _ = await AssetInventory.release(reservedLocale: locale)
            throw CancellationError()
        }
    }

    /// Frees a reserved locale slot; the system allows only a handful at a time.
    public static func release(_ locale: Locale) async {
        _ = await AssetInventory.release(reservedLocale: locale)
    }
}

/// Waits for the Speech framework without making the caller's cancellation
/// wait for a download task that may ignore cancellation.
enum SpeechAssetInstallWait {
    static func run(
        operation: @escaping @Sendable () async throws -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) async throws {
        let race = SpeechAssetInstallRace()
        let taskHandle = SpeechAssetInstallTaskHandle()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                race.install(continuation)
                guard !Task.isCancelled else { return }
                let operationTask = Task.detached {
                    do {
                        try await operation()
                        race.finish(.success(()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                taskHandle.install(operationTask)
            }
        } onCancel: {
            taskHandle.cancel()
            onCancel()
            race.finish(.failure(CancellationError()))
        }
    }
}

private final class SpeechAssetInstallTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var wasCancelled = false

    func install(_ task: Task<Void, Never>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            guard !wasCancelled else { return true }
            self.task = task
            return false
        }
        if cancelImmediately { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            wasCancelled = true
            let task = self.task
            self.task = nil
            return task
        }
        task?.cancel()
    }
}

private final class SpeechAssetInstallRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        let pending = lock.withLock { () -> Result<Void, Error>? in
            guard !isFinished else { return .failure(CancellationError()) }
            if let pendingResult {
                self.pendingResult = nil
                isFinished = true
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pending { resume(continuation, with: pending) }
    }

    func finish(_ result: Result<Void, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            guard !isFinished else { return nil }
            guard let continuation else {
                pendingResult = result
                return nil
            }
            self.continuation = nil
            isFinished = true
            return continuation
        }
        if let continuation { resume(continuation, with: result) }
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, Error>,
        with result: Result<Void, Error>
    ) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

public enum SpeechAssetError: LocalizedError {
    case unsupportedLocale(String)
    case transcriberUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocale(let identifier):
            return "Für „\(identifier)“ gibt es keine lokale Spracherkennung auf diesem Mac."
        case .transcriberUnavailable:
            return "Die lokale Spracherkennung ist auf diesem Mac nicht verfügbar."
        }
    }
}

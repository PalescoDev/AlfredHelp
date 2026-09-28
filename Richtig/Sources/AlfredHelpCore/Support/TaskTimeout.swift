import Foundation

/// Waits for an unstructured task without making the caller part of its
/// lifetime. Structured task groups cannot implement this boundary: when the
/// timeout wins they still await a child that ignores cancellation.
enum TaskTimeout {
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ completed: Bool) {
            let pending = lock.withLock {
                let value = continuation
                continuation = nil
                return value
            }
            pending?.resume(returning: completed)
        }
    }

    static func wait(for task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = Race(continuation)
            Task.detached {
                await task.value
                race.finish(true)
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                race.finish(false)
            }
        }
    }
}

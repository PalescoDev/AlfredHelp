import Foundation

/// Runs async work strictly in order. Translations go through one of these so
/// German lines never appear out of sequence, and so the local model is never
/// asked to do three things at once.
public actor SerialQueue {

    private var tail: Task<Void, Never>?
    private var tailID: UUID?
    private var protectedDrain: Task<Void, Never>?
    private var protectedDrainID: UUID?
    private var cancellationRun: Task<Bool, Never>?
    /// Every job that has not finished yet. Needed because `cancelAll` has to
    /// reach the job that is *currently running*, not just the last one queued.
    private var live: [UUID: Task<Void, Never>] = [:]

    public init() {}

    public func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = tail
        let id = UUID()
        let task = Task { [weak self] in
            await previous?.value
            if !Task.isCancelled {
                await work()
            }
            // Aufräumen ohne `defer` und ohne verschachtelte Aufgabe: beides
            // stößt in Sprachmodus 6 an die Regionsprüfung, weil `work` als
            // `sending` hereinkommt.
            await self?.forget(id)
        }
        tail = task
        tailID = id
        live[id] = task
    }

    /// Stops everything: the running job and every job still waiting behind it.
    ///
    /// Cancelling only `tail` looked equivalent and is not – measured in
    /// `SerialQueueTests`: of three queued jobs, the running one ran to
    /// completion and the middle one started afterwards, because each job is
    /// its own `Task` that merely awaits its predecessor. After a conversation
    /// reset that left translations of the *old* conversation competing with
    /// the new ones for the same GPU.
    @discardableResult
    public func cancelAll() async -> Bool {
        if let cancellationRun {
            _ = await cancellationRun.value
            return await cancelAll()
        }
        // A previous transport is known to be non-cooperative. With no newer
        // jobs there is nothing to cancel, and its barrier must stay intact.
        if live.isEmpty, protectedDrain != nil { return false }

        let tasks = Array(live.values)
        for task in tasks { task.cancel() }
        live.removeAll()
        tail = nil
        tailID = nil
        // Cancellation is cooperative. Give well-behaved transports time to
        // drain, but never let one broken request freeze Reset forever. The
        // pipeline generation still prevents a late result from publishing.
        let precedingBarrier = protectedDrain
        let drain = Task {
            await precedingBarrier?.value
            for task in tasks { await task.value }
        }
        let drainID = UUID()
        // Install the barrier before suspending this reentrant actor. Enqueues
        // during the timeout window now chain behind it and cannot be lost.
        tail = drain
        tailID = drainID
        let run = Task {
            await TaskTimeout.wait(for: drain, timeout: .seconds(2))
        }
        cancellationRun = run
        let completed = await run.value
        cancellationRun = nil
        if completed, tailID == drainID {
            tail = nil
            tailID = nil
        }
        if completed {
            protectedDrain = nil
            protectedDrainID = nil
        } else {
            protectedDrain = drain
            protectedDrainID = drainID
            Task { [weak self] in
                await drain.value
                await self?.releaseProtectedDrain(drainID)
            }
        }
        return completed
    }

    public func drain() async {
        await tail?.value
    }

    private func forget(_ id: UUID) {
        live.removeValue(forKey: id)
    }

    private func releaseProtectedDrain(_ id: UUID) {
        guard protectedDrainID == id else { return }
        protectedDrain = nil
        protectedDrainID = nil
        if tailID == id {
            tail = nil
            tailID = nil
        }
    }
}

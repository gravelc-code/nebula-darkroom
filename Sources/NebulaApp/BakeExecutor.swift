// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Runs each bake on a thread of its own instead of Swift concurrency's
/// cooperative pool.
///
/// `Baker.bake` is synchronous and blocks for minutes (Siril, AI tiles). On the
/// cooperative pool — one thread per core — a few bakes in flight starve every
/// other task in the app: thumbnails, export, Enhance. A task executor keeps the
/// bake a real `Task`, so the `Task.isCancelled` / `Task.checkCancellation()`
/// polls inside the bake still see Cancel, while its thread is a dedicated one.
@available(macOS 15.0, *)
final class BakeExecutor: TaskExecutor {
    static let shared = BakeExecutor()
    static let threadName = "Nebula bake"

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        let thread = Thread { job.runSynchronously(on: executor) }
        thread.name = Self.threadName
        thread.qualityOfService = .userInitiated
        thread.stackSize = 8 << 20      // the bake's image loops like a main-thread-sized stack
        thread.start()
    }
}

/// Start a bake task off the cooperative pool where the OS allows it.
func spawnBakeTask(_ body: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
    if #available(macOS 15.0, *) {
        return Task.detached(executorPreference: BakeExecutor.shared, priority: .userInitiated) {
            await body()
        }
    }
    return Task.detached(priority: .userInitiated) { await body() }
}

/// Run blocking work in a detached task that is cancelled together with the
/// caller. A bare `Task.detached { }.value` is not: cancelling the awaiting
/// task left an AI upscale running to the end and writing its file anyway.
func runDetached<T: Sendable>(priority: TaskPriority = .userInitiated,
                              _ work: @escaping @Sendable () throws -> T) async throws -> T {
    let inner = Task.detached(priority: priority) { try work() }
    return try await withTaskCancellationHandler {
        try await inner.value
    } onCancel: {
        inner.cancel()
    }
}

/// Run filesystem work that may stall — a network share, a sleeping Seestar —
/// on GCD rather than Swift's cooperative pool, so a hung `stat` can never pin
/// one of the few threads every other task in the app needs.
func blockingIO<T: Sendable>(qos: DispatchQoS.QoSClass = .utility,
                             _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
    }
}

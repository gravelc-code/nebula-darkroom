// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaBake

/// Every develop in the app goes through here — the ones the user starts and
/// the ones watch mode starts — so there is one answer to "is this target
/// already being developed?".
///
/// - One registry of in-flight bakes per cache key. Opening a target that watch
///   mode is already developing joins that bake (its progress, its result)
///   instead of starting a second Siril on the same frames; a watch report for
///   a target the user is developing waits and is re-checked afterwards.
/// - Watch-mode bakes run one at a time from a queue: a folder of ten new
///   captures no longer launches ten stacks at once.
/// - Quitting cancels everything and waits (bounded) for the bakes to stop
///   their child processes.
@MainActor
final class BakeCoordinator {
    enum Origin: Sendable, Equatable { case manual, watch }

    /// A target promised to a bake, running or waiting in the watch queue.
    struct Claim: Equatable, Sendable {
        let id: UUID
        let origin: Origin
        let subs: URL
        var running: Bool
    }

    private struct Joiner {
        let id: UUID
        let progress: @MainActor (BakeRunner.Progress) -> Void
        let continuation: CheckedContinuation<BakeRunner.Outcome, Never>
    }

    let cacheRoot: URL
    private let manualRunner: BakeRunner
    private let watchRunner: BakeRunner

    private(set) var claims: [String: Claim] = [:]
    private var watchQueue: [String] = []
    private var draining = false
    /// Watch reports that arrived while their target was busy.
    private var deferred: [String: [FolderWatcher.Arrival]] = [:]
    private var watchProgress: [String: BakeRunner.Progress] = [:]
    /// The user's develop, when it is a running watch bake they joined.
    private var joined: (key: String, id: UUID)?
    private var joiners: [String: Joiner] = [:]
    private var shuttingDown = false

    /// Claims changed (drives the Library's "Developing…" indicator).
    var onChange: (() -> Void)?
    /// A watch bake finished; `joined` when the user was watching it in the
    /// foreground (they get its result directly, so no notification is needed).
    var onWatchFinished: ((_ key: String, _ outcome: BakeRunner.Outcome, _ joined: Bool) -> Void)?

    init(cacheRoot: URL = BakeRunner.defaultCacheRoot,
         work: @escaping BakeRunner.Work = BakeRunner.nativeBake) {
        self.cacheRoot = cacheRoot
        manualRunner = BakeRunner(cacheRoot: cacheRoot, work: work)
        watchRunner = BakeRunner(cacheRoot: cacheRoot, work: work)
    }

    func cacheDir(forKey key: String) -> URL {
        cacheRoot.appendingPathComponent(key, isDirectory: true)
    }

    /// Anything still running or waiting.
    var isBusy: Bool { !claims.isEmpty || manualRunner.isBusy || watchRunner.isBusy }

    /// Targets watch mode is developing or about to.
    var watchKeys: Set<String> { Set(claims.filter { $0.value.origin == .watch }.keys) }

    /// The cache key for `subs`, never one an in-flight bake of a different
    /// folder has already claimed. Disk work happens off the main thread.
    func resolveKey(for subs: URL, fingerprint: SourceFingerprint? = nil) async -> String {
        var key = CacheKey.baseName(for: subs)
        for _ in 0..<4 {
            let claimed = claims.mapValues(\.subs)
            let root = cacheRoot
            key = await blockingIO(qos: .userInitiated) {
                CacheKey.resolve(subsDir: subs, fingerprint: fingerprint ?? SourceFingerprint.of(subs),
                                 cacheRoot: root, claimed: claimed)
            }
            // Claimed by another capture while we were looking? Look again.
            if let c = claims[key], !CacheKey.samePath(c.subs, subs) { continue }
            break
        }
        return key
    }

    // MARK: - The user's develop

    /// Develop `subs` into `key` for the user. Replaces any develop the user
    /// started before. If watch mode is already developing this very folder,
    /// joins that bake; if it's only queued, it's promoted to this one.
    func bakeManually(subs: URL, key: String, force: Bool,
                      onProgress: @escaping @MainActor (BakeRunner.Progress) -> Void)
        async -> BakeRunner.Outcome {
        manualRunner.cancel()
        detachJoined()
        if let c = claims[key], c.origin == .watch, CacheKey.samePath(c.subs, subs) {
            if c.running { return await join(key: key, onProgress: onProgress) }
            watchQueue.removeAll { $0 == key }
            claims[key] = nil
        }
        let id = UUID()
        claims[key] = Claim(id: id, origin: .manual, subs: subs, running: true)
        onChange?()
        let outcome = await manualRunner.bake(subsDir: subs, target: key, force: force,
                                              onProgress: onProgress)
        release(key, id: id)
        return outcome
    }

    /// The user pressed Cancel: stop their develop, including a joined watch bake.
    func cancelManual() {
        manualRunner.cancel()
        if let j = joined { cancelWatchBake(key: j.key) }
    }

    private func join(key: String, onProgress: @escaping @MainActor (BakeRunner.Progress) -> Void)
        async -> BakeRunner.Outcome {
        let id = UUID()
        joined = (key, id)
        if let p = watchProgress[key] { onProgress(p) }
        return await withCheckedContinuation { continuation in
            joiners[key] = Joiner(id: id, progress: onProgress, continuation: continuation)
        }
    }

    /// The user moved on to another develop: stop following the joined watch
    /// bake (it carries on in the background).
    private func detachJoined() {
        guard let j = joined else { return }
        joined = nil
        if let joiner = joiners[j.key], joiner.id == j.id {
            joiners[j.key] = nil
            joiner.continuation.resume(returning: .cancelled)
        }
    }

    // MARK: - Watch mode

    /// A watched folder has settled. Develop it (in the queue) unless its
    /// cached image already reflects exactly these frames.
    func watchArrived(_ arrival: FolderWatcher.Arrival) async {
        guard !shuttingDown else { return }
        let key = await resolveKey(for: arrival.subs, fingerprint: arrival.fingerprint)
        if claims[key] != nil { postpone(arrival, key); return }
        let dir = cacheDir(forKey: key)
        let needed = await blockingIO {
            Self.watchNeedsBake(cacheDir: dir, fingerprint: arrival.fingerprint,
                                changedSinceFirstReport: arrival.changedSinceFirstReport)
        }
        guard needed, !shuttingDown else { return }
        if claims[key] != nil { postpone(arrival, key); return }
        claims[key] = Claim(id: UUID(), origin: .watch, subs: arrival.subs, running: false)
        watchQueue.append(key)
        onChange?()
        drainWatchQueue()
    }

    /// Whether a settled folder needs developing: never developed (or only
    /// by an older pipeline), or its frames differ from what the cache was
    /// made from. A bake from before fingerprints were recorded counts as
    /// current unless the folder visibly changed while being watched.
    nonisolated static func watchNeedsBake(cacheDir: URL, fingerprint: SourceFingerprint,
                                           changedSinceFirstReport: Bool) -> Bool {
        guard BakeRunner.hasCurrentPipeline(in: cacheDir) else { return true }
        if let recorded = SourceFingerprint.recorded(in: cacheDir) { return recorded != fingerprint }
        return changedSinceFirstReport
    }

    /// Stop a watch bake (running or queued).
    func cancelWatchBake(key: String) {
        guard let c = claims[key], c.origin == .watch else { return }
        if c.running {
            watchRunner.cancel()            // the queue runs one at a time: this is it
        } else {
            watchQueue.removeAll { $0 == key }
            claims[key] = nil
            onChange?()
        }
    }

    private func postpone(_ arrival: FolderWatcher.Arrival, _ key: String) {
        var list = deferred[key, default: []]
        list.removeAll { CacheKey.samePath($0.subs, arrival.subs) }   // only the latest matters
        list.append(arrival)
        deferred[key] = list
    }

    private func drainWatchQueue() {
        guard !draining else { return }
        draining = true
        Task { [weak self] in
            while true {
                guard let self, let key = self.nextQueued() else { break }
                await self.runWatchBake(key)
            }
            self?.draining = false
        }
    }

    private func nextQueued() -> String? {
        while !watchQueue.isEmpty {
            let key = watchQueue.removeFirst()
            if let c = claims[key], c.origin == .watch, !c.running { return key }
        }
        return nil
    }

    private func runWatchBake(_ key: String) async {
        guard var claim = claims[key], claim.origin == .watch else { return }
        claim.running = true
        claims[key] = claim
        onChange?()
        let outcome = await watchRunner.bake(subsDir: claim.subs, target: key, force: true) { [weak self] p in
            guard let self else { return }
            self.watchProgress[key] = p
            self.joiners[key]?.progress(p)
        }
        watchProgress[key] = nil
        var wasJoined = false
        if let joiner = joiners.removeValue(forKey: key) {
            wasJoined = true
            if joined?.id == joiner.id { joined = nil }
            joiner.continuation.resume(returning: outcome)
        }
        release(key, id: claim.id)
        onWatchFinished?(key, outcome, wasJoined)
    }

    private func release(_ key: String, id: UUID) {
        guard claims[key]?.id == id else { return }
        claims[key] = nil
        onChange?()
        guard let waiting = deferred.removeValue(forKey: key), !shuttingDown else { return }
        for arrival in waiting {
            Task { [weak self] in await self?.watchArrived(arrival) }
        }
    }

    // MARK: - Quitting

    /// Cancel every bake, drop the queue and accept no new work.
    func cancelEverything() {
        shuttingDown = true
        watchQueue.removeAll()
        deferred.removeAll()
        claims = claims.filter { $0.value.running }
        manualRunner.cancel()
        watchRunner.cancel()
        onChange?()
    }

    /// `cancelEverything`, then wait up to `timeout` for the bakes to wind
    /// down (Siril and StarNet are stopped within a few seconds of a cancel).
    /// Returns whether everything stopped in time.
    @discardableResult
    func cancelEverythingAndWait(timeout: Duration) async -> Bool {
        cancelEverything()
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while isBusy, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isBusy
    }
}

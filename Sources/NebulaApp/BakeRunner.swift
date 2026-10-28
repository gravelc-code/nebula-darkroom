// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaBake
import NebulaCore

/// Why a develop ended without an image. Keeps the original error for the
/// plain-language mapping (`UserMessage`) and the technical details.
struct BakeFailure: Error, CustomStringConvertible {
    enum Stage: Sendable { case prepare, develop, noLayers, save }
    struct NoLayers: Error, CustomStringConvertible {
        var description: String { "the bake finished without writing its layers" }
    }

    let stage: Stage
    let error: any Error
    /// The target's `_work` folder when it holds the failed bake's logs.
    var logsFolder: URL?

    var description: String {
        let what: String
        switch stage {
        case .prepare:  what = "Couldn't prepare the bake"
        case .develop:  what = "Bake failed"
        case .noLayers: what = "Bake produced no layers"
        case .save:     what = "Couldn't save the finished bake"
        }
        return "\(what): \(error)" + (logsFolder.map { "\nLogs: \($0.path)" } ?? "")
    }
}

/// Drives the **native** Nebula bake (Phase 3): Siril register/stack as a
/// subprocess + background-removal / denoise **in-process** via NebulaAI + a
/// typed manifest — no Python, no external GraXpert.app. Runs off the main actor
/// (on a thread of its own, see `BakeExecutor`) and streams progress back so the
/// app goes from a `<Target>_subs` folder to the finished layers without the
/// user touching a terminal.
///
/// Every bake is built in a staging folder and swapped into the cache only once
/// it is complete (`StagedBake`), so a cancel, a failure or a crash never costs
/// the user the image they already had.
@MainActor
final class BakeRunner {
    struct Progress: Sendable, Equatable { var fraction: Double; var status: String }
    enum Outcome: Sendable { case success(URL); case failure(BakeFailure); case cancelled }

    /// The bake itself: `(subs, outDir, progress)`. Swappable so tests can drive
    /// staging and cancellation without Siril or the AI models.
    typealias Work = @Sendable (_ subs: URL, _ out: URL,
                                _ progress: @escaping @Sendable (Baker.Progress) -> Void) throws -> Void

    nonisolated static let nativeBake: Work = { subs, out, progress in
        _ = try Baker().bake(subsDir: subs, outDir: out, onProgress: progress)
    }

    nonisolated static let defaultCacheRoot: URL =
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)

    let cacheRoot: URL
    private let work: Work
    private var running: [UUID: Task<Void, Never>] = [:]

    init(cacheRoot: URL = BakeRunner.defaultCacheRoot, work: @escaping Work = BakeRunner.nativeBake) {
        self.cacheRoot = cacheRoot
        self.work = work
    }

    /// A stable per-target bake cache: `<cacheRoot>/<key>` (see `CacheKey`).
    func cacheDir(forTarget target: String) -> URL {
        cacheRoot.appendingPathComponent(target, isDirectory: true)
    }

    /// True while any bake started here hasn't returned yet.
    var isBusy: Bool { !running.isEmpty }

    nonisolated static func hasAllLayers(in dir: URL) -> Bool {
        ["master", "starless", "stars", "denoised"].allSatisfy {
            FileManager.default.fileExists(atPath:
                dir.appendingPathComponent("\($0).fits").path)
        }
    }

    /// A complete bake from this pipeline — or a newer one: an older build must
    /// never re-develop (and so replace) a newer build's image.
    nonisolated static func hasCurrentPipeline(in dir: URL) -> Bool {
        guard hasAllLayers(in: dir),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrected.fits").path),
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? NebulaCore.Manifest(jsonData: data),
              let version = manifest.pipelineVersion else { return false }
        return version >= Baker.pipelineVersion
    }

    /// The subs folder has gained or lost frames since this bake was made.
    /// Unknown (an older bake that recorded nothing, or the subs are offline)
    /// counts as unchanged.
    nonisolated static func sourceChanged(in bakeDir: URL, current: SourceFingerprint?) -> Bool {
        guard let current, let recorded = SourceFingerprint.recorded(in: bakeDir) else { return false }
        return recorded != current
    }

    private enum Prepared: Sendable {
        case cached
        case built(StagedBake)
        case cancelled(StagedBake?)
        case failed(BakeFailure, StagedBake?)
    }
    private enum Event: Sendable { case progress(Progress), done(Prepared) }

    /// Bake `subsDir` into the target's cache dir, streaming progress via
    /// `onProgress` (on the main actor). A complete cached bake of the same
    /// frames returns immediately unless `force` (re-develop) asks for a fresh one.
    func bake(subsDir: URL, target: String, force: Bool = false,
              onProgress: @MainActor (Progress) -> Void) async -> Outcome {
        let out = cacheDir(forTarget: target)
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let work = self.work
        // Everything from the cache check on runs off the main actor, inside
        // the task Cancel reaches — so Cancel works from the first moment.
        let task = spawnBakeTask {
            let prepared = Self.prepareAndRun(subsDir: subsDir, out: out, force: force, work: work) {
                continuation.yield(.progress($0))
            }
            continuation.yield(.done(prepared))
            continuation.finish()
        }
        // Only a cancelled consumer stops the bake. A normal finish must not
        // cancel the (already complete) task, or it would read as a cancel below.
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        let id = UUID()
        running[id] = task
        defer { running[id] = nil }

        var prepared: Prepared?
        for await event in events {
            switch event {
            case .progress(let p): onProgress(p)
            case .done(let p): prepared = p
            }
        }

        // A cancel that lands after the bake's last checkpoint — or that
        // surfaces as some other error (a stopped Siril) — still means "change
        // nothing", so the result is discarded. The commit happens here, on the
        // main actor, so it can't race `cancel()`.
        let cancelled = task.isCancelled
        switch prepared {
        case .cached?:
            return cancelled ? .cancelled : .success(out)
        case .cancelled(let staged)?:
            staged?.discard()
            return .cancelled
        case .failed(var failure, let staged)?:
            if cancelled { staged?.discard(); return .cancelled }
            staged?.discardKeepingLogs()
            failure.logsFolder = Self.logsFolder(in: out)
            return .failure(failure)
        case .built(let staged)?:
            if cancelled { staged.discard(); return .cancelled }
            do {
                try staged.commit()
            } catch {
                staged.discardKeepingLogs()
                return .failure(BakeFailure(stage: .save, error: error, logsFolder: Self.logsFolder(in: out)))
            }
            return .success(out)
        case nil:
            return cancelled ? .cancelled
                : .failure(BakeFailure(stage: .develop, error: BakeFailure.NoLayers()))
        }
    }

    /// Cancel every bake in flight here. Siril and StarNet are stopped, the AI
    /// stages stop between tiles, and the results are discarded rather than cached.
    func cancel() { for task in running.values { task.cancel() } }

    // MARK: - Off the main actor

    private nonisolated static func prepareAndRun(
        subsDir: URL, out: URL, force: Bool, work: Work,
        progress: @escaping @Sendable (Progress) -> Void
    ) -> Prepared {
        let fm = FileManager.default
        let fingerprint = SourceFingerprint.of(subsDir)
        if !force, hasCurrentPipeline(in: out), !sourceChanged(in: out, current: fingerprint) {
            progress(Progress(fraction: 1.0, status: "Loaded cached bake"))
            return .cached
        }
        // A stale-pipeline cache is still a complete image. If the source subs
        // are offline, open it as-is rather than failing on layers we cannot
        // rebuild — the target re-develops next time the source is reachable.
        if fingerprint == nil, !fm.fileExists(atPath: subsDir.path), hasAllLayers(in: out) {
            progress(Progress(fraction: 1.0, status: "Loaded cached bake"))
            return .cached
        }
        if Task.isCancelled { return .cancelled(nil) }

        // Build beside the cache. Whatever is already there stays untouched, and
        // keeps opening from the Library, until the new bake is complete.
        let staged: StagedBake
        do { staged = try StagedBake(destination: out) }
        catch { return .failed(BakeFailure(stage: .prepare, error: error), nil) }
        // Dev hook `NEBULA_REUSE_STACK=1`: the re-bake reads the previous stack
        // and target metadata, so carry them into the staging folder.
        if ProcessInfo.processInfo.environment["NEBULA_REUSE_STACK"] == "1" {
            staged.seed(["_work/master_stack.fits", "manifest.json"])
        }
        // Remember where this bake came from (Library "Re-develop", cache keys)
        // and what the folder held when it started (watch mode re-develops
        // when frames arrive later). Both land atomically with the layers.
        try? subsDir.path.write(to: staged.directory.appendingPathComponent("source.txt"),
                                atomically: true, encoding: .utf8)
        try? fingerprint?.write(to: staged.directory)

        do {
            try work(subsDir, staged.directory) { p in
                progress(Progress(fraction: p.fraction, status: p.status))
            }
        } catch is CancellationError {
            return .cancelled(staged)
        } catch {
            return .failed(BakeFailure(stage: .develop, error: error), staged)
        }
        guard hasAllLayers(in: staged.directory) else {
            return .failed(BakeFailure(stage: .noLayers, error: BakeFailure.NoLayers()), staged)
        }
        carryOverUserLook(from: out, into: staged.directory)
        return .built(staged)
    }

    /// A look the user saved for the current engine survives a re-develop
    /// (watch mode re-develops when more frames arrive; that must not reset
    /// their edit). The bake's own default look is not carried.
    nonisolated static func carryOverUserLook(from old: URL, into new: URL) {
        let fresh = new.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: old.appendingPathComponent("manifest.json")),
              let previous = try? Manifest(jsonData: data),
              let version = previous.lookVersion, version == Baker.pipelineVersion,
              let freshData = try? Data(contentsOf: fresh),
              let patched = try? Manifest.updatingLook(previous.look, lookVersion: version, in: freshData)
        else { return }
        try? patched.write(to: fresh, options: .atomic)
    }

    private nonisolated static func logsFolder(in out: URL) -> URL? {
        let work = out.appendingPathComponent("_work", isDirectory: true)
        let logs = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []
        return logs.contains { $0.hasSuffix(".log") } ? work : nil
    }
}

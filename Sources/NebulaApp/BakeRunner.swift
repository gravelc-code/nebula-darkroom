// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaBake
import NebulaCore

/// Drives the **native** Nebula bake (Phase 3): Siril register/stack as a
/// subprocess + background-removal / denoise **in-process** via NebulaAI + a
/// typed manifest — no Python, no external GraXpert.app. Runs off the main actor
/// and streams progress back so the app goes from a `<Target>_subs` folder to the
/// finished layers without the user touching a terminal.
@MainActor
final class BakeRunner {
    struct Progress { var fraction: Double; var status: String }
    enum Outcome { case success(URL); case failure(String) }

    private var bakeTask: Task<Void, Never>?

    /// A stable per-target bake cache: `~/Library/Caches/Nebula/<target>`.
    static func cacheDir(forTarget target: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
    }

    nonisolated static func hasAllLayers(in dir: URL) -> Bool {
        ["master", "starless", "stars", "denoised"].allSatisfy {
            FileManager.default.fileExists(atPath:
                dir.appendingPathComponent("\($0).fits").path)
        }
    }

    nonisolated static func hasCurrentPipeline(in dir: URL) -> Bool {
        guard hasAllLayers(in: dir),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrected.fits").path),
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? NebulaCore.Manifest(jsonData: data) else { return false }
        return manifest.pipelineVersion == Baker.pipelineVersion
    }

    /// Bake `subsDir` into a layers dir, streaming progress via `onProgress`
    /// (on the main actor). Returns the output dir or a failure message. A
    /// complete cached bake returns immediately.
    func bake(subsDir: URL, target: String,
              onProgress: @MainActor (Progress) -> Void) async -> Outcome {
        let out = Self.cacheDir(forTarget: target)
        if Self.hasCurrentPipeline(in: out) {
            onProgress(Progress(fraction: 1.0, status: "Loaded cached bake"))
            return .success(out)
        }
        // A stale-pipeline cache is still a complete image. If the source subs
        // are offline, open it as-is rather than deleting layers we cannot
        // rebuild — the target re-develops next time the source is reachable.
        if !FileManager.default.fileExists(atPath: subsDir.path), Self.hasAllLayers(in: out) {
            onProgress(Progress(fraction: 1.0, status: "Loaded cached bake"))
            return .success(out)
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out.appendingPathComponent("thumb.png"))
        for name in ["master", "corrected", "denoised", "starless", "stars"] {
            try? FileManager.default.removeItem(at: out.appendingPathComponent("\(name).fits"))
        }
        // Remember where this bake came from so the Library can offer "Re-develop".
        try? subsDir.path.write(to: out.appendingPathComponent("source.txt"),
                                atomically: true, encoding: .utf8)

        // The native bake is CPU-heavy (Siril + AI), so run it off the main actor
        // and stream progress back through an AsyncStream (Sendable continuation),
        // consumed here on the main actor.
        var failure: String?
        let stream = AsyncStream<Progress> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    _ = try Baker().bake(subsDir: subsDir, outDir: out) { p in
                        continuation.yield(Progress(fraction: p.fraction, status: p.status))
                    }
                } catch {
                    continuation.yield(Progress(fraction: 1.0, status: "\u{1}\(error)"))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            Task { @MainActor in self.bakeTask = task }
        }
        for await p in stream {
            if p.status.hasPrefix("\u{1}") {          // error sentinel
                failure = String(p.status.dropFirst()); continue
            }
            onProgress(p)
        }
        bakeTask = nil

        if let failure { return .failure("Bake failed: \(failure)") }
        if Self.hasAllLayers(in: out) { return .success(out) }
        return .failure("Bake produced no layers. See \(out.appendingPathComponent("_work/siril.log").path)")
    }

    /// Best-effort cancel: stops the loop and cancels the task. In-flight Siril /
    /// AI work already dispatched may run to completion (native stages don't yet
    /// poll for cancellation).
    func cancel() { bakeTask?.cancel(); bakeTask = nil }
}

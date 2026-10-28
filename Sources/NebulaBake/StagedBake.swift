// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// A bake built beside the cache and swapped into place only once it is complete.
///
/// Baking straight into a target's cache folder meant deleting the finished
/// image first. A cancel, a failed re-develop (subs went offline, a model was
/// unreadable) or a crash mid-write then left the user with nothing, or with a
/// half-written layer that still looked complete. Building in a hidden
/// `.staging/` folder keeps the old image untouched until the new one exists;
/// the swap is two renames on the same volume.
public struct StagedBake: Sendable {
    /// Where the finished bake lives: `<cacheRoot>/<target>`.
    public let destination: URL
    /// Where this bake is being built: `<cacheRoot>/.staging/<uuid>`.
    public let directory: URL

    public static func stagingRoot(in cacheRoot: URL) -> URL {
        cacheRoot.appendingPathComponent(".staging", isDirectory: true)
    }

    public init(destination: URL) throws {
        self.destination = destination
        directory = Self.stagingRoot(in: destination.deletingLastPathComponent())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Copy files a re-bake may reuse from the current bake (relative paths;
    /// APFS clones them, so this is cheap). Missing files are skipped.
    public func seed(_ relativePaths: [String]) {
        let fm = FileManager.default
        for path in relativePaths {
            let source = destination.appendingPathComponent(path)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = directory.appendingPathComponent(path)
            try? fm.createDirectory(at: target.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: target)
        }
    }

    /// Swap the finished bake into place. If the final rename fails, the
    /// previous bake is put back, so the destination is never left empty.
    public func commit() throws {
        let fm = FileManager.default
        let retired = directory.deletingLastPathComponent()
            .appendingPathComponent("retired-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: retired) }
        do {
            try fm.moveItem(at: directory, to: destination)
        } catch {
            if hadPrevious { try? fm.moveItem(at: retired, to: destination) }
            throw error
        }
        try? fm.removeItem(at: retired)
    }

    /// Throw this bake away; the destination is untouched.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Throw a failed bake away but keep its logs in the destination's
    /// `_work/`, so the failure can still be diagnosed. Only logs are copied;
    /// the image there is untouched.
    public func discardKeepingLogs() {
        let fm = FileManager.default
        let work = directory.appendingPathComponent("_work", isDirectory: true)
        let keep = destination.appendingPathComponent("_work", isDirectory: true)
        let logs = ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "log" }
        if !logs.isEmpty {
            try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
            for log in logs {
                let target = keep.appendingPathComponent(log.lastPathComponent)
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: log, to: target)
            }
        }
        discard()
    }

    /// Sweep bakes that never finished (force-quit, crash, or a failed bake
    /// kept for its logs). Only call when no bake is running, e.g. at launch.
    public static func removeAbandoned(in cacheRoot: URL) {
        try? FileManager.default.removeItem(at: stagingRoot(in: cacheRoot))
    }
}

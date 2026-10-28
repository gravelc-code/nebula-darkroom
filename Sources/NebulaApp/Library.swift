// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore
import NebulaBake

/// A previously-developed target sitting in the bake cache. The Library grid
/// (design §6, "a photo app") lists these so re-opening is one tap — the bake is
/// already done, so it lands straight in the editor.
struct CachedTarget: Identifiable, Hashable, Sendable {
    let name: String          // cache-dir name == the target's cache key (see `CacheKey`)
    let dir: URL              // the bake dir (holds master/denoised/starless/stars)
    let modified: Date        // newest layer mtime → sort most-recent first
    let sourceSubs: URL?      // the subs folder it was baked from, if still reachable
    let pipelineVersion: Int? // bake pipeline version from the manifest, if known

    var id: String { dir.path }
    var thumbURL: URL { dir.appendingPathComponent("thumb.png") }

    /// This target was baked by an older pipeline, so a re-develop would produce
    /// better layers (e.g. tighter stars). Only actionable when we still know its
    /// subs folder. Drives the "Update" badge in the grid.
    var needsRedevelop: Bool {
        sourceSubs != nil && (pipelineVersion ?? 0) < Baker.pipelineVersion
    }
}

enum Library {
    /// Every complete bake in the cache, most recent first. Touches the disk
    /// (and, to check each source is still reachable, possibly a network share),
    /// so call it off the main thread.
    static func cachedTargets(in root: URL = BakeRunner.defaultCacheRoot) -> [CachedTarget] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return entries.compactMap { dir -> CachedTarget? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  BakeRunner.hasAllLayers(in: dir) else { return nil }
            let modified = (try? dir.appendingPathComponent("master.fits")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let source = (try? String(contentsOf: dir.appendingPathComponent("source.txt"),
                                      encoding: .utf8))
                .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            let version = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
                .flatMap { try? Manifest(jsonData: $0) }?.pipelineVersion
            return CachedTarget(name: dir.lastPathComponent, dir: dir,
                                modified: modified, sourceSubs: source, pipelineVersion: version)
        }
        .sorted { $0.modified > $1.modified }
    }
}

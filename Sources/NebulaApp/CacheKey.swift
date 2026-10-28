// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Which cache folder (`<cacheRoot>/<key>`) a subs folder develops into.
///
/// Keying by the cleaned folder name alone let different captures collide:
/// "M 42_mosaic_sub" and "M 42_sub" both became "M 42", as did two "M 42_sub"
/// folders from different nights, so opening one showed the other's image. The
/// key stays the human target name wherever that is unambiguous (existing
/// caches keep working), mosaics say so ("M 42 mosaic"), and a name already
/// taken by a different capture gets a numbered sibling ("M 42 (2)").
///
/// Manual open, re-develop and watch mode all resolve through here, so they
/// always agree on the folder.
enum CacheKey {
    /// "M 42_sub" → "M 42"; "M 42_mosaic_sub" → "M 42 mosaic". Never hidden
    /// (a leading dot would vanish from the Library and could hit `.staging`).
    static func baseName(for subsDir: URL) -> String {
        let n = subsDir.lastPathComponent
        var base = n
        for (suffix, replacement) in [("_mosaic_subs", " mosaic"), ("_mosaic_sub", " mosaic"),
                                      ("_subs", ""), ("_sub", "")] where n.hasSuffix(suffix) {
            let stem = String(n.dropLast(suffix.count))
            base = stem.isEmpty ? n : stem + replacement
            break
        }
        base = String(base.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "Untitled" : base
    }

    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// Resolve the key for `subsDir`. `claimed` maps keys already promised to
    /// an in-flight bake to the subs folder that bake is reading, so two new
    /// captures with the same name can't both pick the same free folder.
    /// Reads only small files (`source.txt`/`source.json`); call off the main thread.
    static func resolve(subsDir: URL, fingerprint: SourceFingerprint?, cacheRoot: URL,
                        claimed: [String: URL] = [:]) -> String {
        let fm = FileManager.default
        // 1. Already being developed from this very folder.
        if let (key, _) = claimed.first(where: { samePath($0.value, subsDir) }) { return key }

        // 2. A cache made from this very folder keeps its name — including
        //    names from before mosaics were told apart.
        let entries = (try? fm.contentsOfDirectory(
            at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let base = baseName(for: subsDir)
        let fromHere = entries.filter {
            guard let src = SourceFingerprint.recordedSource(in: $0) else { return false }
            return samePath(src, subsDir) && claimed[$0.lastPathComponent] == nil
        }.map(\.lastPathComponent)
        // Prefer the plain name when a folder somehow owns several.
        if let key = fromHere.first(where: { $0 == base }) ?? fromHere.sorted().first { return key }

        // 3. The plain name, then "(2)", "(3)"…: the first that is free, holds
        //    no image, is a legacy bake that never recorded its source, or holds
        //    this same capture after the folder was moved (identical fingerprint).
        for i in 1...999 {
            let key = i == 1 ? base : "\(base) (\(i))"
            if let other = claimed[key], !samePath(other, subsDir) { continue }
            let dir = cacheRoot.appendingPathComponent(key, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { return key }
            guard BakeRunner.hasAllLayers(in: dir) else { return key }
            guard SourceFingerprint.recordedSource(in: dir) != nil else { return key }
            if let fp = fingerprint, fp.count > 0, SourceFingerprint.recorded(in: dir) == fp {
                return key
            }
        }
        return "\(base) (\(UUID().uuidString.prefix(8)))"
    }
}

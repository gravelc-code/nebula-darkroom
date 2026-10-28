// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore

/// What a subs folder looked like: how many light frames, how many bytes, and
/// the newest modification time. Cheap to take (one directory listing with
/// prefetched attributes, no file reads), so watch mode can poll it, and
/// recorded with every bake (`source.json`) so a folder that has since gained
/// frames is recognised as needing a fresh develop.
struct SourceFingerprint: Codable, Equatable, Sendable {
    var count: Int
    var totalBytes: Int64
    var newestModified: Date

    /// Written beside `source.txt` in the bake folder.
    static let fileName = "source.json"

    /// A FITS light frame, as the stacker sees it. Hidden files and macOS
    /// `._` AppleDouble companions (common on SMB/exFAT) are not frames.
    static func isLight(_ name: String) -> Bool {
        let n = name.lowercased()
        guard !n.hasPrefix(".") else { return false }
        return n.hasSuffix(".fit") || n.hasSuffix(".fits")
    }

    /// The folder's current fingerprint, or nil if it can't be listed (offline,
    /// unplugged, not a folder).
    static func of(_ dir: URL) -> SourceFingerprint? {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        else { return nil }
        var fp = SourceFingerprint(count: 0, totalBytes: 0, newestModified: .distantPast)
        for url in items where isLight(url.lastPathComponent) {
            let values = try? url.resourceValues(forKeys: keys)
            fp.count += 1
            fp.totalBytes += Int64(values?.fileSize ?? 0)
            if let m = values?.contentModificationDate, m > fp.newestModified { fp.newestModified = m }
        }
        return fp
    }

    /// The fingerprint a bake recorded, if any (bakes before this existed have none).
    static func recorded(in bakeDir: URL) -> SourceFingerprint? {
        (try? Data(contentsOf: bakeDir.appendingPathComponent(fileName)))
            .flatMap { try? JSONDecoder().decode(SourceFingerprint.self, from: $0) }
    }

    func write(to bakeDir: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: bakeDir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// The subs folder a bake was made from: `source.txt`, else the path the
    /// bake itself recorded in its manifest (older bakes), if either exists.
    static func recordedSource(in bakeDir: URL) -> URL? {
        let text = (try? String(contentsOf: bakeDir.appendingPathComponent("source.txt"), encoding: .utf8))
            ?? (try? Data(contentsOf: bakeDir.appendingPathComponent("manifest.json")))
                .flatMap { try? Manifest(jsonData: $0) }?.target.subsPath
        return text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }
}

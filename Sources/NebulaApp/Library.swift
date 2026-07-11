import Foundation

/// A previously-developed target sitting in the bake cache. The Library grid
/// (design §6, "a photo app") lists these so re-opening is one tap — the bake is
/// already done, so it lands straight in the editor.
struct CachedTarget: Identifiable, Hashable {
    let name: String          // cache-dir name == the clean target name
    let dir: URL              // the bake dir (holds master/denoised/starless/stars)
    let modified: Date        // newest layer mtime → sort most-recent first

    var id: String { dir.path }
    var thumbURL: URL { dir.appendingPathComponent("thumb.png") }
}

enum Library {
    /// Every complete bake in `~/Library/Caches/Nebula/`, most recent first.
    static func cachedTargets() -> [CachedTarget] {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return entries.compactMap { dir -> CachedTarget? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  BakeRunner.hasAllLayers(in: dir) else { return nil }
            let modified = (try? dir.appendingPathComponent("master.fits")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return CachedTarget(name: dir.lastPathComponent, dir: dir, modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }
}

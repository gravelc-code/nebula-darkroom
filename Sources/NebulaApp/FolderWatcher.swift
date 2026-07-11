import Foundation

/// Watch mode (design §6): watch a parent folder for new Seestar `<Target>_sub(s)`
/// subfolders that contain FITS lights, and report each one once. Polls rather
/// than FSEvents — simpler, and a few-second latency is irrelevant for a capture
/// that lands over minutes. Only folders that already contain FITS are reported,
/// so a target isn't baked before Siril has anything to stack.
@MainActor
final class FolderWatcher {
    private let root: URL
    private let onNew: (URL) -> Void
    private var seen: Set<String>
    private var timer: Timer?

    init(root: URL, onNew: @escaping (URL) -> Void) {
        self.root = root
        self.onNew = onNew
        // Seed with what's already there so we only fire on NEW arrivals.
        seen = Set(Self.subTargets(in: root).map(\.path))
    }

    func start(interval: TimeInterval = 8) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Report new sub-target folders since the last scan.
    func scan() {
        for dir in Self.subTargets(in: root) where !seen.contains(dir.path) {
            seen.insert(dir.path)
            onNew(dir)
        }
    }

    /// Immediate subfolders named `…_sub(s)` that contain at least one FITS light.
    static func subTargets(in root: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return items.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            let n = url.lastPathComponent.lowercased()
            guard n.hasSuffix("_sub") || n.hasSuffix("_subs") else { return false }
            let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return files.contains { $0.lowercased().hasSuffix(".fit") || $0.lowercased().hasSuffix(".fits") }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Watch mode (design §6): watch a parent folder for Seestar `<Target>_sub(s)`
/// subfolders that contain FITS lights, and report each one once its contents
/// have settled — and again whenever it later gains (or loses) frames.
///
/// A capture lands over minutes: the Seestar writes a frame every few seconds,
/// a Finder copy streams hundreds of files. Reporting at the first FITS baked a
/// handful of frames and never looked again. A folder is now reported only
/// after its frame count and total size have held still for `quietPeriod`
/// (≥ 60 s of polls), with its `SourceFingerprint`, so the app can tell a new
/// capture, an unchanged one and a grown one apart.
///
/// Polls rather than FSEvents — simpler, works on network shares, and a few
/// seconds' latency is irrelevant here. Each poll is one listing of the root
/// plus one attribute-prefetching listing per `_sub` folder, done off the main
/// thread; a slow share never stacks up overlapping polls.
@MainActor
final class FolderWatcher {
    struct Arrival: Sendable, Equatable {
        let subs: URL
        let fingerprint: SourceFingerprint
        /// The folder changed after it was first reported this session — so it
        /// has new frames even if its existing bake recorded no fingerprint.
        let changedSinceFirstReport: Bool
    }

    static let defaultQuietPeriod: TimeInterval = 60

    let root: URL
    private let onReady: (Arrival) -> Void
    private var tracker: QuietTracker
    private var timer: Timer?
    private var scanning = false

    init(root: URL, quietPeriod: TimeInterval = FolderWatcher.defaultQuietPeriod,
         onReady: @escaping (Arrival) -> Void) {
        self.root = root
        self.onReady = onReady
        tracker = QuietTracker(quietPeriod: quietPeriod)
    }

    func start(interval: TimeInterval = 8) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()          // start every folder's quiet clock now, not one interval later
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// Folders seen but still changing (or not yet quiet for long enough).
    var pendingCount: Int { tracker.pendingCount }

    private func scan() {
        guard timer != nil, !scanning else { return }
        scanning = true
        let root = self.root
        Task { [weak self] in
            let snapshot = await blockingIO { Self.snapshot(of: root) }
            guard let self else { return }
            self.scanning = false
            guard self.timer != nil else { return }        // stopped meanwhile
            for arrival in self.tracker.observe(snapshot, at: Date()) { self.onReady(arrival) }
        }
    }

    /// Every `…_sub(s)` folder directly under `root` that holds at least one
    /// FITS light, with its current fingerprint.
    nonisolated static func snapshot(of root: URL) -> [URL: SourceFingerprint] {
        var out: [URL: SourceFingerprint] = [:]
        for dir in candidateFolders(in: root) {
            if let fp = SourceFingerprint.of(dir), fp.count > 0 { out[dir] = fp }
        }
        return out
    }

    /// Immediate subfolders named `…_sub(s)` that contain at least one FITS light.
    nonisolated static func subTargets(in root: URL) -> [URL] {
        candidateFolders(in: root)
            .filter { (SourceFingerprint.of($0)?.count ?? 0) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func candidateFolders(in root: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return items.filter { url in
            let n = url.lastPathComponent.lowercased()
            guard n.hasSuffix("_sub") || n.hasSuffix("_subs") else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

/// The quiet-period bookkeeping behind `FolderWatcher`, kept pure so it can be
/// tested without waiting a minute.
struct QuietTracker {
    let quietPeriod: TimeInterval
    /// Latest fingerprint per folder and when it was first seen unchanged.
    private var settling: [String: (fingerprint: SourceFingerprint, since: Date)] = [:]
    /// What was last reported per folder. Kept when a folder disappears (a
    /// sleeping Seestar), so an unchanged return isn't reported again.
    private var reported: [String: SourceFingerprint] = [:]

    init(quietPeriod: TimeInterval) { self.quietPeriod = quietPeriod }

    var pendingCount: Int { settling.count }

    /// Feed one poll. Returns the folders that have just become ready.
    mutating func observe(_ snapshot: [URL: SourceFingerprint],
                          at now: Date) -> [FolderWatcher.Arrival] {
        var ready: [FolderWatcher.Arrival] = []
        for (url, fp) in snapshot.sorted(by: { $0.key.path < $1.key.path }) {
            let key = url.standardizedFileURL.path
            if reported[key] == fp { settling[key] = nil; continue }      // nothing new
            guard let s = settling[key], s.fingerprint == fp else {
                settling[key] = (fp, now)          // new, or still changing: restart the clock
                continue
            }
            if now.timeIntervalSince(s.since) >= quietPeriod {
                ready.append(.init(subs: url, fingerprint: fp,
                                   changedSinceFirstReport: reported[key] != nil))
                reported[key] = fp
                settling[key] = nil
            }
        }
        let present = Set(snapshot.keys.map { $0.standardizedFileURL.path })
        settling = settling.filter { present.contains($0.key) }
        return ready
    }
}

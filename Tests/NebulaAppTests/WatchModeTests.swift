// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp
@testable import NebulaBake

/// Watch mode must wait for a capture to finish landing, and notice when it grows.
final class QuietTrackerTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Volumes/Seestar/MyWorks/M 42_sub")
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fp(_ count: Int) -> SourceFingerprint {
        SourceFingerprint(count: count, totalBytes: Int64(count) * 4_000_000,
                          newestModified: Date(timeIntervalSince1970: 1_700_000_000 + Double(count)))
    }

    func testAFolderStillBeingCopiedIsNotReported() {
        var tracker = QuietTracker(quietPeriod: 60)
        // A frame lands every poll for ten minutes: never quiet, never reported.
        for poll in 0..<75 {
            let ready = tracker.observe([folder: fp(poll + 1)], at: t0.addingTimeInterval(Double(poll) * 8))
            XCTAssertEqual(ready, [], "poll \(poll)")
        }
    }

    func testReportedOnceAfterSixtySecondsOfQuiet() {
        var tracker = QuietTracker(quietPeriod: 60)
        XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0), [])
        XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(56)), [], "not yet 60 s")
        let ready = tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(64))
        XCTAssertEqual(ready, [.init(subs: folder, fingerprint: fp(30), changedSinceFirstReport: false)])
        for later in 1...20 {
            XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(64 + Double(later) * 8)),
                           [], "reported once only")
        }
    }

    func testAGrowingFolderIsReportedAgainOnceItSettles() {
        var tracker = QuietTracker(quietPeriod: 60)
        _ = tracker.observe([folder: fp(30)], at: t0)
        XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(64)).count, 1)
        // More frames arrive (tonight's second session).
        XCTAssertEqual(tracker.observe([folder: fp(31)], at: t0.addingTimeInterval(600)), [])
        XCTAssertEqual(tracker.observe([folder: fp(45)], at: t0.addingTimeInterval(608)), [])
        let ready = tracker.observe([folder: fp(45)], at: t0.addingTimeInterval(670))
        XCTAssertEqual(ready, [.init(subs: folder, fingerprint: fp(45), changedSinceFirstReport: true)])
    }

    func testAFolderThatGoesOfflineAndReturnsUnchangedIsNotReportedAgain() {
        var tracker = QuietTracker(quietPeriod: 60)
        _ = tracker.observe([folder: fp(30)], at: t0)
        _ = tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(64))
        XCTAssertEqual(tracker.observe([:], at: t0.addingTimeInterval(200)), [])       // Seestar asleep
        XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(300)), [])
        XCTAssertEqual(tracker.observe([folder: fp(30)], at: t0.addingTimeInterval(400)), [])
    }
}

final class FolderSnapshotTests: XCTestCase {
    private var box: Sandbox!
    override func setUpWithError() throws { box = try Sandbox() }
    override func tearDown() { box.remove() }

    func testOnlySubFoldersWithFramesCountAndOnlyTheirFrames() throws {
        let a = try box.subs("M 42_sub", frames: 3)
        // macOS AppleDouble companions on SMB/exFAT are not frames.
        try Data("x".utf8).write(to: a.appendingPathComponent("._Light_0000.fit"))
        try box.subs("M 31_subs", frames: 0)
        try box.subs("Stacked", frames: 2)
        let snapshot = FolderWatcher.snapshot(of: box.root)
        XCTAssertEqual(snapshot.keys.map(\.lastPathComponent), ["M 42_sub"])
        let fp = try XCTUnwrap(snapshot.values.first)
        XCTAssertEqual(fp.count, 3)
        XCTAssertEqual(fp.totalBytes, Int64(2880 * 3 + 0 + 1 + 2))
        XCTAssertEqual(SourceFingerprint.of(a), fp)
    }

    func testAFingerprintChangesWhenAFrameArrives() throws {
        let a = try box.subs("M 42_sub", frames: 2)
        let before = try XCTUnwrap(SourceFingerprint.of(a))
        try box.addFrame(to: a, index: 7)
        XCTAssertNotEqual(SourceFingerprint.of(a), before)
        XCTAssertNil(SourceFingerprint.of(box.root.appendingPathComponent("missing")))
    }

    func testWatchDecision() throws {
        let subs = try box.subs("M 42_sub", frames: 2)
        let fp = try XCTUnwrap(SourceFingerprint.of(subs))
        let dir = box.cache.appendingPathComponent("M 42")
        XCTAssertTrue(BakeCoordinator.watchNeedsBake(cacheDir: dir, fingerprint: fp,
                                                     changedSinceFirstReport: false), "never developed")
        try writeFinishedBake(dir, marker: "M 42", subs: subs)
        // A bake from before fingerprints: current unless it visibly changed.
        XCTAssertFalse(BakeCoordinator.watchNeedsBake(cacheDir: dir, fingerprint: fp,
                                                      changedSinceFirstReport: false))
        XCTAssertTrue(BakeCoordinator.watchNeedsBake(cacheDir: dir, fingerprint: fp,
                                                     changedSinceFirstReport: true))
        try fp.write(to: dir)
        XCTAssertFalse(BakeCoordinator.watchNeedsBake(cacheDir: dir, fingerprint: fp,
                                                      changedSinceFirstReport: true), "same frames")
        var grown = fp
        grown.count += 1
        XCTAssertTrue(BakeCoordinator.watchNeedsBake(cacheDir: dir, fingerprint: grown,
                                                     changedSinceFirstReport: false), "new frames")
    }
}

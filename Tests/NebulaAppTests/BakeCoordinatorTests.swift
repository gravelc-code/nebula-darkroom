// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp
@testable import NebulaBake

@MainActor
final class ProgressLog { var fractions: [Double] = [] }

/// One registry of bakes for the user's develops and watch mode's: never two
/// bakes of one target, watch bakes one at a time, re-develop when frames
/// arrive, and quitting stops everything.
@MainActor
final class BakeCoordinatorTests: XCTestCase {
    private var box: Sandbox!
    private var probe: BakeProbe!
    private var coordinator: BakeCoordinator!

    override func setUp() async throws {
        box = try Sandbox()
        probe = BakeProbe()
        coordinator = BakeCoordinator(cacheRoot: box.cache, work: probe.work())
    }

    override func tearDown() async throws {
        probe.releaseEverything()
        await coordinator.cancelEverythingAndWait(timeout: .seconds(5))
        box.remove()
    }

    private func arrival(_ subs: URL, changed: Bool = false) throws -> FolderWatcher.Arrival {
        .init(subs: subs, fingerprint: try XCTUnwrap(SourceFingerprint.of(subs)),
              changedSinceFirstReport: changed)
    }

    private func finished(_ key: String) -> Bool {
        BakeRunner.hasCurrentPipeline(in: coordinator.cacheDir(forKey: key))
    }

    func testWatchModeDevelopsOneFolderAtATime() async throws {
        let names = ["M 42_sub", "M 31_sub", "M 8_sub"]
        for name in names { await coordinator.watchArrived(try arrival(try box.subs(name))) }
        XCTAssertEqual(coordinator.watchKeys, ["M 42", "M 31", "M 8"])
        await eventually("first bake to start") { probe.started.count == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.started, ["M 42_sub"], "the others wait their turn")
        for (i, name) in names.enumerated() {
            await eventually("\(name) to start") { probe.started.count == i + 1 }
            probe.release(name)
        }
        await eventually("all done") { !coordinator.isBusy }
        XCTAssertEqual(probe.started, names, "in arrival order")
        XCTAssertEqual(probe.maxConcurrent, 1)
        for key in ["M 42", "M 31", "M 8"] { XCTAssertTrue(finished(key), key) }
    }

    func testOpeningATargetWatchModeIsDevelopingJoinsThatBake() async throws {
        let subs = try box.subs("M 42_sub")
        await coordinator.watchArrived(try arrival(subs))
        await eventually("watch bake to start") { probe.started.count == 1 }

        let progress = ProgressLog()
        let key = await coordinator.resolveKey(for: subs)
        XCTAssertEqual(key, "M 42")
        let coordinator = self.coordinator!
        let manual = Task { await coordinator.bakeManually(subs: subs, key: key, force: false) {
            progress.fractions.append($0.fraction)
        } }
        await eventually("join to pick up progress") { !progress.fractions.isEmpty }
        probe.release("M 42_sub")
        guard case .success(let dir) = await manual.value else { return XCTFail("expected the joined result") }
        XCTAssertEqual(dir.lastPathComponent, "M 42")
        XCTAssertEqual(probe.started, ["M 42_sub"], "no second bake of the same frames")
        XCTAssertEqual(progress.fractions, [0.5])
    }

    func testCancelOnAJoinedDevelopCancelsIt() async throws {
        let subs = try box.subs("M 42_sub")
        await coordinator.watchArrived(try arrival(subs))
        await eventually("watch bake to start") { probe.started.count == 1 }
        let coordinator = self.coordinator!
        let manual = Task { await coordinator.bakeManually(subs: subs, key: "M 42", force: false) { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        coordinator.cancelManual()
        guard case .cancelled = await manual.value else { return XCTFail("expected a cancel") }
        XCTAssertEqual(probe.sawCancel, ["M 42_sub"])
        XCTAssertFalse(finished("M 42"), "Cancel changes nothing")
    }

    func testOpeningAQueuedTargetDevelopsItNowAndOnlyOnce() async throws {
        let first = try box.subs("M 42_sub"), second = try box.subs("M 31_sub")
        await coordinator.watchArrived(try arrival(first))
        await coordinator.watchArrived(try arrival(second))
        await eventually("first watch bake") { probe.started == ["M 42_sub"] }
        // The user opens the queued one: it starts now, beside the watch bake.
        probe.release("M 31_sub")
        guard case .success = await coordinator.bakeManually(subs: second, key: "M 31", force: false,
                                                             onProgress: { _ in })
        else { return XCTFail("expected success") }
        XCTAssertEqual(probe.started, ["M 42_sub", "M 31_sub"])
        probe.release("M 42_sub")
        await eventually("queue drained") { !coordinator.isBusy }
        XCTAssertEqual(probe.started, ["M 42_sub", "M 31_sub"], "the promoted one isn't baked twice")
    }

    func testFramesArrivingLaterAreDevelopedAndUnchangedFoldersAreNot() async throws {
        let subs = try box.subs("M 42_sub", frames: 2)
        probe.releaseEverything()
        await coordinator.watchArrived(try arrival(subs))
        await eventually("first develop") { !coordinator.isBusy && finished("M 42") }
        XCTAssertEqual(SourceFingerprint.recorded(in: coordinator.cacheDir(forKey: "M 42")),
                       SourceFingerprint.of(subs), "the bake records what it was made from")

        // Reported again with the same frames (e.g. after a relaunch): nothing to do.
        await coordinator.watchArrived(try arrival(subs))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.started.count, 1)

        // More frames: develop again, into the same target.
        try box.addFrame(to: subs, index: 2)
        await coordinator.watchArrived(try arrival(subs, changed: true))
        await eventually("re-develop") { probe.started.count == 2 && !coordinator.isBusy }
        XCTAssertEqual(SourceFingerprint.recorded(in: coordinator.cacheDir(forKey: "M 42"))?.count, 3)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: box.cache.path)
                        .filter { !$0.hasPrefix(".") }, ["M 42"])
    }

    func testAWatchReportDuringTheUsersDevelopIsCheckedAfterwards() async throws {
        let subs = try box.subs("M 42_sub", frames: 2)
        let coordinator = self.coordinator!
        let manual = Task { await coordinator.bakeManually(subs: subs, key: "M 42", force: false) { _ in } }
        await eventually("manual bake") { probe.started.count == 1 }
        // A frame lands mid-develop and watch mode reports the grown folder.
        try box.addFrame(to: subs, index: 2)
        await coordinator.watchArrived(try arrival(subs, changed: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(probe.started.count, 1, "never a second bake of a busy target")
        probe.releaseEverything()
        guard case .success = await manual.value else { return XCTFail("expected success") }
        // The develop recorded the 2-frame folder, so the 3-frame report re-develops.
        await eventually("follow-up develop") { probe.started.count == 2 && !coordinator.isBusy }
        XCTAssertEqual(SourceFingerprint.recorded(in: coordinator.cacheDir(forKey: "M 42"))?.count, 3)
    }

    func testQuittingCancelsEverythingAndWaitsForIt() async throws {
        let a = try box.subs("M 42_sub"), b = try box.subs("M 31_sub"), c = try box.subs("M 8_sub")
        await coordinator.watchArrived(try arrival(a))
        await coordinator.watchArrived(try arrival(b))
        let coordinator = self.coordinator!
        let manual = Task { await coordinator.bakeManually(subs: c, key: "M 8", force: false) { _ in } }
        await eventually("both running") { probe.started.count == 2 }
        let stopped = await coordinator.cancelEverythingAndWait(timeout: .seconds(5))
        XCTAssertTrue(stopped)
        XCTAssertFalse(coordinator.isBusy)
        guard case .cancelled = await manual.value else { return XCTFail("expected a cancel") }
        XCTAssertEqual(Set(probe.sawCancel), ["M 42_sub", "M 8_sub"])
        XCTAssertFalse(probe.started.contains("M 31_sub"), "queued work never starts")
        for key in ["M 42", "M 31", "M 8"] { XCTAssertFalse(finished(key), key) }
        // And no new work is accepted while quitting.
        await coordinator.watchArrived(try arrival(b))
        XCTAssertTrue(coordinator.watchKeys.isEmpty)
    }
}

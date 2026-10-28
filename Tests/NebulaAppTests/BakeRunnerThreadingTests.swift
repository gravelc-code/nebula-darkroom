// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp
@testable import NebulaBake
import NebulaCore

/// The bake blocks for minutes, so it must not sit on Swift concurrency's
/// cooperative pool — yet Cancel must still reach it.
@MainActor
final class BakeRunnerThreadingTests: XCTestCase {
    private var box: Sandbox!
    override func setUp() async throws { box = try Sandbox() }
    override func tearDown() async throws { box.remove() }

    private final class Barrier: @unchecked Sendable {
        private let lock = NSLock()
        private var arrived = 0
        private var threadNames: [String] = []
        func arrive() { lock.withLock { arrived += 1; threadNames.append(Thread.current.name ?? "") } }
        var count: Int { lock.withLock { arrived } }
        var names: [String] { lock.withLock { threadNames } }
    }

    func testManyBlockingBakesDoNotStarveTheCooperativePool() async throws {
        // More simultaneous blocking bakes than the cooperative pool has
        // threads, each waiting for all the others to start. On the pool this
        // can never complete; on dedicated threads it does at once.
        let n = ProcessInfo.processInfo.activeProcessorCount + 2
        let barrier = Barrier()
        let runner = BakeRunner(cacheRoot: box.cache) { subs, out, _ in
            barrier.arrive()
            let giveUp = Date().addingTimeInterval(10)
            while barrier.count < n {
                if Date() > giveUp { throw CocoaError(.featureUnsupported) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            try writeFinishedBake(out, marker: subs.lastPathComponent)
        }
        var bakes: [Task<BakeRunner.Outcome, Never>] = []
        for i in 0..<n {
            let subs = try box.subs("T\(i)_sub", frames: 1)
            bakes.append(Task { await runner.bake(subsDir: subs, target: "T\(i)") { _ in } })
        }
        // Meanwhile the app's own async work keeps flowing.
        let started = Date()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        for bake in bakes {
            guard case .success = await bake.value else { return XCTFail("a bake never got a thread") }
        }
        if #available(macOS 15.0, *) {
            XCTAssertEqual(Set(barrier.names), [BakeExecutor.threadName])
        }
    }

    func testCancelReachesTheBakeOnItsOwnThread() async throws {
        let subs = try box.subs("M 42_sub")
        let saw = Barrier()
        let runner = BakeRunner(cacheRoot: box.cache) { _, _, _ in
            let giveUp = Date().addingTimeInterval(10)
            while !Task.isCancelled {
                if Date() > giveUp { throw CocoaError(.featureUnsupported) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            saw.arrive()
            try Task.checkCancellation()
        }
        let bake = Task { await runner.bake(subsDir: subs, target: "M 42") { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(runner.isBusy)
        runner.cancel()
        guard case .cancelled = await bake.value else { return XCTFail("expected a cancel") }
        XCTAssertEqual(saw.count, 1, "Task.isCancelled became true inside the bake")
        XCTAssertFalse(runner.isBusy)
    }

    func testCancelTheMomentADevelopStartsChangesNothing() async throws {
        // Cancel lands while the bake is still checking the cache (or has
        // just raced past it, ignoring cancellation): nothing may be kept.
        let subs = try box.subs("M 42_sub")
        let runner = BakeRunner(cacheRoot: box.cache) { _, out, _ in
            try writeFinishedBake(out, marker: "new")
        }
        let bake = Task { await runner.bake(subsDir: subs, target: "M 42") { _ in } }
        await Task.yield()
        XCTAssertTrue(runner.isBusy, "registered before its first suspension")
        runner.cancel()
        guard case .cancelled = await bake.value else { return XCTFail("expected a cancel") }
        XCTAssertFalse(BakeRunner.hasAllLayers(in: box.cache.appendingPathComponent("M 42")))
    }

    func testUnchangedFramesOpenTheCacheAndNewFramesDevelopAgain() async throws {
        let subs = try box.subs("M 42_sub", frames: 2)
        let runs = Barrier()
        let runner = BakeRunner(cacheRoot: box.cache) { subs, out, _ in
            runs.arrive()
            try writeFinishedBake(out, marker: "run\(runs.count)", subs: subs)
        }
        guard case .success(let dir) = await runner.bake(subsDir: subs, target: "M 42", onProgress: { _ in })
        else { return XCTFail("first develop") }
        XCTAssertEqual(SourceFingerprint.recorded(in: dir), SourceFingerprint.of(subs))
        XCTAssertEqual(contents(dir.appendingPathComponent("source.txt")), subs.path)

        var statuses: [String] = []
        _ = await runner.bake(subsDir: subs, target: "M 42") { statuses.append($0.status) }
        XCTAssertEqual(runs.count, 1, "same frames: the cached image opens")
        XCTAssertEqual(statuses, ["Loaded cached bake"])

        try box.addFrame(to: subs, index: 5)
        _ = await runner.bake(subsDir: subs, target: "M 42") { _ in }
        XCTAssertEqual(runs.count, 2, "new frames: developed again")
        XCTAssertEqual(contents(dir.appendingPathComponent("master.fits")), "run2")
    }

    func testTheUsersLookSurvivesARedevelop() async throws {
        let subs = try box.subs("M 42_sub")
        var edited = LookState.default
        edited[.glow] = 0.91
        let dir = box.cache.appendingPathComponent("M 42")
        try writeFinishedBake(dir, marker: "old", subs: subs, look: edited,
                              lookVersion: Baker.pipelineVersion)
        let runner = BakeRunner(cacheRoot: box.cache) { subs, out, _ in
            try writeFinishedBake(out, marker: "new", subs: subs)        // the bake's default look
        }
        guard case .success = await runner.bake(subsDir: subs, target: "M 42", force: true,
                                                onProgress: { _ in })
        else { return XCTFail("expected success") }
        let manifest = try Manifest(jsonData: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(contents(dir.appendingPathComponent("master.fits")), "new")
        XCTAssertEqual(manifest.look(forPipelineVersion: Baker.pipelineVersion), edited)

        // A look the user never touched is not carried: the new bake's own applies.
        try writeFinishedBake(dir, marker: "old", subs: subs, look: edited, lookVersion: nil)
        _ = await runner.bake(subsDir: subs, target: "M 42", force: true) { _ in }
        let fresh = try Manifest(jsonData: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        XCTAssertEqual(fresh.look, .default)
        XCTAssertNil(fresh.lookVersion)
    }

    func testAFailureKeepsTheOriginalErrorAndItsLogs() async throws {
        let subs = try box.subs("M 42_sub")
        let runner = BakeRunner(cacheRoot: box.cache) { _, out, _ in
            let work = out.appendingPathComponent("_work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try Data("siril says no".utf8).write(to: work.appendingPathComponent("siril.log"))
            throw SirilStage.SirilError.noMaster("exit 1; check subs are registrable FITS")
        }
        guard case .failure(let failure) = await runner.bake(subsDir: subs, target: "M 42",
                                                            onProgress: { _ in })
        else { return XCTFail("expected failure") }
        XCTAssertEqual(failure.stage, .develop)
        XCTAssertTrue(failure.error is SirilStage.SirilError)
        XCTAssertEqual(failure.logsFolder?.lastPathComponent, "_work")
        XCTAssertEqual(UserMessage.developFailed(failure).title, "Your frames couldn’t be combined")
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaBake
import NebulaAI
import NebulaEngine

/// "Never a dead end" and "Cancel means cancel": an unusable AI model must cost
/// only its own stage, a cancel must never be swallowed by an optional stage,
/// and a bake must never touch the existing image until the new one is done.
final class BakeRobustnessTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct ModelBroke: Error {}
    private let pixels = (0..<(20 * 15 * 3)).map { Float($0) / Float(20 * 15 * 3) }

    // MARK: - AI stages fall back instead of failing the bake

    func testUnreadableModelFilesFallBackToTheInputUnchanged() throws {
        // The realistic failure: a model that exists but isn't usable (partial
        // download, corrupt file). It must not throw out of the bake.
        let corrupt = tmp.appendingPathComponent("model.onnx")
        try Data("not an onnx model".utf8).write(to: corrupt)
        let work = tmp.appendingPathComponent("_work")
        let px = pixels

        let bg = try Baker.aiStage("background-removal", input: px, workDir: work) {
            try BgExtractor(modelPath: corrupt.path).extract(pixels: px, h: 15, w: 20, c: 3, smoothing: 0.5)
        }
        let dn = try Baker.aiStage("denoise", input: px, workDir: work) {
            try Denoiser(modelPath: corrupt.path).denoise(pixels: px, h: 15, w: 20, c: 3, strength: 1)
        }
        for stage in [bg, dn] {
            XCTAssertEqual(stage.pixels, px, "a failed stage passes its input through exactly")
            XCTAssertFalse(stage.outcome.succeeded)
            XCTAssertEqual(stage.outcome.fallback, "model-failed-input-preserved")
        }
        let log = try String(contentsOf: work.appendingPathComponent("ai.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("background-removal:") && log.contains("denoise:"),
                      "the reason is kept for diagnosis")
    }

    func testWrongSizedModelOutputIsTreatedAsAFailedStage() throws {
        let stage = try Baker.aiStage("denoise", input: pixels, workDir: tmp) { [1, 2, 3] }
        XCTAssertEqual(stage.pixels, pixels)
        XCTAssertFalse(stage.outcome.succeeded)
    }

    func testWorkingStageReportsSuccess() throws {
        let doubled = pixels.map { $0 * 2 }
        let stage = try Baker.aiStage("denoise", input: pixels, workDir: tmp) { doubled }
        XCTAssertEqual(stage.pixels, doubled)
        XCTAssertTrue(stage.outcome.succeeded)
        XCTAssertNil(stage.outcome.fallback)
    }

    // MARK: - Cancel is never swallowed

    func testCancelPropagatesThroughAIStagesAndOptionalStages() {
        XCTAssertThrowsError(try Baker.aiStage("denoise", input: pixels, workDir: tmp) {
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }

        XCTAssertThrowsError(try Baker.attempt { () throws -> Int? in throw CancellationError() }) {
            XCTAssertTrue($0 is CancellationError, "a bare try? used to swallow this")
        }
        XCTAssertNil(try Baker.attempt { () throws -> Int? in throw ModelBroke() },
                     "an ordinary failure still means: use the fallback")
        XCTAssertEqual(try Baker.attempt { 7 }, 7)
    }

    // MARK: - Staged bakes never touch the existing image until complete

    private func makeBake(_ dir: URL, _ marker: String, extra: [String] = []) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["master", "corrected", "denoised", "starless", "stars"] {
            try Data(marker.utf8).write(to: dir.appendingPathComponent("\(name).fits"))
        }
        for name in extra { try Data(marker.utf8).write(to: dir.appendingPathComponent(name)) }
    }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testCommitSwapsInTheNewBakeAndLeavesNothingBehind() throws {
        let destination = tmp.appendingPathComponent("M 42")
        try makeBake(destination, "old", extra: ["thumb.png"])

        let staged = try StagedBake(destination: destination)
        XCTAssertEqual(contents(destination.appendingPathComponent("master.fits")), "old",
                       "starting a bake doesn't touch the existing image")
        try makeBake(staged.directory, "new")
        try staged.commit()

        XCTAssertEqual(contents(destination.appendingPathComponent("master.fits")), "new")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("thumb.png").path),
            "the old bake's thumbnail goes with it")
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: StagedBake.stagingRoot(in: tmp).path)
        XCTAssertEqual(leftovers, [], "no staging or retired folders remain")
    }

    func testCommitWorksForAFirstBake() throws {
        let destination = tmp.appendingPathComponent("M 13")
        let staged = try StagedBake(destination: destination)
        try makeBake(staged.directory, "new")
        try staged.commit()
        XCTAssertEqual(contents(destination.appendingPathComponent("stars.fits")), "new")
    }

    func testDiscardedBakeLeavesTheExistingImageExactlyAsItWas() throws {
        let destination = tmp.appendingPathComponent("M 42")
        try makeBake(destination, "old", extra: ["manifest.json", "thumb.png"])
        let before = try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted()

        let staged = try StagedBake(destination: destination)
        try makeBake(staged.directory, "half-written")
        staged.discard()

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path).sorted(), before)
        XCTAssertEqual(contents(destination.appendingPathComponent("manifest.json")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }

    func testFailedBakeKeepsOnlyItsLogsBesideTheExistingImage() throws {
        let destination = tmp.appendingPathComponent("M 42")
        try makeBake(destination, "old")
        let staged = try StagedBake(destination: destination)
        let work = staged.directory.appendingPathComponent("_work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("stack failed".utf8).write(to: work.appendingPathComponent("siril.log"))
        try Data("big".utf8).write(to: work.appendingPathComponent("master_stack.fits"))
        try makeBake(staged.directory, "partial")

        staged.discardKeepingLogs()

        XCTAssertEqual(contents(destination.appendingPathComponent("master.fits")), "old")
        XCTAssertEqual(contents(destination.appendingPathComponent("_work/siril.log")), "stack failed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("_work/master_stack.fits").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }

    func testSeedCarriesForwardOnlyWhatExists() throws {
        let destination = tmp.appendingPathComponent("M 42")
        try makeBake(destination, "old", extra: ["manifest.json"])
        let staged = try StagedBake(destination: destination)
        staged.seed(["manifest.json", "_work/master_stack.fits"])
        XCTAssertEqual(contents(staged.directory.appendingPathComponent("manifest.json")), "old")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.directory.appendingPathComponent("_work/master_stack.fits").path))
    }

    func testAbandonedStagingIsSwept() throws {
        let staged = try StagedBake(destination: tmp.appendingPathComponent("M 42"))
        try makeBake(staged.directory, "crashed")
        StagedBake.removeAbandoned(in: tmp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: StagedBake.stagingRoot(in: tmp).path))
    }

    // MARK: - Siril's working copies never outlive the stack

    /// Runs the real Siril (skipped where it isn't installed, e.g. CI) on frames
    /// it can't register, so the stack fails. Its working copies of the subs must
    /// be gone either way, both in place and in the temp scratch used for paths
    /// with a space.
    func testSirilWorkingCopiesAreRemovedEvenWhenTheStackFails() throws {
        guard let siril = try? SirilStage() else { throw XCTSkip("Siril not installed") }
        let subs = tmp.appendingPathComponent("Blank_sub")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        for i in 0..<3 {
            try FITSImage.fromHWC([Float](repeating: 0.1, count: 32 * 32 * 3),
                                  width: 32, height: 32, channels: 3)
                .write(subs.appendingPathComponent("light_\(i).fits"))
        }
        func scratchDirs() -> Set<String> {
            Set(((try? FileManager.default.contentsOfDirectory(
                atPath: NSTemporaryDirectory())) ?? []).filter { $0.hasPrefix("nebula-siril-") })
        }

        for workName in ["work", "work with space"] {
            let work = tmp.appendingPathComponent(workName)
            let scratchBefore = scratchDirs()
            _ = try? siril.stack(subsDir: subs, workDir: work)
            for leftover in ["process", "lights", "master.fits"] {
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: work.appendingPathComponent(leftover).path),
                    "\(workName): \(leftover) must not outlive the stack")
            }
            XCTAssertEqual(scratchDirs(), scratchBefore, "\(workName): temp scratch removed")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: work.appendingPathComponent("siril.log").path), "the log is kept")
        }
    }
}

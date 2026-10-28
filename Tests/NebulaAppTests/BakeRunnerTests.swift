// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp
@testable import NebulaBake

/// The bake runner's promises to the user, driven with a stand-in bake (no
/// Siril, no models): re-developing never costs the image already there, and
/// Cancel means nothing changes.
@MainActor
final class BakeRunnerTests: XCTestCase {
    private var tmp: URL!
    private var cache: URL!
    private var subs: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-runner-\(UUID().uuidString)", isDirectory: true)
        cache = tmp.appendingPathComponent("cache", isDirectory: true)
        subs = tmp.appendingPathComponent("M 42_sub", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private struct Broke: Error {}

    nonisolated private static func writeLayers(_ dir: URL, _ marker: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["master", "corrected", "denoised", "starless", "stars"] {
            try Data(marker.utf8).write(to: dir.appendingPathComponent("\(name).fits"))
        }
    }

    private func contents(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// An existing finished bake of "M 42", as the Library shows it.
    private func existingImage() throws -> URL {
        let dir = cache.appendingPathComponent("M 42")
        try Self.writeLayers(dir, "old")
        try Data("old".utf8).write(to: dir.appendingPathComponent("thumb.png"))
        return dir
    }

    private func assertUntouched(_ dir: URL, file: StaticString = #filePath, line: UInt = #line) {
        for name in ["master.fits", "stars.fits", "thumb.png"] {
            XCTAssertEqual(contents(dir.appendingPathComponent(name)), "old",
                           "\(name) must be untouched", file: file, line: line)
        }
        let staging = (try? FileManager.default.contentsOfDirectory(
            atPath: StagedBake.stagingRoot(in: cache).path)) ?? []
        XCTAssertEqual(staging, [], "no half-built bake left behind", file: file, line: line)
    }

    func testFailedRedevelopLeavesTheExistingImageUntouched() async throws {
        let old = try existingImage()
        let runner = BakeRunner(cacheRoot: cache) { _, out, _ in
            try Data("half-written".utf8).write(to: out.appendingPathComponent("master.fits"))
            throw Broke()
        }
        let outcome = await runner.bake(subsDir: subs, target: "M 42", force: true) { _ in }
        guard case .failure = outcome else { return XCTFail("expected failure, got \(outcome)") }
        assertUntouched(old)
    }

    func testCancelledRedevelopChangesNothing() async throws {
        let old = try existingImage()
        let runner = BakeRunner(cacheRoot: cache) { _, out, _ in
            try Self.writeLayers(out, "new")
            let giveUp = Date().addingTimeInterval(5)
            while Date() < giveUp {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        let bake = Task { await runner.bake(subsDir: subs, target: "M 42", force: true) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()
        guard case .cancelled = await bake.value else { return XCTFail("expected a cancel") }
        assertUntouched(old)
    }

    func testCancelAfterTheLastCheckpointStillChangesNothing() async throws {
        // The bake ignores the cancel and finishes anyway (e.g. it was already
        // writing layers). The user asked to cancel, so the result is dropped.
        let old = try existingImage()
        let runner = BakeRunner(cacheRoot: cache) { _, out, _ in
            try Self.writeLayers(out, "new")
            Thread.sleep(forTimeInterval: 0.3)
        }
        let bake = Task { await runner.bake(subsDir: subs, target: "M 42", force: true) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        runner.cancel()
        guard case .cancelled = await bake.value else { return XCTFail("expected a cancel") }
        assertUntouched(old)
    }

    func testSuccessfulRedevelopSwapsInTheNewImage() async throws {
        let old = try existingImage()
        var progress: [Double] = []
        let runner = BakeRunner(cacheRoot: cache) { _, out, report in
            report(.init(fraction: 0.5, status: "Halfway"))
            try Self.writeLayers(out, "new")
        }
        let outcome = await runner.bake(subsDir: subs, target: "M 42", force: true) {
            progress.append($0.fraction)
        }
        guard case .success(let dir) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(dir.standardizedFileURL, old.standardizedFileURL)
        XCTAssertEqual(contents(old.appendingPathComponent("master.fits")), "new")
        XCTAssertNil(contents(old.appendingPathComponent("thumb.png")), "the stale thumbnail is gone")
        XCTAssertEqual(contents(old.appendingPathComponent("source.txt")), subs.path)
        XCTAssertEqual(progress, [0.5])
    }

    func testAFinishedBakeDoesNotStealANewerBakesCancel() async throws {
        // Bake A finishes while bake B is running. A used to clear the shared
        // handle on its way out, so Cancel then did nothing for B.
        let fast = tmp.appendingPathComponent("fast"), slow = tmp.appendingPathComponent("slow")
        for d in [fast, slow] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let runner = BakeRunner(cacheRoot: cache) { subs, out, _ in
            if subs.lastPathComponent == "fast" {
                Thread.sleep(forTimeInterval: 0.2)
                try Self.writeLayers(out, "A")
                return
            }
            let giveUp = Date().addingTimeInterval(5)
            while Date() < giveUp {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw Broke()     // never cancelled: fail rather than hang
        }
        let a = Task { await runner.bake(subsDir: fast, target: "A") { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000)
        let b = Task { await runner.bake(subsDir: slow, target: "B") { _ in } }
        guard case .success = await a.value else { return XCTFail("A should finish") }
        runner.cancel()
        guard case .cancelled = await b.value else { return XCTFail("Cancel must still reach B") }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaApp

/// Two different captures must never share a cache folder; existing caches
/// must keep opening under the names they already have.
final class CacheKeyTests: XCTestCase {
    private var box: Sandbox!
    override func setUpWithError() throws { box = try Sandbox() }
    override func tearDown() { box.remove() }

    private func key(_ subs: URL, claimed: [String: URL] = [:]) -> String {
        CacheKey.resolve(subsDir: subs, fingerprint: SourceFingerprint.of(subs),
                         cacheRoot: box.cache, claimed: claimed)
    }

    /// A finished bake in the cache, made from `subs`.
    private func cached(_ name: String, from subs: URL?, recordFingerprint: Bool = false) throws {
        let dir = box.cache.appendingPathComponent(name)
        try writeFinishedBake(dir, marker: name, subs: subs)
        if let subs {
            try subs.path.write(to: dir.appendingPathComponent("source.txt"), atomically: true, encoding: .utf8)
            if recordFingerprint { try SourceFingerprint.of(subs)?.write(to: dir) }
        }
    }

    func testBaseNamesStayHumanAndMosaicsSaySo() {
        func base(_ n: String) -> String { CacheKey.baseName(for: URL(fileURLWithPath: "/x/\(n)")) }
        XCTAssertEqual(base("M 42_sub"), "M 42")
        XCTAssertEqual(base("M 42_subs"), "M 42")
        XCTAssertEqual(base("M 42_mosaic_sub"), "M 42 mosaic")
        XCTAssertEqual(base("M 42_mosaic_subs"), "M 42 mosaic")
        XCTAssertEqual(base("NGC 7000"), "NGC 7000")
        XCTAssertEqual(base("_sub"), "_sub")
        XCTAssertEqual(base(".staging_sub"), "staging", "never a hidden folder")
    }

    func testMosaicAndRegularCapturesOfOneTargetDoNotCollide() throws {
        let regular = try box.subs("M 42_sub")
        let mosaic = try box.subs("M 42_mosaic_sub")
        XCTAssertEqual(key(regular), "M 42")
        XCTAssertEqual(key(mosaic), "M 42 mosaic")
    }

    func testTwoFoldersWithTheSameNameGetTheirOwnCaches() throws {
        let night1 = try box.subs("M 42_sub", in: try box.subs("night1", frames: 0))
        let night2 = try box.subs("M 42_sub", frames: 5, in: try box.subs("night2", frames: 0))
        try cached("M 42", from: night1)
        XCTAssertEqual(key(night1), "M 42", "the folder it was made from keeps it")
        XCTAssertEqual(key(night2), "M 42 (2)")
        try cached("M 42 (2)", from: night2)
        XCTAssertEqual(key(night2), "M 42 (2)", "and keeps finding its own afterwards")
        XCTAssertEqual(key(night1), "M 42")
    }

    func testAnOldMosaicCacheUnderThePlainNameKeepsWorking() throws {
        // Before mosaics were told apart, "M 42_mosaic_sub" cached as "M 42".
        let mosaic = try box.subs("M 42_mosaic_sub")
        let regular = try box.subs("M 42_sub")
        try cached("M 42", from: mosaic)
        XCTAssertEqual(key(mosaic), "M 42", "no pointless re-develop of the existing cache")
        XCTAssertEqual(key(regular), "M 42 (2)", "and never shows the mosaic for the other capture")
    }

    func testABakeThatRecordedNoSourceKeepsThePlainName() throws {
        let subs = try box.subs("M 42_sub")
        try cached("M 42", from: nil)
        try FileManager.default.removeItem(at: box.cache.appendingPathComponent("M 42/manifest.json"))
        XCTAssertEqual(key(subs), "M 42")
    }

    func testAFolderWithoutAnImageIsFreeToUse() throws {
        // A failed first develop keeps only its logs.
        let logs = box.cache.appendingPathComponent("M 42/_work")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("log".utf8).write(to: logs.appendingPathComponent("siril.log"))
        XCTAssertEqual(key(try box.subs("M 42_sub")), "M 42")
    }

    func testAMovedCaptureFindsItsCacheByFingerprint() throws {
        let original = try box.subs("M 42_sub", frames: 3, in: try box.subs("Seestar", frames: 0))
        try cached("M 42", from: original, recordFingerprint: true)
        let copyParent = try box.subs("Pictures", frames: 0)
        let copy = copyParent.appendingPathComponent("M 42_sub")
        try FileManager.default.copyItem(at: original, to: copy)   // copies keep mtimes
        XCTAssertEqual(SourceFingerprint.of(copy), SourceFingerprint.of(original))
        XCTAssertEqual(key(copy), "M 42")
    }

    func testAKeyClaimedByAnotherCaptureInFlightIsSkipped() throws {
        let a = try box.subs("M 42_sub", in: try box.subs("a", frames: 0))
        let b = try box.subs("M 42_sub", in: try box.subs("b", frames: 0))
        XCTAssertEqual(key(b, claimed: ["M 42": a]), "M 42 (2)")
        XCTAssertEqual(key(a, claimed: ["M 42": a]), "M 42", "its own claim")
    }
}

/// Picking the wrong folder gets a useful answer, not "no FITS light frames".
final class OpenRouteTests: XCTestCase {
    private var box: Sandbox!
    override func setUpWithError() throws { box = try Sandbox() }
    override func tearDown() { box.remove() }

    /// Compare routes by real path (listings may spell a folder differently).
    private func XCTAssertRoute(_ route: OpenRoute, _ expected: OpenRoute,
                                _ message: String = "", line: UInt = #line) {
        func norm(_ u: URL) -> String { u.resolvingSymlinksInPath().standardizedFileURL.path }
        func describe(_ r: OpenRoute) -> String {
            switch r {
            case .notFound(let n): return "notFound(\(n))"
            case .notAFolder(let n): return "notAFolder(\(n))"
            case .bakeDir(let u): return "bakeDir(\(norm(u)))"
            case .subs(let u): return "subs(\(norm(u)))"
            case .parentOfSubs(let u, let names): return "parent(\(norm(u)), \(names))"
            case .nothing(let n): return "nothing(\(n))"
            }
        }
        XCTAssertEqual(describe(route), describe(expected), message, line: line)
    }

    func testRoutes() throws {
        let subs = try box.subs("M 42_sub")
        XCTAssertRoute(OpenRoute.classify(subs), .subs(subs))

        let file = subs.appendingPathComponent("preview.jpg")
        XCTAssertRoute(OpenRoute.classify(file), .notAFolder("preview.jpg"))
        XCTAssertRoute(OpenRoute.classify(box.root.appendingPathComponent("gone")), .notFound("gone"))

        let bake = box.cache.appendingPathComponent("M 42")
        try writeFinishedBake(bake, marker: "M 42")
        XCTAssertRoute(OpenRoute.classify(bake), .bakeDir(bake))

        let empty = try box.subs("Empty", frames: 0)
        XCTAssertRoute(OpenRoute.classify(empty), .nothing("Empty"))
    }

    func testTheStackedResultsFolderOpensItsFrames() throws {
        let results = try box.subs("M 42", frames: 0)
        try Data("x".utf8).write(to: results.appendingPathComponent("Stacked_30_M 42_10.0s.fit"))
        let frames = try box.subs("M 42_sub")
        XCTAssertRoute(OpenRoute.classify(results), .subs(frames))
    }

    func testAParentOfCapturesIsRecognised() throws {
        let myWorks = try box.subs("MyWorks", frames: 0)
        let only = try box.subs("M 42_sub", in: myWorks)
        XCTAssertRoute(OpenRoute.classify(myWorks), .subs(only), "a single capture just opens")
        try box.subs("M 31_sub", in: myWorks)
        XCTAssertRoute(OpenRoute.classify(myWorks), .parentOfSubs(myWorks, ["M 31_sub", "M 42_sub"]))
    }
}

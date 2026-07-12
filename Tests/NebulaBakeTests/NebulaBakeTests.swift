// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaBake
import NebulaEngine

final class NebulaBakeTests: XCTestCase {
    func testQualityStatsDetectBackgroundCast() {
        let neutral = [Float](repeating: 0.02, count: 100 * 3)
        var cast = neutral
        for p in 0..<100 { cast[p*3] = 0.04; cast[p*3+2] = 0.01 }
        XCTAssertEqual(ImageQualityStats.measure(neutral, channels: 3).backgroundCast, 0,
                       accuracy: 1e-6)
        XCTAssertGreaterThan(ImageQualityStats.measure(cast, channels: 3).backgroundCast, 1)
    }

    func testCorrectionValidatorRejectsNoOpAndAcceptsSaferNeutralisation() {
        var before = [Float](repeating: 0, count: 1000 * 3)
        var after = before
        for p in 0..<1000 {
            before[p*3] = 0.04; before[p*3+1] = 0.02; before[p*3+2] = 0.01
            after[p*3] = 0.021; after[p*3+1] = 0.020; after[p*3+2] = 0.019
        }
        XCTAssertFalse(CorrectionValidator.accept(before: before, after: before, channels: 3).0)
        XCTAssertTrue(CorrectionValidator.accept(before: before, after: after, channels: 3).0)
    }

    func testNativeBalanceNeutralisesBackgroundCast() {
        let w=40, h=40
        var image=[Float](repeating: 0, count: w*h*3)
        for i in 0..<(w*h) {
            image[i*3]=0.03; image[i*3+1]=0.02; image[i*3+2]=0.01
        }
        let out = Baker.nativeWhiteBalance(image, h: h, w: w, c: 3, broadband: false)
        XCTAssertEqual(out[0], out[1], accuracy: 1e-6)
        XCTAssertEqual(out[1], out[2], accuracy: 1e-6)
    }

    func testClassicalStarlessRemovesStarAndPreservesBackground() {
        let w=64, h=64
        var master=[Float](repeating: 0.01, count: w*h*3)
        for y in 0..<h { for x in 0..<w {
            let d=Float((x-32)*(x-32)+(y-32)*(y-32))
            let star: Float = 0.7 * exp(-d/3)
            for ch in 0..<3 { master[(y*w+x)*3+ch] += star }
        } }
        let starless = Baker.classicalStarless(master: master, detection: master,
                                               h: h, w: w, c: 3)
        // The star core is replaced with the local background…
        let core = (32*w+32)*3
        XCTAssertLessThan(starless[core], 0.1)
        XCTAssertGreaterThan(master[core] - starless[core], 0.5)
        // …while pixels far from any star are untouched.
        let corner = (2*w+2)*3
        XCTAssertEqual(starless[corner], master[corner], accuracy: 1e-4)
    }

    /// Regression: a bright star's own halo must not inflate the background
    /// estimate it is replaced with. One clip-and-blur pass left a ~3x
    /// elevated plateau under big stars, which rendered as a bright ring
    /// around any star the user shrank or dimmed (M 8, 2026-07-12).
    func testClassicalStarlessLeavesNoElevatedPlateauUnderBrightStars() {
        let w=128, h=128
        let bg: Float = 0.01
        var master=[Float](repeating: bg, count: w*h*3)
        for y in 0..<h { for x in 0..<w {
            let d=Float((x-64)*(x-64)+(y-64)*(y-64))
            // Saturated core + halo comparable to the estimator's element
            // (the regime where clip-and-blur used to fail).
            let star: Float = min(0.85 * exp(-d/8), 0.8)
            for ch in 0..<3 { master[(y*w+x)*3+ch] += star }
        } }
        let starless = Baker.classicalStarless(master: master, detection: master,
                                               h: h, w: w, c: 3)
        // Everywhere under/near the star the replacement must stay close to
        // the true background — no bright plateau, no ring.
        for r in [0, 4, 8, 12] {
            let p = (64*w + 64 + r)*3
            XCTAssertLessThan(starless[p], bg * 2.2,
                              "elevated starless plateau at r=\(r): \(starless[p]) vs bg \(bg)")
        }
    }

    func testProtectSignalKeepsNebulaColourAndCorrectsSky() {
        let w = 64, h = 64, n = w*h
        var master = [Float](repeating: 0, count: n*3)
        var corrected = master
        for p in 0..<n {
            let bright = p < n/8                      // "nebula": strong red signal
            master[p*3]   = bright ? 0.05 : 0.004     // R
            master[p*3+1] = bright ? 0.02 : 0.003     // G
            master[p*3+2] = bright ? 0.02 : 0.003     // B
            // BGE subtracts a "gradient" that includes the nebula's red.
            corrected[p*3]   = bright ? 0.02 : 0.002
            corrected[p*3+1] = bright ? 0.015 : 0.002
            corrected[p*3+2] = bright ? 0.015 : 0.002
        }
        let out = Baker.protectSignal(master: master, corrected: corrected, h: h, w: w, c: 3)
        // Sky pixels take the full correction…
        XCTAssertEqual(out[(n-1)*3], 0.002, accuracy: 1e-4)
        // …while the bright nebula keeps most of its original red signal.
        XCTAssertGreaterThan(out[0], 0.04)
    }

    func testMissingCorrectionModelsPreserveMasterExactly() {
        let src=(0..<(20*15*3)).map { Float($0) / Float(20*15*3) }
        XCTAssertEqual(Baker.fallbackBackground(src, h: 15, w: 20, c: 3), src)
        XCTAssertEqual(Baker.fallbackDenoise(src, h: 15, w: 20, c: 3), src)
    }

    func testLightSelectionRejectsDifferentFilterAndKeepsMixedExposure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func light(_ name: String, filter: String, exposure: Double,
                   width: Int = 4, height: Int = 4) throws {
            let url = dir.appendingPathComponent("\(name).fits")
            let image = FITSImage.fromHWC([Float](repeating: 0.1, count: width*height*3),
                                          width: width, height: height, channels: 3)
            try image.write(url)
            var data = try Data(contentsOf: url)
            func card(_ key: String, _ value: String) -> Data {
                let s = (key.padding(toLength: 8, withPad: " ", startingAt: 0)
                    + "= " + value).padding(toLength: 80, withPad: " ", startingAt: 0)
                return Data(s.utf8)
            }
            let endOffset = 6 * 80 // SIMPLE, BITPIX, NAXIS, NAXIS1/2/3
            data.replaceSubrange(endOffset..<(endOffset+80), with: card("FILTER", "'\(filter)'"))
            data.replaceSubrange((endOffset+80)..<(endOffset+160),
                                 with: card("EXPTIME", String(exposure)))
            data.replaceSubrange((endOffset+160)..<(endOffset+240),
                                 with: Data("END".padding(toLength: 80, withPad: " ", startingAt: 0).utf8))
            try data.write(to: url)
        }
        try light("a", filter: "IRCUT", exposure: 10)
        try light("b", filter: "IRCUT", exposure: 30)
        try light("c", filter: "LP", exposure: 10)
        try light("d", filter: "IRCUT", exposure: 5, width: 8, height: 8)

        let selected = try SirilStage.selectLights(in: dir)
        XCTAssertEqual(selected.filter, "IRCUT")
        XCTAssertEqual(selected.lights.count, 2)
        XCTAssertEqual(selected.skippedIncompatible, 2)
        XCTAssertEqual(selected.integrationSeconds, 40)
        XCTAssertEqual(selected.exposures, [10, 30])
        XCTAssertFalse(selected.supportsTwoXDrizzle)
    }
}

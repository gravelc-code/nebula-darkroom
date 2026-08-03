// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaBake
import NebulaEngine

final class NebulaBakeTests: XCTestCase {
    func testStarNetStretchRoundTripsAndPNGBridgeIsLossless() throws {
        // The StarNet hook stretches linear→display, hands StarNet a 16-bit PNG,
        // then inverts the stretch. Both halves must round-trip: otherwise the
        // starless comes back wrong and stars = master - starless is garbage.
        let shadow: Float = 0.002, midtone: Float = 0.08
        for x in stride(from: Float(0), through: 1, by: 0.017) {
            let there = Baker.forwardStretch(x, shadow: shadow, midtone: midtone)
            let back = Baker.inverseStretch(there, shadow: shadow, midtone: midtone)
            // Below the black point the stretch clips to 0 (lossy by design); stars
            // are bright, so only assert invertibility above the shadow.
            if x > shadow { XCTAssertEqual(back, x, accuracy: 2e-3, "stretch not invertible at \(x)") }
        }

        // 16-bit PNG write→read preserves pixels (top-row-first, no flip).
        let w = 5, h = 3
        var rgb = [Float](repeating: 0, count: w*h*3)
        for i in 0..<(w*h*3) { rgb[i] = Float((i * 37) % 100) / 99 }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula_png16_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Baker.writePNG16(rgb, w: w, h: h, to: url)
        let back = try Baker.readPNG16(url, w: w, h: h)
        XCTAssertEqual(back.count, rgb.count)
        for i in 0..<rgb.count { XCTAssertEqual(back[i], rgb[i], accuracy: 1.0/65535 + 1e-4,
                                                "PNG bridge changed pixel \(i)") }
    }

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

    func testRenormaliseLuminanceUndoesPCCDimmingButKeepsRatios() {
        let n = 4096
        var reference = [Float](repeating: 0, count: n*3)
        var calibrated = reference
        for p in 0..<n {
            let signal: Float = p < n/10 ? 0.05 : 0.002      // subject vs sky
            reference[p*3] = signal; reference[p*3+1] = signal; reference[p*3+2] = signal
            // A PCC that halved red and dimmed green (Siril normalises max gain to 1).
            calibrated[p*3] = signal * 0.5
            calibrated[p*3+1] = signal * 0.7
            calibrated[p*3+2] = signal * 1.0
        }
        let out = Baker.renormaliseLuminance(reference: reference, calibrated: calibrated, c: 3)
        // Overall brightness restored (single scalar, bounded)…
        let p = 0
        XCTAssertGreaterThan(out[p*3] + out[p*3+1] + out[p*3+2],
                             (calibrated[p*3] + calibrated[p*3+1] + calibrated[p*3+2]) * 1.2)
        // …while the calibrated channel ratios are untouched.
        XCTAssertEqual(out[p*3] / out[p*3+2], 0.5, accuracy: 1e-4)
        XCTAssertEqual(out[p*3+1] / out[p*3+2], 0.7, accuracy: 1e-4)
    }

    /// The repair that keeps StarNet usable on galaxy fields: a separator that
    /// removed both a galaxy and the stars should come back with the galaxy
    /// restored and the stars still gone.
    func testCompactOnlyRepairRestoresTheSubjectButNotTheStars() {
        let w = 192, h = 192, n = w*h
        var master = [Float](repeating: 0.002, count: n*3)
        func addBlob(_ cx: Int, _ cy: Int, _ amp: Float, _ spread: Float) {
            for y in 0..<h { for x in 0..<w {
                let d = Float((x-cx)*(x-cx) + (y-cy)*(y-cy))
                let v = amp * exp(-d/spread)
                for ch in 0..<3 { master[(y*w+x)*3+ch] += v }
            } }
        }
        addBlob(96, 96, 0.03, 900)     // extended "galaxy"
        addBlob(40, 40, 0.60, 6)       // compact star
        addBlob(150, 60, 0.50, 6)      // compact star
        // A separator that removed everything it found — galaxy included.
        let overzealous = [Float](repeating: 0.002, count: n*3)
        let repaired = Baker.compactOnlyStarless(master: master, starless: overzealous,
                                                 h: h, w: w, c: 3)
        // The galaxy centre is back…
        XCTAssertGreaterThan(repaired[(96*w+96)*3], master[(96*w+96)*3] * 0.8)
        // …while the star cores stay removed.
        XCTAssertLessThan(repaired[(40*w+40)*3], master[(40*w+40)*3] * 0.25)
        XCTAssertLessThan(repaired[(60*w+150)*3], master[(60*w+150)*3] * 0.25)
        // And the repair makes the split acceptable to the validator.
        let before = Baker.extendedFluxRetention(master: master, starless: overzealous,
                                                 h: h, w: w, c: 3)
        let after = Baker.extendedFluxRetention(master: master, starless: repaired,
                                                h: h, w: w, c: 3)
        XCTAssertLessThan(before.retention, 0.7)
        XCTAssertGreaterThan(after.retention, 0.7)
    }

    /// The O(n) deque erosion must agree exactly with the straightforward
    /// window minimum, including the shrinking window at the edges.
    func testErodeMatchesTheNaiveWindowMinimum() {
        let w = 37, h = 23
        var src = [Float](repeating: 0, count: w*h)
        var seed: UInt64 = 12345
        for i in src.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            src[i] = Float((seed >> 33) % 1000) / 1000
        }
        for radius in [1, 3, 10] {
            // Naive separable reference.
            var mid = src
            for y in 0..<h { for x in 0..<w {
                var m = Float.greatestFiniteMagnitude
                for d in max(0, x-radius)...min(w-1, x+radius) { m = min(m, src[y*w+d]) }
                mid[y*w+x] = m
            } }
            var expect = mid
            for y in 0..<h { for x in 0..<w {
                var m = Float.greatestFiniteMagnitude
                for d in max(0, y-radius)...min(h-1, y+radius) { m = min(m, mid[d*w+x]) }
                expect[y*w+x] = m
            } }
            let got = Baker.erode(src, h: h, w: w, radius: radius)
            for i in got.indices {
                XCTAssertEqual(got[i], expect[i], accuracy: 1e-7, "radius \(radius), index \(i)")
            }
            // Dilation is the dual.
            let dil = Baker.dilate(src, h: h, w: w, radius: radius)
            for i in dil.indices { XCTAssertGreaterThanOrEqual(dil[i], src[i] - 1e-7) }
        }
    }

    func testExtendedFluxRetentionCatchesASwallowedSubject() {
        let w = 192, h = 192, n = w*h
        var master = [Float](repeating: 0.002, count: n*3)
        for y in 0..<h { for x in 0..<w {
            // A broad "galaxy" — far wider than any star.
            let d = Float((x-96)*(x-96) + (y-96)*(y-96))
            let g = 0.03 * exp(-d/900)
            for ch in 0..<3 { master[(y*w+x)*3+ch] += g }
        } }
        // A separator that ate the subject: starless == flat sky.
        let flat = [Float](repeating: 0.002, count: n*3)
        let bad = Baker.extendedFluxRetention(master: master, starless: flat, h: h, w: w, c: 3)
        XCTAssertTrue(bad.meaningful)
        XCTAssertLessThan(bad.retention, 0.3)
        // A separator that only removed stars: starless == master (no stars here).
        let good = Baker.extendedFluxRetention(master: master, starless: master, h: h, w: w, c: 3)
        XCTAssertGreaterThan(good.retention, 0.95)
    }

    /// Regression: the metric must measure EXTENDED flux only. A blur conserves
    /// a star's total flux, so a blur-based measure reads a rich star field as
    /// "subject" and then rejects perfectly good star removal — which is what
    /// pushed M 83 down the fallback ladder.
    func testStarRemovalInARichFieldIsNotMistakenForSubjectLoss() {
        let w = 256, h = 256, n = w*h
        let sky: Float = 0.002
        var master = [Float](repeating: sky, count: n*3)
        var starless = master
        // A modest galaxy…
        for y in 0..<h { for x in 0..<w {
            let d = Float((x-128)*(x-128) + (y-128)*(y-128))
            let g = 0.02 * exp(-d/1200)
            for ch in 0..<3 { master[(y*w+x)*3+ch] += g; starless[(y*w+x)*3+ch] += g }
        } }
        // …in a field of 200 bright compact stars, present only in `master`.
        var seed: UInt64 = 99
        for _ in 0..<200 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let cx = Int((seed >> 33) % UInt64(w)), cy = Int((seed >> 13) % UInt64(h))
            for dy in -4...4 { for dx in -4...4 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let star = 0.5 * exp(-Float(dx*dx + dy*dy) / 4)
                for ch in 0..<3 { master[(y*w+x)*3+ch] += star }
            } }
        }
        let v = Baker.extendedFluxRetention(master: master, starless: starless, h: h, w: w, c: 3)
        XCTAssertGreaterThan(v.retention, 0.85,
                             "perfect star removal must not read as subject loss")
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

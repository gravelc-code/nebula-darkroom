// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaAI

/// Runs the real Denoiser / BgExtractor code through onnxruntime with tiny
/// fixture models (see OnnxFixtures). An identity model makes the denoiser a
/// near-exact round trip, so "output ≈ input" is a sharp check of the tiling,
/// padding and normalisation; the other fixtures misbehave on purpose.
final class PipelineRobustnessTests: XCTestCase {
    private var identityPath: String!

    override func setUpWithError() throws {
        identityPath = try OnnxFixture.write(OnnxFixture.identity(), named: "identity").path
    }

    /// A sky-like frame: 0.1 background, gentle gradient, deterministic noise,
    /// a few bright "stars" — stays well inside the denoise model threshold.
    private func skyImage(h: Int, w: Int, c: Int) -> [Float] {
        var px = [Float](repeating: 0, count: h * w * c)
        var seed: UInt32 = 12345
        for r in 0..<h { for x in 0..<w { for ch in 0..<c {
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(seed >> 8) / Float(1 << 24) - 0.5
            var v = 0.1 + 0.02 * Float(r) / Float(h) + 0.01 * Float(ch) + noise * 0.01
            if (r * 31 + x * 17) % 997 == 0 { v = 0.18 }
            px[(r * w + x) * c + ch] = v
        } } }
        return px
    }

    private func maxAbsDiff(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    func testIdentityDenoiseIsARoundTrip() throws {
        let dn = try Denoiser(modelPath: identityPath)
        for c in [1, 3] {
            let px = skyImage(h: 300, w: 200, c: c)
            let out = try dn.denoise(pixels: px, h: 300, w: 200, c: c, strength: 1)
            XCTAssertEqual(out.count, px.count)
            XCTAssertLessThan(maxAbsDiff(out, px), 1e-6, "c=\(c)")
        }
    }

    /// #48: batch size changes memory, never pixels.
    func testBatchSizeDoesNotChangePixels() throws {
        let px = skyImage(h: 400, w: 300, c: 3)
        let ref = try Denoiser(modelPath: identityPath, batchSize: 1)
            .denoise(pixels: px, h: 400, w: 300, c: 3, strength: 1)
        for b in [4, 8] {
            let out = try Denoiser(modelPath: identityPath, batchSize: b)
                .denoise(pixels: px, h: 400, w: 300, c: 3, strength: 1)
            XCTAssertEqual(out, ref, "batch \(b)")
        }
    }

    /// #45: < 64 px used to trap on a negative range.
    func testDenoiseHandlesTinyImages() throws {
        let dn = try Denoiser(modelPath: identityPath)
        for (h, w) in [(50, 40), (40, 50), (1, 1), (63, 130), (64, 64)] {
            for c in [1, 3] {
                let px = skyImage(h: h, w: w, c: c)
                let out = try dn.denoise(pixels: px, h: h, w: w, c: c, strength: 1)
                XCTAssertEqual(out.count, h * w * c)
                XCTAssertLessThan(maxAbsDiff(out, px), 1e-6, "\(w)x\(h)x\(c)")
            }
        }
        let bg = try BgExtractor(modelPath: identityPath)
        let tiny = try bg.extract(pixels: skyImage(h: 50, w: 40, c: 3), h: 50, w: 40, c: 3, smoothing: 0.5)
        XCTAssertEqual(tiny.count, 50 * 40 * 3)
        XCTAssertTrue(tiny.allSatisfy(\.isFinite))
    }

    /// #41: NaN/Inf are replaced by the channel median; nothing else moves.
    func testDenoiseSanitisesNonFiniteInput() throws {
        let (h, w, c) = (300, 260, 3)
        let clean = skyImage(h: h, w: w, c: c)
        var dirty = clean
        // Off the ::4 statistics grid, so median/MAD — and every other pixel — are unchanged.
        let bad: [(Int, Int, Int, Float)] = [(1, 1, 0, .nan), (5, 7, 1, .infinity),
                                              (150, 101, 2, -.infinity), (299, 259, 0, .nan)]
        for (r, x, ch, v) in bad { dirty[(r * w + x) * c + ch] = v }

        let dn = try Denoiser(modelPath: identityPath)
        let ref = try dn.denoise(pixels: clean, h: h, w: w, c: c, strength: 1)
        let out = try dn.denoise(pixels: dirty, h: h, w: w, c: c, strength: 1)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        var badIdx = Set<Int>()
        for (r, x, ch, _) in bad {
            let i = (r * w + x) * c + ch
            badIdx.insert(i)
            var sample: [Float] = []
            var rr = 0
            while rr < h { var xx = 0; while xx < w { sample.append(clean[(rr * w + xx) * c + ch]); xx += 4 }; rr += 4 }
            XCTAssertEqual(out[i], medianOf(sample), accuracy: 1e-6)
        }
        for i in out.indices where !badIdx.contains(i) { XCTAssertEqual(out[i], ref[i]) }
    }

    func testBackgroundExtractionSanitisesNonFiniteInput() throws {
        let (h, w, c) = (300, 260, 3)
        let clean = skyImage(h: h, w: w, c: c)
        var dirty = clean
        let badIdx: Set = [(10 * w + 10) * c, (200 * w + 100) * c + 1]
        for (k, i) in badIdx.sorted().enumerated() { dirty[i] = k == 0 ? .nan : .infinity }
        let bg = try BgExtractor(modelPath: identityPath)
        let ref = try bg.extract(pixels: clean, h: h, w: w, c: c, smoothing: 0.5)
        let out = try bg.extract(pixels: dirty, h: h, w: w, c: c, smoothing: 0.5)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        // Elsewhere one replaced pixel barely moves the sky model (it was NaN everywhere before).
        var worst: Float = 0
        for i in out.indices where !badIdx.contains(i) { worst = max(worst, abs(out[i] - ref[i])) }
        XCTAssertLessThan(worst, 1e-3)
    }

    func testAllNonFiniteInputStillYieldsFiniteOutput() throws {
        let px = [Float](repeating: .nan, count: 100 * 90 * 3)
        let dn = try Denoiser(modelPath: identityPath)
        XCTAssertTrue(try dn.denoise(pixels: px, h: 100, w: 90, c: 3, strength: 1).allSatisfy(\.isFinite))
        let bg = try BgExtractor(modelPath: identityPath)
        XCTAssertTrue(try bg.extract(pixels: px, h: 100, w: 90, c: 3, smoothing: 0.5).allSatisfy(\.isFinite))
    }

    /// #46: MAD = 0 (flat, or more than half one value) used to divide by zero.
    func testFlatAndMostlyZeroImagesStayFinite() throws {
        let dn = try Denoiser(modelPath: identityPath)
        let bg = try BgExtractor(modelPath: identityPath)
        let flat = [Float](repeating: 0.2, count: 300 * 200 * 3)
        let d = try dn.denoise(pixels: flat, h: 300, w: 200, c: 3, strength: 1)
        XCTAssertTrue(d.allSatisfy { $0.isFinite && abs($0 - 0.2) < 1e-6 })
        let b = try bg.extract(pixels: flat, h: 300, w: 200, c: 3, smoothing: 0.5)
        XCTAssertTrue(b.allSatisfy { $0.isFinite && abs($0 - 0.2) < 1e-5 })

        // A frame two-thirds zero-filled (big registration border): MAD is 0.
        var bordered = skyImage(h: 300, w: 300, c: 3)
        for i in 0..<(200 * 300 * 3) { bordered[i] = 0 }
        let d2 = try dn.denoise(pixels: bordered, h: 300, w: 300, c: 3, strength: 1)
        XCTAssertTrue(d2.allSatisfy(\.isFinite))
        XCTAssertLessThan(maxAbsDiff(d2, bordered), 1e-6)   // untrusted pixels keep their input
        let b2 = try bg.extract(pixels: bordered, h: 300, w: 300, c: 3, smoothing: 0.5)
        XCTAssertTrue(b2.allSatisfy(\.isFinite))
    }

    /// A model emitting NaN: denoise keeps the input there; background refuses.
    func testNonFiniteModelOutput() throws {
        let log = try OnnxFixture.write(OnnxFixture.log(), named: "log").path
        let px = skyImage(h: 200, w: 200, c: 3)
        let out = try Denoiser(modelPath: log).denoise(pixels: px, h: 200, w: 200, c: 3, strength: 1)
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        XCTAssertThrowsError(try BgExtractor(modelPath: log).extract(pixels: px, h: 200, w: 200, c: 3)) {
            guard case AIError.unexpectedOutput = $0 else { return XCTFail("\($0)") }
        }
    }

    /// #47: a non-float32 or wrongly-sized output is a thrown error, not a trap.
    func testOutputTypeAndCountAreChecked() throws {
        let px = skyImage(h: 130, w: 130, c: 3)
        let cases: [(String, Data, String)] = [
            ("uint8", OnnxFixture.cast(to: .uint8), "uint8"),
            ("fp16", OnnxFixture.cast(to: .float16), "float32"),
            ("gap", OnnxFixture.globalAveragePool(), "expected"),
        ]
        for (name, data, needle) in cases {
            let path = try OnnxFixture.write(data, named: name).path
            let runs: [() throws -> Void] = [
                { _ = try Denoiser(modelPath: path).denoise(pixels: px, h: 130, w: 130, c: 3, strength: 1) },
                { _ = try BgExtractor(modelPath: path).extract(pixels: px, h: 130, w: 130, c: 3) },
            ]
            for run in runs {
                XCTAssertThrowsError(try run(), name) { error in
                    guard case AIError.unexpectedOutput(let msg) = error else { return XCTFail("\(name): \(error)") }
                    XCTAssertTrue(msg.contains(needle), "\(name): \(msg)")
                }
            }
        }
    }

    func testBadShapesThrowInsteadOfTrapping() throws {
        let dn = try Denoiser(modelPath: identityPath)
        let bg = try BgExtractor(modelPath: identityPath)
        let bad: [([Float], Int, Int, Int)] = [
            ([Float](repeating: 0.1, count: 20 * 10 * 2), 10, 20, 2),   // 2 channels
            ([Float](repeating: 0.1, count: 20 * 10 * 4), 10, 20, 4),   // RGBA
            ([Float](repeating: 0.1, count: 99), 10, 10, 1),            // count mismatch
            ([], 0, 0, 3),                                              // empty
        ]
        for (px, h, w, c) in bad {
            XCTAssertThrowsError(try dn.denoise(pixels: px, h: h, w: w, c: c, strength: 1))
            XCTAssertThrowsError(try bg.extract(pixels: px, h: h, w: w, c: c))
        }
        XCTAssertThrowsError(try dn.denoise(pixels: [0.1], h: 1, w: 1, c: 1, strength: .nan))
    }

    /// #42: the background mean over a 4K frame. A running Float32 sum drifts
    /// by several percent here (numpy's pairwise sum doesn't); Double doesn't.
    func testBackgroundMeanIsAccurateAt4K() {
        let n = 3840 * 2160 * 3
        let constant = [Float](repeating: 0.1, count: n)
        XCTAssertEqual(AIInput.mean(constant), 0.1, accuracy: 1e-7)
        var naive: Float = 0
        for v in constant { naive += v }
        XCTAssertGreaterThan(abs(naive / Float(n) - 0.1) / 0.1, 0.01)   // the old bug, for the record

        // A 1080p ramp (+1.2% drift there before): values k/1000, k = i % 1000.
        let ramp = (0..<(1920 * 1080 * 3)).map { Float($0 % 1000) / 1000 }
        var exact = 0.0
        for v in ramp { exact += Double(v) }
        exact /= Double(ramp.count)
        XCTAssertEqual(Double(AIInput.mean(ramp)), exact, accuracy: 1e-7)

        // And through the subtraction itself: img == bg -> exactly the pedestal.
        let out = BgExtractor.subtract(background: constant, from: constant)
        XCTAssertEqual(out.min()!, 0.1, accuracy: 1e-7)
        XCTAssertEqual(out.max()!, 0.1, accuracy: 1e-7)
    }

    func testFiniteInputIsNotCopiedOrChanged() {
        let px = skyImage(h: 64, w: 64, c: 3)
        let r = AIInput.replacingNonFinite(px, h: 64, w: 64, c: 3)
        XCTAssertEqual(r.replaced, 0)
        XCTAssertEqual(r.pixels, px)
        XCTAssertEqual(AIInput.flooredMAD(0.004), 0.004)        // real MADs pass through
        XCTAssertEqual(AIInput.flooredMAD(0), AIInput.madFloor)
    }
}

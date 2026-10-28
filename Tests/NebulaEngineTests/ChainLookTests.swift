// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
import NebulaCore
@testable import NebulaEngine

/// Look-correctness tests for the shader chain on tiny synthetic layer bundles
/// (audit items 32, 33, 35, 38, 40). They run in CI wherever Metal exists.
final class ChainLookTests: XCTestCase {

    // MARK: 32 — the highlight guard is the identity in gamut

    private let guardProbe = """
    kernel void probeGuard(device const float4* xs [[buffer(0)]], device float4* ys [[buffer(1)]],
                           constant Uniforms& u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        ys[i] = float4(protectHighlights(xs[i].rgb), 0.0);
    }
    """

    func testHighlightGuardIsIdentityInGamutAndHoldsLuminanceAbove() throws {
        let r = try Synth.renderer()
        let lib = try Synth.probeLibrary(r.device, guardProbe)
        var inputs: [SIMD4<Float>] = [
            [1, 1, 1, 0], [0.9, 0.86, 0.95, 0], [1, 0.4, 0.2, 0], [0.5, 0.5, 0.5, 0], [0, 0, 0, 0],
        ]
        // A ray through one hue: in range, at the boundary, and over range.
        let hue = SIMD4<Float>(1.0, 0.55, 0.3, 0)
        for k in stride(from: Float(0.2), through: 4.0, by: 0.05) { inputs.append(hue * k) }
        let out = try Synth.runProbe(r, lib, "probeGuard", input: inputs, uniforms: Synth.uniforms(.default))
        func lum(_ c: SIMD4<Float>) -> Float { c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722 }

        var prevLum: Float = -1
        for (i, (c, o)) in zip(inputs, out).enumerated() {
            let peak = max(c.x, c.y, c.z)
            if peak <= 1 {
                // In gamut: untouched. (The old 0.85 knee sent pure white to 0.945.)
                XCTAssertEqual(o.x, c.x, accuracy: 1e-6); XCTAssertEqual(o.y, c.y, accuracy: 1e-6)
                XCTAssertEqual(o.z, c.z, accuracy: 1e-6)
            } else {
                // Over range: peak lands exactly on the gamut boundary, luminance
                // held (or white once luminance itself reaches white).
                XCTAssertEqual(max(o.x, o.y, o.z), 1, accuracy: 1e-5)
                XCTAssertEqual(lum(o), min(lum(c), 1), accuracy: 1e-5)
                XCTAssertGreaterThanOrEqual(min(o.x, o.y, o.z), 0)
            }
            if i >= 5 {
                // Along the ray, a brighter input never renders darker.
                XCTAssertGreaterThanOrEqual(lum(o), prevLum - 1e-6)
                prevLum = lum(o)
            }
        }
        XCTAssertEqual(out[0], SIMD4<Float>(1, 1, 1, 0), "pure white must render 255/255")
    }

    /// End to end: in the truthful look an in-gamut image comes out as exactly
    /// the documented base stretch (per-channel black point, one luminance
    /// MTF carried back colour-preserving) — no highlight knee, no SCNR, no
    /// shadow neutralisation, no core whitening.
    func testNeutralLookRendersExactlyTheBaseStretch() throws {
        let r = try Synth.renderer()
        let w = 96, h = 24
        // A coloured ramp (a green-leaning nebula, so a stray SCNR would show)
        // from sky to well up the curve, over a sky with a gradient.
        let master = Synth.image(w, h) { x, y in
            let v = 0.004 + 0.9 * pow(Float(x) / Float(w - 1), 3) + Float(y) * 1e-5
            return (0.01 + v * 0.8, 0.01 + v * 1.1, 0.01 + v * 0.7)
        }
        // The base stretch parks the STARLESS layer's bright end at its
        // highlight cap (0.72), so put the brightest part of the ramp in the
        // star layer: the rendered pixels are still exactly the master, and
        // they now run up through the 0.85–1 range the old knee squashed.
        let starless = Synth.image(w, h) { x, y in
            let p = (y * w + x) * 4
            return (min(master.rgba[p], 0.03), min(master.rgba[p+1], 0.03), min(master.rgba[p+2], 0.03))
        }
        let stars = Synth.image(w, h) { x, y in
            let p = (y * w + x) * 4
            return (master.rgba[p] - starless.rgba[p], master.rgba[p+1] - starless.rgba[p+1],
                    master.rgba[p+2] - starless.rgba[p+2])
        }
        let bundle = r.makeBundle(master: master, corrected: master, denoised: master,
                                  starless: starless, stars: stars)
        let out = try r.renderImage(bundle: bundle, params: LookState.neutral.engineParams)
        let st = bundle.autoMaster ?? bundle.auto
        let sh = [st.shadow.0, st.shadow.1, st.shadow.2]
        var checked = 0
        for p in 0..<(w * h) {
            let n = (0..<3).map { max(master.rgba[p*4+$0] - sh[$0], 0) / max(1 - sh[$0], 1e-4) }
            let l = n[0] * 0.2126 + n[1] * 0.7152 + n[2] * 0.0722
            guard l > 1e-6 else { continue }
            let scale = AutoStretch.mtf(l, st.midtone.0) / l
            let expected = n.map { $0 * scale }
            guard expected.max()! <= 1 else { continue }          // over range: the guard's job
            for c in 0..<3 {
                XCTAssertEqual(out.rgba[p*4+c], expected[c], accuracy: 2e-4 + expected[c] * 2e-4,
                               "pixel \(p) channel \(c)")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, w * h / 2)
        // The ramp really does run through the old knee's territory in gamut.
        let inGamutPeaks = (0..<(w * h)).map { p in max(out.rgba[p*4], out.rgba[p*4+1], out.rgba[p*4+2]) }
            .filter { $0 < 0.999 }
        XCTAssertGreaterThan(inGamutPeaks.max()!, 0.95)
    }

    // MARK: 33 — Detail never acts on stars

    /// Detail's bands are measured on the star-free development, and its
    /// change is taken by each pixel in proportion to the nebula's share of
    /// its light. So: away from the star the change is EXACTLY what it is with
    /// no star at all — no halo, no darkened sky ring (the audit simulated
    /// +0.107 at r=12–16 px and −18 % at r=25–30 px at the default Detail) —
    /// and the star itself keeps its Detail-0 profile instead of picking up
    /// the sky's stretched noise.
    func testDetailLeavesStarsAndTheirSurroundingsAlone() throws {
        let r = try Synth.renderer()
        let w = 128, h = 128
        // A noisy sky with a broad nebula swell (so Detail has real structure
        // to work on) and a bright star on its flank.
        func noise(_ x: Int, _ y: Int) -> Float {
            var v = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663)
            v = (v ^ (v >> 13)) &* 1274126177
            return (Float(v & 0xFFFF) / 65535 - 0.5) * 0.004
        }
        func neb(_ x: Int, _ y: Int) -> Float {
            0.03 + noise(x, y) + Synth.star(x, y, cx: 40, cy: 64, amp: 0.10, s2: 300)
        }
        func st(_ x: Int, _ y: Int) -> Float { Synth.star(x, y, cx: 84, cy: 64, amp: 0.6, s2: 4) }
        let starless = Synth.grey(w, h, neb)
        let withStar = Synth.grey(w, h) { x, y in neb(x, y) + st(x, y) }
        let bundle = r.makeBundle(master: withStar, corrected: withStar, denoised: withStar,
                                  starless: starless, stars: Synth.grey(w, h, st))

        // Default look with Denoise off isolates Detail (the bilateral's own
        // change is fed through Detail's bands by design); Star Size 50. The
        // star-free reference is the SAME bundle at Stars 0, so the stretch is
        // identical and only the star's presence differs.
        var on = LookState.default; on[.denoise] = 0; on[.starSize] = 0.5
        var off = on; off[.detail] = 0
        var onNoStar = on; onNoStar[.stars] = 0
        var offNoStar = off; offNoStar[.stars] = 0
        func render(_ look: LookState) throws -> FITSImage {
            try r.renderImage(bundle: bundle, params: look.engineParams)
        }
        let aOn = try render(on), aOff = try render(off)
        let bOn = try render(onNoStar), bOff = try render(offNoStar)
        XCTAssertGreaterThan(abs(Synth.lum(bOn, 40, 64) - Synth.lum(bOff, 40, 64)), 0.005,
                             "Detail must still shape the nebula")
        XCTAssertGreaterThan(Synth.lum(aOn, 84, 64) - Synth.lum(bOn, 84, 64), 0.2, "star missing")

        // Away from the star (no star flux at all): identical to no star.
        var worstOutside: Float = 0
        for y in 0..<h { for x in 0..<w where st(x, y) < 1e-6 {
            let dA = Synth.lum(aOn, x, y) - Synth.lum(aOff, x, y)
            let dB = Synth.lum(bOn, x, y) - Synth.lum(bOff, x, y)
            worstOutside = max(worstOutside, abs(dA - dB))
        } }
        // On the star: Detail's change is at most the nebula's share of it.
        var worstOnStar: Float = 0
        for y in 56...72 { for x in 76...92 {
            let share = neb(x, y) / (neb(x, y) + st(x, y))
            let dA = abs(Synth.lum(aOn, x, y) - Synth.lum(aOff, x, y))
            let dB = abs(Synth.lum(bOn, x, y) - Synth.lum(bOff, x, y))
            worstOnStar = max(worstOnStar, dA - dB * share)
        } }
        let core = Synth.lum(aOn, 84, 64) - Synth.lum(aOff, 84, 64)
        print("Detail on/off: outside-star mismatch \(worstOutside), on-star excess \(worstOnStar), core Δ \(core)")
        XCTAssertLessThan(worstOutside, 1e-4, "Detail acted around the star (halo / ring)")
        XCTAssertLessThan(worstOnStar, 2e-3, "Detail transplanted nebula change onto the star")
        XCTAssertLessThan(abs(core), 2e-3, "Detail changed the star core")

        // The halo and ring metrics themselves, around the star.
        func ring(_ img: FITSImage, _ r0: Float, _ r1: Float) -> Float {
            var s: Float = 0, n: Float = 0
            for y in 0..<h { for x in 0..<w {
                let d = hypot(Float(x - 84), Float(y - 64))
                if d >= r0 && d <= r1 && x > 84 { s += Synth.lum(img, x, y); n += 1 }  // away from the swell
            } }
            return s / n
        }
        let halo = (ring(aOn, 12, 16) - ring(aOff, 12, 16)) - (ring(bOn, 12, 16) - ring(bOff, 12, 16))
        let sky = (ring(aOn, 25, 30) - ring(aOff, 25, 30)) - (ring(bOn, 25, 30) - ring(bOff, 25, 30))
        print("halo r12-16 = \(halo), sky ring r25-30 = \(sky / ring(aOff, 25, 30) * 100)%")
        XCTAssertLessThan(abs(halo), 1e-4)
        XCTAssertLessThan(abs(sky) / ring(aOff, 25, 30), 1e-3)
    }

    // MARK: 35 — the master end of Background uses the master's own stretch

    /// Below Background 60 the chain fades toward the raw master; its black
    /// points must then come from the master, or a master whose pedestals
    /// differ from the corrected layer renders a coloured, lifted sky (the
    /// "crushed red" mismatch in reverse).
    func testBackgroundZeroRendersTheMasterThroughItsOwnStretch() throws {
        let r = try Synth.renderer()
        let w = 96, h = 96
        // Sky with per-channel pedestals and noise-like texture; the corrected
        // layer has them removed (what PCC + BGE do).
        func tex(_ x: Int, _ y: Int) -> Float { Float((x * 37 + y * 91) % 17) / 17 * 0.004 }
        let master = Synth.image(w, h) { x, y in (0.050 + tex(x, y), 0.032 + tex(x, y), 0.021 + tex(x, y)) }
        let corrected = Synth.image(w, h) { x, y in (0.010 + tex(x, y), 0.010 + tex(x, y), 0.010 + tex(x, y)) }
        let stars = Synth.grey(w, h) { _, _ in 0 }
        let bundle = r.makeBundle(master: master, corrected: corrected, denoised: corrected,
                                  starless: corrected, stars: stars)
        let out = try r.renderImage(bundle: bundle, params: LookState.neutral.engineParams)
        var med = [Float]()
        for c in 0..<3 {
            var v = (0..<(w*h)).map { out.rgba[$0*4+c] }; v.sort(); med.append(v[v.count/2])
        }
        XCTAssertLessThan((med.max()! - med.min()!) * 255, 2, "sky not neutral at Background 0: \(med)")
        let sky = med[0] * 0.2126 + med[1] * 0.7152 + med[2] * 0.0722
        XCTAssertEqual(sky, bundle.autoMaster!.displaySky, accuracy: 0.02)

        // From Background 60 up nothing changes: the blended uniforms are
        // bit-identical to the corrected layer's own stretch.
        for bg in [0.6, 0.8, 1.0] {
            var look = LookState.default; look[.background] = bg
            let blended = EngineParamsGPU(look.engineParams, auto: bundle.auto,
                                          master: bundle.autoMaster, star: bundle.star)
            let plain = EngineParamsGPU(look.engineParams, auto: bundle.auto, star: bundle.star)
            XCTAssertEqual(blended.shadow0, plain.shadow0); XCTAssertEqual(blended.shadow1, plain.shadow1)
            XCTAssertEqual(blended.shadow2, plain.shadow2); XCTAssertEqual(blended.midtone0, plain.midtone0)
            XCTAssertEqual(blended.autoSky, plain.autoSky)
        }
    }

    // MARK: 38 — star-layer stretch on a sparse layer

    func testStarStretchMeasuresStarFluxOnASparseLayer() throws {
        let w = 256, h = 256
        // Three small stars: well under 0.5% of the frame carries any flux.
        let centres = [(40, 40), (200, 90), (120, 210)]
        let sparse = Synth.grey(w, h) { x, y in
            centres.map { c -> Float in
                let d2 = (x - c.0) * (x - c.0) + (y - c.1) * (y - c.1)
                return d2 <= 4 ? 0.2 * exp(-Float(d2) / 2) : 0
            }.reduce(0, +)
        }
        let s = StarStretch(base: sparse)
        XCTAssertGreaterThan(s.midtone.0, 1e-3, "midtone collapsed to its floor")
        XCTAssertEqual(s.shadow.0, 0)
        // An empty layer has nothing to lift: identity midtone, no crash.
        let empty = StarStretch(base: Synth.grey(64, 64) { _, _ in 0 })
        XCTAssertEqual(empty.midtone.0, 0.5)
        XCTAssertEqual(empty.shadow.0, 0)
    }

    /// The visible symptom: with Star Size bloom on, a faint feathered edge of
    /// a sparse star mask must not glow.
    func testBloomDoesNotLightFeatheredMaskEdgesOnASparseLayer() throws {
        let r = try Synth.renderer()
        let w = 128, h = 128
        func st(_ x: Int, _ y: Int) -> Float {
            let d2 = (x - 64) * (x - 64) + (y - 64) * (y - 64)
            if d2 <= 2 { return 0.3 }
            return d2 <= 9 ? 0.002 : 0          // a faint feathered rim
        }
        let starless = Synth.grey(w, h) { _, _ in 0.02 }
        let master = Synth.grey(w, h) { x, y in 0.02 + st(x, y) }
        let bundle = r.makeBundle(master: master, corrected: master, denoised: master,
                                  starless: starless, stars: Synth.grey(w, h, st))
        var look = LookState.neutral
        let plain = try r.renderImage(bundle: bundle, params: look.engineParams)
        look[.starSize] = 1
        let bloomed = try r.renderImage(bundle: bundle, params: look.engineParams)
        let rim = Synth.lum(bloomed, 67, 64) - Synth.lum(plain, 67, 64)
        XCTAssertLessThan(rim, 0.05, "a 0.002 feathered edge glowed by \(rim)")
        XCTAssertGreaterThan(Synth.lum(bloomed, 64, 64), Synth.lum(plain, 64, 64) - 1e-4)
    }

    // MARK: 40 — one GHS, CPU and GPU

    private let ghsProbe = """
    kernel void probeGHS(device const float4* xs [[buffer(0)]], device float4* ys [[buffer(1)]],
                         constant Uniforms& u [[buffer(2)]], uint i [[thread_position_in_grid]]) {
        ys[i] = float4(ghsStretch(xs[i].x, u.glowD, u.ghsB, u.contrastSP, u.ghsHP), 0, 0, 0);
    }
    """

    /// The shader's GHS against its CPU mirror over the whole slider range,
    /// through the uniforms the engine actually uploads (so the shape constants
    /// come from `GHS`, not from literals). Tolerance: the engine compiles with
    /// Metal's default fast-math, where `pow` is evaluated as exp2(y·log2 x)
    /// with a few-ulp error; propagated through the normalisation the curve
    /// can differ from the float32 CPU result by ~1e-6–1e-5 (measured max is
    /// printed). 2e-5 still catches any change of b, HP or the closed form —
    /// those move the curve by orders of magnitude more.
    func testShaderGHSMatchesCPU() throws {
        let r = try Synth.renderer()
        let lib = try Synth.probeLibrary(r.device, ghsProbe)
        let xs = (0..<2048).map { SIMD4<Float>(Float($0) / 2047, 0, 0, 0) }
        var worst: Float = 0
        for glow in [0.05, 0.25, 0.47, 0.75, 1.0] {
            for contrast in [0.0, 0.3, 0.58, 1.0] {
                var look = LookState.default
                look[.glow] = glow; look[.contrast] = contrast
                let u = Synth.uniforms(look)
                XCTAssertEqual(u.ghsB, GHS.b); XCTAssertEqual(u.ghsHP, GHS.highlightProtect)
                let gpu = try Synth.runProbe(r, lib, "probeGHS", input: xs, uniforms: u)
                let p = look.engineParams
                for (x, g) in zip(xs, gpu) {
                    let cpu = GHS.stretch(x.x, D: p.glowD, b: GHS.b, SP: p.contrastSP,
                                          HP: GHS.highlightProtect)
                    worst = max(worst, abs(cpu - g.x))
                }
            }
        }
        print("GHS GPU vs CPU max |Δ| = \(worst)")
        XCTAssertLessThan(worst, 2e-5)
        XCTAssertFalse(shaderSource.contains("u.contrastSP, 0.20"), "GHS constants hard-coded again")
    }
}

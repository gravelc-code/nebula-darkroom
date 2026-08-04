// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
import NebulaCore
@testable import NebulaEngine

final class NebulaEngineTests: XCTestCase {
    func testStarShaderRefreshesLuminanceAfterMidtoneStretch() {
        let midtone = shaderSource.range(of: "st = withLuminance(st, starLum, mtfPivot")!
        let refresh = shaderSource.range(of: "starLum = luminance(st);", range: midtone.upperBound..<shaderSource.endIndex)!
        let glow = shaderSource.range(of: "glowStretch(starLum", range: refresh.upperBound..<shaderSource.endIndex)!
        XCTAssertLessThan(refresh.lowerBound, glow.lowerBound)
    }

    func testCropCopiesTheSamePixelsFromEveryLayer() {
        var rgba = [Float](repeating: 1, count: 6*5*4)
        for y in 0..<5 { for x in 0..<6 {
            rgba[(y*6+x)*4] = Float(y*10+x)
        } }
        let image = FITSImage(width: 6, height: 5, channels: 3, rgba: rgba)
        let crop = image.cropped(x: 2, y: 1, width: 3, height: 2)
        XCTAssertEqual(crop.width, 3)
        XCTAssertEqual(crop.height, 2)
        XCTAssertEqual(crop.rgba[0], 12)
        XCTAssertEqual(crop.rgba[(1*3+2)*4], 24)
    }

    /// The base stretch takes its black point per channel (that is what
    /// neutralises the sky) but its midtone ONCE, from luminance.
    ///
    /// Stretching each channel to its own target is what an unlinked
    /// autostretch does, and on emission data it destroys the colour rather
    /// than merely shifting the balance: the MTF saturates, so the channel
    /// carrying the most signal is compressed hardest. A real M 8 pixel at
    /// R/G 1.83 came back at 0.91 — a red nebula rendered faintly blue.
    func testAutoStretchIsColourPreserving() {
        var rgba = [Float](repeating: 1, count: 80*80*4)
        for i in 0..<(80*80) {
            // Distinct per-channel pedestals AND a strongly red subject.
            let v = Float(i % 80) / 800 + 0.01
            rgba[i*4] = v * 1.8 + 0.004; rgba[i*4+1] = v + 0.002; rgba[i*4+2] = v * 0.9 + 0.001
        }
        let stretch = AutoStretch(base: FITSImage(width: 80, height: 80, channels: 3, rgba: rgba))
        // One linked midtone — the whole point.
        XCTAssertEqual(stretch.midtone.0, stretch.midtone.1)
        XCTAssertEqual(stretch.midtone.1, stretch.midtone.2)
        XCTAssertGreaterThan(stretch.midtone.0, 0)

        // Applying it the way the shader does preserves the hue: a bright
        // pixel keeps its channel ratio instead of collapsing toward grey.
        let px: (Float, Float, Float) = (0.09, 0.05, 0.045)
        let n = (max(px.0 - stretch.shadow.0, 0) / (1 - stretch.shadow.0),
                 max(px.1 - stretch.shadow.1, 0) / (1 - stretch.shadow.1),
                 max(px.2 - stretch.shadow.2, 0) / (1 - stretch.shadow.2))
        let lum = n.0 * 0.2126 + n.1 * 0.7152 + n.2 * 0.0722
        let scale = AutoStretch.mtf(lum, stretch.midtone.0) / lum
        let ratioBefore = n.0 / n.1, ratioAfter = (n.0 * scale) / (n.1 * scale)
        XCTAssertEqual(ratioAfter, ratioBefore, accuracy: 1e-5)
        XCTAssertGreaterThan(ratioAfter, 1.4, "red subject must stay red")
    }

    /// Regression: the starless/denoised deltas must not be faded by the
    /// Background correction blend — at Background=0 (the Auto default) the
    /// Denoise and Stars sliders still have to change the render.
    func testDenoiseAndStarsSlidersActAtZeroBackground() throws {
        let renderer: ChainRenderer
        do { renderer = try ChainRenderer() } catch { throw XCTSkip("no Metal device") }

        let w = 64, h = 64
        func image(_ fill: (Int, Int) -> Float) -> FITSImage {
            var rgba = [Float](repeating: 1, count: w*h*4)
            for y in 0..<h { for x in 0..<w {
                let v = fill(x, y)
                let p = (y*w+x)*4; rgba[p] = v; rgba[p+1] = v; rgba[p+2] = v
            } }
            return FITSImage(width: w, height: h, channels: 3, rgba: rgba)
        }
        func star(_ x: Int, _ y: Int) -> Float {
            let d = Float((x-32)*(x-32) + (y-32)*(y-32))
            return 0.6 * exp(-d/3)
        }
        func noise(_ x: Int, _ y: Int) -> Float { Float((x*31 + y*17) % 7) / 7 * 0.02 }

        let master   = image { x, y in 0.05 + noise(x, y) + star(x, y) }
        let denoised = image { x, y in 0.05 + star(x, y) }          // noise removed
        let starless = image { x, y in 0.05 + noise(x, y) }         // star removed
        let stars    = image { x, y in star(x, y) }
        let bundle = renderer.makeBundle(master: master, corrected: master,
                                         denoised: denoised, starless: starless, stars: stars)

        var look = LookState.neutral                                  // background = 0
        let base = try renderer.renderImage(bundle: bundle, params: look.engineParams)

        look[.denoise] = 1
        let denoisedOut = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        let denoiseDiff = zip(base.rgba, denoisedOut.rgba).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(denoiseDiff, 0.005, "Denoise slider is dead at Background=0")

        look = LookState.neutral
        look[.stars] = 0
        let noStars = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        let core = (32*w+32)*4
        XCTAssertGreaterThan(base.rgba[core] - noStars.rgba[core], 0.1,
                             "Stars slider is dead at Background=0")
    }

    /// Star Size is bidirectional: below its midpoint it erodes the star flux
    /// (halo pixels dim, background untouched), above it blooms; the midpoint
    /// leaves the captured profiles alone.
    func testStarSizeShrinksAndBloomsAroundNeutral() throws {
        let renderer: ChainRenderer
        do { renderer = try ChainRenderer() } catch { throw XCTSkip("no Metal device") }

        let w = 64, h = 64
        func image(_ fill: (Int, Int) -> Float) -> FITSImage {
            var rgba = [Float](repeating: 1, count: w*h*4)
            for y in 0..<h { for x in 0..<w {
                let v = fill(x, y)
                let p = (y*w+x)*4; rgba[p] = v; rgba[p+1] = v; rgba[p+2] = v
            } }
            return FITSImage(width: w, height: h, channels: 3, rgba: rgba)
        }
        func star(_ x: Int, _ y: Int) -> Float {
            let d = Float((x-32)*(x-32) + (y-32)*(y-32))
            return 0.6 * exp(-d/12)   // a broad, halo-heavy star
        }
        let master   = image { x, y in 0.05 + star(x, y) }
        let starless = image { _, _ in 0.05 }
        let stars    = image { x, y in star(x, y) }
        let bundle = renderer.makeBundle(master: master, corrected: master,
                                         denoised: master, starless: starless, stars: stars)

        func lum(_ img: FITSImage, _ x: Int, _ y: Int) -> Float {
            let p = (y*w+x)*4
            return img.rgba[p]*0.2126 + img.rgba[p+1]*0.7152 + img.rgba[p+2]*0.0722
        }
        var look = LookState.neutral                       // starSize = 50: natural
        let natural = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        look[.starSize] = 0.2
        let tightened = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        look[.starSize] = 0.8
        let bloomed = try renderer.renderImage(bundle: bundle, params: look.engineParams)

        // Halo skirt (r≈4 from the core) dims when shrinking, brightens with bloom.
        XCTAssertLessThan(lum(tightened, 36, 32) + 0.02, lum(natural, 36, 32),
                          "shrink did not pull the halo in")
        XCTAssertGreaterThan(lum(bloomed, 36, 32), lum(natural, 36, 32) - 1e-4,
                             "bloom should never dim the halo")
        // The star survives shrinking: its core still stands far above the sky.
        XCTAssertGreaterThan(lum(tightened, 32, 32), lum(tightened, 5, 5) + 0.1)
        // Star-free background is untouched by either direction.
        XCTAssertEqual(lum(tightened, 5, 5), lum(natural, 5, 5), accuracy: 2e-3)
        XCTAssertEqual(lum(bloomed, 5, 5), lum(natural, 5, 5), accuracy: 2e-3)
    }

    /// Detail's large-scale structure boost is multi-scale local contrast: a
    /// broad nebula swell (wider than the small box gathers) must gain contrast
    /// against its surround when Detail rises — that swell is the visible "pop".
    func testDetailStructureBoostRaisesLargeScaleContrast() throws {
        let renderer: ChainRenderer
        do { renderer = try ChainRenderer() } catch { throw XCTSkip("no Metal device") }

        let w = 96, h = 96
        func image(_ fill: (Int, Int) -> Float) -> FITSImage {
            var rgba = [Float](repeating: 1, count: w*h*4)
            for y in 0..<h { for x in 0..<w {
                let v = fill(x, y)
                let p = (y*w+x)*4; rgba[p] = v; rgba[p+1] = v; rgba[p+2] = v
            } }
            return FITSImage(width: w, height: h, channels: 3, rgba: rgba)
        }
        // A broad, smooth nebula blob (σ≈14 px) — larger than the ±4 px box
        // gathers, so only the coarse mip bands (structure) can see it.
        func blob(_ x: Int, _ y: Int) -> Float {
            let d = Float((x-48)*(x-48) + (y-48)*(y-48))
            return 0.45 * exp(-d/380)
        }
        let neb   = image { x, y in 0.04 + blob(x, y) }
        let stars = image { _, _ in 0.0 }
        let bundle = renderer.makeBundle(master: neb, corrected: neb,
                                         denoised: neb, starless: neb, stars: stars)

        func lum(_ img: FITSImage, _ x: Int, _ y: Int) -> Float {
            let p = (y*w+x)*4
            return img.rgba[p]*0.2126 + img.rgba[p+1]*0.7152 + img.rgba[p+2]*0.0722
        }
        var look = LookState.neutral          // detail = 0: structure boost off
        look[.detail] = 0
        let flat = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        look[.detail] = 1                    // full multi-scale structure
        let popped = try renderer.renderImage(bundle: bundle, params: look.engineParams)

        // Contrast = blob core minus a point out on its skirt (r≈20 px). The boost
        // must widen that gap; the swell is what reads as depth.
        let flatContrast = lum(flat, 48, 48) - lum(flat, 68, 48)
        let popContrast  = lum(popped, 48, 48) - lum(popped, 68, 48)
        XCTAssertGreaterThan(popContrast, flatContrast + 0.01,
                             "structure boost did not deepen large-scale contrast")
        // The core (above its coarse surround) genuinely brightens — it pops.
        XCTAssertGreaterThan(lum(popped, 48, 48), lum(flat, 48, 48) + 1e-3)
    }

    func testAutoCropFindsACompactCentralTarget() {
        let w = 400, h = 600
        var rgba = [Float](repeating: 1, count: w*h*4)
        for y in 0..<h { for x in 0..<w {
            let dx = Float(x-w/2)/34, dy = Float(y-h/2)/34
            let v: Float = 0.01 + 0.25 * exp(-(dx*dx+dy*dy)/2)
            let p=(y*w+x)*4; rgba[p]=v; rgba[p+1]=v; rgba[p+2]=v
        } }
        let region = AutoCrop.region(for: FITSImage(width: w, height: h, channels: 3, rgba: rgba))
        XCTAssertLessThan(region.width, w)
        XCTAssertLessThan(region.height, h)
        XCTAssertGreaterThanOrEqual(region.width, Int(Float(w)*0.57))
        XCTAssertTrue(region.x < w/2 && region.x+region.width > w/2)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
import Metal
import NebulaCore
@testable import NebulaEngine

/// Where the chain's result goes: off-screen renders vs the live view (audit
/// item 28) and the 8-bit preview vs the 16-bit export (item 39).
final class ChainOutputTests: XCTestCase {

    private func fieldBundle(_ r: ChainRenderer, _ w: Int = 96, _ h: Int = 64) -> ChainRenderer.LayerBundle {
        func st(_ x: Int, _ y: Int) -> Float { Synth.star(x, y, cx: 30, cy: 30, amp: 0.4, s2: 3) }
        let neb = Synth.image(w, h) { x, y in
            let v = 0.02 + 0.15 * Float(x) / Float(w) + Synth.star(x, y, cx: 60, cy: 32, amp: 0.1, s2: 150)
            return (v * 1.1, v, v * 0.9)
        }
        let master = Synth.image(w, h) { x, y in
            let p = (y * w + x) * 4, s = st(x, y)
            return (neb.rgba[p] + s, neb.rgba[p+1] + s, neb.rgba[p+2] + s)
        }
        return r.makeBundle(master: master, corrected: master, denoised: master,
                            starless: neb, stars: Synth.grey(w, h, st))
    }

    // MARK: 28

    /// An off-screen render (export, thumbnail, AI input) never reads the live
    /// view's textures: the 120 Hz loop can be mid-flight on another look and
    /// the export still contains exactly its own look.
    func testOffscreenRenderIsIsolatedFromTheLiveView() throws {
        let r = try Synth.renderer()
        let bundle = fieldBundle(r)
        let exportLook = LookState.default
        var look = LookState.default; look[.glow] = 1; look[.saturation] = 0
        let liveLook = look
        let reference = try r.renderImage(bundle: bundle, params: exportLook.engineParams)

        // The live view keeps drawing a very different look while exports run
        // on another thread; every export must equal the reference exactly.
        let stop = ManagedAtomicFlag()
        let live = Thread {
            while !stop.isSet {
                let cmd = r.queue.makeCommandBuffer()!
                r.encodeChain(cmd, liveLook.engineParams, bundle, into: bundle.live)
                cmd.commit()
            }
        }
        live.start()
        defer { stop.set() }
        for _ in 0..<12 {
            let out = try r.renderImage(bundle: bundle, params: exportLook.engineParams)
            XCTAssertEqual(out.rgba, reference.rgba, "an export picked up the live view's look")
        }
        stop.set()

        // And the live textures hold the live look, untouched by the exports.
        let cmd = r.queue.makeCommandBuffer()!
        r.encodeChain(cmd, liveLook.engineParams, bundle, into: bundle.live)
        cmd.commit(); cmd.waitUntilCompleted()
        let liveOut = ChainRenderer.readBack(bundle.live.out)
        let liveRef = try r.renderImage(bundle: bundle, params: liveLook.engineParams)
        XCTAssertEqual(liveOut, liveRef.rgba, "preview and export disagree for the same look")
    }

    // MARK: 39

    private func renderTarget(_ r: ChainRenderer, _ w: Int, _ h: Int) -> (MTLTexture, MTLRenderPassDescriptor) {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: ChainRenderer.drawablePixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let t = r.device.makeTexture(descriptor: d)!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = t
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        return (t, rpd)
    }

    /// BGRA8 drawable → RGB codes (0…255) as floats.
    private func codes(_ t: MTLTexture) -> [Float] {
        let (w, h) = (t.width, t.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            out[i*3] = Float(px[i*4+2]); out[i*3+1] = Float(px[i*4+1]); out[i*3+2] = Float(px[i*4])
        }
        return out
    }

    private func floatTexture(_ r: ChainRenderer, _ w: Int, _ h: Int, _ f: (Int, Int) -> Float) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead]
        let t = r.device.makeTexture(descriptor: d)!
        var v = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = f(x, y); for k in 0..<3 { v[(y*w+x)*4+k] = c } } }
        v.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                      withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        return t
    }

    private func blit(_ r: ChainRenderer, _ src: MTLTexture, dither: Float) -> [Float] {
        let (t, rpd) = renderTarget(r, src.width, src.height)
        let cmd = r.queue.makeCommandBuffer()!
        r.encodeDisplayBlit(cmd, source: src, before: src, compare: false, divider: 0.5,
                            clipping: false, ditherLSB: dither, pass: rpd)
        cmd.commit(); cmd.waitUntilCompleted()
        return codes(t)
    }

    /// A slow sky gradient spanning a few 8-bit codes: undithered, each column
    /// snaps to one code (bands, mean error up to ½ LSB); dithered, every
    /// column's MEAN tracks the true value — the export's tone — to a small
    /// fraction of a code, and no pixel is off by more than 1.5 codes.
    func testPreviewDitherRemovesBandingWithoutChangingTone() throws {
        let r = try Synth.renderer()
        let w = 256, h = 128
        let lo: Float = 30.0 / 255, span: Float = 4.0 / 255
        let src = floatTexture(r, w, h) { x, _ in lo + span * Float(x) / Float(w - 1) }
        let dithered = blit(r, src, dither: ChainRenderer.previewDitherLSB)
        let plain = blit(r, src, dither: 0)
        var worstMeanD: Float = 0, worstMeanP: Float = 0, worstPixel: Float = 0
        for x in 0..<w {
            let truth = (lo + span * Float(x) / Float(w - 1)) * 255
            var sd: Float = 0, sp: Float = 0
            for y in 0..<h {
                let d = dithered[(y*w+x)*3+1], p = plain[(y*w+x)*3+1]
                sd += d; sp += p; worstPixel = max(worstPixel, abs(d - truth))
            }
            worstMeanD = max(worstMeanD, abs(sd / Float(h) - truth))
            worstMeanP = max(worstMeanP, abs(sp / Float(h) - truth))
        }
        print("column-mean error: dithered \(worstMeanD) LSB, plain \(worstMeanP) LSB; worst pixel \(worstPixel)")
        XCTAssertGreaterThan(worstMeanP, 0.4)           // the banding being fixed
        XCTAssertLessThan(worstMeanD, 0.2)              // tone kept on average
        XCTAssertLessThanOrEqual(worstPixel, 1.5 + 1e-3)

        // Pure black and pure white stay pure (and so does the clipping overlay).
        let ends = blit(r, floatTexture(r, 16, 16) { x, _ in x < 8 ? 0 : 1 }, dither: ChainRenderer.previewDitherLSB)
        for i in 0..<(16*16) {
            XCTAssertEqual(ends[i*3+1], (i % 16) < 8 ? 0 : 255)
        }
    }

    /// The real live frame (chain + dithered display blit) against the export
    /// of the same look: same tone, within quantisation + dither.
    func testLivePreviewMatchesExportTone() throws {
        let r = try Synth.renderer()
        let bundle = fieldBundle(r)
        let look = LookState.default
        let (t, rpd) = renderTarget(r, bundle.width, bundle.height)
        let cmd = r.queue.makeCommandBuffer()!
        r.encodePreview(cmd, bundle: bundle, params: look.engineParams, compare: false,
                        divider: 0.5, clipping: false, pass: rpd)
        cmd.commit(); cmd.waitUntilCompleted()
        let preview = codes(t)
        let export = try r.renderImage(bundle: bundle, params: look.engineParams)
        var sum: Float = 0, worst: Float = 0
        for i in 0..<(bundle.width * bundle.height) { for c in 0..<3 {
            let e = export.rgba[i*4+c] * 255, p = preview[i*3+c]
            sum += p - e; worst = max(worst, abs(p - e))
        } }
        let mean = sum / Float(bundle.width * bundle.height * 3)
        XCTAssertLessThanOrEqual(worst, 1.5 + 1e-3)
        XCTAssertLessThan(abs(mean), 0.1)
    }
}

/// Minimal thread-safe flag for the stress test.
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NebulaCore

/// GPU-side layout of `EngineParams` + the per-channel auto base stretch — field
/// order MUST match `Uniforms` in the shader source.
public struct EngineParamsGPU {
    var denoiseBlend: Float
    var smoothStrength: Float
    var correctionBlend: Float
    var blackPoint: Float
    var glowD: Float
    var contrastSP: Float
    var detailStrength: Float
    var structureStrength: Float
    var saturation: Float
    var vibrance: Float
    var tint: Float
    var warmth: Float
    var shadowNeutralize: Float
    var starWeight: Float
    var starD: Float
    var starShrink: Float
    /// The sky level the base stretch achieved for THIS image (measured, not
    /// assumed) — the shader derives the black point and every sky-relative
    /// threshold from it.
    var autoSky: Float
    var shadow0: Float; var shadow1: Float; var shadow2: Float
    var midtone0: Float; var midtone1: Float; var midtone2: Float
    var starShadow0: Float; var starShadow1: Float; var starShadow2: Float
    var starMidtone0: Float; var starMidtone1: Float; var starMidtone2: Float

    public init(_ p: EngineParams, auto a: AutoStretch, star s: StarStretch) {
        denoiseBlend = p.denoiseBlend; smoothStrength = p.smoothStrength
        correctionBlend = p.correctionBlend
        blackPoint = p.blackPoint
        glowD = p.glowD; contrastSP = p.contrastSP
        detailStrength = p.detailStrength; structureStrength = p.structureStrength
        saturation = p.saturation; vibrance = p.vibrance; tint = p.tint
        warmth = p.warmth; shadowNeutralize = p.shadowNeutralize
        starWeight = p.starWeight; starD = p.starD; starShrink = p.starShrink
        autoSky = a.displaySky
        shadow0 = a.shadow.0; shadow1 = a.shadow.1; shadow2 = a.shadow.2
        midtone0 = a.midtone.0; midtone1 = a.midtone.1; midtone2 = a.midtone.2
        starShadow0 = s.shadow.0; starShadow1 = s.shadow.1; starShadow2 = s.shadow.2
        starMidtone0 = s.midtone.0; starMidtone1 = s.midtone.1; starMidtone2 = s.midtone.2
    }
}

/// Dedicated stretch for the sparse star layer. The star layer is mostly zero
/// (background) with compact star flux, so an image-median autostretch would
/// over-lift noise. Instead: black point at the median (~0), and a midtone that
/// maps a high percentile (typical faint-star flux) up to a visible level — so
/// faint field stars survive separation + denoise.
public struct StarStretch {
    public var shadow: (Float, Float, Float)
    public var midtone: (Float, Float, Float)

    public init(base: FITSImage, refPercentile: Float = 0.995, target: Float = 0.48) {
        var vals: [Float] = []
        vals.reserveCapacity(base.width * base.height / 16)
        var i = 0
        while i < base.rgba.count {
            vals.append(base.rgba[i] * 0.2126 + base.rgba[i + 1] * 0.7152 + base.rgba[i + 2] * 0.0722)
            i += 16
        }
        vals.sort()
        let s = max(0, vals[vals.count / 2])
        let ref = vals[min(vals.count - 1, Int(Float(vals.count) * refPercentile))]
        let x0 = (ref - s) / max(1 - s, 1e-4)
        let m = x0 * (1 - target) / max(x0 * (1 - 2 * target) + target, 1e-6)
        let clamped = min(max(m, 1e-4), 0.5)
        shadow = (s, s, s)
        midtone = (clamped, clamped, clamped)
    }
}

/// Blit params — field order MUST match `BlitUniforms` in the shader source.
struct BlitUniforms { var divider: Float; var compare: Float; var clipping: Float }

/// Per-channel auto base stretch (black point + MTF midtone) from image
/// statistics, mirroring Siril's autostretch: shadow = median − 2.8·σ (via MAD),
/// midtone so the background lands at a low target. Computed once per bundle; the
/// sliders ride on top ("Import → instant Auto").
public struct AutoStretch {
    public var shadow: (Float, Float, Float)
    public var midtone: (Float, Float, Float)
    /// Where the sky actually lands in display space after this stretch. It is
    /// *measured*, not assumed: the midtone is adaptive (see below), so on a
    /// high-dynamic-range target the sky deliberately lands darker than
    /// `targetBG`. Everything downstream anchors on this value.
    public var displaySky: Float = 0.12

    /// `targetBG` is where the sky lands after this base stretch. Siril's and
    /// PixInsight's 0.25 is a *screen* convention for inspecting linear data;
    /// on a finished image it is far too bright — pulling the sky that high
    /// compresses everything above it (a galaxy core at 29× sky arrives at
    /// 0.91 before a single slider moves, so it can only ever render white).
    /// Nebula lands the base stretch near a finished background and lets the
    /// GHS above shape the tones, which is what the published workflows do.
    /// The midtone that maps `x` to `y` under the MTF — the standard identity
    /// `m = MTF(y, x)` PixInsight's STFAutoStretch uses to hit a target level.
    static func midtoneMapping(_ x: Float, to y: Float) -> Float {
        x * (1 - y) / max(x * (1 - 2 * y) + y, 1e-9)
    }

    static func mtf(_ x: Float, _ m: Float) -> Float {
        let d = (2 * m - 1) * x - m
        return abs(d) < 1e-9 ? x : min(max(((m - 1) * x) / d, 0), 1)
    }

    /// - Parameter extended: the starless layer when available. The highlight
    ///   guard below must respond to the **subject's** brightness, not to a few
    ///   saturated field stars — on a galaxy field the stars sit far above the
    ///   galaxy, and measuring them would throttle the stretch of an image that
    ///   needs all of it. Star-free pixels answer the right question.
    public init(base: FITSImage, extended: FITSImage? = nil, targetBG: Float = 0.12,
                highlightCap: Float = 0.88, minSky: Float = 0.03) {
        func samples(_ image: FITSImage, channel: Int) -> [Float] {
            var vals: [Float] = []
            vals.reserveCapacity(image.width * image.height / 16)
            var i = channel
            while i < image.rgba.count {
                let v = image.rgba[i]
                if v > 1e-7 && v.isFinite { vals.append(v) }
                i += 16
            }
            if vals.isEmpty { vals = [0, 1e-4] }
            vals.sort()
            return vals
        }
        func parameters(channel: Int) -> (Float, Float, Float) {
            let vals = samples(base, channel: channel)
            let median = vals[vals.count / 2]
            var dev = vals.map { abs($0 - median) }; dev.sort()
            var mad = dev[dev.count / 2]
            if mad == 0 { mad = 0.001 }   // Siril's guard for flat frames
            let sigma = 1.4826 * mad
            // Clip guard: MAD saturates on gradient-dominated frames, and a
            // black point above the displayed layer's pedestal crushes the
            // whole channel (the "94% of red at zero" failure). Never clip
            // more than the darkest 0.5% of this channel's finite pixels.
            let p05 = vals[max(0, Int(Float(vals.count) * 0.005) - 1)]
            let s = min(max(0, median - 2.8 * sigma), p05)
            let norm = { (v: Float) in max(v - s, 0) / max(1 - s, 1e-4) }
            let x0 = norm(median)
            let highSource = extended.map { samples($0, channel: channel) } ?? vals
            let hi = norm(highSource[min(highSource.count - 1, Int(Float(highSource.count) * 0.999))])

            // Placing the sky at `targetBG` is the right call for an ordinary
            // frame, but it says nothing about the top end — and deep-sky
            // targets differ there by orders of magnitude (M 42's sky sits at
            // 574× below its bright nebula; M 8's at 12×). Applied blindly, the
            // same rule drives M 42's whole nebula body past white.
            //
            // So take the *gentlest* midtone that still satisfies both ends:
            // keep the bright end under `highlightCap`, but never darken the
            // sky below `minSky` chasing it. On an ordinary frame the highlight
            // constraint is slack and this reduces to the classic autostretch.
            let mBG = Self.midtoneMapping(x0, to: targetBG)
            let mHi = Self.midtoneMapping(hi, to: highlightCap)
            let mFloor = Self.midtoneMapping(x0, to: minSky)
            let m = min(max(mBG, mHi), max(mFloor, mBG))
            let clamped = min(max(m, 1e-4), 0.5)
            return (s, clamped, Self.mtf(x0, clamped))
        }
        let r = parameters(channel: 0), g = parameters(channel: 1), b = parameters(channel: 2)
        shadow = (r.0, g.0, b.0)
        midtone = (r.1, g.1, b.1)
        displaySky = (r.2 + g.2 + b.2) / 3
    }
}

public struct ImageRegion: Equatable, Sendable {
    public let x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Conservative subject-aware framing for compact deep-sky targets. It works on
/// a tiny averaged grid, so stars/noise contribute far less than extended signal.
/// The crop never goes below 58% of the sensor frame and remains reversible
/// because the cached FITS layers stay full-size.
public enum AutoCrop {
    public static func region(for image: FITSImage) -> ImageRegion {
        let full = ImageRegion(x: 0, y: 0, width: image.width, height: image.height)
        guard image.width >= 320, image.height >= 320 else { return full }
        let long = max(image.width, image.height)
        let gw = max(20, image.width * 64 / long), gh = max(20, image.height * 64 / long)
        var grid = [Float](repeating: 0, count: gw*gh)
        var counts = [Int](repeating: 0, count: gw*gh)
        for y in stride(from: 0, to: image.height, by: 2) {
            let gy = min(gh-1, y*gh/image.height)
            for x in stride(from: 0, to: image.width, by: 2) {
                let gx = min(gw-1, x*gw/image.width), p = (y*image.width+x)*4
                grid[gy*gw+gx] += image.rgba[p]*0.2126 + image.rgba[p+1]*0.7152 + image.rgba[p+2]*0.0722
                counts[gy*gw+gx] += 1
            }
        }
        for i in grid.indices { grid[i] /= Float(max(counts[i], 1)) }
        func blurred(_ src: [Float], radius: Int) -> [Float] {
            var out = src
            for y in 0..<gh { for x in 0..<gw {
                var sum: Float = 0; var n: Float = 0
                for dy in -radius...radius { for dx in -radius...radius {
                    let yy=min(max(y+dy,0),gh-1), xx=min(max(x+dx,0),gw-1)
                    sum += src[yy*gw+xx]; n += 1
                } }
                out[y*gw+x] = sum/n
            } }
            return out
        }
        grid = blurred(grid, radius: 2)
        let sorted = grid.sorted(), median = sorted[sorted.count/2]
        let deviations = grid.map { abs($0-median) }.sorted()
        let sigma = max(1.4826 * deviations[deviations.count/2], 1e-6)
        let xr = (gw*15/100)..<(gw*85/100), yr = (gh*15/100)..<(gh*85/100)
        var peak: Float = 0, bestScore: Float = -.greatestFiniteMagnitude
        var peakX = gw/2, peakY = gh/2
        for y in yr { for x in xr {
            let nx=(Float(x)+0.5)/Float(gw)-0.5, ny=(Float(y)+0.5)/Float(gh)-0.5
            // Seestar centres the selected target. This prior prevents a single
            // saturated field star from winning over extended central signal.
            let score=(grid[y*gw+x]-median)/(1 + 30*(nx*nx+ny*ny))
            if score > bestScore { bestScore=score; peak=grid[y*gw+x]; peakX=x; peakY=y }
        } }
        guard peak > median + 6*sigma else { return full }
        let threshold = median + max(3*sigma, (peak-median)*0.30)
        var minX=peakX, maxX=peakX, minY=peakY, maxY=peakY, selected=0
        // Flood only the connected extended signal around the primary peak;
        // unrelated field stars must not expand the crop back to the full frame.
        var seen = [Bool](repeating: false, count: gw*gh)
        var queue = [(peakX, peakY)], head = 0
        seen[peakY*gw+peakX] = true
        while head < queue.count {
            let (x,y)=queue[head]; head += 1
            guard grid[y*gw+x] >= threshold else { continue }
            minX=min(minX,x); maxX=max(maxX,x); minY=min(minY,y); maxY=max(maxY,y); selected += 1
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let xx=x+dx, yy=y+dy
                if xx>=0 && xx<gw && yy>=0 && yy<gh && !seen[yy*gw+xx] {
                    seen[yy*gw+xx]=true; queue.append((xx,yy))
                }
            } }
        }
        guard selected >= 4 else { return full }
        let signalScale = max(Float(maxX-minX+1)/Float(gw), Float(maxY-minY+1)/Float(gh))
        let scale = min(1, max(0.58, signalScale * 2.2))
        guard scale < 0.94 else { return full }
        let cw = max(1, Int(Float(image.width)*scale)), ch = max(1, Int(Float(image.height)*scale))
        let targetX = (Float(peakX)+0.5)/Float(gw)*Float(image.width)
        let targetY = (Float(peakY)+0.5)/Float(gh)*Float(image.height)
        let cx = targetX*0.8 + Float(image.width)*0.1
        let cy = targetY*0.8 + Float(image.height)*0.1
        let x = min(max(Int(cx)-cw/2, 0), image.width-cw)
        let y = min(max(Int(cy)-ch/2, 0), image.height-ch)
        return ImageRegion(x: x, y: y, width: cw, height: ch)
    }
}

/// The native Metal Stage-B engine. One instance compiles the pipelines; a
/// `LayerBundle` holds the four baked layers resident on the GPU. The SAME
/// `encodeChain` feeds both the headless PNG export and the live `MTKView`, so
/// preview == export by construction (design §5).
public final class ChainRenderer: @unchecked Sendable {
    public static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let processPipeline: MTLComputePipelineState
    let finishPipeline: MTLComputePipelineState
    let beforePipeline: MTLComputePipelineState
    let blitPipeline: MTLRenderPipelineState

    public static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm

    public enum Err: Error { case msg(String) }

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Err.msg("no Metal device") }
        self.device = device
        self.queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        self.processPipeline = try device.makeComputePipelineState(
            function: lib.makeFunction(name: "processNebula")!)
        self.finishPipeline = try device.makeComputePipelineState(
            function: lib.makeFunction(name: "finish")!)
        self.beforePipeline = try device.makeComputePipelineState(
            function: lib.makeFunction(name: "stretchBefore")!)
        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = lib.makeFunction(name: "blitVertex")
        rpd.fragmentFunction = lib.makeFunction(name: "blitFragment")
        rpd.colorAttachments[0].pixelFormat = Self.drawablePixelFormat
        self.blitPipeline = try device.makeRenderPipelineState(descriptor: rpd)
    }

    /// Four baked layers uploaded to `MTLTexture`s and kept resident, plus the
    /// intermediate/output textures and the cached auto stretch.
    public final class LayerBundle: @unchecked Sendable {
        let master, corrected, denoised, starless, stars: MTLTexture
        let nebTex, outTex, beforeTex: MTLTexture
        public let width: Int, height: Int
        let auto: AutoStretch
        /// Master-derived stretch for the truthful "before" view only.
        let autoBefore: AutoStretch
        let star: StarStretch
        init(master: MTLTexture, corrected: MTLTexture, denoised: MTLTexture, starless: MTLTexture,
             stars: MTLTexture, nebTex: MTLTexture, outTex: MTLTexture,
             beforeTex: MTLTexture, width: Int, height: Int,
             auto: AutoStretch, autoBefore: AutoStretch, star: StarStretch) {
            self.master = master; self.corrected = corrected; self.denoised = denoised
            self.starless = starless; self.stars = stars
            self.nebTex = nebTex; self.outTex = outTex; self.beforeTex = beforeTex
            self.width = width; self.height = height; self.auto = auto
            self.autoBefore = autoBefore; self.star = star
        }
    }

    private func upload(_ img: FITSImage) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: img.width, height: img.height, mipmapped: false)
        d.usage = [.shaderRead]
        let t = device.makeTexture(descriptor: d)!
        img.rgba.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height),
                      mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: img.width * 16)
        }
        return t
    }

    private func scratch(_ w: Int, _ h: Int, mipmapped: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: d)!
    }

    public func makeBundle(master originalMaster: FITSImage, corrected originalCorrected: FITSImage? = nil,
                           denoised originalDenoised: FITSImage,
                           starless originalStarless: FITSImage, stars originalStars: FITSImage,
                           profile: Profile? = nil) -> LayerBundle {
        let correctedInput = originalCorrected ?? originalMaster
        // No auto-crop: always present the full stacked frame (the Seestar keeps
        // the whole field, and cropping into the subject threw away the surrounding
        // starfield). The cached FITS layers are full-size regardless.
        _ = profile
        let region = ImageRegion(x: 0, y: 0, width: originalMaster.width, height: originalMaster.height)
        let master = originalMaster.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
        let corrected = correctedInput.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
        let denoised = originalDenoised.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
        let starless = originalStarless.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
        let stars = originalStars.cropped(x: region.x, y: region.y, width: region.width, height: region.height)
        let (w, h) = (master.width, master.height)
        // The chain renders ~90% the corrected layer at the default look, so the
        // auto stretch must come from the SAME layer — master-derived statistics
        // put the black point above the corrected pedestal (PCC rescales
        // channels, BGE re-pedestals them) and crushed whole channels to zero.
        // The raw master keeps its own stretch for the truthful "before" view.
        let auto = AutoStretch(base: corrected, extended: starless)
        let autoBefore = AutoStretch(base: master)
        let star = StarStretch(base: stars)
        let masterTex = upload(master)
        // outTex/beforeTex are mipmapped so the fit-to-window preview downsamples
        // faithfully (faint stars survive); the compute writes mip 0.
        let bundle = LayerBundle(
            master: masterTex, corrected: upload(corrected),
            denoised: upload(denoised),
            starless: upload(starless), stars: upload(stars),
            nebTex: scratch(w, h, mipmapped: true), outTex: scratch(w, h, mipmapped: true),
            beforeTex: scratch(w, h, mipmapped: true),
            width: w, height: h, auto: auto, autoBefore: autoBefore, star: star)
        renderBefore(bundle)
        return bundle
    }

    /// Render the static "before" (raw stack, auto-stretched) once.
    private func renderBefore(_ b: LayerBundle) {
        var u = EngineParamsGPU(LookState.neutral.engineParams, auto: b.autoBefore, star: b.star)
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (b.width + 15) / 16, height: (b.height + 15) / 16, depth: 1)
        let cmd = queue.makeCommandBuffer()!
        let e = cmd.makeComputeCommandEncoder()!
        e.setComputePipelineState(beforePipeline)
        e.setTextures([b.master, b.beforeTex], range: 0..<2)
        e.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e.endEncoding()
        let blit = cmd.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: b.beforeTex)
        blit.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
    }

    /// Encode the two compute passes into `cmd`, leaving the result in `outTex`.
    private func encodeChain(_ cmd: MTLCommandBuffer, _ params: EngineParams,
                             _ b: LayerBundle) {
        var u = EngineParamsGPU(params, auto: b.auto, star: b.star)
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (b.width + 15) / 16, height: (b.height + 15) / 16, depth: 1)

        let e1 = cmd.makeComputeCommandEncoder()!
        e1.setComputePipelineState(processPipeline)
        e1.setTextures([b.master, b.corrected, b.denoised, b.starless, b.nebTex], range: 0..<5)
        e1.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e1.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e1.endEncoding()

        // Build the nebula's mip chain so `finish` can read coarse (tens-of-pixel)
        // blur levels for the large-scale structure boost without a huge inline
        // gather. Apple-Silicon filters rgba32Float, so linear mip sampling is exact.
        let mipEnc = cmd.makeBlitCommandEncoder()!
        mipEnc.generateMipmaps(for: b.nebTex)
        mipEnc.endEncoding()

        let e2 = cmd.makeComputeCommandEncoder()!
        e2.setComputePipelineState(finishPipeline)
        e2.setTextures([b.nebTex, b.stars, b.outTex], range: 0..<3)
        e2.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e2.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e2.endEncoding()
    }

    /// Live path: render the chain result into the view's drawable every frame.
    /// Slider input only mutates `params`; the loop always draws current params.
    @MainActor public func draw(bundle: LayerBundle, params: EngineParams,
                     compare: Bool = false, divider: Float = 0.5,
                     clipping: Bool = false, in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle)
        // Rebuild mips so the trilinear blit downsamples faithfully to the window.
        if bundle.outTex.mipmapLevelCount > 1 {
            let blit = cmd.makeBlitCommandEncoder()!
            blit.generateMipmaps(for: bundle.outTex)
            blit.endEncoding()
        }
        var bu = BlitUniforms(divider: divider, compare: compare ? 1 : 0,
                              clipping: clipping ? 1 : 0)
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(blitPipeline)
        enc.setFragmentTexture(bundle.outTex, index: 0)
        enc.setFragmentTexture(bundle.beforeTex, index: 1)
        enc.setFragmentBytes(&bu, length: MemoryLayout<BlitUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Render the finished look at reduced size for a library thumbnail. Reuses
    /// the exact chain (so the card matches the editor), then downsamples on the
    /// CPU to an 8-bit sRGB `CGImage` — plenty for a grid cell.
    public func renderThumbnail(bundle: LayerBundle, params: EngineParams,
                                maxDimension: Int) throws -> CGImage {
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle)
        cmd.commit(); cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }
        return try downscaled(bundle.outTex, maxDimension: maxDimension)
    }

    /// 8-bit sRGB CGImage from a float image — the display path for AI results
    /// shown live in the app (the PNG export path stays 16-bit).
    public static func displayImage(_ image: FITSImage) throws -> CGImage {
        let (w, h) = (image.width, image.height)
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                px[i*4+c] = UInt8((max(0, min(1, image.rgba[i*4+c])) * 255).rounded())
            }
        }
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let cg = px.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: outputColorSpace, bitmapInfo: info)?.makeImage()
        }) else { throw Err.msg("display CGContext failed") }
        return cg
    }

    /// Read an RGBA32F texture back and produce a downscaled 8-bit sRGB CGImage.
    private func downscaled(_ tex: MTLTexture, maxDimension: Int) throws -> CGImage {
        let (w, h) = (tex.width, tex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                px[i*4+c] = UInt8((max(0, min(1, floats[i*4+c])) * 255).rounded())
            }
        }
        let cs = Self.outputColorSpace
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let full = px.withUnsafeMutableBytes({ raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: cs, bitmapInfo: info)?.makeImage()
        }) else { throw Err.msg("thumb CGContext failed") }

        let scale = min(1, Double(maxDimension) / Double(max(w, h)))
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: info) else {
            throw Err.msg("thumb scale ctx failed")
        }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let out = ctx.makeImage() else { throw Err.msg("thumb scale failed") }
        return out
    }

    /// Headless export: run the chain and write a PNG (the CLI path).
    public func renderPNG(bundle: LayerBundle, params: EngineParams, scale: Int = 1, to url: URL) throws {
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle)
        cmd.commit(); cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }
        try writePNG(bundle.outTex, scale: min(max(scale, 1), 2), to: url)
    }

    /// Render the display-referred floating-point result for an additional
    /// export-only processor such as AI super-resolution.
    public func renderImage(bundle: LayerBundle, params: EngineParams) throws -> FITSImage {
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle)
        cmd.commit(); cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }
        let (w, h) = (bundle.outTex.width, bundle.outTex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            bundle.outTex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                                   from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return FITSImage(width: w, height: h, channels: 3, rgba: floats)
    }

    public func writePNG(_ image: FITSImage, to url: URL) throws {
        try writePNG(width: image.width, height: image.height, floats: image.rgba,
                     scale: 1, to: url)
    }

    /// Write the float result as a 16-bit PNG (design §5: high-precision export,
    /// no 8-bit banding). The RGBA32F values quantise to 16-bit cleanly, so no
    /// dithering is needed — 16 bits has no visible banding in deep-sky gradients.
    private func writePNG(_ tex: MTLTexture, scale: Int, to url: URL) throws {
        let (w, h) = (tex.width, tex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        try writePNG(width: w, height: h, floats: floats, scale: scale, to: url)
    }

    private func writePNG(width w: Int, height h: Int, floats: [Float],
                          scale: Int, to url: URL) throws {
        var px = [UInt16](repeating: 0xFFFF, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                px[i*4+c] = UInt16((max(0, min(1, floats[i*4+c])) * 65535).rounded())
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
                 | CGBitmapInfo.byteOrder16Little.rawValue
        let ctx = px.withUnsafeMutableBytes { raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 16,
                      bytesPerRow: w * 8, space: cs, bitmapInfo: info)
        }
        guard let ctx, let nativeImage = ctx.makeImage() else { throw Err.msg("CGContext failed") }
        let image: CGImage
        if scale == 1 {
            image = nativeImage
        } else {
            let sw = w * scale, sh = h * scale
            guard let scaled = CGContext(data: nil, width: sw, height: sh,
                                         bitsPerComponent: 16, bytesPerRow: 0,
                                         space: cs, bitmapInfo: info) else {
                throw Err.msg("scaled export CGContext failed")
            }
            scaled.interpolationQuality = .high
            scaled.draw(nativeImage, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let made = scaled.makeImage() else { throw Err.msg("scaled export failed") }
            image = made
        }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Err.msg("cannot create PNG at \(url.path)")
        }
        let properties = [kCGImagePropertyProfileName: "sRGB IEC61966-2.1"] as CFDictionary
        CGImageDestinationAddImage(dest, image, properties)
        guard CGImageDestinationFinalize(dest) else { throw Err.msg("PNG write failed") }
    }
}

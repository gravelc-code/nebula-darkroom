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
    /// GHS shape constants — injected from `GHS` so the shader and its CPU
    /// mirror share ONE source (they used to be literals in the shader).
    var ghsB: Float
    var ghsHP: Float
    /// Cosmetic finishing strength (`EngineParams.finishing`).
    var finishing: Float

    /// - Parameter master: the auto stretch measured on the MASTER end of the
    ///   Background blend. Below Background 60 the shader renders
    ///   `mix(master, corrected, correctionBlend)`, so the stretch is blended
    ///   the same way: each end is then measured on the layer actually
    ///   rendered there (the HANDOFF invariant), and at full correction
    ///   (Background ≥ 60) the values are exactly `auto`'s. `nil` = no separate
    ///   corrected layer, so `auto` already describes the master.
    public init(_ p: EngineParams, auto a: AutoStretch, master m: AutoStretch? = nil,
                star s: StarStretch) {
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
        if let m {
            // x·(1−t) + y·t is exactly y at t = 1, so Background ≥ 60 renders
            // bit-for-bit as before.
            let t = min(max(p.correctionBlend, 0), 1)
            func blend(_ x: Float, _ y: Float) -> Float { x * (1 - t) + y * t }
            autoSky = blend(m.displaySky, a.displaySky)
            shadow0 = blend(m.shadow.0, a.shadow.0)
            shadow1 = blend(m.shadow.1, a.shadow.1)
            shadow2 = blend(m.shadow.2, a.shadow.2)
            midtone0 = blend(m.midtone.0, a.midtone.0)
            midtone1 = blend(m.midtone.1, a.midtone.1)
            midtone2 = blend(m.midtone.2, a.midtone.2)
        }
        starShadow0 = s.shadow.0; starShadow1 = s.shadow.1; starShadow2 = s.shadow.2
        starMidtone0 = s.midtone.0; starMidtone1 = s.midtone.1; starMidtone2 = s.midtone.2
        ghsB = GHS.b; ghsHP = GHS.highlightProtect
        finishing = p.finishing
    }
}

/// Dedicated stretch for the sparse star layer. The star layer is mostly zero
/// (background) with compact star flux, so an image-median autostretch would
/// over-lift noise. Instead: black point at the median (~0), and a midtone that
/// maps a high percentile of the star flux up to a visible level — so faint
/// field stars survive separation + denoise.
public struct StarStretch {
    public var shadow: (Float, Float, Float)
    public var midtone: (Float, Float, Float)

    public init(base: FITSImage, refPercentile: Float = 0.995, target: Float = 0.48) {
        var all: [Float] = [], lit: [Float] = []
        all.reserveCapacity(base.width * base.height / 16)
        var i = 0
        while i + 2 < base.rgba.count {
            let l = base.rgba[i] * 0.2126 + base.rgba[i + 1] * 0.7152 + base.rgba[i + 2] * 0.0722
            if l.isFinite {
                all.append(l)
                if l > 1e-7 { lit.append(l) }
            }
            i += 16
        }
        all.sort(); lit.sort()
        // The black point stays at the median of the whole layer (~0).
        let s = all.isEmpty ? 0 : max(0, all[all.count / 2])
        // The reference percentile is taken over the pixels that actually
        // carry star flux. Over the whole layer it only lands on star flux
        // while stars cover more than 0.5% of the frame: on a sparser layer
        // (a galaxy field, the feathered classical mask) it fell in the zero
        // mass, ref = s = 0, the midtone hit its 1e-4 floor and Star Size's
        // bloom lit every faint feathered mask edge.
        let ref = lit.isEmpty ? s : lit[min(lit.count - 1, Int(Float(lit.count) * refPercentile))]
        let m: Float
        if ref > s {
            let x0 = (ref - s) / max(1 - s, 1e-4)
            m = x0 * (1 - target) / max(x0 * (1 - 2 * target) + target, 1e-6)
        } else {
            // No star flux above the black point: nothing to measure, so no
            // lift at all — MTF midtone 0.5 is the identity.
            m = 0.5
        }
        let clamped = min(max(m, 1e-4), 0.5)
        shadow = (s, s, s)
        midtone = (clamped, clamped, clamped)
    }
}

/// Blit params — field order MUST match `BlitUniforms` in the shader source.
struct BlitUniforms {
    var divider: Float; var compare: Float; var clipping: Float
    /// Dither amplitude in display units (one LSB of the drawable); 0 = off.
    var ditherLSB: Float
}

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

    /// `targetBG` is where the sky lands after this base stretch, chosen so the
    /// FINISHED sky obeys the published conventions. Two sources agree on the
    /// finished level: Lodriguss's RGB 35-35-35 guideline (≈ 0.08–0.14) and the
    /// duo-band survey's "neutral near-black grey, ~5–12% luminance". The
    /// default look's Background (60) only fades in the gradient correction —
    /// its sky trim starts above 60 — so the base IS the finished sky, and
    /// 0.12 lands it inside both ranges. (It was 0.15, derived for an older
    /// default of Background 72, whose ~21% trim brought 0.15 down to 0.12;
    /// when the default moved to 60 the sky was left at 0.15.) (Siril's
    /// and PixInsight's 0.25 is a *screen* convention for inspecting linear
    /// data, far too bright for a finished image: a core at 29× sky would
    /// arrive at 0.91 before a single slider moved.)
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
    /// - Parameter highlightCap: where the subject's bright end lands. This is
    ///   also the **colour headroom** control: a colour-preserving stretch
    ///   scales RGB by one luminance factor, so a saturated pixel hits the
    ///   gamut boundary well below white. Park the bright end too high and
    ///   every strong colour ends up pinned there — the image flattens into a
    ///   slab and the Saturation slider stops doing anything, because chroma is
    ///   dictated by the boundary rather than by the setting.
    public init(base: FITSImage, extended: FITSImage? = nil, targetBG: Float = 0.12,
                highlightCap: Float = 0.72, minSky: Float = 0.065) {
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
        // --- 1. Per-channel black point: this is what neutralises the sky. ---
        //
        // Each channel is clipped the SAME distance below its own median, not
        // 2.8x its own sigma. The midtone above is linked, so sky neutrality
        // now rests entirely here: a per-channel depth leaves the noisier
        // channel with more residual above its black point and the background
        // renders with that channel's cast (M 8's sky came out distinctly red).
        // A common depth makes every channel's normalised median equal, which
        // is the definition of a neutral sky.
        func statsFor(channel: Int) -> (median: Float, sigma: Float, p05: Float) {
            let vals = samples(base, channel: channel)
            let median = vals[vals.count / 2]
            var dev = vals.map { abs($0 - median) }; dev.sort()
            var mad = dev[dev.count / 2]
            if mad == 0 { mad = 0.001 }   // Siril's guard for flat frames
            return (median, 1.4826 * mad,
                    vals[max(0, Int(Float(vals.count) * 0.005) - 1)])
        }
        let st = (statsFor(channel: 0), statsFor(channel: 1), statsFor(channel: 2))
        let depth = 2.8 * (st.0.sigma + st.1.sigma + st.2.sigma) / 3
        // Clip guard: MAD saturates on gradient-dominated frames, and a black
        // point above the displayed layer's pedestal crushes the whole channel
        // (the "94% of red at zero" failure). Never clip more than the darkest
        // 0.5% of a channel's finite pixels.
        func shadowFrom(_ s: (median: Float, sigma: Float, p05: Float)) -> Float {
            min(max(0, s.median - depth), s.p05)
        }
        let sh = (shadowFrom(st.0), shadowFrom(st.1), shadowFrom(st.2))
        shadow = sh

        // --- 2. ONE midtone, measured on luminance and applied colour-
        // preserving (the shader scales RGB by the same scalar).
        //
        // Stretching each channel to its own target is what an unlinked
        // autostretch does, and on emission data it does not merely shift the
        // balance — it destroys the colour. The MTF saturates, so the channel
        // carrying the most signal is compressed hardest: an M 8 pixel at
        // R/G 1.83 came out at 0.91, i.e. a red nebula rendered faintly blue.
        // Every reference tool stretches a luminance and scales RGB by the
        // same factor (PixInsight ArcsinhStretch, GHS "human/even" colour
        // models) for exactly this reason.
        func normalised(_ v: Float, _ s: Float) -> Float { max(v - s, 0) / max(1 - s, 1e-4) }
        func luminanceSamples(_ image: FITSImage) -> [Float] {
            var vals: [Float] = []
            vals.reserveCapacity(image.width * image.height / 16)
            var i = 0
            while i + 2 < image.rgba.count {
                let l = normalised(image.rgba[i], sh.0) * 0.2126
                      + normalised(image.rgba[i + 1], sh.1) * 0.7152
                      + normalised(image.rgba[i + 2], sh.2) * 0.0722
                if l.isFinite { vals.append(l) }
                i += 16
            }
            if vals.isEmpty { vals = [0, 1e-4] }
            vals.sort()
            return vals
        }
        let lum = luminanceSamples(base)
        let x0 = lum[lum.count / 2]
        let highSource = extended.map { luminanceSamples($0) } ?? lum
        let hi = highSource[min(highSource.count - 1, Int(Float(highSource.count) * 0.999))]

        // Placing the sky at `targetBG` is the right call for an ordinary
        // frame, but it says nothing about the top end — and deep-sky targets
        // differ there by orders of magnitude (M 42's sky sits 574× below its
        // bright nebula; M 8's only 12×). Applied blindly, the same rule drives
        // M 42's whole nebula body past white.
        //
        // So take the *gentlest* midtone that still satisfies both ends: keep
        // the bright end under `highlightCap`, but never darken the sky below
        // `minSky` chasing it. On an ordinary frame the highlight constraint is
        // slack and this reduces to the classic autostretch.
        //
        // `minSky` is 0.065 so that a floor-limited frame's finished sky at
        // the default look (Background 60, no sky trim) lands inside the
        // documented 0.05-0.09 convention; raising Background above 60 is the
        // user deliberately darkening it further. It was 0.03 — which contradicted that convention and
        // held whole high-dynamic-range frames dark (the independent 244-sub
        // M 42 landed its sky at 0.028). Squeezing the sky is not this stage's
        // job: highlight protection belongs to the GHS highlight-protect
        // point (0.20), whose entire purpose is compressing the bright end.
        let mBG = Self.midtoneMapping(x0, to: targetBG)
        let mHi = Self.midtoneMapping(hi, to: highlightCap)
        let mFloor = Self.midtoneMapping(x0, to: minSky)
        let m = min(max(min(max(mBG, mHi), max(mFloor, mBG)), 1e-4), 0.5)
        midtone = (m, m, m)
        displaySky = Self.mtf(x0, m)
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
    /// One quantisation step of `drawablePixelFormat` (8-bit) — the preview's
    /// dither amplitude. The 16-bit export is never dithered.
    static let previewDitherLSB: Float = 1.0 / 255.0

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

    /// Where one evaluation of the chain writes: the developed image, its
    /// star-free twin (r = luminance, g = the nebula's share of the light;
    /// mipmapped — Detail's coarse bands sample it), and the finished output.
    struct ChainTargets {
        let neb: MTLTexture
        let starfree: MTLTexture
        let out: MTLTexture
    }

    /// Four baked layers uploaded to `MTLTexture`s and kept resident, plus the
    /// live view's intermediate/output textures and the cached auto stretch.
    public final class LayerBundle: @unchecked Sendable {
        let master, corrected, denoised, starless, stars: MTLTexture
        /// Owned by the live view ONLY. Off-screen renders (export, thumbnail,
        /// AI input) allocate their own targets: the 120 Hz loop rewrites these
        /// every frame, so an export reading them back could contain a frame
        /// drawn for a different look.
        let live: ChainTargets
        let beforeTex: MTLTexture
        public let width: Int, height: Int
        let auto: AutoStretch
        /// Measured on the master end of the Background blend (nil when there
        /// is no separate corrected layer). See `EngineParamsGPU`.
        let autoMaster: AutoStretch?
        /// Master-derived stretch for the truthful "before" view only.
        let autoBefore: AutoStretch
        let star: StarStretch
        init(master: MTLTexture, corrected: MTLTexture, denoised: MTLTexture, starless: MTLTexture,
             stars: MTLTexture, live: ChainTargets,
             beforeTex: MTLTexture, width: Int, height: Int,
             auto: AutoStretch, autoMaster: AutoStretch?, autoBefore: AutoStretch,
             star: StarStretch) {
            self.master = master; self.corrected = corrected; self.denoised = denoised
            self.starless = starless; self.stars = stars
            self.live = live; self.beforeTex = beforeTex
            self.width = width; self.height = height; self.auto = auto
            self.autoMaster = autoMaster; self.autoBefore = autoBefore; self.star = star
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

    private func scratch(_ w: Int, _ h: Int, mipmapped: Bool = false,
                         format: MTLPixelFormat = .rgba32Float) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: w, height: h, mipmapped: mipmapped)
        d.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: d)!
    }

    /// A fresh set of chain targets. The live view's output is mipmapped so
    /// the fit-to-window preview downsamples faithfully; an off-screen
    /// render reads mip 0 only.
    func makeTargets(_ w: Int, _ h: Int, mipmappedOut: Bool) -> ChainTargets {
        ChainTargets(neb: scratch(w, h),
                     starfree: scratch(w, h, mipmapped: true, format: .rg32Float),
                     out: scratch(w, h, mipmapped: mipmappedOut))
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
        // Below Background 60 the chain renders toward the raw master, so the
        // master end needs its own stretch, measured exactly as `auto` is: on
        // the layer rendered there (the master) with the highlight guard on
        // its star-free version (master + the baked starless delta — the same
        // expression the shader evaluates at correctionBlend 0).
        let autoMaster: AutoStretch? = originalCorrected == nil ? nil
            : Self.starfreeMaster(master: master, corrected: corrected, starless: starless)
                .map { AutoStretch(base: master, extended: $0) }
        let autoBefore = AutoStretch(base: master)
        let star = StarStretch(base: stars)
        let masterTex = upload(master)
        // beforeTex (and the live output) are mipmapped so the fit-to-window
        // preview downsamples faithfully (faint stars survive); the compute
        // writes mip 0.
        let bundle = LayerBundle(
            master: masterTex, corrected: upload(corrected),
            denoised: upload(denoised),
            starless: upload(starless), stars: upload(stars),
            live: makeTargets(w, h, mipmappedOut: true),
            beforeTex: scratch(w, h, mipmapped: true),
            width: w, height: h, auto: auto, autoMaster: autoMaster,
            autoBefore: autoBefore, star: star)
        renderBefore(bundle)
        return bundle
    }

    /// `max(master + (starless − corrected), 0)` — the starless layer carried
    /// onto the master, as `processNebula` builds it at correctionBlend 0.
    /// nil if the layers disagree in size (nothing sensible to measure).
    static func starfreeMaster(master: FITSImage, corrected: FITSImage,
                               starless: FITSImage) -> FITSImage? {
        guard master.rgba.count == corrected.rgba.count,
              master.rgba.count == starless.rgba.count else { return nil }
        var out = master.rgba
        var i = 0
        while i + 3 < out.count {
            for c in 0..<3 {
                out[i + c] = max(master.rgba[i + c] + (starless.rgba[i + c] - corrected.rgba[i + c]), 0)
            }
            i += 4
        }
        return FITSImage(width: master.width, height: master.height,
                         channels: master.channels, rgba: out)
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

    /// Encode the two compute passes into `cmd`, leaving the result in `t.out`.
    /// The ONE chain behind the live view and every export (preview == export).
    func encodeChain(_ cmd: MTLCommandBuffer, _ params: EngineParams,
                     _ b: LayerBundle, into t: ChainTargets) {
        var u = EngineParamsGPU(params, auto: b.auto, master: b.autoMaster, star: b.star)
        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (b.width + 15) / 16, height: (b.height + 15) / 16, depth: 1)

        let e1 = cmd.makeComputeCommandEncoder()!
        e1.setComputePipelineState(processPipeline)
        e1.setTextures([b.master, b.corrected, b.denoised, b.starless, t.neb, t.starfree],
                       range: 0..<6)
        e1.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e1.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e1.endEncoding()

        // Build the star-free twin's mip chain so `finish` can read coarse
        // (tens-of-pixel) blur levels for the large-scale structure boost
        // without a huge inline gather. Apple-Silicon filters 32-bit float, so
        // linear mip sampling is exact.
        let mipEnc = cmd.makeBlitCommandEncoder()!
        mipEnc.generateMipmaps(for: t.starfree)
        mipEnc.endEncoding()

        let e2 = cmd.makeComputeCommandEncoder()!
        e2.setComputePipelineState(finishPipeline)
        e2.setTextures([t.neb, b.stars, t.out, t.starfree], range: 0..<4)
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
        encodePreview(cmd, bundle: bundle, params: params, compare: compare,
                      divider: divider, clipping: clipping, pass: rpd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// The live frame: the chain into the bundle's live targets, then the
    /// display blit (the only place the preview differs from the export: it
    /// is resampled to the window and dithered to the 8-bit drawable).
    func encodePreview(_ cmd: MTLCommandBuffer, bundle: LayerBundle, params: EngineParams,
                       compare: Bool, divider: Float, clipping: Bool,
                       pass rpd: MTLRenderPassDescriptor) {
        encodeChain(cmd, params, bundle, into: bundle.live)
        // Rebuild mips so the trilinear blit downsamples faithfully to the window.
        if bundle.live.out.mipmapLevelCount > 1 {
            let blit = cmd.makeBlitCommandEncoder()!
            blit.generateMipmaps(for: bundle.live.out)
            blit.endEncoding()
        }
        encodeDisplayBlit(cmd, source: bundle.live.out, before: bundle.beforeTex,
                          compare: compare, divider: divider, clipping: clipping,
                          ditherLSB: Self.previewDitherLSB, pass: rpd)
    }

    func encodeDisplayBlit(_ cmd: MTLCommandBuffer, source: MTLTexture, before: MTLTexture,
                           compare: Bool, divider: Float, clipping: Bool, ditherLSB: Float,
                           pass rpd: MTLRenderPassDescriptor) {
        var bu = BlitUniforms(divider: divider, compare: compare ? 1 : 0,
                              clipping: clipping ? 1 : 0, ditherLSB: ditherLSB)
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(blitPipeline)
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentTexture(before, index: 1)
        enc.setFragmentBytes(&bu, length: MemoryLayout<BlitUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// Run the chain into targets of its own and wait. Every off-screen render
    /// goes through here, never through the live view's textures — the 120 Hz
    /// loop would otherwise overwrite the result between completion and
    /// read-back, mixing in a frame from a different look.
    private func renderOffscreen(bundle: LayerBundle, params: EngineParams) throws -> MTLTexture {
        let targets = makeTargets(bundle.width, bundle.height, mipmappedOut: false)
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle, into: targets)
        cmd.commit(); cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }
        return targets.out
    }

    /// Render the finished look at reduced size for a library thumbnail. Reuses
    /// the exact chain (so the card matches the editor), then downsamples on the
    /// CPU to an 8-bit sRGB `CGImage` — plenty for a grid cell.
    public func renderThumbnail(bundle: LayerBundle, params: EngineParams,
                                maxDimension: Int) throws -> CGImage {
        try downscaled(try renderOffscreen(bundle: bundle, params: params),
                       maxDimension: maxDimension)
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
        let out = try renderOffscreen(bundle: bundle, params: params)
        try writePNG(out, scale: min(max(scale, 1), 2), to: url)
    }

    /// Render the display-referred floating-point result for an additional
    /// export-only processor such as AI super-resolution.
    public func renderImage(bundle: LayerBundle, params: EngineParams) throws -> FITSImage {
        let out = try renderOffscreen(bundle: bundle, params: params)
        return FITSImage(width: out.width, height: out.height, channels: 3, rgba: Self.readBack(out))
    }

    /// Mip 0 of an RGBA32F texture as interleaved floats.
    static func readBack(_ tex: MTLTexture) -> [Float] {
        let (w, h) = (tex.width, tex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return floats
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

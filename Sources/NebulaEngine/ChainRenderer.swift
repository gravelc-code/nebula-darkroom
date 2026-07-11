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
    var blackPoint: Float
    var glowD: Float
    var contrastSP: Float
    var detailStrength: Float
    var saturation: Float
    var starWeight: Float
    var starD: Float
    var shadow0: Float; var shadow1: Float; var shadow2: Float
    var midtone0: Float; var midtone1: Float; var midtone2: Float
    var starShadow0: Float; var starShadow1: Float; var starShadow2: Float
    var starMidtone0: Float; var starMidtone1: Float; var starMidtone2: Float

    public init(_ p: EngineParams, auto a: AutoStretch, star s: StarStretch) {
        denoiseBlend = p.denoiseBlend; blackPoint = p.blackPoint
        glowD = p.glowD; contrastSP = p.contrastSP
        detailStrength = p.detailStrength; saturation = p.saturation
        starWeight = p.starWeight; starD = p.starD
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

    public init(base: FITSImage, refPercentile: Float = 0.995, target: Float = 0.55) {
        func channel(_ c: Int) -> (Float, Float) {
            var vals: [Float] = []
            vals.reserveCapacity(base.width * base.height / 16)
            var i = c
            let stride = 4 * 4
            while i < base.rgba.count { vals.append(base.rgba[i]); i += stride }
            vals.sort()
            let shadow = max(0, vals[vals.count / 2])                 // background ~0
            let ref = vals[min(vals.count - 1, Int(Float(vals.count) * refPercentile))]
            let x0 = (ref - shadow) / max(1 - shadow, 1e-4)
            let t = target
            let m = x0 * (1 - t) / max(x0 * (1 - 2 * t) + t, 1e-6)
            return (shadow, min(max(m, 1e-4), 0.5))
        }
        let (s0, m0) = channel(0)
        let (s1, m1) = channel(1)
        let (s2, m2) = channel(2)
        shadow = (s0, s1, s2)
        midtone = (m0, m1, m2)
    }
}

/// Blit params — field order MUST match `BlitUniforms` in the shader source.
struct BlitUniforms { var divider: Float; var compare: Float }

/// Per-channel auto base stretch (black point + MTF midtone) from image
/// statistics, mirroring Siril's autostretch: shadow = median − 2.8·σ (via MAD),
/// midtone so the background lands at a low target. Computed once per bundle; the
/// sliders ride on top ("Import → instant Auto").
public struct AutoStretch {
    public var shadow: (Float, Float, Float)
    public var midtone: (Float, Float, Float)

    public init(base: FITSImage, targetBG: Float = 0.12) {
        func channel(_ c: Int) -> (Float, Float) {
            var vals: [Float] = []
            vals.reserveCapacity(base.width * base.height / 16)
            var i = c
            let stride = 4 * 4                 // every 4th pixel, ×4 floats/px
            while i < base.rgba.count { vals.append(base.rgba[i]); i += stride }
            vals.sort()
            let median = vals[vals.count / 2]
            var dev = vals.map { abs($0 - median) }
            dev.sort()
            let sigma = 1.4826 * dev[dev.count / 2]
            let shadow = max(0, median - 2.8 * sigma)
            let x0 = (median - shadow) / max(1 - shadow, 1e-4)
            let t = targetBG
            let m = x0 * (1 - t) / max(x0 * (1 - 2 * t) + t, 1e-6)
            return (shadow, min(max(m, 1e-4), 0.5))
        }
        let (s0, m0) = channel(0)
        let (s1, m1) = channel(1)
        let (s2, m2) = channel(2)
        shadow = (s0, s1, s2)
        midtone = (m0, m1, m2)
    }
}

/// The native Metal Stage-B engine. One instance compiles the pipelines; a
/// `LayerBundle` holds the four baked layers resident on the GPU. The SAME
/// `encodeChain` feeds both the headless PNG export and the live `MTKView`, so
/// preview == export by construction (design §5).
public final class ChainRenderer {
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
    public final class LayerBundle {
        let master, denoised, starless, stars: MTLTexture
        let nebTex, outTex, beforeTex: MTLTexture
        public let width: Int, height: Int
        let auto: AutoStretch
        let star: StarStretch
        init(master: MTLTexture, denoised: MTLTexture, starless: MTLTexture,
             stars: MTLTexture, nebTex: MTLTexture, outTex: MTLTexture,
             beforeTex: MTLTexture, width: Int, height: Int,
             auto: AutoStretch, star: StarStretch) {
            self.master = master; self.denoised = denoised
            self.starless = starless; self.stars = stars
            self.nebTex = nebTex; self.outTex = outTex; self.beforeTex = beforeTex
            self.width = width; self.height = height; self.auto = auto; self.star = star
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

    public func makeBundle(master: FITSImage, denoised: FITSImage,
                           starless: FITSImage, stars: FITSImage) -> LayerBundle {
        let (w, h) = (master.width, master.height)
        let auto = AutoStretch(base: starless), star = StarStretch(base: stars)
        let masterTex = upload(master)
        // outTex/beforeTex are mipmapped so the fit-to-window preview downsamples
        // faithfully (faint stars survive); the compute writes mip 0.
        let bundle = LayerBundle(
            master: masterTex, denoised: upload(denoised),
            starless: upload(starless), stars: upload(stars),
            nebTex: scratch(w, h), outTex: scratch(w, h, mipmapped: true),
            beforeTex: scratch(w, h, mipmapped: true),
            width: w, height: h, auto: auto, star: star)
        renderBefore(bundle)
        return bundle
    }

    /// Render the static "before" (raw stack, auto-stretched) once.
    private func renderBefore(_ b: LayerBundle) {
        var u = EngineParamsGPU(Preset.auto.look.engineParams, auto: b.auto, star: b.star)
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
        e1.setTextures([b.master, b.denoised, b.starless, b.nebTex], range: 0..<4)
        e1.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e1.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e1.endEncoding()

        let e2 = cmd.makeComputeCommandEncoder()!
        e2.setComputePipelineState(finishPipeline)
        e2.setTextures([b.nebTex, b.stars, b.outTex], range: 0..<3)
        e2.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e2.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e2.endEncoding()
    }

    /// Live path: render the chain result into the view's drawable every frame.
    /// Slider input only mutates `params`; the loop always draws current params.
    public func draw(bundle: LayerBundle, params: EngineParams,
                     compare: Bool = false, divider: Float = 0.5, in view: MTKView) {
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
        var bu = BlitUniforms(divider: divider, compare: compare ? 1 : 0)
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

    /// Headless export: run the chain and write a PNG (the CLI path).
    public func renderPNG(bundle: LayerBundle, params: EngineParams, to url: URL) throws {
        let cmd = queue.makeCommandBuffer()!
        encodeChain(cmd, params, bundle)
        cmd.commit(); cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }
        try writePNG(bundle.outTex, to: url)
    }

    /// Write the float result as a 16-bit PNG (design §5: high-precision export,
    /// no 8-bit banding). The RGBA32F values quantise to 16-bit cleanly, so no
    /// dithering is needed — 16 bits has no visible banding in deep-sky gradients.
    private func writePNG(_ tex: MTLTexture, to url: URL) throws {
        let (w, h) = (tex.width, tex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
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
        guard let ctx, let image = ctx.makeImage() else { throw Err.msg("CGContext failed") }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Err.msg("cannot create PNG at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Err.msg("PNG write failed") }
    }
}

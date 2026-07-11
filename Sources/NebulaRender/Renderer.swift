import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import NebulaCore

/// GPU-side layout of `EngineParams` — field order MUST match `Uniforms` in the
/// shader source.
struct EngineParamsGPU {
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

    init(_ p: EngineParams, auto a: AutoStretch) {
        denoiseBlend = p.denoiseBlend; blackPoint = p.blackPoint
        glowD = p.glowD; contrastSP = p.contrastSP
        detailStrength = p.detailStrength; saturation = p.saturation
        starWeight = p.starWeight; starD = p.starD
        shadow0 = a.shadow.0; shadow1 = a.shadow.1; shadow2 = a.shadow.2
        midtone0 = a.midtone.0; midtone1 = a.midtone.1; midtone2 = a.midtone.2
    }
}

/// Per-channel auto base stretch (black point + MTF midtone) derived from image
/// statistics, mirroring Siril's autostretch: shadow = median − 2.8·σ (via MAD),
/// midtone chosen so the background lands at a low target. Computed once on the
/// CPU; the shader applies it as the "instant Auto" baseline the sliders ride on.
struct AutoStretch {
    var shadow: (Float, Float, Float)
    var midtone: (Float, Float, Float)

    init(base: FITSImage, targetBG: Float = 0.12) {
        func channel(_ c: Int) -> (Float, Float) {
            // Subsample for speed; plenty of pixels for robust median/MAD.
            var vals: [Float] = []
            vals.reserveCapacity(base.width * base.height / 16)
            var i = c
            let stride = 4 * 4                 // every 4th pixel, ×4 floats/px
            while i < base.rgba.count { vals.append(base.rgba[i]); i += stride }
            vals.sort()
            let median = vals[vals.count / 2]
            var dev = vals.map { abs($0 - median) }
            dev.sort()
            let mad = dev[dev.count / 2]
            let sigma = 1.4826 * mad
            let shadow = max(0, median - 2.8 * sigma)
            let x0 = (median - shadow) / max(1 - shadow, 1e-4)
            let t = targetBG
            // Solve mtf(x0, m) = t  ->  m = x0(1-t) / (x0(1-2t) + t).
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

/// Headless Metal renderer for the Stage-B shader chain. This is the same code
/// path the interactive view and the tiled export will use; here it renders one
/// full frame to a PNG to prove the kernel on real baked layers.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let processPipeline: MTLComputePipelineState
    let finishPipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw Err.msg("no Metal device")
        }
        self.device = device
        self.queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        self.processPipeline = try device.makeComputePipelineState(
            function: lib.makeFunction(name: "processNebula")!)
        self.finishPipeline = try device.makeComputePipelineState(
            function: lib.makeFunction(name: "finish")!)
    }

    enum Err: Error { case msg(String) }

    private func texture(_ img: FITSImage, write: Bool = false) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: img.width, height: img.height, mipmapped: false)
        desc.usage = write ? [.shaderWrite, .shaderRead] : [.shaderRead]
        let tex = device.makeTexture(descriptor: desc)!
        img.rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, img.width, img.height),
                        mipmapLevel: 0, withBytes: raw.baseAddress!,
                        bytesPerRow: img.width * 16)
        }
        return tex
    }

    private func emptyTexture(_ w: Int, _ h: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: desc)!
    }

    /// Run the full chain on the four layers and write a PNG.
    func render(master: FITSImage, denoised: FITSImage, starless: FITSImage,
                stars: FITSImage, params: EngineParams, to url: URL) throws {
        let (w, h) = (master.width, master.height)
        let mTex = texture(master), dTex = texture(denoised)
        let sTex = texture(starless), stTex = texture(stars)
        let nebTex = emptyTexture(w, h)
        let outTex = emptyTexture(w, h)
        // Auto base stretch from the starless nebula statistics.
        var u = EngineParamsGPU(params, auto: AutoStretch(base: starless))

        let tpg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)

        let cmd = queue.makeCommandBuffer()!

        let e1 = cmd.makeComputeCommandEncoder()!
        e1.setComputePipelineState(processPipeline)
        e1.setTextures([mTex, dTex, sTex, nebTex], range: 0..<4)
        e1.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e1.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e1.endEncoding()

        let e2 = cmd.makeComputeCommandEncoder()!
        e2.setComputePipelineState(finishPipeline)
        e2.setTextures([nebTex, stTex, outTex], range: 0..<3)
        e2.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 0)
        e2.dispatchThreadgroups(grid, threadsPerThreadgroup: tpg)
        e2.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        if let err = cmd.error { throw Err.msg("GPU: \(err)") }

        try writePNG(outTex, to: url)
    }

    /// Read back an RGBA32Float texture, convert to 8-bit sRGB, write a PNG.
    private func writePNG(_ tex: MTLTexture, to url: URL) throws {
        let (w, h) = (tex.width, tex.height)
        var floats = [Float](repeating: 0, count: w * h * 4)
        floats.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            for c in 0..<3 {
                let v = max(0, min(1, floats[i * 4 + c]))
                bytes[i * 4 + c] = UInt8((v * 255).rounded())
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Err.msg("cannot create PNG at \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw Err.msg("PNG write failed") }
    }
}

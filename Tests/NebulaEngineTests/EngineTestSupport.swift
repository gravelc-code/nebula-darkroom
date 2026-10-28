// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
import Metal
import NebulaCore
@testable import NebulaEngine

/// Small synthetic layer bundles for engine tests (no real bake needed).
enum Synth {
    static func image(_ w: Int, _ h: Int, _ fill: (Int, Int) -> (Float, Float, Float)) -> FITSImage {
        var rgba = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = fill(x, y), p = (y * w + x) * 4
            rgba[p] = v.0; rgba[p + 1] = v.1; rgba[p + 2] = v.2
        } }
        return FITSImage(width: w, height: h, channels: 3, rgba: rgba)
    }

    static func grey(_ w: Int, _ h: Int, _ fill: (Int, Int) -> Float) -> FITSImage {
        image(w, h) { x, y in let v = fill(x, y); return (v, v, v) }
    }

    /// A Gaussian star of peak `amp` and variance `s2` (px²) centred at (cx, cy).
    static func star(_ x: Int, _ y: Int, cx: Int, cy: Int, amp: Float, s2: Float) -> Float {
        let d = Float((x - cx) * (x - cx) + (y - cy) * (y - cy))
        return amp * exp(-d / (2 * s2))
    }

    static func lum(_ img: FITSImage, _ x: Int, _ y: Int) -> Float {
        let p = (y * img.width + x) * 4
        return img.rgba[p] * 0.2126 + img.rgba[p + 1] * 0.7152 + img.rgba[p + 2] * 0.0722
    }

    static func renderer() throws -> ChainRenderer {
        do { return try ChainRenderer() } catch { throw XCTSkip("no Metal device") }
    }

    /// Compile the production shader source plus a test-only probe kernel,
    /// with the SAME (default, fast-math) compile options the engine uses.
    static func probeLibrary(_ device: MTLDevice, _ probe: String) throws -> MTLLibrary {
        try device.makeLibrary(source: shaderSource + "\n" + probe, options: nil)
    }

    /// Run a 1-D probe kernel `name(float4 in[], float4 out[], Uniforms u)`.
    static func runProbe(_ r: ChainRenderer, _ lib: MTLLibrary, _ name: String,
                         input: [SIMD4<Float>], uniforms: EngineParamsGPU) throws -> [SIMD4<Float>] {
        let pso = try r.device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
        let n = input.count
        let inBuf = r.device.makeBuffer(bytes: input, length: n * 16)!
        let outBuf = r.device.makeBuffer(length: n * 16)!
        var u = uniforms
        let cmd = r.queue.makeCommandBuffer()!
        let e = cmd.makeComputeCommandEncoder()!
        e.setComputePipelineState(pso)
        e.setBuffer(inBuf, offset: 0, index: 0)
        e.setBuffer(outBuf, offset: 0, index: 1)
        e.setBytes(&u, length: MemoryLayout<EngineParamsGPU>.stride, index: 2)
        e.dispatchThreads(MTLSize(width: n, height: 1, depth: 1),
                          threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        e.endEncoding()
        cmd.commit(); cmd.waitUntilCompleted()
        let p = outBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// Uniforms for a look, with stretch values from a tiny dummy image (only
    /// the slider-derived and constant fields matter to the probes).
    static func uniforms(_ look: LookState) -> EngineParamsGPU {
        let img = grey(8, 8) { x, y in 0.01 + Float(x + y) * 0.001 }
        return EngineParamsGPU(look.engineParams, auto: AutoStretch(base: img),
                               star: StarStretch(base: img))
    }
}

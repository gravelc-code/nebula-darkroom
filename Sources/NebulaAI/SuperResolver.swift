// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Tiled ONNX super-resolution for Real-ESRGAN-style models. Input and output
/// tensors are NCHW RGB floats in 0...1; the output scale is inferred from the
/// tensor length (2x and 4x are supported). Overlap is discarded at tile edges,
/// avoiding seams without averaging independently hallucinated pixels.
public final class SuperResolver {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badInput, unsupportedOutput(Int)
        public var description: String {
            switch self {
            case .badInput: return "super-resolution expects an RGB image"
            case .unsupportedOutput(let n): return "unsupported super-resolution output size (\(n) floats)"
            }
        }
    }

    private let model: OrtModel
    private let tile: Int
    private let overlap: Int

    public init(modelPath: String, tile: Int = 256, overlap: Int = 16) throws {
        // CPU EP is the compatibility baseline. Many community ONNX exports use
        // operators the CoreML EP cannot compile; ORT CPU still runs them exactly.
        model = try OrtModel(modelPath: modelPath, useCoreML: false)
        self.tile = tile
        self.overlap = min(max(overlap, 0), tile / 4)
    }

    /// Returns `(pixels, outputHeight, outputWidth)` with interleaved HWC RGB.
    public func upscale(pixels: [Float], h: Int, w: Int, strength: Float = 1,
                        progress: @Sendable (Double) -> Void = { _ in }) throws -> ([Float], Int, Int) {
        guard pixels.count == h * w * 3, h > 0, w > 0 else { throw Error.badInput }
        let core = tile - overlap * 2
        let first = try inferTile(pixels, h: h, w: w, originY: -overlap, originX: -overlap)
        let scale = first.scale
        let oh = h * scale, ow = w * scale
        var output = [Float](repeating: 0, count: oh * ow * 3)
        let jobsX = (w + core - 1) / core, jobsY = (h + core - 1) / core
        let jobCount = jobsX * jobsY
        var completed = 0

        var y = 0
        while y < h {
            var x = 0
            while x < w {
                try Task.checkCancellation()
                let inferred = (x == 0 && y == 0)
                    ? first
                    : try inferTile(pixels, h: h, w: w,
                                    originY: y - overlap, originX: x - overlap)
                let copyH = min(core, h - y), copyW = min(core, w - x)
                for dy in 0..<(copyH * scale) {
                    for dx in 0..<(copyW * scale) {
                        let sy = overlap * scale + dy, sx = overlap * scale + dx
                        let dyOut = y * scale + dy, dxOut = x * scale + dx
                        for ch in 0..<3 {
                            output[(dyOut * ow + dxOut) * 3 + ch] =
                                inferred.hwc[(sy * tile * scale + sx) * 3 + ch]
                        }
                    }
                }
                completed += 1
                progress(Double(completed) / Double(max(jobCount, 1)))
                x += core
            }
            y += core
        }
        let amount = min(max(strength, 0), 1)
        if amount < 0.999 {
            let baseline = Self.resizeBilinear(pixels, h: h, w: w, dh: oh, dw: ow)
            for i in output.indices { output[i] = baseline[i] + (output[i] - baseline[i]) * amount }
        }
        return (output, oh, ow)
    }

    private func inferTile(_ pixels: [Float], h: Int, w: Int,
                           originY: Int, originX: Int) throws -> (hwc: [Float], scale: Int) {
        var nchw = [Float](repeating: 0, count: 3 * tile * tile)
        for ty in 0..<tile {
            let sy = min(max(originY + ty, 0), h - 1)
            for tx in 0..<tile {
                let sx = min(max(originX + tx, 0), w - 1)
                for ch in 0..<3 {
                    nchw[ch * tile * tile + ty * tile + tx] = pixels[(sy * w + sx) * 3 + ch]
                }
            }
        }
        let raw = try model.run(nchw, shape: [1, 3, tile, tile])
        let plane = tile * tile
        let scale: Int
        if raw.count == 3 * plane * 4 { scale = 2 }
        else if raw.count == 3 * plane * 16 { scale = 4 }
        else { throw Error.unsupportedOutput(raw.count) }
        let side = tile * scale, outPlane = side * side
        var hwc = [Float](repeating: 0, count: outPlane * 3)
        for p in 0..<outPlane { for ch in 0..<3 {
            hwc[p * 3 + ch] = min(max(raw[ch * outPlane + p], 0), 1)
        } }
        return (hwc, scale)
    }

    static func resizeBilinear(_ src: [Float], h: Int, w: Int, dh: Int, dw: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: dh * dw * 3)
        let sy = Float(h) / Float(dh), sx = Float(w) / Float(dw)
        for y in 0..<dh {
            let fy = max(0, (Float(y) + 0.5) * sy - 0.5)
            let y0 = min(Int(fy), h - 1), y1 = min(y0 + 1, h - 1), ay = fy - Float(y0)
            for x in 0..<dw {
                let fx = max(0, (Float(x) + 0.5) * sx - 0.5)
                let x0 = min(Int(fx), w - 1), x1 = min(x0 + 1, w - 1), ax = fx - Float(x0)
                for ch in 0..<3 {
                    let a = src[(y0*w+x0)*3+ch] * (1-ax) + src[(y0*w+x1)*3+ch] * ax
                    let b = src[(y1*w+x0)*3+ch] * (1-ax) + src[(y1*w+x1)*3+ch] * ax
                    dst[(y*dw+x)*3+ch] = a * (1-ay) + b * ay
                }
            }
        }
        return dst
    }
}

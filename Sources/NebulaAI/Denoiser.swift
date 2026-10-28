// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// A row-major HxWxC float image (mirrors the numpy HxWxC the GraXpert pipeline
/// works in), with just the concatenation helpers the tiling padding needs.
struct Plane {
    var h: Int, w: Int, c: Int
    var d: [Float]

    init(h: Int, w: Int, c: Int, d: [Float]) { self.h = h; self.w = w; self.c = c; self.d = d }

    @inline(__always) func idx(_ r: Int, _ x: Int, _ ch: Int) -> Int { (r * w + x) * c + ch }

    /// numpy `concatenate((self, self[rows]), axis=0)` — rows are contiguous.
    func appendRows(_ rows: Range<Int>) -> Plane {
        var nd = d
        nd.reserveCapacity((h + rows.count) * w * c)
        for r in rows { nd.append(contentsOf: d[(r * w * c)..<((r + 1) * w * c)]) }
        return Plane(h: h + rows.count, w: w, c: c, d: nd)
    }

    /// numpy `concatenate((self[rows], self), axis=0)`.
    func prependRows(_ rows: Range<Int>) -> Plane {
        var nd = [Float](); nd.reserveCapacity((h + rows.count) * w * c)
        for r in rows { nd.append(contentsOf: d[(r * w * c)..<((r + 1) * w * c)]) }
        nd.append(contentsOf: d)
        return Plane(h: h + rows.count, w: w, c: c, d: nd)
    }

    /// numpy `concatenate((self, self[:, cols]), axis=1)` — columns need splicing.
    func appendCols(_ cols: Range<Int>) -> Plane {
        let nw = w + cols.count
        var nd = [Float](repeating: 0, count: h * nw * c)
        for r in 0..<h {
            let src = r * w * c, dst = r * nw * c
            for k in 0..<(w * c) { nd[dst + k] = d[src + k] }
            var dc = dst + w * c
            for x in cols { for ch in 0..<c { nd[dc] = d[(r * w + x) * c + ch]; dc += 1 } }
        }
        return Plane(h: h, w: nw, c: c, d: nd)
    }

    /// numpy `concatenate((self[:, cols], self), axis=1)`.
    func prependCols(_ cols: Range<Int>) -> Plane {
        let nw = w + cols.count
        var nd = [Float](repeating: 0, count: h * nw * c)
        for r in 0..<h {
            let src = r * w * c, dst = r * nw * c
            var dc = dst
            for x in cols { for ch in 0..<c { nd[dc] = d[(r * w + x) * c + ch]; dc += 1 } }
            for k in 0..<(w * c) { nd[dc + k] = d[src + k] }
        }
        return Plane(h: h, w: nw, c: c, d: nd)
    }
}

/// numpy `np.median` — averages the two middle elements for even counts.
func medianOf(_ v: [Float]) -> Float {
    let s = v.sorted()
    let n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Port of GraXpert 3.0.2 `denoising.py` (validated bit-exact by the Python
/// spike, `prototype/ai_native/denoise_onnx.py`). Runs the denoise ONNX model
/// in-process via ORT with the same tiling / normalization / stitch / blend.
public final class Denoiser {
    private let model: OrtModel
    private let window = 256, stride = 128
    /// Tiles per `model.run`. Tiles are independent, so this changes memory and
    /// speed, never pixels.
    public let batchSize: Int
    /// Normalised-value ceiling the model is trusted below (see `modelThreshold(for:)`).
    public let modelThreshold: Float

    /// `modelVersion` defaults to the version implied by a GraXpert cache path
    /// (`…/denoise-ai-models/<version>/model.onnx`); an unversioned file keeps
    /// the current-model threshold. `batchSize` defaults to `defaultBatchSize()`.
    public init(modelPath: String, modelVersion: ModelVersion? = nil, batchSize: Int? = nil,
                useCoreML: Bool = false) throws {
        model = try OrtModel(modelPath: modelPath, useCoreML: useCoreML)
        modelThreshold = Self.modelThreshold(
            for: modelVersion ?? ModelLocator.version(ofModelAt: modelPath))
        self.batchSize = min(max(batchSize ?? Self.defaultBatchSize(), 1), 32)
    }

    public convenience init(model: LocatedModel, batchSize: Int? = nil) throws {
        try self.init(modelPath: model.path, modelVersion: model.version, batchSize: batchSize)
    }

    /// GraXpert `denoising.py:33-36`: `model_threshold = 1.0` when the model
    /// path contains "1.0.0" or "1.1.0" (the first two denoise releases), else
    /// `10.0`. Unknown versions are today's (3.x) models → 10.
    public static func modelThreshold(for version: ModelVersion?) -> Float {
        guard let v = version else { return 10 }
        return v == ModelVersion(1, 0, 0) || v == ModelVersion(1, 1, 0) ? 1 : 10
    }

    /// GraXpert's own default is 4 (`denoising.py:14`); 8 amortises ORT call
    /// overhead but measured 2.62 GB peak RSS vs 1.82 GB at 4 on a full Seestar
    /// frame (audit 2026-10-27 #48) — too tight beside the rest of a bake on an
    /// 8 GB Mac. So: 4 below 16 GB of RAM, 8 from 16 GB up.
    public static func defaultBatchSize(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        physicalMemory < 16 << 30 ? 4 : 8
    }

    /// `pixels` is row-major HxWxC (C = 1 or 3), values in [0,1]. Returns same
    /// shape, always finite. Throws (never traps) on a bad shape or model.
    public func denoise(pixels: [Float], h: Int, w: Int, c: Int,
                        strength: Float) throws -> [Float] {
        try AIInput.validate(count: pixels.count, h: h, w: w, c: c)
        guard strength.isFinite else { throw AIError.invalidImage("strength \(strength)") }
        let modelThreshold = self.modelThreshold, batchSize = self.batchSize
        // NaN/Inf -> channel median; identity (same storage) for a finite image.
        let input = AIInput.replacingNonFinite(pixels, h: h, w: w, c: c).pixels

        // median / MAD per channel from every-4th pixel (numpy image[::4,::4,:]).
        var median = [Float](repeating: 0, count: c)
        var mad = [Float](repeating: 0, count: c)
        for ch in 0..<c {
            var sample: [Float] = []
            sample.reserveCapacity((h / 4 + 1) * (w / 4 + 1))
            var r = 0
            while r < h { var x = 0; while x < w { sample.append(input[(r * w + x) * c + ch]); x += 4 }; r += 4 }
            let m = medianOf(sample)
            median[ch] = m
            sample = sample.map { abs($0 - m) }
            mad[ch] = AIInput.flooredMAD(medianOf(sample))
        }

        // Broadcast mono -> 3ch for the model.
        var img: Plane
        if c == 1 {
            var three = [Float](repeating: 0, count: h * w * 3)
            for i in 0..<(h * w) { let v = input[i]; three[i*3] = v; three[i*3+1] = v; three[i*3+2] = v }
            img = Plane(h: h, w: w, c: 3, d: three)
        } else {
            img = Plane(h: h, w: w, c: c, d: input)
        }
        let med3 = c == 1 ? [median[0], median[0], median[0]] : median
        let mad3 = c == 1 ? [mad[0], mad[0], mad[0]] : mad

        let H = h, W = w
        let offset = (window - stride) / 2
        let ith = h / stride + 1
        let itw = w / stride + 1
        let dh = ith * stride - h
        let dw = itw * stride - w

        // numpy `concatenate((img, img[h-dh:]))`. For h >= 64 that's one block
        // (dh <= h) — identical to upstream. Below 64 px upstream's negative
        // slice wraps and the tiles come out short (it crashes); repeating the
        // same block-append until the grid is full keeps the same tiling rule.
        var needRows = dh
        while needRows > 0 { let k = min(needRows, img.h); img = img.appendRows((img.h - k)..<img.h); needRows -= k }
        var needCols = dw
        while needCols > 0 { let k = min(needCols, img.w); img = img.appendCols((img.w - k)..<img.w); needCols -= k }
        img = img.appendRows((img.h - offset)..<img.h)
        img = img.prependRows(0..<offset)
        img = img.appendCols((img.w - offset)..<img.w)
        img = img.prependCols(0..<offset)

        var output = img              // written in stride blocks, cropped at the end
        let pw = img.w
        let tileFloats = window * window * 3

        // Run tiles in batches through one model.run — same per-tile math as a
        // 1-at-a-time loop (bit-identical), but amortizes the per-call overhead.
        var jobs: [(Int, Int)] = []
        for i in 0..<ith { for j in 0..<itw { jobs.append((i, j)) } }

        var jb = 0
        while jb < jobs.count {
            try Task.checkCancellation()      // stop promptly if the bake is cancelled
            let n = min(batchSize, jobs.count - jb)
            var batch = [Float](repeating: 0, count: n * tileFloats)
            var copy = [Float](repeating: 0, count: n * tileFloats)
            for b in 0..<n {
                let (i, j) = jobs[jb + b]
                let x = stride * i, y = stride * j
                let base = b * tileFloats
                for ty in 0..<window {
                    let srcRow = (x + ty) * pw
                    for tx in 0..<window {
                        let s = (srcRow + (y + tx)) * 3
                        let t = base + (ty * window + tx) * 3
                        for ch in 0..<3 {
                            let norm = (img.d[s + ch] - med3[ch]) / mad3[ch] * 0.04
                            copy[t + ch] = norm
                            batch[t + ch] = min(max(norm, -modelThreshold), modelThreshold)
                        }
                    }
                }
            }

            let result = try model.run(batch, shape: [n, window, window, 3],
                                       expectedCount: n * tileFloats)

            for b in 0..<n {
                let (i, j) = jobs[jb + b]
                let x = stride * i, y = stride * j
                let base = b * tileFloats
                for oy in 0..<stride {
                    let ty = oy + offset
                    let dstRow = (x + offset + oy) * pw
                    for ox in 0..<stride {
                        let tx = ox + offset
                        let t = base + (ty * window + tx) * 3
                        let dst = (dstRow + (y + offset + ox)) * 3
                        for ch in 0..<3 {
                            // Upstream keeps the input where the model isn't trusted
                            // (>= threshold); a non-finite model value is treated the same.
                            let m = result[t + ch]
                            var v = copy[t + ch] < modelThreshold && m.isFinite ? m : copy[t + ch]
                            v = v / 0.04 * mad3[ch] + med3[ch]
                            output.d[dst + ch] = v
                        }
                    }
                }
            }
            jb += n
        }

        // Crop padding: output[offset:H+offset, offset:W+offset], back to c channels.
        var denoised = [Float](repeating: 0, count: H * W * c)
        for r in 0..<H {
            let srcRow = (r + offset) * pw
            for x in 0..<W {
                let s = (srcRow + (x + offset)) * 3
                if c == 1 {
                    denoised[r * W + x] = output.d[s]     // mono: take channel 0
                } else {
                    for ch in 0..<c { denoised[(r * W + x) * c + ch] = output.d[s + ch] }
                }
            }
        }

        // Blend by strength; pixels at/above the model threshold keep the original
        // (with the 3.x threshold of 10 that is ~250 MADs -> effectively all denoised).
        var out = [Float](repeating: 0, count: H * W * c)
        for ch in 0..<c {
            let thr = modelThreshold / 0.04 * mad[ch] + median[ch]
            var i = ch
            while i < out.count {
                let orig = input[i]
                let blended = (orig < thr ? denoised[i] : orig) * strength + orig * (1 - strength)
                out[i] = min(max(blended, 0), 1)
                i += c
            }
        }
        return out
    }
}

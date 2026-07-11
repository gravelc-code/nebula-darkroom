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

private func medianOf(_ v: [Float]) -> Float {
    let s = v.sorted()
    let n = s.count
    // Match numpy np.median: average the two middle elements for even counts.
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// Port of GraXpert 3.0.2 `denoising.py` (validated bit-exact by the Python
/// spike, `prototype/ai_native/denoise_onnx.py`). Runs the denoise ONNX model
/// in-process via ORT with the same tiling / normalization / stitch / blend.
public final class Denoiser {
    private let model: OrtModel
    private let window = 256, stride = 128
    private let modelThreshold: Float = 10.0   // 3.x models

    public init(modelPath: String) throws { model = try OrtModel(modelPath: modelPath) }

    /// `pixels` is row-major HxWxC (C = 1 or 3), values in [0,1]. Returns same shape.
    public func denoise(pixels: [Float], h: Int, w: Int, c: Int,
                        strength: Float) throws -> [Float] {
        let input = pixels

        // median / MAD per channel from every-4th pixel (numpy image[::4,::4,:]).
        var median = [Float](repeating: 0, count: c)
        var mad = [Float](repeating: 0, count: c)
        for ch in 0..<c {
            var sample: [Float] = []
            sample.reserveCapacity((h / 4 + 1) * (w / 4 + 1))
            var r = 0
            while r < h { var x = 0; while x < w { sample.append(pixels[(r * w + x) * c + ch]); x += 4 }; r += 4 }
            let m = medianOf(sample)
            median[ch] = m
            sample = sample.map { abs($0 - m) }
            mad[ch] = medianOf(sample)
        }

        // Broadcast mono -> 3ch for the model.
        var img: Plane
        if c == 1 {
            var three = [Float](repeating: 0, count: h * w * 3)
            for i in 0..<(h * w) { let v = pixels[i]; three[i*3] = v; three[i*3+1] = v; three[i*3+2] = v }
            img = Plane(h: h, w: w, c: 3, d: three)
        } else {
            img = Plane(h: h, w: w, c: c, d: pixels)
        }
        let med3 = c == 1 ? [median[0], median[0], median[0]] : median
        let mad3 = c == 1 ? [mad[0], mad[0], mad[0]] : mad

        let H = h, W = w
        let offset = (window - stride) / 2
        let ith = h / stride + 1
        let itw = w / stride + 1
        let dh = ith * stride - h
        let dw = itw * stride - w

        if dh > 0 { img = img.appendRows((img.h - dh)..<img.h) }
        if dw > 0 { img = img.appendCols((img.w - dw)..<img.w) }
        img = img.appendRows((img.h - offset)..<img.h)
        img = img.prependRows(0..<offset)
        img = img.appendCols((img.w - offset)..<img.w)
        img = img.prependCols(0..<offset)

        var output = img              // written in stride blocks, cropped at the end
        let pw = img.w

        for i in 0..<ith {
            for j in 0..<itw {
                let x = stride * i, y = stride * j
                // Build normalized tile + keep a copy for the keep-bright mask.
                var tile = [Float](repeating: 0, count: window * window * 3)
                var copy = [Float](repeating: 0, count: window * window * 3)
                for ty in 0..<window {
                    let srcRow = (x + ty) * pw
                    for tx in 0..<window {
                        let s = (srcRow + (y + tx)) * 3
                        let t = (ty * window + tx) * 3
                        for ch in 0..<3 {
                            let norm = (img.d[s + ch] - med3[ch]) / mad3[ch] * 0.04
                            copy[t + ch] = norm
                            tile[t + ch] = min(max(norm, -modelThreshold), modelThreshold)
                        }
                    }
                }

                let result = try model.run(tile, shape: [1, window, window, 3])

                // keep-bright, denormalize, crop center stride, place into output.
                for oy in 0..<stride {
                    let ty = oy + offset
                    let dstRow = (x + offset + oy) * pw
                    for ox in 0..<stride {
                        let tx = ox + offset
                        let t = (ty * window + tx) * 3
                        let dst = (dstRow + (y + offset + ox)) * 3
                        for ch in 0..<3 {
                            var v = copy[t + ch] < modelThreshold ? result[t + ch] : copy[t + ch]
                            v = v / 0.04 * mad3[ch] + med3[ch]
                            output.d[dst + ch] = v
                        }
                    }
                }
            }
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

        // Blend by strength (keep-bright threshold is enormous -> effectively denoised).
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

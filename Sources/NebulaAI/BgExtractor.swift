import Foundation

/// Port of GraXpert 3.0.2 `background_extraction.py` (AI + Subtraction path,
/// validated by `prototype/ai_native/bg_extract_onnx.py`): downscale the whole
/// frame to 240, pad to 256, normalize, one model pass, denormalize, blur,
/// upscale, subtract. The two OpenCV ops (bilinear resize, Gaussian blur) are
/// reimplemented here to OpenCV's conventions — aiming for visually-identical
/// output, not bit-exactness (the background is a smooth estimate that gets
/// subtracted, so sub-1e-3 differences don't show).
public final class BgExtractor {
    private let model: OrtModel

    public init(modelPath: String) throws { model = try OrtModel(modelPath: modelPath) }

    /// `pixels` is row-major HxWxC in [0,1]; returns the background-subtracted image.
    public func extract(pixels: [Float], h: Int, w: Int, c: Int,
                        smoothing: Float = 0) throws -> [Float] {
        let padding = 8
        let inner = 256 - 2 * padding                       // 240

        // Downscale whole frame -> 240x240, then edge-pad to 256.
        var shrink = resizeBilinear(pixels, sh: h, sw: w, c: c, dh: inner, dw: inner)
        shrink = padEdge(shrink, h: inner, w: inner, c: c, pad: padding)   // 256x256
        let ss = 256

        // Per-channel median / MAD over the 256x256 shrink.
        var median = [Float](repeating: 0, count: c)
        var mad = [Float](repeating: 0, count: c)
        for ch in 0..<c {
            var vals = [Float](repeating: 0, count: ss * ss)
            for i in 0..<(ss * ss) { vals[i] = shrink[i * c + ch] }
            let m = medianOf(vals); median[ch] = m
            mad[ch] = medianOf(vals.map { abs($0 - m) })
        }

        // Normalize, clip [-1,1], broadcast mono -> 3ch for the model.
        var tile = [Float](repeating: 0, count: ss * ss * 3)
        for i in 0..<(ss * ss) {
            for ch in 0..<3 {
                let sc = c == 1 ? 0 : ch
                let v = (shrink[i * c + sc] - median[sc]) / mad[sc] * 0.04
                tile[i * 3 + ch] = min(max(v, -1.0), 1.0)
            }
        }

        let result = try model.run(tile, shape: [1, ss, ss, 3])   // 256x256x3

        // Denormalize to a c-channel background.
        var bg = [Float](repeating: 0, count: ss * ss * c)
        for i in 0..<(ss * ss) {
            for ch in 0..<c {
                bg[i * c + ch] = result[i * 3 + ch] / 0.04 * mad[ch] + median[ch]
            }
        }

        if smoothing != 0 {
            let sigma = smoothing * 20
            bg = gaussianBlur(bg, h: ss, w: ss, c: c, kernel: gaussianKernel(sigma: Float(sigma)))
        }

        // Crop the 8px pad -> 240, blur (sigma 3), upscale to full res.
        bg = cropEdge(bg, h: ss, w: ss, c: c, pad: padding)         // 240x240
        bg = gaussianBlur(bg, h: inner, w: inner, c: c, kernel: gaussianKernel(sigma: 3.0))
        bg = resizeBilinear(bg, sh: inner, sw: inner, c: c, dh: h, dw: w)

        // Subtraction correction: img - bg + mean(bg), clip.
        var mean: Float = 0
        for v in bg { mean += v }
        mean /= Float(bg.count)
        var out = [Float](repeating: 0, count: h * w * c)
        for i in 0..<out.count { out[i] = min(max(pixels[i] - bg[i] + mean, 0), 1) }
        return out
    }
}

// MARK: - OpenCV-convention image ops

/// Bilinear resize matching OpenCV `INTER_LINEAR`: half-pixel source centers,
/// `src = (dst + 0.5) * scale - 0.5`, with clamped edge sampling.
func resizeBilinear(_ src: [Float], sh: Int, sw: Int, c: Int, dh: Int, dw: Int) -> [Float] {
    if sh == dh && sw == dw { return src }
    var dst = [Float](repeating: 0, count: dh * dw * c)
    let scaleY = Float(sh) / Float(dh), scaleX = Float(sw) / Float(dw)
    for dy in 0..<dh {
        var fy = (Float(dy) + 0.5) * scaleY - 0.5
        if fy < 0 { fy = 0 }
        var y0 = Int(fy.rounded(.down))
        var ay = fy - Float(y0)
        if y0 >= sh - 1 { y0 = sh - 1; ay = 0 }
        let y1 = min(y0 + 1, sh - 1)
        for dx in 0..<dw {
            var fx = (Float(dx) + 0.5) * scaleX - 0.5
            if fx < 0 { fx = 0 }
            var x0 = Int(fx.rounded(.down))
            var ax = fx - Float(x0)
            if x0 >= sw - 1 { x0 = sw - 1; ax = 0 }
            let x1 = min(x0 + 1, sw - 1)
            let w00 = (1 - ay) * (1 - ax), w01 = (1 - ay) * ax
            let w10 = ay * (1 - ax), w11 = ay * ax
            for ch in 0..<c {
                let p00 = src[(y0 * sw + x0) * c + ch], p01 = src[(y0 * sw + x1) * c + ch]
                let p10 = src[(y1 * sw + x0) * c + ch], p11 = src[(y1 * sw + x1) * c + ch]
                dst[(dy * dw + dx) * c + ch] = w00 * p00 + w01 * p01 + w10 * p10 + w11 * p11
            }
        }
    }
    return dst
}

/// OpenCV `getGaussianKernel(ksize, sigma)` for sigma>0: ksize from GraXpert's
/// `gaussian_kernel(sigma)` helper (round(sigma*4), made odd).
func gaussianKernel(sigma: Float) -> [Float] {
    let k = Int((sigma * 4).rounded())
    let ksize = k % 2 == 0 ? k - 1 : k
    let center = (ksize - 1) / 2
    var kern = [Float](repeating: 0, count: max(ksize, 1))
    var sum: Float = 0
    for i in 0..<kern.count {
        let x = Float(i - center)
        let v = expf(-(x * x) / (2 * sigma * sigma))
        kern[i] = v; sum += v
    }
    for i in 0..<kern.count { kern[i] /= sum }
    return kern
}

/// Separable Gaussian blur with OpenCV's default `BORDER_REFLECT_101` border.
func gaussianBlur(_ src: [Float], h: Int, w: Int, c: Int, kernel: [Float]) -> [Float] {
    if kernel.count <= 1 { return src }
    let r = (kernel.count - 1) / 2

    func reflect101(_ p: Int, _ n: Int) -> Int {
        if n == 1 { return 0 }
        var q = p
        while q < 0 || q >= n { if q < 0 { q = -q }; if q >= n { q = 2 * (n - 1) - q } }
        return q
    }

    var tmp = [Float](repeating: 0, count: h * w * c)   // horizontal pass
    for y in 0..<h {
        for x in 0..<w {
            for ch in 0..<c {
                var acc: Float = 0
                for k in -r...r {
                    let xx = reflect101(x + k, w)
                    acc += kernel[k + r] * src[(y * w + xx) * c + ch]
                }
                tmp[(y * w + x) * c + ch] = acc
            }
        }
    }
    var dst = [Float](repeating: 0, count: h * w * c)   // vertical pass
    for y in 0..<h {
        for x in 0..<w {
            for ch in 0..<c {
                var acc: Float = 0
                for k in -r...r {
                    let yy = reflect101(y + k, h)
                    acc += kernel[k + r] * tmp[(yy * w + x) * c + ch]
                }
                dst[(y * w + x) * c + ch] = acc
            }
        }
    }
    return dst
}

/// Replicate-pad `pad` px on every side (numpy `mode="edge"`).
func padEdge(_ src: [Float], h: Int, w: Int, c: Int, pad: Int) -> [Float] {
    let nh = h + 2 * pad, nw = w + 2 * pad
    var dst = [Float](repeating: 0, count: nh * nw * c)
    for y in 0..<nh {
        let sy = min(max(y - pad, 0), h - 1)
        for x in 0..<nw {
            let sx = min(max(x - pad, 0), w - 1)
            for ch in 0..<c { dst[(y * nw + x) * c + ch] = src[(sy * w + sx) * c + ch] }
        }
    }
    return dst
}

/// Inverse of `padEdge` — crop `pad` px off every side.
func cropEdge(_ src: [Float], h: Int, w: Int, c: Int, pad: Int) -> [Float] {
    let nh = h - 2 * pad, nw = w - 2 * pad
    var dst = [Float](repeating: 0, count: nh * nw * c)
    for y in 0..<nh {
        for x in 0..<nw {
            for ch in 0..<c { dst[(y * nw + x) * c + ch] = src[((y + pad) * w + (x + pad)) * c + ch] }
        }
    }
    return dst
}

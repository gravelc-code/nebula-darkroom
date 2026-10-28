// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Errors the AI pipelines **throw** (never trap) so `Baker.aiStage` can log
/// the reason and fall back to the input instead of the app crashing.
public enum AIError: Error, CustomStringConvertible, LocalizedError {
    /// The caller's image doesn't describe a usable HxWxC buffer.
    case invalidImage(String)
    /// The model produced something the pipeline can't interpret.
    case unexpectedOutput(String)

    public var description: String {
        switch self {
        case .invalidImage(let m): return "invalid image: \(m)"
        case .unexpectedOutput(let m): return "unexpected model output: \(m)"
        }
    }
    public var errorDescription: String? { description }
}

/// Input hygiene shared by `Denoiser` and `BgExtractor`. None of this changes a
/// normal (finite, non-flat) image by a single bit — it only defines behaviour
/// where the GraXpert reference itself produces NaN or crashes.
enum AIInput {
    /// Shape check: both pipelines index `pixels[(r*w+x)*c+ch]` and the models
    /// take 3 channels (mono is broadcast), so anything else must be refused here.
    static func validate(count: Int, h: Int, w: Int, c: Int) throws {
        guard h > 0, w > 0 else { throw AIError.invalidImage("empty \(w)x\(h) image") }
        guard c == 1 || c == 3 else { throw AIError.invalidImage("\(c) channels (expected 1 or 3)") }
        let (wc, o1) = w.multipliedReportingOverflow(by: c)
        let (n, o2) = h.multipliedReportingOverflow(by: wc)
        guard !o1, !o2, count == n else {
            throw AIError.invalidImage("\(count) values for \(w)x\(h)x\(c)")
        }
    }

    /// Floor for the median absolute deviation both pipelines divide by.
    ///
    /// GraXpert normalises as `(x - median) / mad * 0.04` with no guard
    /// (`denoising.py:106`, `background_extraction.py:61`), so a flat sample —
    /// MAD exactly 0, e.g. a frame more than half zero-filled — yields 0/0 = NaN
    /// tiles. 1e-6 is ~15x below one 16-bit ADU (1/65535 = 1.5e-5), the finest
    /// step the Seestar's sensor data has, so any real sky's MAD is far above it
    /// and is used unchanged (bit-exact); only the degenerate case is affected.
    /// It also keeps `(x - median) / mad` finite for any |x - median| < 1e32, so
    /// the denormalise round-trip (`* mad + median`) can't hit Inf * 0.
    static let madFloor: Float = 1e-6

    @inline(__always) static func flooredMAD(_ mad: Float) -> Float { max(mad, madFloor) }

    /// Replace NaN/±Inf with the channel's **median of finite values** (sampled
    /// on GraXpert's own `image[::4, ::4]` grid). Returns the input untouched —
    /// same storage, zero cost beyond one scan — when everything is finite.
    ///
    /// Why the median, not 0: a non-finite pixel is "no measurement" (a FITS
    /// BLANK, a zero-coverage stack edge, an overflowed calibration). Both
    /// models see `(x - median) / mad * 0.04`, so the median maps to exactly 0 —
    /// the centre of the training distribution, i.e. "plain sky, no signal".
    /// Zero would instead map to `-median/mad*0.04`, a strong negative outlier
    /// (~-1 for a typical Seestar master) that the background model reads as a
    /// hole in the sky — pulling the whole local background estimate down — and
    /// the denoiser as a dark defect. Upstream has no handling at all: one NaN
    /// poisons the median sort, a whole 256² denoise tile, or (via the
    /// background mean) every output pixel.
    static func replacingNonFinite(_ pixels: [Float], h: Int, w: Int, c: Int)
        -> (pixels: [Float], replaced: Int) {
        let clean = pixels.withUnsafeBufferPointer { buf -> Bool in
            for v in buf where !v.isFinite { return false }
            return true
        }
        if clean { return (pixels, 0) }

        var fill = [Float](repeating: 0, count: c)
        for ch in 0..<c {
            var sample: [Float] = []
            var r = 0
            while r < h {
                var x = 0
                while x < w { let v = pixels[(r * w + x) * c + ch]; if v.isFinite { sample.append(v) }; x += 4 }
                r += 4
            }
            if sample.isEmpty {     // decimated grid all bad: use every finite pixel
                var i = ch
                while i < pixels.count { if pixels[i].isFinite { sample.append(pixels[i]) }; i += c }
            }
            fill[ch] = sample.isEmpty ? 0 : medianOf(sample)    // nothing finite at all -> 0
        }
        var out = pixels
        var replaced = 0
        for i in out.indices where !out[i].isFinite { out[i] = fill[i % c]; replaced += 1 }
        return (out, replaced)
    }

    /// `np.mean` of a Float32 array, accumulated in Double. numpy's pairwise
    /// summation keeps float32 error at O(log n · eps); a naive running Float sum
    /// does not (+1.2% at 1920x1080x3, -6.7% at 4K), which shifted the
    /// background pedestal of every output pixel. A Double accumulator is within
    /// one float32 rounding of the exact mean for any frame size we can load.
    static func mean(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        return v.withUnsafeBufferPointer { buf -> Float in
            // Four lanes only to break the dependency chain; each is Double.
            var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0
            let n = buf.count
            var i = 0
            while i + 4 <= n {
                s0 += Double(buf[i]); s1 += Double(buf[i + 1])
                s2 += Double(buf[i + 2]); s3 += Double(buf[i + 3])
                i += 4
            }
            while i < n { s0 += Double(buf[i]); i += 1 }
            return Float(((s0 + s1) + (s2 + s3)) / Double(n))
        }
    }

    /// True when every value is finite (used to vet model outputs).
    static func allFinite(_ v: [Float]) -> Bool {
        v.withUnsafeBufferPointer { buf in
            for x in buf where !x.isFinite { return false }
            return true
        }
    }
}

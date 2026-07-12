import Foundation

public struct ImageQualityStats: Codable, Equatable, Sendable {
    public let channelMedian: [Float]
    public let channelNoiseMAD: [Float]
    public let blackClippedFraction: Float
    public let whiteClippedFraction: Float
    public let backgroundCast: Float
    public let finiteFraction: Float

    public static func measure(_ pixels: [Float], channels: Int) -> ImageQualityStats {
        guard channels > 0, !pixels.isEmpty else {
            return ImageQualityStats(channelMedian: [], channelNoiseMAD: [],
                                     blackClippedFraction: 0, whiteClippedFraction: 0,
                                     backgroundCast: 0, finiteFraction: 0)
        }
        var samples = [[Float]](repeating: [], count: channels)
        let pixelCount = pixels.count / channels
        let stridePixels = max(1, pixelCount / 100_000)
        var black = 0, white = 0, finite = 0, sampled = 0
        for p in Swift.stride(from: 0, to: pixelCount, by: stridePixels) {
            var allFinite = true, peak: Float = 0
            for ch in 0..<channels {
                let value = pixels[p * channels + ch]
                if value.isFinite { samples[ch].append(value); peak = max(peak, value) }
                else { allFinite = false }
            }
            if allFinite { finite += 1 }
            if peak <= 1e-6 { black += 1 }
            if peak >= 0.999 { white += 1 }
            sampled += 1
        }
        var medians: [Float] = [], noise: [Float] = []
        for ch in 0..<channels {
            let sorted = samples[ch].sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let deviations = sorted.map { abs($0 - median) }.sorted()
            medians.append(median)
            noise.append(deviations.isEmpty ? 0 : 1.4826 * deviations[deviations.count / 2])
        }
        let positive = medians.filter { $0 > 1e-6 }
        let cast = positive.count < 2 ? 0 : (positive.max()! - positive.min()!) / max(positive.reduce(0,+) / Float(positive.count), 1e-6)
        let n = Float(max(sampled, 1))
        return ImageQualityStats(channelMedian: medians, channelNoiseMAD: noise,
                                 blackClippedFraction: Float(black) / n,
                                 whiteClippedFraction: Float(white) / n,
                                 backgroundCast: cast, finiteFraction: Float(finite) / n)
    }
}

public struct ImageQualityReport: Codable, Sendable {
    public let raw: ImageQualityStats
    public let corrected: ImageQualityStats
    public let correctionAccepted: Bool
    public let colourMethod: String
    public let notes: [String]
}

enum CorrectionValidator {
    static func accept(before: [Float], after: [Float], channels: Int) -> (Bool, [String]) {
        guard before.count == after.count, !before.isEmpty else { return (false, ["shape-mismatch"]) }
        let a = ImageQualityStats.measure(before, channels: channels)
        let b = ImageQualityStats.measure(after, channels: channels)
        var notes: [String] = []
        if b.finiteFraction < 1 { notes.append("non-finite-output") }
        if b.blackClippedFraction > a.blackClippedFraction + 0.02 { notes.append("excess-black-clipping") }
        if b.whiteClippedFraction > a.whiteClippedFraction + 0.005 { notes.append("excess-white-clipping") }
        if b.backgroundCast > max(0.35, a.backgroundCast * 1.75) { notes.append("background-cast-worsened") }
        var delta: Double = 0
        let step = max(channels, before.count / 50_000)
        var i = 0, count = 0
        while i < before.count {
            if before[i].isFinite && after[i].isFinite { delta += Double(abs(before[i] - after[i])); count += 1 }
            i += step
        }
        if delta / Double(max(count, 1)) < 1e-7 { notes.append("no-meaningful-change") }
        return (notes.isEmpty, notes)
    }
}

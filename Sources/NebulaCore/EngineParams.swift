import Foundation

/// Concrete parameters consumed by the Metal shader chain (design §5), derived
/// purely from a `LookState`. Keeping this mapping here — not in the shader or
/// the UI — means preview, export, and manifest all agree by construction, and
/// the mapping is unit-testable without a GPU.
///
/// The shader chain is:
/// ```
/// lerp(starless, denoisedStarless, denoiseBlend) + starFlux·starWeight
///   → blackPoint(blackPoint)
///   → ghs(D: glowD, SP: contrastSP)
///   → saturateMidtones(saturation)
///   → bilateral(smoothStrength) → localContrast(detailStrength)
///   → screen(image, starLayerBloom(starD) · starWeight)   // Star Size only
/// ```
/// Star presence is linear in the real star flux, so Stars=1 reconstructs the
/// master exactly and lower values only dim the true stars — separation
/// imperfections can never blur the image.
public struct EngineParams: Equatable, Sendable {
    /// master ↔ denoised blend, `0` = raw master, `1` = fully denoised.
    public var denoiseBlend: Float
    /// Edge-preserving GPU smoothing on the starless nebula. The baked AI layer
    /// is subtle on a deep stack, so the top of the Denoise slider adds real,
    /// visible smoothing; stars are recombined afterwards and stay sharp.
    public var smoothStrength: Float
    /// Preserved master ↔ calibrated/background-corrected alternative.
    public var correctionBlend: Float
    /// Small background trim around a neutral midpoint. Positive values darken;
    /// negative values lift. This is deliberately not a large black-point clip.
    public var blackPoint: Float
    /// Generalised hyperbolic stretch strength (D) on the starless layer.
    public var glowD: Float
    /// GHS symmetry point (SP) — the pivot around which contrast pivots.
    public var contrastSP: Float
    /// Local-contrast (unsharp on starless) strength.
    public var detailStrength: Float
    /// Midtone saturation multiplier; background stays neutral.
    public var saturation: Float
    /// Star layer presence in the final screen recombine.
    public var starWeight: Float
    /// GHS strength (D) applied to the star layer — controls apparent star size.
    public var starD: Float
    /// Morphological star tightening (0 = none, 1 = strongest). Star Size below
    /// its midpoint erodes the real star flux before recombination, pulling in
    /// the stretched halo skirt; above the midpoint `starD` blooms as before.
    public var starShrink: Float

    /// Map a look to shader parameters. Ranges are chosen so the neutral look
    /// (all sliders at 0.5) is a pleasant, conservative starting point and the
    /// destructive directions (Detail, Denoise) dial *down* by default.
    public init(_ look: LookState) {
        let glow       = Float(look[.glow])
        let colour     = Float(look[.colour])
        let stars      = Float(look[.stars])
        let contrast   = Float(look[.contrast])
        let background = Float(look[.background])
        let detail     = Float(look[.detail])
        let starSize   = Float(look[.starSize])
        let denoise    = Float(look[.denoise])

        // Denoise is a straight blend, never a destructive bake. The bilateral
        // smoothing ramps in quadratically so the low half stays gentle while
        // the top half has clearly visible authority.
        denoiseBlend = denoise
        smoothStrength = denoise * denoise
        correctionBlend = background

        // The middle of the slider is neutral. The first 60% is a reversible
        // correction blend; the top 40% additionally trims the display black
        // point (up to 6%) for genuinely deep blacks on demand.
        blackPoint = max(background - 0.6, 0) * 0.15

        // Glow drives GHS stretch strength; SP (contrast) pivots the curve.
        glowD = glow * 3.5
        // `contrastSP` is retained in the GPU ABI, but now carries a conventional
        // contrast amount centred on 1 rather than a second midtone stretch.
        // Wide range so the top end crushes shadows into properly deep blacks.
        contrastSP = 0.4 + contrast * 1.2

        // Detail is local contrast; conservative ceiling so it can't overcook.
        detailStrength = detail * 0.9

        // Centre the control on truthful colour instead of making 0.5 arbitrary.
        // The shader applies boosts vibrance-style (chroma-protected), so the
        // wide top end enriches pale nebulosity without clipping strong colour.
        saturation = 0.2 + colour * 1.6

        // Stars recombine weight; Star Size is bidirectional around a neutral
        // midpoint: below 50 tightens the real star flux (shrink), above 50
        // blooms via the stretched star layer. At exactly 50 stars pass through
        // untouched, so preview == the captured stellar profiles.
        starWeight = stars
        starShrink = max(0.5 - starSize, 0) * 2
        starD = max(starSize - 0.5, 0) * 2 * 1.8
    }
}

extension LookState {
    /// The engine parameters for this look.
    public var engineParams: EngineParams { EngineParams(self) }
}

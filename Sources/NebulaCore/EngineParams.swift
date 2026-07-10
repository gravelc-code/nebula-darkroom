import Foundation

/// Concrete parameters consumed by the Metal shader chain (design §5), derived
/// purely from a `LookState`. Keeping this mapping here — not in the shader or
/// the UI — means preview, export, and manifest all agree by construction, and
/// the mapping is unit-testable without a GPU.
///
/// The shader chain is:
/// ```
/// lerp(master, denoised, denoiseBlend)
///   → blackPoint(blackPoint)
///   → ghs(D: glowD, SP: contrastSP)          // starless
///   → localContrast(detailStrength)
///   → saturateMidtones(saturation)
///   ─ stars: ghs(D: starD) · starWeight
///   → screen(starless, stars)
/// ```
public struct EngineParams: Equatable, Sendable {
    /// master ↔ denoised blend, `0` = raw master, `1` = fully denoised.
    public var denoiseBlend: Float
    /// Black-point clip applied to the starless layer, as a fraction of range.
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

        // Denoise is a straight blend, never a destructive bake.
        denoiseBlend = denoise

        // Background raises the black point; keep it gentle to avoid clipping signal.
        blackPoint = background * 0.15

        // Glow drives GHS stretch strength; SP (contrast) pivots the curve.
        glowD = glow * 6.0
        contrastSP = 0.1 + contrast * 0.5

        // Detail is local contrast; conservative ceiling so it can't overcook.
        detailStrength = detail * 1.5

        // Colour is midtone saturation; matches the mockup's ~2.2× ceiling.
        saturation = colour * 2.2

        // Stars recombine weight and their own stretch (apparent size).
        starWeight = stars
        starD = starSize * 4.0
    }
}

extension LookState {
    /// The engine parameters for this look.
    public var engineParams: EngineParams { EngineParams(self) }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
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
///   → saturation → vibrance → tint(green↔magenta) → warmth(blue↔amber)
///   → shadowNeutralize → bilateral(smoothStrength)
///   → localContrast(detailStrength) + structureBoost(structureStrength)
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
    /// Small-radius local contrast (unsharp on starless) — micro-detail "bite".
    public var detailStrength: Float
    /// Large-radius local contrast on the starless layer — the multi-scale
    /// structure boost that gives nebulosity depth and "pop". Sampled from coarse
    /// mip levels of the nebula so it swells real structure without amplifying
    /// grain; recombined chroma-preserving so colour is retained, and applied to
    /// the starless nebula only so stars never bloat or halo.
    public var structureStrength: Float
    /// Uniform midtone saturation multiplier (`1` = unchanged, `0` = greyscale);
    /// background stays neutral.
    public var saturation: Float
    /// Vibrance multiplier — a chroma-protected boost applied after saturation, so
    /// pale nebulosity enriches while already-saturated cores are held back.
    public var vibrance: Float
    /// Green↔magenta tint, `0.5` neutral. Below suppresses green harder (toward
    /// magenta); above restores and adds green. Drives the SCNR green balance.
    public var tint: Float
    /// Warmth (blue↔amber white balance), `0` cool … `1` warm, `0.5` neutral.
    /// The second white-balance axis alongside Tint: corrects the residual blue
    /// cast heavy red light-pollution leaves in the faint end after calibration.
    public var warmth: Float
    /// How strongly to pull deep-shadow colour toward neutral grey. Faint-signal
    /// colour is noise-dominated, so a gentle always-on neutralisation removes the
    /// blue-green shadow cast without touching real colour above the noise floor.
    public var shadowNeutralize: Float
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
        let sat        = Float(look[.saturation])
        let vib        = Float(look[.vibrance])
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

        // Detail now drives a *multi-scale* local contrast. The small-radius band
        // (bite) stays conservative so it can't crunch into noise, while the
        // large-radius structure band carries the visible "pop" — it swells real
        // nebula structure. Structure ramps quadratically so the bottom of the
        // slider stays gentle and the top has genuine authority; the shader clamps
        // the recovered signal, so this is a strength, not an unbounded gain.
        detailStrength = detail * 0.7
        structureStrength = detail * detail * 1.6

        // Colour is three independent controls, all neutral at the 0.5 midpoint.
        // Saturation is a uniform chroma scale: 0 → greyscale, 0.5 → truthful,
        // 1 → 2× for bold colour. Vibrance is a chroma-protected boost centred on
        // 1 (so it can also gently drain). Tint (green↔magenta) passes through as
        // a normalised value; the shader derives the green balance from it.
        saturation = sat * 2.0
        vibrance = 1.0 + (vib - 0.5) * 1.6
        tint = Float(look[.tint])
        warmth = Float(look[.warmth])
        // Always-on gentle shadow neutralisation, lifted a little more as the user
        // cleans the Background — deep-shadow colour is noise, and neutralising it
        // removes the residual blue-green cast without draining real signal colour.
        shadowNeutralize = 0.55 + background * 0.35

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

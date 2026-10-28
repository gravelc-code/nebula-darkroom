// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaCore

final class SliderTests: XCTestCase {
    func testHeadlineAndAdvancedSplit() {
        XCTAssertEqual(Slider.headline, [.glow, .saturation, .vibrance, .tint, .warmth, .stars])
        XCTAssertEqual(Set(Slider.advanced),
                       [.contrast, .background, .detail, .starSize, .denoise])
        XCTAssertEqual(Slider.allCases.count, 11)
    }

    func testActsOnMapping() {
        XCTAssertEqual(Slider.glow.actsOn, .starless)
        XCTAssertEqual(Slider.stars.actsOn, .recombine)
        XCTAssertEqual(Slider.starSize.actsOn, .stars)
        XCTAssertEqual(Slider.denoise.actsOn, .master)
    }

    func testNoJargonInLabels() {
        let banned = ["GHS", "SPCC", "sigma", "starless", "SP ", "black point"]
        for slider in Slider.allCases {
            for word in banned {
                XCTAssertFalse(slider.displayName.contains(word),
                               "\(slider.displayName) leaks jargon: \(word)")
            }
        }
    }
}

final class LookStateTests: XCTestCase {
    func testClampsToUnitInterval() {
        var look = LookState()
        look[.glow] = 5.0
        look[.saturation] = -2.0
        XCTAssertEqual(look[.glow], 1.0)
        XCTAssertEqual(look[.saturation], 0.0)
    }

    func testPercentInitAndReadback() {
        let look = LookState(percent: [.glow: 60, .stars: 65])
        XCTAssertEqual(look.percent(.glow), 60)
        XCTAssertEqual(look.percent(.stars), 65)
        // Unspecified sliders default to the neutral midpoint.
        XCTAssertEqual(look.percent(.detail), 50)
    }

    func testCodableRoundTripIsFlatAndStable() throws {
        let look = LookState.default
        let data = try JSONEncoder().encode(look)
        let json = String(decoding: data, as: UTF8.self)
        // Encoded as a flat object keyed by slider raw values.
        XCTAssertTrue(json.contains("\"glow\""))
        let decoded = try JSONDecoder().decode(LookState.self, from: data)
        XCTAssertEqual(decoded, look)
    }
}

final class CanonicalLookTests: XCTestCase {
    func testNeutralIsATruthfulMasterFirstBaseline() {
        let n = LookState.neutral
        XCTAssertEqual(n.percent(.glow), 0)
        XCTAssertEqual(n.percent(.saturation), 50)     // colour trio all neutral
        XCTAssertEqual(n.percent(.vibrance), 50)
        XCTAssertEqual(n.percent(.tint), 50)
        XCTAssertEqual(n.percent(.warmth), 50)
        XCTAssertEqual(n.percent(.stars), 100)
        XCTAssertEqual(n.percent(.background), 0)
        XCTAssertEqual(n.percent(.detail), 0)
        XCTAssertEqual(n.percent(.starSize), 50)       // bidirectional: 50 = natural
        XCTAssertEqual(n.percent(.denoise), 0)
    }

    func testDefaultIsADevelopedStartingLook() {
        let d = LookState.default
        // The one-tap opening look must actually develop the image: faint signal
        // lifted, structure boosted, colour enriched — not the truthful baseline.
        XCTAssertGreaterThan(d[.glow], 0.2)
        XCTAssertGreaterThan(d[.detail], 0.2)
        XCTAssertGreaterThan(d[.saturation], 0.5)
        XCTAssertGreaterThan(d[.background], 0.2)
        XCTAssertNotEqual(d, LookState.neutral)
        // Every value stays in range.
        for slider in Slider.allCases { XCTAssert((0...1).contains(d[slider])) }
    }
}

final class ProfileTests: XCTestCase {
    func testGuessFromHints() {
        XCTAssertEqual(Profile.guess(filter: "LP", objectType: nil), .broadbandNebula)
        XCTAssertEqual(Profile.guess(filter: "Duo-band", objectType: nil), .narrowbandDuoband)
        XCTAssertEqual(Profile.guess(filter: nil, objectType: "Spiral galaxy"), .galaxy)
        XCTAssertEqual(Profile.guess(filter: "LP", objectType: "open cluster"), .starCluster)
        XCTAssertEqual(Profile.guess(filter: nil, objectType: nil), .broadbandNebula)
        XCTAssertEqual(Profile.guess(filter: "IRCUT", objectType: "M 83"), .galaxy)
        XCTAssertEqual(Profile.guess(filter: "LP", objectType: "M 27"), .broadbandNebula)
    }

    func testInitialLooksAreValid() {
        for profile in Profile.allCases {
            for slider in Slider.allCases {
                let v = profile.initialLook[slider]
                XCTAssert((0...1).contains(v), "\(profile) \(slider) out of range: \(v)")
            }
        }
    }
}

final class EngineParamsTests: XCTestCase {
    func testNeutralLookIsConservative() {
        let p = LookState().engineParams   // all sliders at 0.5
        XCTAssertEqual(p.denoiseBlend, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.saturation, 1.0, accuracy: 1e-6)   // 0.5 → truthful colour
        XCTAssertEqual(p.vibrance, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.tint, 0.5, accuracy: 1e-6)         // green↔magenta neutral
        XCTAssertEqual(p.warmth, 0.5, accuracy: 1e-6)       // blue↔amber neutral
        XCTAssertEqual(p.glowD, expm1(1.5), accuracy: 1e-5)   // log-domain D → effective
        XCTAssertEqual(p.contrastSP, 0.01 + 0.25 * 0.12, accuracy: 1e-6)
        // Background 0.5 is still inside the correction-blend phase: no sky
        // is removed yet, and the corrected layer is not yet fully faded in.
        XCTAssertEqual(p.blackPoint, 0, accuracy: 1e-6)
        XCTAssertEqual(p.correctionBlend, 0.5 / 0.6, accuracy: 1e-6)
        XCTAssertEqual(p.starWeight, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.starD, 0, accuracy: 1e-6)       // Star Size midpoint: no bloom…
        XCTAssertEqual(p.starShrink, 0, accuracy: 1e-6)  // …and no shrink — stars as captured
    }

    func testNeutralDisablesCreativeAndDestructiveStages() {
        let p = LookState.neutral.engineParams
        XCTAssertEqual(p.denoiseBlend, 0, accuracy: 1e-6)
        XCTAssertEqual(p.smoothStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(p.correctionBlend, 0, accuracy: 1e-6)
        XCTAssertEqual(p.glowD, 0, accuracy: 1e-6)
        XCTAssertEqual(p.detailStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(p.structureStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(p.blackPoint, 0, accuracy: 1e-6)
        XCTAssertEqual(p.saturation, 1, accuracy: 1e-6)
        XCTAssertEqual(p.vibrance, 1, accuracy: 1e-6)
        XCTAssertEqual(p.tint, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.warmth, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.shadowNeutralize, 0, accuracy: 1e-6)     // finishing stages off…
        XCTAssertEqual(p.finishing, 0, accuracy: 1e-6)            // …at the truthful baseline
        XCTAssertEqual(p.starWeight, 1, accuracy: 1e-6)
        XCTAssertEqual(p.starD, 0, accuracy: 1e-6)
        XCTAssertEqual(p.starShrink, 0, accuracy: 1e-6)
    }

    func testStarSizeIsBidirectional() {
        var look = LookState()
        look[.starSize] = 0
        XCTAssertEqual(look.engineParams.starShrink, 1, accuracy: 1e-6)
        XCTAssertEqual(look.engineParams.starD, 0, accuracy: 1e-6)
        look[.starSize] = 0.25
        XCTAssertEqual(look.engineParams.starShrink, 0.5, accuracy: 1e-6)
        look[.starSize] = 0.75
        XCTAssertEqual(look.engineParams.starShrink, 0, accuracy: 1e-6)
        XCTAssertEqual(look.engineParams.starD, 0.9, accuracy: 1e-6)
    }

    func testDetailDrivesMultiScaleStructure() {
        var look = LookState()
        // Detail off: neither the small-radius bite nor the large-scale pop.
        look[.detail] = 0
        XCTAssertEqual(look.engineParams.detailStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(look.engineParams.structureStrength, 0, accuracy: 1e-6)
        // Structure ramps quadratically, so the bottom half stays gentle relative
        // to its top — half detail is a quarter of the full structure strength.
        look[.detail] = 0.5
        XCTAssertEqual(look.engineParams.detailStrength, 0.35, accuracy: 1e-6)
        XCTAssertEqual(look.engineParams.structureStrength, 0.4, accuracy: 1e-6)
        // Full detail: bite capped low, structure carries the visible authority.
        look[.detail] = 1
        XCTAssertEqual(look.engineParams.detailStrength, 0.7, accuracy: 1e-6)
        XCTAssertEqual(look.engineParams.structureStrength, 1.6, accuracy: 1e-6)
    }

    func testExtremesStayBounded() {
        let maxLook = LookState(Dictionary(uniqueKeysWithValues: Slider.allCases.map { ($0, 1.0) }))
        let p = maxLook.engineParams
        XCTAssertEqual(p.saturation, 2.0, accuracy: 1e-6)
        XCTAssertEqual(p.vibrance, 1.8, accuracy: 1e-6)
        XCTAssertEqual(p.tint, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.warmth, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.shadowNeutralize, 0.5, accuracy: 1e-6)   // 0.25 + 1.0*0.25
        XCTAssertEqual(p.detailStrength, 0.7, accuracy: 1e-6)
        XCTAssertEqual(p.structureStrength, 1.6, accuracy: 1e-6)
        XCTAssertEqual(p.glowD, expm1(3.0), accuracy: 1e-4)
        XCTAssertEqual(p.contrastSP, 0.13, accuracy: 1e-6)
        // Background at full removes 70% of the sky — never all of it.
        XCTAssertEqual(p.blackPoint, 0.70, accuracy: 1e-6)
        XCTAssertEqual(p.correctionBlend, 1, accuracy: 1e-6)
        XCTAssertEqual(p.starD, 1.8, accuracy: 1e-6)
        XCTAssertEqual(p.starShrink, 0, accuracy: 1e-6)
        XCTAssertEqual(p.smoothStrength, 1, accuracy: 1e-6)
    }
}

final class ManifestLookVersionTests: XCTestCase {
    /// Slider semantics changed with the pipeline (Glow became a GHS D, Contrast
    /// a symmetry point), so a look saved by an older bake must not be replayed
    /// through the current engine — it would render something never chosen.
    func testStaleLooksFallBackToTheCurrentDefault() throws {
        let capture = CaptureStats(frameCount: 10, subExposureSeconds: 10)
        let target = Target(name: "M 83", subsPath: "/tmp", capture: capture, profile: .galaxy)
        var saved = LookState.neutral
        saved[.glow] = 0.81
        func manifest(_ version: Int) -> Manifest {
            Manifest(target: target, look: saved, colourMethod: .pcc, layers: [],
                     stageOutcomes: [StageOutcome(stage: "pipeline-v\(version)", succeeded: true)])
        }
        XCTAssertEqual(manifest(9).look(forPipelineVersion: 9), saved)
        XCTAssertEqual(manifest(7).look(forPipelineVersion: 9), .default)
    }
}

final class HonestIntegrationTests: XCTestCase {
    /// Registration and stack filtering routinely drop 10-35% of the imported
    /// frames. The figures shown must describe what was actually stacked.
    func testReportsWhatWasStackedNotWhatWasImported() {
        var s = CaptureStats(frameCount: 126, subExposureSeconds: 30,
                             totalIntegrationSeconds: 2600, hasMixedExposures: true)
        XCTAssertEqual(s.integrationSeconds, 2600)
        XCTAssertNil(s.stackedFramesNote)

        s.stackedFrameCount = 112
        s.stackedIntegrationSeconds = 2380
        XCTAssertEqual(s.integrationSeconds, 2380)
        XCTAssertEqual(s.stackedFramesNote, "Stacked 112 of 126 frames")
        XCTAssertTrue(s.placardMeta.contains("112"))
        XCTAssertFalse(s.placardMeta.contains("126"))
    }

    func testStackedFieldsSurviveAManifestRoundTrip() throws {
        var s = CaptureStats(frameCount: 30, subExposureSeconds: 10)
        s.stackedFrameCount = 19
        s.stackedIntegrationSeconds = 190
        let back = try JSONDecoder().decode(CaptureStats.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.stackedFrameCount, 19)
        XCTAssertEqual(back.stackedIntegrationSeconds, 190)
        // Older manifests without the fields still decode.
        let legacy = #"{"frameCount":30,"subExposureSeconds":10,"isBroadband":true,"hasMixedExposures":false}"#
        let old = try JSONDecoder().decode(CaptureStats.self, from: Data(legacy.utf8))
        XCTAssertNil(old.stackedFrameCount)
        XCTAssertEqual(old.integrationSeconds, 300)
    }
}

final class GHSTests: XCTestCase {
    /// The published-GHS invariants the shader relies on. The Metal ghsStretch
    /// mirrors `GHS.stretch` exactly — these tests guard the shared maths.
    func testEndpointsAndIdentity() {
        XCTAssertEqual(GHS.stretch(0, D: 5, b: GHS.b, SP: 0.13, HP: GHS.highlightProtect), 0, accuracy: 1e-6)
        XCTAssertEqual(GHS.stretch(1, D: 5, b: GHS.b, SP: 0.13, HP: GHS.highlightProtect), 1, accuracy: 1e-5)
        // D ≈ 0 is the identity (Glow slider at zero changes nothing).
        for x: Float in [0, 0.1, 0.4, 0.9] {
            XCTAssertEqual(GHS.stretch(x, D: 0, b: GHS.b, SP: 0.13, HP: GHS.highlightProtect), x, accuracy: 1e-6)
        }
    }

    /// Sweep the whole range the Glow/Contrast sliders can produce: every curve
    /// must stay monotonic and land on [0,1], or a slider could invert tones.
    func testMonotonicAndBoundedAcrossTheSliderRange() {
        for gi in 0...10 {
            for ci in 0...10 {
                let look = LookState(percent: [.glow: Double(gi) * 10, .contrast: Double(ci) * 10])
                let p = look.engineParams
                var prev: Float = -1
                for i in 0...100 {
                    let x = Float(i) / 100
                    let y = GHS.stretch(x, D: p.glowD, b: GHS.b, SP: p.contrastSP, HP: GHS.highlightProtect)
                    XCTAssertGreaterThanOrEqual(y, prev - 1e-5,
                        "not monotonic at x=\(x), glow=\(gi), contrast=\(ci)")
                    XCTAssert(y >= 0 && y <= 1, "out of range: \(y)")
                    XCTAssert(y.isFinite, "non-finite at glow=\(gi) contrast=\(ci)")
                    prev = y
                }
            }
        }
    }

    func testMonotonicAndC1AtSP() {
        var prev: Float = -1
        for i in 0...200 {
            let x = Float(i) / 200
            let y = GHS.stretch(x, D: 8, b: GHS.b, SP: 0.05, HP: GHS.highlightProtect)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-6, "not monotonic at \(x)")
            prev = y
        }
        // C1 across the symmetry point: one-sided slopes agree.
        let e: Float = 1e-4
        let sL = (GHS.stretch(0.05, D: 8, b: GHS.b, SP: 0.05, HP: GHS.highlightProtect)
                - GHS.stretch(0.05 - e, D: 8, b: GHS.b, SP: 0.05, HP: GHS.highlightProtect)) / e
        let sR = (GHS.stretch(0.05 + e, D: 8, b: GHS.b, SP: 0.05, HP: GHS.highlightProtect)
                - GHS.stretch(0.05, D: 8, b: GHS.b, SP: 0.05, HP: GHS.highlightProtect)) / e
        XCTAssertEqual(sL, sR, accuracy: max(sL, sR) * 0.02)
    }

    /// The engine applies the curve to the above-sky signal, so the sky floor
    /// itself is invariant under any Glow/Contrast setting.
    func testSkyAnchoredApplicationLeavesTheFloorAlone() {
        let f: Float = 0.124
        for (d, sp): (Float, Float) in [(1, 0.02), (5, 0.05), (19, 0.12)] {
            let y = f + (1 - f) * GHS.stretch(0, D: d, b: GHS.b, SP: sp, HP: GHS.highlightProtect)
            XCTAssertEqual(y, f, accuracy: 1e-6)
        }
    }
}

final class CaptureStatsTests: XCTestCase {
    func testIntegrationDescription() {
        let s = CaptureStats(frameCount: 288, subExposureSeconds: 10)
        XCTAssertEqual(s.integrationSeconds, 2880)
        XCTAssertEqual(s.integrationDescription, "48 min")
        XCTAssertEqual(s.placardMeta, "48 min integrated · 288 × 10s · broadband")
    }

    func testHoursFormatting() {
        let s = CaptureStats(frameCount: 432, subExposureSeconds: 10)  // 72 min
        XCTAssertEqual(s.integrationDescription, "1 h 12 min")
    }

    func testMixedExposureUsesExactIntegration() {
        let s = CaptureStats(frameCount: 4, subExposureSeconds: 30,
                             totalIntegrationSeconds: 80, hasMixedExposures: true)
        XCTAssertEqual(s.integrationSeconds, 80)
        XCTAssertTrue(s.placardMeta.contains("4 mixed exposures"))
    }
}

final class ManifestTests: XCTestCase {
    private func sampleManifest() -> Manifest {
        let target = Target(
            name: "Orion Nebula",
            catalogue: "M 42",
            subsPath: "/Seestar/M42_subs",
            capture: CaptureStats(frameCount: 288, subExposureSeconds: 10, filter: "LP"),
            profile: .broadbandNebula
        )
        let layers = BakedLayer.allCases.map {
            LayerRef(layer: $0, path: "\($0.rawValue).exr", format: .exr, width: 1400, height: 900)
        }
        return Manifest(target: target,
                        look: LookState.neutral,
                        colourMethod: .nativeWhiteBalance,
                        layers: layers,
                        stageOutcomes: [StageOutcome(stage: "plate-solve", succeeded: false,
                                                     fallback: "native-white-balance")],
                        // Whole-second date: ISO-8601 encoding is exact, so the
                        // round-trip is comparable to the millisecond.
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testJSONRoundTrip() throws {
        let manifest = sampleManifest()
        let data = try manifest.jsonData()
        let decoded = try Manifest(jsonData: data)
        XCTAssertEqual(decoded, manifest)
    }

    func testHasAllLayers() {
        XCTAssertTrue(sampleManifest().hasAllLayers)
    }

    func testMissingLayerDetected() {
        var m = sampleManifest()
        m.layers.removeLast()
        XCTAssertFalse(m.hasAllLayers)
        XCTAssertNil(m.layer(.stars))
    }
}

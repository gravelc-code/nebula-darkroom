// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaCore

final class SliderTests: XCTestCase {
    func testHeadlineAndAdvancedSplit() {
        XCTAssertEqual(Slider.headline, [.glow, .saturation, .vibrance, .tint, .stars])
        XCTAssertEqual(Set(Slider.advanced),
                       [.contrast, .background, .detail, .starSize, .denoise])
        XCTAssertEqual(Slider.allCases.count, 10)
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
        XCTAssertEqual(p.glowD, 1.75, accuracy: 1e-6)
        XCTAssertEqual(p.blackPoint, 0, accuracy: 1e-6)
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
        XCTAssertEqual(p.detailStrength, 0.7, accuracy: 1e-6)
        XCTAssertEqual(p.structureStrength, 1.6, accuracy: 1e-6)
        XCTAssertEqual(p.glowD, 3.5, accuracy: 1e-6)
        XCTAssertEqual(p.blackPoint, 0.06, accuracy: 1e-6)
        XCTAssertEqual(p.starD, 1.8, accuracy: 1e-6)
        XCTAssertEqual(p.starShrink, 0, accuracy: 1e-6)
        XCTAssertEqual(p.smoothStrength, 1, accuracy: 1e-6)
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

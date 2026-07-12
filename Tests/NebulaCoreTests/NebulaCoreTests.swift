import XCTest
@testable import NebulaCore

final class SliderTests: XCTestCase {
    func testHeadlineAndAdvancedSplit() {
        XCTAssertEqual(Slider.headline, [.glow, .colour, .stars])
        XCTAssertEqual(Set(Slider.advanced),
                       [.contrast, .background, .detail, .starSize, .denoise])
        XCTAssertEqual(Slider.allCases.count, 8)
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
        look[.colour] = -2.0
        XCTAssertEqual(look[.glow], 1.0)
        XCTAssertEqual(look[.colour], 0.0)
    }

    func testPercentInitAndReadback() {
        let look = LookState(percent: [.glow: 60, .stars: 65])
        XCTAssertEqual(look.percent(.glow), 60)
        XCTAssertEqual(look.percent(.stars), 65)
        // Unspecified sliders default to the neutral midpoint.
        XCTAssertEqual(look.percent(.detail), 50)
    }

    func testCodableRoundTripIsFlatAndStable() throws {
        let look = Preset.vivid.look
        let data = try JSONEncoder().encode(look)
        let json = String(decoding: data, as: UTF8.self)
        // Encoded as a flat object keyed by slider raw values.
        XCTAssertTrue(json.contains("\"glow\""))
        let decoded = try JSONDecoder().decode(LookState.self, from: data)
        XCTAssertEqual(decoded, look)
    }
}

final class PresetTests: XCTestCase {
    func testAutoIsAConservativeMasterFirstBaseline() {
        let auto = Preset.auto.look
        XCTAssertEqual(auto.percent(.glow), 0)
        XCTAssertEqual(auto.percent(.colour), 50)
        XCTAssertEqual(auto.percent(.stars), 100)
        XCTAssertEqual(auto.percent(.background), 0)
        XCTAssertEqual(auto.percent(.detail), 0)
        XCTAssertEqual(auto.percent(.starSize), 50)   // bidirectional: 50 = natural
        XCTAssertEqual(auto.percent(.denoise), 0)
    }

    func testMatchingIdentifiesPreset() {
        XCTAssertEqual(Preset.matching(Preset.deep.look), .deep)
        var edited = Preset.deep.look
        edited[.glow] = edited[.glow] + 0.01
        XCTAssertNil(Preset.matching(edited))
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
        XCTAssertEqual(p.saturation, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.glowD, 1.75, accuracy: 1e-6)
        XCTAssertEqual(p.blackPoint, 0, accuracy: 1e-6)
        XCTAssertEqual(p.starWeight, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.starD, 0, accuracy: 1e-6)       // Star Size midpoint: no bloom…
        XCTAssertEqual(p.starShrink, 0, accuracy: 1e-6)  // …and no shrink — stars as captured
    }

    func testAutoDisablesCreativeAndDestructiveStages() {
        let p = Preset.auto.look.engineParams
        XCTAssertEqual(p.denoiseBlend, 0, accuracy: 1e-6)
        XCTAssertEqual(p.smoothStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(p.correctionBlend, 0, accuracy: 1e-6)
        XCTAssertEqual(p.glowD, 0, accuracy: 1e-6)
        XCTAssertEqual(p.detailStrength, 0, accuracy: 1e-6)
        XCTAssertEqual(p.blackPoint, 0, accuracy: 1e-6)
        XCTAssertEqual(p.saturation, 1, accuracy: 1e-6)
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

    func testExtremesStayBounded() {
        let maxLook = LookState(Dictionary(uniqueKeysWithValues: Slider.allCases.map { ($0, 1.0) }))
        let p = maxLook.engineParams
        XCTAssertEqual(p.saturation, 1.8, accuracy: 1e-6)
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
                        look: Preset.auto.look,
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

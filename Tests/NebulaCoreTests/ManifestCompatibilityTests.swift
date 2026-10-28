// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaCore

/// A manifest outlives the build that wrote it: the cache survives upgrades and
/// downgrades. These pin the promises that make that safe — user edits are
/// never silently dropped, and one unfamiliar value never sinks the whole file.
final class ManifestCompatibilityTests: XCTestCase {
    private func sample(pipeline: Int, look: LookState = .default,
                        lookVersion: Int? = nil) -> Manifest {
        let target = Target(name: "M 83", subsPath: "/tmp/M 83_sub",
                            capture: CaptureStats(frameCount: 10, subExposureSeconds: 10),
                            profile: .galaxy)
        let layers = BakedLayer.allCases.map {
            LayerRef(layer: $0, path: "\($0.rawValue).fits", format: .fits, width: 64, height: 48)
        }
        return Manifest(target: target, look: look, colourMethod: .pcc, layers: layers,
                        stageOutcomes: [StageOutcome(stage: "pipeline-v\(pipeline)", succeeded: true)],
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                        lookVersion: lookVersion)
    }

    private var edited: LookState {
        var look = LookState.default
        look[.glow] = 0.81
        look[.warmth] = 0.33
        return look
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: lookVersion (audit item 24)

    func testALookSavedInTheCurrentEngineSurvivesOnAnOlderBake() throws {
        // The bake predates the current pipeline, but the user edited it in
        // today's engine: reopening must show their edit, not the default.
        var m = sample(pipeline: 7)
        let data = try Manifest.updatingLook(edited, lookVersion: 8, in: m.jsonData())
        m = try Manifest(jsonData: data)
        XCTAssertEqual(m.lookVersion, 8)
        XCTAssertEqual(m.look(forPipelineVersion: 8), edited)
        // …but a look authored for another engine is still not replayed.
        XCTAssertEqual(m.look(forPipelineVersion: 9), .default)
    }

    func testALookStampedForAnotherEngineFallsBackEvenOnACurrentBake() {
        let m = sample(pipeline: 8, look: edited, lookVersion: 7)
        XCTAssertEqual(m.look(forPipelineVersion: 8), .default)
    }

    func testUnstampedLooksKeepTheOldRule() throws {
        XCTAssertEqual(sample(pipeline: 8, look: edited).look(forPipelineVersion: 8), edited)
        XCTAssertEqual(sample(pipeline: 7, look: edited).look(forPipelineVersion: 8), .default)
        // Old manifests have no field at all and still decode.
        let old = sample(pipeline: 8, look: edited)
        let json = try old.jsonData()
        XCTAssertNil(try object(json)["lookVersion"], "unset lookVersion leaves the JSON unchanged")
        XCTAssertNil(try Manifest(jsonData: json).lookVersion)
    }

    func testUpdatingLookMatchesTheTypedEncodingByteForByte() throws {
        let m = sample(pipeline: 8)
        var expected = m
        expected.look = edited
        expected.lookVersion = 8
        let patched = try Manifest.updatingLook(edited, lookVersion: 8, in: m.jsonData())
        XCTAssertEqual(String(decoding: patched, as: UTF8.self),
                       String(decoding: try expected.jsonData(), as: UTF8.self))
    }

    // MARK: Lenient reading (audit item 37)

    func testUnknownEnumValuesDoNotSinkTheManifest() throws {
        var json = try object(sample(pipeline: 8, look: edited).jsonData())
        json["colourMethod"] = "spectralFutureMethod"
        var layers = try XCTUnwrap(json["layers"] as? [[String: Any]])
        layers.append(["layer": "hdrPreview", "path": "hdr.fits", "format": "fits",
                       "width": 64, "height": 48])
        layers.append(["layer": "master", "path": "master.jxl", "format": "jxl",
                       "width": 64, "height": 48])
        json["layers"] = layers
        var target = try XCTUnwrap(json["target"] as? [String: Any])
        target["profile"] = "planetaryNebula"
        json["target"] = target

        let m = try Manifest(jsonData: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(m.colourMethod, .nativeWhiteBalance, "unknown method claims no calibration")
        XCTAssertEqual(m.layers.count, BakedLayer.allCases.count, "unknown entries are skipped")
        XCTAssertTrue(m.layers.allSatisfy { $0.format == .fits })
        XCTAssertTrue(m.hasAllLayers)
        XCTAssertEqual(m.target.profile, .broadbandNebula)
        XCTAssertEqual(m.target.name, "M 83")
        XCTAssertEqual(m.pipelineVersion, 8)
        XCTAssertEqual(m.look(forPipelineVersion: 8), edited, "the user's look survives")
    }

    func testANewerSchemaIsReadNotTreatedAsGarbage() throws {
        var json = try object(sample(pipeline: 9, look: edited).jsonData())
        json["schemaVersion"] = 2
        json["futureField"] = ["anything": [1, 2, 3]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let m = try Manifest(jsonData: data)
        XCTAssertTrue(m.isNewerSchema)
        XCTAssertTrue(m.hasAllLayers)
        XCTAssertEqual(m.pipelineVersion, 9)

        // Saving a look into it keeps what this build doesn't understand.
        let patched = try object(Manifest.updatingLook(edited, lookVersion: 8, in: data))
        XCTAssertEqual(patched["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(patched["futureField"])
        XCTAssertEqual(patched["lookVersion"] as? Int, 8)
    }

    func testAnUnreadableNewerSchemaSaysSo() throws {
        let json: [String: Any] = ["schemaVersion": 3, "somethingElse": true]
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertThrowsError(try Manifest(jsonData: data)) { error in
            XCTAssertEqual(error as? Manifest.ReadError, .newerSchema(3))
        }
        // The same damage in a current-schema file is just a decoding error.
        let current = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1])
        XCTAssertThrowsError(try Manifest(jsonData: current)) { error in
            XCTAssertNil(error as? Manifest.ReadError)
        }
    }

    func testThePrototypeFixtureStillPatchesAndReads() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prototype_manifest",
                                                  withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let before = try Manifest(jsonData: data)
        let after = try Manifest(jsonData: Manifest.updatingLook(edited, lookVersion: 8, in: data))
        XCTAssertEqual(after.look, edited)
        XCTAssertEqual(after.lookVersion, 8)
        XCTAssertEqual(after.target, before.target)
        XCTAssertEqual(after.layers, before.layers)
        XCTAssertEqual(after.stageOutcomes, before.stageOutcomes)
        XCTAssertEqual(after.createdAt, before.createdAt)
    }
}

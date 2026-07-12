import XCTest
@testable import NebulaCore

/// Proves the Phase 0 Python prototype and the Swift core agree on the manifest
/// schema: a `manifest.json` emitted by `prototype/bake.py` must decode into
/// `NebulaCore.Manifest` without loss. Regenerate the fixture with:
///   cd prototype && .venv/bin/python bake.py <subs> --from-master <m> --out out/X
///   cp out/X/manifest.json ../Tests/NebulaCoreTests/Fixtures/prototype_manifest.json
final class ManifestFixtureTests: XCTestCase {
    private func loadFixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "prototype_manifest",
                              withExtension: "json",
                              subdirectory: "Fixtures"),
            "prototype_manifest.json fixture missing from test bundle"
        )
        return try Data(contentsOf: url)
    }

    func testPrototypeManifestDecodes() throws {
        let manifest = try Manifest(jsonData: try loadFixture())

        XCTAssertEqual(manifest.schemaVersion, Manifest.currentSchemaVersion)
        XCTAssertTrue(manifest.hasAllLayers)
        XCTAssertEqual(manifest.colourMethod, .nativeWhiteBalance)
        XCTAssertEqual(manifest.target.profile, .broadbandNebula)
        XCTAssertEqual(manifest.target.catalogue, "M 42")
        XCTAssertEqual(manifest.target.capture.frameCount, 12)
        XCTAssertEqual(manifest.target.capture.subExposureSeconds, 10, accuracy: 1e-6)
        XCTAssertEqual(manifest.target.capture.filter, "LP")
        XCTAssertTrue(manifest.target.capture.isBroadband)

        // The look round-trips into the same 8 floats the engine will consume.
        XCTAssertEqual(manifest.look.percent(.glow), 60)
        XCTAssertEqual(manifest.look.percent(.stars), 65)

        // Every emitted layer resolves and carries dimensions.
        // Legacy v1 manifests predate the optional reversible correction layer.
        for kind in [BakedLayer.master, .denoised, .starless, .stars] {
            let ref = try XCTUnwrap(manifest.layer(kind))
            XCTAssertEqual(ref.format, .fits)
            XCTAssertGreaterThan(ref.width, 0)
            XCTAssertGreaterThan(ref.height, 0)
        }
    }

    func testEngineParamsDeriveFromDecodedLook() throws {
        let manifest = try Manifest(jsonData: try loadFixture())
        let params = manifest.look.engineParams
        // Sanity: derived shader params are in the expected bounded ranges.
        XCTAssertGreaterThanOrEqual(params.saturation, 0)
        XCTAssertLessThanOrEqual(params.saturation, 2.2)
        XCTAssertGreaterThanOrEqual(params.glowD, 0)
        XCTAssertLessThanOrEqual(params.glowD, 6)
    }
}

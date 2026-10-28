// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaAI

final class ModelLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func touch(_ rel: String) -> String {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return url.path
    }

    private func paths(env: [String: String] = [:]) -> ModelLocator.SearchPaths {
        ModelLocator.SearchPaths(environment: env, bundleResources: nil,
                                 nebulaModels: root.appendingPathComponent("Nebula/Models").path,
                                 devBuildModels: nil,
                                 graxpertData: root.appendingPathComponent("GraXpert").path)
    }

    // MARK: versions

    func testVersionParsing() {
        XCTAssertEqual(ModelVersion("3.0.2")?.components, [3, 0, 2])
        XCTAssertEqual(ModelVersion("v1.10.0")?.components, [1, 10, 0])
        XCTAssertEqual(ModelVersion("1.0.0.1")?.components, [1, 0, 0, 1])
        for bad in ["Models", "1.0", "3", "1..0", "1.0.0-beta", "", "a.b.c", ".DS_Store", "1.0.0 "] {
            XCTAssertNil(ModelVersion(bad), bad)
        }
    }

    /// The bug: a string sort put "1.9.0" above "1.10.0".
    func testVersionsCompareNumerically() {
        XCTAssertGreaterThan(ModelVersion("1.10.0")!, ModelVersion("1.9.0")!)
        XCTAssertGreaterThan(ModelVersion("3.0.2")!, ModelVersion("3.0.1")!)
        XCTAssertGreaterThan(ModelVersion("10.0.0")!, ModelVersion("9.9.9")!)
        XCTAssertEqual(ModelVersion("3.0.0.0")!, ModelVersion(3, 0, 0))
        XCTAssertEqual(Set([ModelVersion("3.0.0.0")!, ModelVersion(3, 0, 0)]).count, 1)
    }

    func testGraXpertCachePicksNewestNumericVersionWithAModel() {
        let base = "GraXpert/denoise-ai-models"
        _ = touch("\(base)/1.9.0/model.onnx")
        _ = touch("\(base)/1.10.0/model.onnx")
        _ = touch("\(base)/2.0.0/model.zip")          // half-downloaded: no model.onnx
        _ = touch("\(base)/notes.txt")
        let found = ModelLocator.locate(.denoise, in: paths())
        XCTAssertEqual(found?.version, ModelVersion(1, 10, 0))
        XCTAssertEqual(found?.source, .graxpertCache)
        XCTAssertTrue(found?.path.hasSuffix("denoise-ai-models/1.10.0/model.onnx") ?? false)
        XCTAssertEqual(ModelLocator.graxpertVersions(in: root.appendingPathComponent(base).path)
                        .map(\.version.description), ["1.10.0", "1.9.0"])
        XCTAssertNil(ModelLocator.locate(.backgroundExtraction, in: paths()))
    }

    func testSearchOrderAndVersionKnowledge() {
        _ = touch("GraXpert/bge-ai-models/1.0.1/model.onnx")
        XCTAssertEqual(ModelLocator.locate(.backgroundExtraction, in: paths())?.source, .graxpertCache)

        // Nebula's own Models folder beats the GraXpert cache; its file is unversioned.
        let home = touch("Nebula/Models/bge.onnx")
        let mine = ModelLocator.locate(.backgroundExtraction, in: paths())
        XCTAssertEqual(mine, LocatedModel(path: home, version: nil, source: .nebulaModels))

        // The env override beats both; a missing env file is ignored.
        let custom = touch("elsewhere/my-bge.onnx")
        XCTAssertEqual(ModelLocator.locate(.backgroundExtraction,
                                           in: paths(env: ["NEBULA_BGE_MODEL": custom]))?.path, custom)
        XCTAssertEqual(ModelLocator.locate(.backgroundExtraction,
                                           in: paths(env: ["NEBULA_BGE_MODEL": custom + ".gone"]))?.path, home)

        // An env path into a GraXpert version dir still knows its version.
        let old = touch("GraXpert/denoise-ai-models/1.1.0/model.onnx")
        XCTAssertEqual(ModelLocator.locate(.denoise, in: paths(env: ["NEBULA_DENOISE_MODEL": old]))?.version,
                       ModelVersion(1, 1, 0))
        // The generic (Baker) form picks the same file name rule as before.
        XCTAssertEqual(ModelLocator.locate(graxpertDirectory: "bge-ai-models",
                                           environmentVariable: "NEBULA_BGE_MODEL", in: paths())?.path, home)
    }

    func testVersionFromModelPath() {
        XCTAssertEqual(ModelLocator.version(ofModelAt: "/x/GraXpert/denoise-ai-models/3.0.2/model.onnx"),
                       ModelVersion(3, 0, 2))
        XCTAssertNil(ModelLocator.version(ofModelAt: "/x/Nebula/Models/denoise.onnx"))
    }

    // MARK: denoise threshold + batch

    /// GraXpert denoising.py:33-36 — 1.0 for the 1.0.0/1.1.0 models, else 10.
    func testDenoiseThresholdFollowsModelVersion() {
        XCTAssertEqual(Denoiser.modelThreshold(for: ModelVersion(1, 0, 0)), 1)
        XCTAssertEqual(Denoiser.modelThreshold(for: ModelVersion(1, 1, 0)), 1)
        XCTAssertEqual(Denoiser.modelThreshold(for: ModelVersion(2, 0, 0)), 10)
        XCTAssertEqual(Denoiser.modelThreshold(for: ModelVersion(3, 0, 2)), 10)
        XCTAssertEqual(Denoiser.modelThreshold(for: nil), 10)       // unversioned: today's behaviour
    }

    func testDenoiserReadsVersionFromItsPath() throws {
        let model = OnnxFixture.identity()
        let old = root.appendingPathComponent("GraXpert/denoise-ai-models/1.1.0/model.onnx")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try model.write(to: old)
        let plain = root.appendingPathComponent("denoise.onnx")
        try model.write(to: plain)
        XCTAssertEqual(try Denoiser(modelPath: old.path).modelThreshold, 1)
        XCTAssertEqual(try Denoiser(modelPath: plain.path).modelThreshold, 10)
        XCTAssertEqual(try Denoiser(modelPath: plain.path, modelVersion: ModelVersion(1, 0, 0)).modelThreshold, 1)
    }

    /// 2.62 GB peak RSS at batch 8 vs 1.82 GB at 4 → 4 below 16 GB of RAM.
    func testBatchSizeFollowsPhysicalMemory() {
        let gib: UInt64 = 1 << 30
        XCTAssertEqual(Denoiser.defaultBatchSize(physicalMemory: 8 * gib), 4)
        XCTAssertEqual(Denoiser.defaultBatchSize(physicalMemory: 16 * gib - 1), 4)
        XCTAssertEqual(Denoiser.defaultBatchSize(physicalMemory: 16 * gib), 8)
        XCTAssertEqual(Denoiser.defaultBatchSize(physicalMemory: 64 * gib), 8)
    }
}

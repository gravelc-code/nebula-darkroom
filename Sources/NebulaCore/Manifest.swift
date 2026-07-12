// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// The four floating-point layers emitted by the bake (design §4 step 9).
public enum BakedLayer: String, CaseIterable, Codable, Sendable {
    case master
    /// Reversible calibrated / gradient-corrected alternative to `master`.
    case corrected
    case denoised
    case starless
    case stars
}

/// On-disk float layer format. FITS is what Siril emits; EXR (half-float) is the
/// compact cache format that maps 1:1 to a Metal RGBA16F texture.
public enum LayerFormat: String, Codable, Sendable {
    case fits
    case exr
}

/// A reference to one emitted layer file.
public struct LayerRef: Codable, Equatable, Sendable {
    public var layer: BakedLayer
    public var path: String
    public var format: LayerFormat
    public var width: Int
    public var height: Int

    public init(layer: BakedLayer, path: String, format: LayerFormat, width: Int, height: Int) {
        self.layer = layer
        self.path = path
        self.format = format
        self.width = width
        self.height = height
    }
}

/// Which colour method actually ran — records the silent fallback chain
/// (design §4 step 5: spcc → pcc → native white-balance).
public enum ColourMethod: String, Codable, Sendable {
    case spcc
    case pcc
    case nativeWhiteBalance
}

/// A bake stage's outcome, recording whether a fallback was taken. Never scraped
/// from stdout — written explicitly by the orchestrator (design §1).
public struct StageOutcome: Codable, Equatable, Sendable {
    public var stage: String
    public var succeeded: Bool
    /// If a fallback path was used, a short machine-readable note (never shown raw
    /// to the user — the user only ever sees a good image).
    public var fallback: String?

    public init(stage: String, succeeded: Bool, fallback: String? = nil) {
        self.stage = stage
        self.succeeded = succeeded
        self.fallback = fallback
    }
}

/// The typed bake manifest — the structured contract handed from Stage A (bake)
/// to Stage B (play). File + typed manifest IPC, never scraped stdout.
///
/// The whole look is ~8 floats saved here, making a bake reproducible and a look
/// shareable as a preset.
public struct Manifest: Codable, Equatable, Sendable {
    /// Bumped when the on-disk schema changes; readers reject unknown majors.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    public var target: Target
    /// The look applied when the bake finished (profile's initial look, unless
    /// the user has since edited it).
    public var look: LookState
    /// Colour method that actually ran (fallback-aware).
    public var colourMethod: ColourMethod
    /// The four emitted layers.
    public var layers: [LayerRef]
    /// Per-stage outcomes, for diagnostics and the robustness suite.
    public var stageOutcomes: [StageOutcome]

    public init(target: Target,
                look: LookState,
                colourMethod: ColourMethod,
                layers: [LayerRef],
                stageOutcomes: [StageOutcome] = [],
                createdAt: Date = Date(),
                schemaVersion: Int = Manifest.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.target = target
        self.look = look
        self.colourMethod = colourMethod
        self.layers = layers
        self.stageOutcomes = stageOutcomes
    }

    /// Look up a specific layer reference.
    public func layer(_ kind: BakedLayer) -> LayerRef? {
        layers.first { $0.layer == kind }
    }

    /// True when all four layers are present — the precondition for Stage B.
    public var hasAllLayers: Bool {
        let present = Set(layers.map(\.layer))
        return Set([.master, .denoised, .starless, .stars]).isSubset(of: present)
    }

    // MARK: JSON round-trip helpers (the on-disk `manifest.json`)

    public static func makeJSONEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeJSONDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func jsonData() throws -> Data {
        try Manifest.makeJSONEncoder().encode(self)
    }

    public init(jsonData data: Data) throws {
        self = try Manifest.makeJSONDecoder().decode(Manifest.self, from: data)
    }
}

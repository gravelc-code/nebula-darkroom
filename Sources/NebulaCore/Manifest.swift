// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// The floating-point layers emitted by the bake (design §4 step 9).
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
/// The whole look is ~11 floats saved here, making a bake reproducible and a
/// look shareable.
///
/// Reading is deliberately forgiving. A manifest outlives the app that wrote it
/// (the cache survives upgrades *and* downgrades), so one value this build
/// doesn't know — a new colour method, layer kind, layer format or profile —
/// must not make the whole file unreadable: that used to reset the user's look,
/// drop their edits and flag the target for a pointless re-develop. Unknown
/// layers are skipped, an unknown colour method or profile falls back to the
/// most conservative known one, and `schemaVersion` is checked explicitly.
public struct Manifest: Codable, Equatable, Sendable {
    /// Bumped when the on-disk schema changes incompatibly.
    public static let currentSchemaVersion = 1

    /// Why a manifest could not be read at all.
    public enum ReadError: Error, Equatable, CustomStringConvertible {
        /// Written by a newer Nebula with a schema this build cannot interpret.
        case newerSchema(Int)

        public var description: String {
            switch self {
            case .newerSchema(let v):
                return "manifest schema \(v) is newer than this build's \(Manifest.currentSchemaVersion)"
            }
        }
    }

    public var schemaVersion: Int
    public var createdAt: Date
    public var target: Target
    /// The look to open with: the profile's initial look from the bake, or the
    /// user's last edit.
    public var look: LookState
    /// The engine version `look` was authored for. The app stamps it with the
    /// current `Baker.pipelineVersion` whenever it saves the user's look; the
    /// bake leaves it unset, so its look belongs to the bake's own pipeline.
    /// Absent in manifests written before it existed.
    public var lookVersion: Int?
    /// Colour method that actually ran (fallback-aware).
    public var colourMethod: ColourMethod
    /// The emitted layers.
    public var layers: [LayerRef]
    /// Per-stage outcomes, for diagnostics and the robustness suite.
    public var stageOutcomes: [StageOutcome]

    public init(target: Target,
                look: LookState,
                colourMethod: ColourMethod,
                layers: [LayerRef],
                stageOutcomes: [StageOutcome] = [],
                createdAt: Date = Date(),
                schemaVersion: Int = Manifest.currentSchemaVersion,
                lookVersion: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.target = target
        self.look = look
        self.lookVersion = lookVersion
        self.colourMethod = colourMethod
        self.layers = layers
        self.stageOutcomes = stageOutcomes
    }

    /// True when a newer Nebula wrote this manifest. Its layers still open, but
    /// it must only ever be patched (`updatingLook`), never re-encoded whole —
    /// that would drop the fields this build doesn't know.
    public var isNewerSchema: Bool { schemaVersion > Self.currentSchemaVersion }

    /// Look up a specific layer reference.
    public func layer(_ kind: BakedLayer) -> LayerRef? {
        layers.first { $0.layer == kind }
    }

    /// The bake pipeline version this target was produced with, parsed from the
    /// `pipeline-vN` stage outcome. `nil` means a pre-versioned (very old) bake.
    /// The app compares this to `Baker.pipelineVersion` to flag stale targets.
    public var pipelineVersion: Int? {
        for outcome in stageOutcomes where outcome.stage.hasPrefix("pipeline-v") {
            if let n = Int(outcome.stage.dropFirst("pipeline-v".count)) { return n }
        }
        return nil
    }

    /// The look to open this bake with.
    ///
    /// A look authored for another engine version is **not portable**: the
    /// sliders were re-based on the published GHS in v8 (Glow became a log-domain
    /// D, Contrast the symmetry point, Background a fraction of the measured
    /// sky), so replaying those numbers through the current engine renders
    /// something the user never chose. Such a look opens on today's default.
    ///
    /// A look the user saved carries its own `lookVersion`, so edits made in the
    /// current engine survive even on a bake from an older pipeline (which is
    /// only flagged for re-develop). Without one, the look is the bake's own
    /// and belongs to the bake's pipeline.
    public func look(forPipelineVersion current: Int) -> LookState {
        (lookVersion ?? pipelineVersion) == current ? look : .default
    }

    /// True when all four layers are present — the precondition for Stage B.
    public var hasAllLayers: Bool {
        let present = Set(layers.map(\.layer))
        return Set([.master, .denoised, .starless, .stars]).isSubset(of: present)
    }

    // MARK: Lenient decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, createdAt, target, look, lookVersion
        case colourMethod, layers, stageOutcomes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? Self.currentSchemaVersion
        do {
            target = try Self.decodeTarget(c)
            layers = try c.decode([Lenient<LayerRef>].self, forKey: .layers).compactMap(\.value)
        } catch {
            // A newer schema we can't interpret says so, rather than looking
            // like a corrupt file.
            if schemaVersion > Self.currentSchemaVersion { throw ReadError.newerSchema(schemaVersion) }
            throw error
        }
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        look = (try? c.decodeIfPresent(LookState.self, forKey: .look)) ?? .default
        lookVersion = try? c.decodeIfPresent(Int.self, forKey: .lookVersion)
        // Diagnostic only: an unknown method claims no calibration at all.
        let method = try? c.decodeIfPresent(String.self, forKey: .colourMethod)
        colourMethod = method.flatMap(ColourMethod.init(rawValue:)) ?? .nativeWhiteBalance
        stageOutcomes = (try? c.decodeIfPresent([Lenient<StageOutcome>].self, forKey: .stageOutcomes))?
            .compactMap(\.value) ?? []
    }

    /// `Target` with an unknown profile falls back to the broadband default
    /// (`Profile.guess`'s own safe answer) instead of failing the manifest.
    private static func decodeTarget(_ c: KeyedDecodingContainer<CodingKeys>) throws -> Target {
        if let target = try? c.decode(Target.self, forKey: .target) { return target }
        var raw = try c.decode([String: JSONValue].self, forKey: .target)
        guard case .string(let profile)? = raw["profile"], Profile(rawValue: profile) == nil else {
            return try c.decode(Target.self, forKey: .target)   // rethrow the real problem
        }
        raw["profile"] = .string(Profile.broadbandNebula.rawValue)
        return try JSONDecoder().decode(Target.self, from: JSONEncoder().encode(raw))
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

    /// Replace only the look (and stamp its `lookVersion`) in an on-disk
    /// manifest, leaving every other byte's meaning untouched — including
    /// fields and enum values this build doesn't know. This is how the app
    /// saves edits: re-encoding the decoded struct would silently strip a newer
    /// Nebula's additions. Output formatting matches `jsonData()`.
    public static func updatingLook(_ look: LookState, lookVersion: Int,
                                    in data: Data) throws -> Data {
        guard case .object(var object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "manifest is not a JSON object"))
        }
        object["look"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(look))
        object["lookVersion"] = .int(lookVersion)
        return try makeJSONEncoder().encode(JSONValue.object(object))
    }
}

/// Decodes `T`, or nothing if this element can't be read (e.g. an enum value
/// from a newer build). Never throws, so an unkeyed container always advances.
private struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// A minimal JSON tree, so a manifest can be patched without losing anything
/// this build doesn't model. Numbers keep their integer-ness; doubles
/// round-trip exactly (shortest representation).
private enum JSONValue: Codable, Equatable {
    case null, bool(Bool), int(Int), double(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

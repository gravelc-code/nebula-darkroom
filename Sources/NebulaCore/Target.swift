// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Capture statistics parsed from the Seestar FITS headers. Surfaced in the UI
/// (the placard) so users attribute quality limits to capture, not the app
/// (design §0/§9).
public struct CaptureStats: Codable, Equatable, Sendable {
    /// Number of light sub-frames stacked.
    public var frameCount: Int
    /// Per-sub exposure in seconds (Seestar lights are 10 s).
    public var subExposureSeconds: Double
    /// Exact integration when a folder contains more than one exposure length.
    /// Older manifests omit this and retain the frameCount × subExposure fallback.
    public var totalIntegrationSeconds: Double?
    /// True when more than one exposure length was accepted into the stack.
    public var hasMixedExposures: Bool
    /// `FILTER` header value, if present (e.g. "LP", "IRCUT", "Duo-band").
    public var filter: String?
    /// Whether the capture is broadband (clear/LP) vs duo-band/narrowband.
    public var isBroadband: Bool
    /// Target right ascension / declination in degrees, from the header, if present.
    public var raDegrees: Double?
    public var decDegrees: Double?
    /// Sensor temperature in °C, if present.
    public var sensorTemperatureC: Double?

    public init(frameCount: Int,
                subExposureSeconds: Double,
                totalIntegrationSeconds: Double? = nil,
                hasMixedExposures: Bool = false,
                filter: String? = nil,
                isBroadband: Bool = true,
                raDegrees: Double? = nil,
                decDegrees: Double? = nil,
                sensorTemperatureC: Double? = nil) {
        self.frameCount = frameCount
        self.subExposureSeconds = subExposureSeconds
        self.totalIntegrationSeconds = totalIntegrationSeconds
        self.hasMixedExposures = hasMixedExposures
        self.filter = filter
        self.isBroadband = isBroadband
        self.raDegrees = raDegrees
        self.decDegrees = decDegrees
        self.sensorTemperatureC = sensorTemperatureC
    }

    /// Total integration time in seconds.
    public var integrationSeconds: Double {
        totalIntegrationSeconds ?? Double(frameCount) * subExposureSeconds
    }

    /// Human-readable integration time, e.g. "48 min" or "1 h 12 min".
    public var integrationDescription: String {
        let minutes = Int((integrationSeconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// The placard meta line, e.g. "48 min integrated · 288 × 10s · broadband".
    public var placardMeta: String {
        let sub = subExposureSeconds.rounded() == subExposureSeconds
            ? String(Int(subExposureSeconds))
            : String(subExposureSeconds)
        let band = isBroadband ? "broadband" : "narrowband"
        let frames = hasMixedExposures ? "\(frameCount) mixed exposures" : "\(frameCount) × \(sub)s"
        return "\(integrationDescription) integrated · \(frames) · \(band)"
    }
}

// Keep schema-1 manifests readable after mixed-exposure accounting was added.
extension CaptureStats {
    private enum CodingKeys: String, CodingKey {
        case frameCount, subExposureSeconds, totalIntegrationSeconds, hasMixedExposures
        case filter, isBroadband, raDegrees, decDegrees, sensorTemperatureC
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frameCount = try c.decode(Int.self, forKey: .frameCount)
        subExposureSeconds = try c.decode(Double.self, forKey: .subExposureSeconds)
        totalIntegrationSeconds = try c.decodeIfPresent(Double.self, forKey: .totalIntegrationSeconds)
        hasMixedExposures = try c.decodeIfPresent(Bool.self, forKey: .hasMixedExposures) ?? false
        filter = try c.decodeIfPresent(String.self, forKey: .filter)
        isBroadband = try c.decode(Bool.self, forKey: .isBroadband)
        raDegrees = try c.decodeIfPresent(Double.self, forKey: .raDegrees)
        decDegrees = try c.decodeIfPresent(Double.self, forKey: .decDegrees)
        sensorTemperatureC = try c.decodeIfPresent(Double.self, forKey: .sensorTemperatureC)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(frameCount, forKey: .frameCount)
        try c.encode(subExposureSeconds, forKey: .subExposureSeconds)
        try c.encodeIfPresent(totalIntegrationSeconds, forKey: .totalIntegrationSeconds)
        try c.encode(hasMixedExposures, forKey: .hasMixedExposures)
        try c.encodeIfPresent(filter, forKey: .filter)
        try c.encode(isBroadband, forKey: .isBroadband)
        try c.encodeIfPresent(raDegrees, forKey: .raDegrees)
        try c.encodeIfPresent(decDegrees, forKey: .decDegrees)
        try c.encodeIfPresent(sensorTemperatureC, forKey: .sensorTemperatureC)
    }
}

/// An imported target: a `<Name>_subs/` folder plus what we know about it.
public struct Target: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Display name, e.g. "Orion Nebula".
    public var name: String
    /// Catalogue designation if known, e.g. "M 42".
    public var catalogue: String?
    /// The `_subs` folder this target was imported from.
    public var subsPath: String
    public var capture: CaptureStats
    public var profile: Profile

    public init(id: UUID = UUID(),
                name: String,
                catalogue: String? = nil,
                subsPath: String,
                capture: CaptureStats,
                profile: Profile) {
        self.id = id
        self.name = name
        self.catalogue = catalogue
        self.subsPath = subsPath
        self.capture = capture
        self.profile = profile
    }
}

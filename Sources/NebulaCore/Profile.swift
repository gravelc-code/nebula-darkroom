// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// A profile = bake settings + a starting look (design §7). Auto-selected from
/// filter + object type, user-overridable in one tap.
public enum Profile: String, CaseIterable, Codable, Sendable {
    case galaxy
    case broadbandNebula
    case narrowbandDuoband
    case starCluster

    public var displayName: String {
        switch self {
        case .galaxy:            return "Galaxy"
        case .broadbandNebula:   return "Broadband Nebula"
        case .narrowbandDuoband: return "Narrowband / Duo-band"
        case .starCluster:       return "Star Cluster"
        }
    }

    /// The initial look applied when a target of this profile finishes baking —
    /// the pleasant, finished starting point the user then refines ("one tap → a
    /// developed image"). Profiles stay useful metadata; the default look gives
    /// every target the same developed opening regardless of type.
    public var initialLook: LookState {
        LookState.default
    }

    /// Best-guess profile from Seestar FITS header hints. Broadband nebula is the
    /// safe default when nothing else matches.
    ///
    /// - Parameters:
    ///   - filter: the `FILTER` header value (e.g. "LP", "IRCUT", "Duo-band"), if present.
    ///   - objectType: a coarse object classification if known (e.g. "galaxy", "cluster").
    public static func guess(filter: String?, objectType: String?) -> Profile {
        let f = filter?.lowercased() ?? ""
        let o = objectType?.lowercased() ?? ""

        if o.contains("galaxy") { return .galaxy }
        if o.contains("cluster") { return .starCluster }
        // Seestar normally puts a catalogue name ("M 83"), not an object type,
        // in OBJECT. Cover the Messier catalogue locally so Auto is useful
        // without a network lookup.
        let compact = o.uppercased().replacingOccurrences(of: " ", with: "")
        if compact.first == "M", let n = Int(compact.dropFirst()) {
            let galaxies: Set<Int> = [31,32,33,49,51,58,59,60,61,63,64,65,66,74,77,
                                      81,82,83,84,85,86,87,88,89,90,91,94,95,96,98,99,
                                      100,101,102,104,105,106,108,109,110]
            let nebulae: Set<Int> = [1,8,16,17,20,27,42,43,57,76,78,97]
            if galaxies.contains(n) { return .galaxy }
            if nebulae.contains(n) { return .broadbandNebula }
            if (2...110).contains(n) { return .starCluster }
        }
        if f.contains("duo") || f.contains("narrow") || f.contains("ha") || f.contains("oiii") {
            return .narrowbandDuoband
        }
        return .broadbandNebula
    }
}

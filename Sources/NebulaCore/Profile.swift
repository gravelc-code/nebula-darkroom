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

    /// The initial look applied when a target of this profile finishes baking.
    /// A starting point the user then refines; all four begin from `Auto` and
    /// nudge toward what each target type usually wants.
    public var initialLook: LookState {
        var look = Preset.auto.look
        switch self {
        case .galaxy:
            // Compact object: restrained glow, tighter stars, cleaner background.
            look[.glow] = 0.52
            look[.stars] = 0.55
            look[.starSize] = 0.40
            look[.background] = 0.60
        case .broadbandNebula:
            // Balanced default — closest to Auto.
            break
        case .narrowbandDuoband:
            // Duo-band: push colour and glow, hold stars back so nebulosity sings.
            look[.colour] = 0.68
            look[.glow] = 0.66
            look[.stars] = 0.50
        case .starCluster:
            // Stars are the subject: bright, present stars; gentle background.
            look[.stars] = 0.78
            look[.starSize] = 0.55
            look[.glow] = 0.45
            look[.colour] = 0.48
        }
        return look
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
        if f.contains("duo") || f.contains("narrow") || f.contains("ha") || f.contains("oiii") {
            return .narrowbandDuoband
        }
        return .broadbandNebula
    }
}

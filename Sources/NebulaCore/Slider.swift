import Foundation

/// The eight user-facing controls. Plain language only — never jargon.
///
/// Each case maps to an internal engine parameter and the layer it acts on
/// (design §6). The three non-advanced sliders are the headline front screen;
/// the rest live under "Advanced".
public enum Slider: String, CaseIterable, Codable, Sendable {
    case glow
    case colour
    case stars
    case contrast
    case background
    case detail
    case starSize
    case denoise

    /// The label shown to the user. Deliberately jargon-free.
    public var displayName: String {
        switch self {
        case .glow:       return "Glow"
        case .colour:     return "Colour"
        case .stars:      return "Stars"
        case .contrast:   return "Contrast"
        case .background: return "Background"
        case .detail:     return "Detail"
        case .starSize:   return "Star Size"
        case .denoise:    return "Denoise"
        }
    }

    /// The three headline sliders on the front screen; the rest are hidden
    /// behind the "Advanced" disclosure.
    public var isAdvanced: Bool {
        switch self {
        case .glow, .colour, .stars:
            return false
        default:
            return true
        }
    }

    /// Which baked layer this control ultimately acts on (design §6 table).
    public var actsOn: LayerKind {
        switch self {
        case .glow, .contrast, .background, .colour, .detail:
            return .starless
        case .starSize:
            return .stars
        case .stars:
            return .recombine
        case .denoise:
            return .master
        }
    }

    /// Headline sliders first, in display order.
    public static var headline: [Slider] { allCases.filter { !$0.isAdvanced } }
    /// Advanced sliders, in display order.
    public static var advanced: [Slider] { allCases.filter { $0.isAdvanced } }
}

/// The layer (or recombine stage) a slider acts on.
public enum LayerKind: String, Codable, Sendable {
    case master
    case denoised
    case starless
    case stars
    case recombine
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// The user-facing controls. Plain language only — never jargon.
///
/// Each case maps to an internal engine parameter and the layer it acts on
/// (design §6). The non-advanced sliders are the headline "feel" controls;
/// the rest live under "Refine".
public enum Slider: String, CaseIterable, Codable, Sendable {
    case glow
    case saturation
    case vibrance
    case tint
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
        case .saturation: return "Saturation"
        case .vibrance:   return "Vibrance"
        case .tint:       return "Tint"
        case .stars:      return "Stars"
        case .contrast:   return "Contrast"
        case .background: return "Background"
        case .detail:     return "Detail"
        case .starSize:   return "Star Size"
        case .denoise:    return "Denoise"
        }
    }

    /// The headline "feel" sliders shown up top (Glow, the colour trio, Stars);
    /// the rest are grouped under "Refine".
    public var isAdvanced: Bool {
        switch self {
        case .glow, .saturation, .vibrance, .tint, .stars:
            return false
        default:
            return true
        }
    }

    /// Which baked layer this control ultimately acts on (design §6 table).
    public var actsOn: LayerKind {
        switch self {
        case .glow, .contrast, .background, .saturation, .vibrance, .tint, .detail:
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

import Foundation

/// Presets are just named look states — "one tap, instantly previewed".
/// The starting values mirror the UI mockup (`seestar-ui-mockup.html`).
public enum Preset: String, CaseIterable, Codable, Sendable {
    case auto
    case natural
    case vivid
    case deep

    public var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .natural: return "Natural"
        case .vivid:   return "Vivid"
        case .deep:    return "Deep"
        }
    }

    /// The look this preset applies. Values on the `0...100` UI scale, matching
    /// the mockup's `PRESETS` table.
    public var look: LookState {
        LookState(percent: percentValues)
    }

    private var percentValues: [Slider: Double] {
        switch self {
        case .auto:
            return [.glow: 60, .colour: 55, .stars: 65, .contrast: 50,
                    .background: 55, .detail: 40, .starSize: 45, .denoise: 60]
        case .natural:
            return [.glow: 48, .colour: 40, .stars: 62, .contrast: 44,
                    .background: 48, .detail: 32, .starSize: 42, .denoise: 66]
        case .vivid:
            return [.glow: 70, .colour: 86, .stars: 72, .contrast: 64,
                    .background: 58, .detail: 52, .starSize: 50, .denoise: 56]
        case .deep:
            return [.glow: 84, .colour: 62, .stars: 44, .contrast: 60,
                    .background: 74, .detail: 64, .starSize: 40, .denoise: 72]
        }
    }

    /// The preset whose look exactly matches `state`, if any — lets the UI
    /// highlight the active preset chip and clear it once the user edits.
    public static func matching(_ state: LookState) -> Preset? {
        allCases.first { $0.look == state }
    }
}

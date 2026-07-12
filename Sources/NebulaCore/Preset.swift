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
            // Truthful baseline: only the robust statistical linear->display
            // stretch is active. Every creative/destructive stage starts off.
            // Star Size is bidirectional, so its "off" is the 50 midpoint.
            return [.glow: 0, .colour: 50, .stars: 100, .contrast: 50,
                    .background: 0, .detail: 0, .starSize: 50, .denoise: 0]
        case .natural:
            return [.glow: 48, .colour: 45, .stars: 62, .contrast: 50,
                    .background: 66, .detail: 32, .starSize: 45, .denoise: 60]
        case .vivid:
            return [.glow: 66, .colour: 82, .stars: 72, .contrast: 68,
                    .background: 84, .detail: 52, .starSize: 55, .denoise: 56]
        case .deep:
            return [.glow: 80, .colour: 66, .stars: 44, .contrast: 70,
                    .background: 92, .detail: 60, .starSize: 35, .denoise: 70]
        }
    }

    /// The preset whose look exactly matches `state`, if any — lets the UI
    /// highlight the active preset chip and clear it once the user edits.
    public static func matching(_ state: LookState) -> Preset? {
        allCases.first { $0.look == state }
    }
}

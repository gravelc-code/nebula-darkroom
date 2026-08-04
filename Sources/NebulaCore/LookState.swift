// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// The complete look: the ~8 floats that fully describe how a baked target is
/// rendered. This is the single source of truth shared by the Metal engine, the
/// UI sliders, and the manifest. It is small, `Codable`, and shareable as a preset.
///
/// Each value is normalised to `0...1`. The UI presents them on a `0...100`
/// scale (see `Slider` and the mockup); the engine consumes `EngineParams`
/// derived from these values.
public struct LookState: Codable, Equatable, Sendable {
    private var values: [Slider: Double]

    /// Create a look from per-slider normalised values (`0...1`). Missing
    /// sliders fall back to the neutral default (`0.5`).
    public init(_ values: [Slider: Double] = [:]) {
        var v: [Slider: Double] = [:]
        for slider in Slider.allCases {
            v[slider] = (values[slider] ?? 0.5).clamped01
        }
        self.values = v
    }

    /// Convenience initialiser from `0...100` UI values (as used by presets).
    public init(percent: [Slider: Double]) {
        self.init(percent.mapValues { $0 / 100.0 })
    }

    /// Normalised value (`0...1`) for a slider.
    public subscript(slider: Slider) -> Double {
        get { values[slider] ?? 0.5 }
        set { values[slider] = newValue.clamped01 }
    }

    /// The value on the UI's `0...100` scale, rounded — matches the number
    /// shown beside each slider in the mockup.
    public func percent(_ slider: Slider) -> Int {
        Int((self[slider] * 100).rounded())
    }
}

// MARK: - Canonical looks

extension LookState {
    /// The truthful baseline: only the robust statistical linear→display stretch
    /// is active, every creative and destructive stage off. This is the "before"
    /// reference (the raw stack made visible) — it must never alter real pixels.
    /// Colour is neutral (Saturation/Vibrance at the midpoint, Tint neutral).
    public static var neutral: LookState {
        LookState(percent: [.glow: 0, .saturation: 50, .vibrance: 50, .tint: 50,
                            .warmth: 50, .stars: 100, .contrast: 50, .background: 0,
                            .detail: 0, .starSize: 50, .denoise: 0])
    }

    /// The look a freshly baked target opens on — a pleasant, finished starting
    /// point ("one tap → a developed image") that the user then refines. Lifts
    /// faint signal (Glow), cleans the background, enriches colour, and brings in
    /// the multi-scale structure boost (Detail) so nebulosity has depth on open.
    public static var `default`: LookState {
        // Tuned on the full cached target set (galaxies, emission nebulae, a
        // planetary, a supernova remnant) against the published conventions:
        // background 0.05–0.14 display, neutral to within ~2/255, no channel
        // clipped at either end, white star cores with colour kept in the halo.
        //
        // Stars sit at 100 — the star layer is now validated to hold only
        // compact flux, so dimming it by default was throwing away real signal
        // (and, before the validator, part of the subject). Star Size just
        // below neutral tightens the display-ballooned halo without touching
        // the core. Warmth is neutral: it existed to hide a red-crushing
        // stretch bug that no longer exists.
        LookState(percent: [.glow: 47, .saturation: 55, .vibrance: 53, .tint: 50,
                            .warmth: 50, .stars: 100, .contrast: 58, .background: 60,
                            .detail: 55, .starSize: 42, .denoise: 55])
    }
}

extension Double {
    /// Clamp to the closed unit interval.
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - Codable as a flat [String: Double] for a stable, human-readable manifest

extension LookState {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([String: Double].self)
        var v: [Slider: Double] = [:]
        for (key, value) in raw {
            if let slider = Slider(rawValue: key) { v[slider] = value }
        }
        self.init(v)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        var raw: [String: Double] = [:]
        for slider in Slider.allCases { raw[slider.rawValue] = self[slider] }
        try container.encode(raw)
    }
}

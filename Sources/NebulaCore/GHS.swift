// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// The published Generalised Hyperbolic Stretch (D. Payne / M. Cranfield,
/// ghsastro.co.uk; the same closed forms Siril implements in `ght.c`),
/// restricted to the hyperbolic branch (b > 0) with LP = 0 — the shape Nebula
/// uses interactively. This CPU mirror exists so the shader's curve is
/// unit-testable without a GPU; `Shaders.swift` implements the identical maths.
///
/// The curve is evaluated on the *above-sky signal* t ∈ [0, 1]:
///   base           T(x)  = 1 − (1 + b·D·x)^(−1/b)
///   below SP       T2(t) = −T(SP − t)                  (odd reflection)
///   SP ≤ t < HP    T3(t) = T(t − SP)
///   t ≥ HP         T4(t) = T3(HP) + T3′(HP)·(t − HP)   (linear, protects cores)
///   f(t) = (Ti(t) − T2(0)) / (T4(1) − T2(0))           (f(0)=0, f(1)=1, C1)
public enum GHS {
    /// The effective strength for a log-domain slider value, per the published
    /// convention (PixInsight labels the slider "ln(D+1)"; Siril applies expm1).
    public static func effectiveD(_ logD: Float) -> Float { expm1(logD) }

    static func t(_ x: Float, _ D: Float, _ b: Float) -> Float {
        1 - powf(1 + D * b * x, -1 / b)
    }
    static func td(_ x: Float, _ D: Float, _ b: Float) -> Float {
        D * powf(1 + D * b * x, -(1 + b) / b)
    }

    /// The normalised piecewise stretch. `D` is the effective (linear-domain)
    /// strength; `D ≈ 0` is the identity.
    public static func stretch(_ x: Float, D: Float, b: Float, SP: Float, HP: Float) -> Float {
        let x = min(max(x, 0), 1)
        guard D > 1e-4 else { return x }
        let q0 = -t(SP, D, b)
        let q1 = t(HP - SP, D, b) + td(HP - SP, D, b) * (1 - HP)
        let q = 1 / max(q1 - q0, 1e-6)
        let Ti: Float
        if x < SP { Ti = -t(SP - x, D, b) }
        else if x < HP { Ti = t(x - SP, D, b) }
        else { Ti = t(HP - SP, D, b) + td(HP - SP, D, b) * (x - HP) }
        return min(max((Ti - q0) * q, 0), 1)
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaCore

/// The cosmetic finishing stages (shadow neutralisation, the neutral-Tint SCNR
/// floor, star-core whitening) are off in the truthful look and unchanged
/// wherever the gradient correction is fully in (Background ≥ 60).
final class FinishingStageTests: XCTestCase {
    func testTruthfulLookHasNoFinishing() {
        let p = LookState.neutral.engineParams
        XCTAssertEqual(p.finishing, 0)
        XCTAssertEqual(p.shadowNeutralize, 0)
    }

    func testDefaultLookFinishingUnchanged() {
        let p = LookState.default.engineParams          // Background 60
        XCTAssertEqual(p.finishing, 1)
        XCTAssertEqual(p.shadowNeutralize, 0.25 + 0.6 * 0.25, accuracy: 1e-6)
    }

    func testFinishingFollowsTheCorrectionPhaseOfBackground() {
        var look = LookState.default
        for bg in stride(from: 0.0, through: 1.0, by: 0.05) {
            look[.background] = bg
            let p = look.engineParams
            XCTAssertEqual(p.finishing, p.correctionBlend)
            if bg >= 0.6 {
                // Exactly the old mapping from Background 60 up.
                XCTAssertEqual(p.finishing, 1)
                XCTAssertEqual(p.shadowNeutralize, 0.25 + Float(bg) * 0.25, accuracy: 1e-6)
            } else {
                XCTAssertLessThan(p.finishing, 1)
            }
        }
    }
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaAI

final class NebulaAITests: XCTestCase {
    func testFaithfulResizePreservesConstantRGB() {
        let src = [Float](repeating: 0.25, count: 7 * 5 * 3)
        let result = SuperResolver.resizeBilinear(src, h: 5, w: 7, dh: 10, dw: 14)
        XCTAssertEqual(result.count, 10 * 14 * 3)
        XCTAssertEqual(result.min()!, 0.25, accuracy: 1e-6)
        XCTAssertEqual(result.max()!, 0.25, accuracy: 1e-6)
    }

    func testFaithfulResizeDoesNotMixChannels() {
        var src = [Float](repeating: 0, count: 2 * 2 * 3)
        for p in 0..<4 { src[p*3] = 1; src[p*3+1] = 0.5 }
        let result = SuperResolver.resizeBilinear(src, h: 2, w: 2, dh: 4, dw: 4)
        for p in 0..<16 {
            XCTAssertEqual(result[p*3], 1, accuracy: 1e-6)
            XCTAssertEqual(result[p*3+1], 0.5, accuracy: 1e-6)
            XCTAssertEqual(result[p*3+2], 0, accuracy: 1e-6)
        }
    }
}

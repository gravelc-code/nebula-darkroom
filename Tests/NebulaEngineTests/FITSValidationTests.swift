// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaEngine

/// FITS headers are untrusted input (audit item 36): bad geometry must throw,
/// never trap or pass through to crash the engine later.
final class FITSValidationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-fits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// A FITS file with the given header cards and `dataBytes` of payload.
    private func crafted(_ cards: [(String, String)], dataBytes: Int = 2880) throws -> URL {
        var header = ""
        for (k, v) in [("SIMPLE", "T")] + cards {
            header += (k.padding(toLength: 8, withPad: " ", startingAt: 0) + "= "
                       + String(repeating: " ", count: max(0, 20 - v.count)) + v)
                .padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while header.count % 2880 != 0 { header += String(repeating: " ", count: 80) }
        var data = Data(header.utf8)
        data.append(Data(count: dataBytes))
        let url = dir.appendingPathComponent("\(UUID().uuidString).fits")
        try data.write(to: url)
        return url
    }

    private func geometry(_ naxis: String, _ w: String, _ h: String, _ c: String? = nil) -> [(String, String)] {
        var cards = [("BITPIX", "-32"), ("NAXIS", naxis), ("NAXIS1", w), ("NAXIS2", h)]
        if let c { cards.append(("NAXIS3", c)) }
        return cards
    }

    private func assertBadHeader(_ cards: [(String, String)], file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try crafted(cards)
        XCTAssertThrowsError(try FITSImage.read(url), file: file, line: line) { error in
            guard case FITSImage.FITSError.badHeader = error else {
                return XCTFail("expected badHeader, got \(error)", file: file, line: line)
            }
        }
    }

    func testRejectsImpossibleGeometry() throws {
        try assertBadHeader(geometry("2", "-1", "4"))                 // used to trap
        try assertBadHeader(geometry("2", "4", "-1"))
        try assertBadHeader(geometry("2", "0", "4"))                  // used to pass, crash later
        try assertBadHeader(geometry("2", "4", "0"))
        try assertBadHeader(geometry("2", "65537", "4"))
        let huge = String(Int.max / 2)
        try assertBadHeader(geometry("2", huge, huge))                // used to overflow-trap
        try assertBadHeader(geometry("3", "4", "4", "2"))             // only mono or RGB
        try assertBadHeader(geometry("3", "4", "4", "0"))
        try assertBadHeader(geometry("1", "4", "4"))
        try assertBadHeader(geometry("4", "4", "4", "3"))
    }

    func testRejectsTruncatedData() throws {
        // 64×64 float32 needs 16 384 bytes; give it one block.
        let url = try crafted(geometry("2", "64", "64"), dataBytes: 2880)
        XCTAssertThrowsError(try FITSImage.read(url)) { error in
            guard case FITSImage.FITSError.truncated = error else { return XCTFail("\(error)") }
        }
    }

    func testValidLayersRoundTrip() throws {
        let rgb = FITSImage(width: 3, height: 2, channels: 3,
                            rgba: (0..<24).map { $0 % 4 == 3 ? 1 : Float($0) * 0.01 })
        let mono = FITSImage.fromHWC([0.1, 0.2, 0.3, 0.4], width: 2, height: 2, channels: 1)
        for img in [rgb, mono] {
            let url = dir.appendingPathComponent("layer.fits")
            try img.write(url)
            let back = try FITSImage.read(url)
            XCTAssertEqual(back.width, img.width); XCTAssertEqual(back.height, img.height)
            XCTAssertEqual(back.channels, img.channels)
            XCTAssertEqual(back.rgba, img.rgba)
        }
        // The smallest legal image is accepted.
        XCTAssertNoThrow(try FITSImage.read(try crafted(geometry("2", "1", "1"))))
    }

    /// `write` replaces a layer atomically: a fresh complete file appears under
    /// the real name and no temporary is left beside it.
    func testWriteReplacesAtomically() throws {
        let url = dir.appendingPathComponent("stars.fits")
        let big = FITSImage(width: 64, height: 64, channels: 3, rgba: [Float](repeating: 0.5, count: 64*64*4))
        try big.write(url)
        let small = FITSImage(width: 2, height: 2, channels: 3, rgba: [Float](repeating: 0.25, count: 16))
        try small.write(url)
        let back = try FITSImage.read(url)
        XCTAssertEqual(back.width, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["stars.fits"])
        // A write that cannot complete leaves nothing behind under the name.
        let missing = dir.appendingPathComponent("no-such-dir/denoised.fits")
        XCTAssertThrowsError(try small.write(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}

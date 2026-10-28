// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import NebulaBake
import NebulaEngine

/// Light selection reads headers only and ignores files that aren't subs; the
/// colour stage keeps float layers' ratios, guards saturation on recorded
/// values, and only unmixes duo-band data from the instrument it was measured
/// on; the StarNet image bridge decodes every sample layout correctly.
final class BakeInputAndColourTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - FITS header-only reading

    private func card(_ key: String, _ value: String) -> String {
        (key.padding(toLength: 8, withPad: " ", startingAt: 0) + "= " + value)
            .padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    private func headerData(_ cards: [String]) -> Data {
        var h = cards.joined() + "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while h.utf8.count % 2880 != 0 { h += String(repeating: " ", count: 80) }
        return Data(h.utf8)
    }

    private func subHeader(width: Int, height: Int, bitpix: Int = 16, naxis3: Int? = nil,
                           extra: [String] = []) -> [String] {
        var cards = [card("SIMPLE", "T"), card("BITPIX", "\(bitpix)"),
                     card("NAXIS", naxis3 == nil ? "2" : "3"),
                     card("NAXIS1", "\(width)"), card("NAXIS2", "\(height)")]
        if let naxis3 { cards.append(card("NAXIS3", "\(naxis3)")) }
        return cards + extra
    }

    func testHeaderReaderNeedsNoPixelDataAndParsesFITSStrings() throws {
        // A header with no data unit at all: a whole-file reader that wanted
        // the pixels would fail; the header reader only reads up to END.
        let url = tmp.appendingPathComponent("header_only.fit")
        try headerData(subHeader(width: 1080, height: 1920, extra: [
            card("OBJECT", "'M 42/Orion''s Sword'"),
            card("FILTER", "'LP      '           / Active filter name"),
            card("EXPTIME", "10.0 / [s]"),
            card("COMMENT", "ignored"),
        ])).write(to: url)
        let h = try FITSHeader.read(url)
        XCTAssertEqual(h["OBJECT"], "M 42/Orion's Sword", "quoted strings keep '/' and unescape ''")
        XCTAssertEqual(h["FILTER"], "LP")
        XCTAssertEqual(h["EXPTIME"], "10.0")
        XCTAssertEqual(h["NAXIS1"], "1080")
        XCTAssertNil(h["COMMENT"])
    }

    func testHeaderReaderFollowsMultiBlockHeadersAndRejectsNonFITS() throws {
        let long = tmp.appendingPathComponent("long.fits")
        let filler = (0..<50).map { card(String(format: "KEY%05d", $0), "\($0)") }
        try headerData(subHeader(width: 4, height: 4) + filler + [card("FILTER", "'IRCUT'")]).write(to: long)
        XCTAssertEqual(try FITSHeader.read(long)["FILTER"], "IRCUT", "END is found in the second block")

        // macOS AppleDouble sidecar (`._x.fit`): magic 0x00051607, not FITS.
        let appleDouble = tmp.appendingPathComponent("appledouble.fit")
        try Data([0x00, 0x05, 0x16, 0x07] + [UInt8](repeating: 0, count: 4092)).write(to: appleDouble)
        XCTAssertThrowsError(try FITSHeader.read(appleDouble)) {
            XCTAssertEqual($0 as? FITSHeader.Failure, .notFITS)
        }
        let noEnd = tmp.appendingPathComponent("noend.fit")
        try Data((card("SIMPLE", "T") + String(repeating: " ", count: 2800)).utf8).write(to: noEnd)
        XCTAssertThrowsError(try FITSHeader.read(noEnd)) { XCTAssertEqual($0 as? FITSHeader.Failure, .noEnd) }
        let empty = tmp.appendingPathComponent("empty.fit")
        try Data().write(to: empty)
        XCTAssertThrowsError(try FITSHeader.read(empty))
    }

    func testLightSelectionSkipsFilesThatAreNotSubs() throws {
        let subs = tmp.appendingPathComponent("M 42_sub")
        try FileManager.default.createDirectory(at: subs, withIntermediateDirectories: true)
        let ircut = [card("FILTER", "'IRCUT'"), card("EXPTIME", "10.0")]
        for i in 0..<3 {
            try headerData(subHeader(width: 1080, height: 1920, extra: ircut))
                .write(to: subs.appendingPathComponent("Light_\(i).fit"))
        }
        // What a real Seestar folder copied over SMB also contains:
        try Data([0x00, 0x05, 0x16, 0x07] + [UInt8](repeating: 0, count: 4092))
            .write(to: subs.appendingPathComponent("._Light_0.fit"))                    // AppleDouble
        try headerData(subHeader(width: 1080, height: 1920, extra: ircut))
            .write(to: subs.appendingPathComponent(".hidden.fit"))                     // hidden
        try Data("not fits".utf8).write(to: subs.appendingPathComponent("broken.fit"))  // unreadable
        try headerData(subHeader(width: 0, height: 1920, extra: ircut))
            .write(to: subs.appendingPathComponent("zero.fits"))                       // width 0
        try FileManager.default.createDirectory(at: subs.appendingPathComponent("folder.fits"),
                                                withIntermediateDirectories: true)
        try Data([0xFF, 0xD8]).write(to: subs.appendingPathComponent("Light_0_thn.jpg"))

        let selection = try SirilStage.selectLights(in: subs)
        XCTAssertEqual(selection.lights.count, 3)
        XCTAssertEqual(selection.filter, "IRCUT")
        XCTAssertEqual(selection.skippedIncompatible, 0, "no phantom UNKNOWN|0x0 group")
        XCTAssertEqual(selection.skippedUnreadable, 2, "broken.fit and the width-0 frame")
        XCTAssertEqual(selection.integrationSeconds, 30)
        XCTAssertEqual(selection.lights[0].dataBytes, 1080 * 1920 * 2, "16-bit mono CFA")
    }

    func testLightSelectionFailsCleanlyWhenNothingIsReadable() throws {
        try Data([0x00, 0x05, 0x16, 0x07]).write(to: tmp.appendingPathComponent("._a.fit"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("b.fit"))
        XCTAssertThrowsError(try SirilStage.selectLights(in: tmp))
    }

    // MARK: - Stack time budget

    func testStackBudgetScalesWithFramesAndHasAFloor() throws {
        let one = SirilStage.Light(url: tmp, filter: "IRCUT", exposure: 10, width: 1080, height: 1920,
                                   dataBytes: 1080 * 1920 * 2, header: [:])
        XCTAssertEqual(SirilStage.stackTimeout(for: [one]), SirilStage.stackTimeoutFloor)
        let session = [SirilStage.Light](repeating: one, count: 200)
        let perFrame = 2.0736 * SirilStage.measuredStackSecondsPerMegapixel * SirilStage.stackComputeHeadroom
            + 4.1472
        XCTAssertEqual(SirilStage.stackTimeout(for: session), 200 * perFrame, accuracy: 0.5)
        let multiNight = [SirilStage.Light](repeating: one, count: 1000)
        XCTAssertGreaterThan(SirilStage.stackTimeout(for: multiNight), 1800 * 3,
                             "a 1,000-sub folder is no longer cut off at the old fixed 30 min")
    }

    func testStarSeparationBudgetScalesWithImageSize() {
        XCTAssertEqual(Baker.starSeparationTimeout(width: 1080, height: 1920), 300, "floor")
        XCTAssertEqual(Baker.starSeparationTimeout(width: 4000, height: 6000), 1440, accuracy: 1e-6)
    }

    // MARK: - Validator samples every channel

    func testValidatorSeesAChangeConfinedToGreenAndBlue() {
        // 150,000 RGB pixels: the old flat stride was max(3, 450000/50000) = 9,
        // a multiple of 3 — it only ever looked at red.
        let pixels = 150_000
        let before = [Float](repeating: 0.1, count: pixels * 3)
        var after = before
        for p in 0..<pixels { after[p*3+1] = 0.101; after[p*3+2] = 0.101 }
        let verdict = CorrectionValidator.accept(before: before, after: after, channels: 3)
        XCTAssertFalse(verdict.1.contains("no-meaningful-change"), "\(verdict.1)")
        XCTAssertTrue(verdict.0)
    }

    // MARK: - Float layers keep their channel ratios

    func testRenormalisedPCCKeepsRatiosAboveOne() {
        let n = 4096
        var reference = [Float](repeating: 0, count: n * 3)
        var calibrated = reference
        for p in 0..<n {
            let signal: Float = p < n / 10 ? 0.05 : 0.002
            for ch in 0..<3 { reference[p*3+ch] = signal }
            calibrated[p*3] = signal * 0.5; calibrated[p*3+1] = signal * 0.7; calibrated[p*3+2] = signal
        }
        // A bright core that the luminance restore lifts past 1.
        reference[0] = 0.95; reference[1] = 0.95; reference[2] = 0.95
        calibrated[0] = 0.45; calibrated[1] = 0.63; calibrated[2] = 0.9
        let out = Baker.renormaliseLuminance(reference: reference, calibrated: calibrated, c: 3)
        XCTAssertGreaterThan(out[2], 1, "no ceiling on a float layer")
        XCTAssertEqual(out[0] / out[2], 0.5, accuracy: 1e-5, "ratios untouched, as documented")
        XCTAssertEqual(out[1] / out[2], 0.7, accuracy: 1e-5)
    }

    func testNativeBalancePassesBrightValuesThroughUnclamped() {
        let w = 20, h = 20
        var image = [Float](repeating: 0.1, count: w * h * 3)
        image[0] = 1.4; image[1] = 1.1; image[2] = 0.8
        let out = Baker.nativeWhiteBalance(image, h: h, w: w, c: 3, broadband: true)
        XCTAssertEqual(out[0], 1.4, accuracy: 1e-6)
        XCTAssertEqual(out[1], 1.1, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.8, accuracy: 1e-6)
    }

    /// Saturated cores must not become the white reference just because a
    /// bright sky was subtracted from them first.
    func testSaturatedCoresOverBrightSkyAreNotTheWhiteReference() {
        let w = 160, h = 100, n = w * h
        let sky: Float = 0.15
        var image = [Float](repeating: sky, count: n * 3)
        var neutralBright: Int?
        // Only every 16th pixel is sampled; plant ~3% of samples each as
        // clipped cores (recorded 1.0/1.0/0.7 — the core of a red-white star
        // with R and G at full scale) and as bright, unsaturated neutral stars.
        for s in stride(from: 0, to: n, by: 16) {
            switch (s / 16) % 33 {
            case 0: image[s*3] = 1.0; image[s*3+1] = 1.0; image[s*3+2] = 0.7
            case 1: for ch in 0..<3 { image[s*3+ch] = 0.8 }; neutralBright = neutralBright ?? s
            default: break
            }
        }
        let out = Baker.nativeWhiteBalance(image, h: h, w: w, c: 3, broadband: true,
                                           saturationReference: image)
        let p = neutralBright!
        // Post-subtraction the cores read 0.85/0.85/0.55 < 0.9 and used to pass
        // the guard, pulling blue's gain up by ~1.4× across the whole image.
        XCTAssertEqual(out[p*3+2] / out[p*3+1], 1, accuracy: 0.02,
                       "a neutral star stays neutral; clipped cores didn't set the balance")
        XCTAssertEqual(out[p*3] / out[p*3+1], 1, accuracy: 0.02)
    }

    // MARK: - Duo-band unmixing only for the instrument it was measured on

    func testDuoBandMatrixIsGatedOnTheSeestarS50() {
        XCTAssertTrue(Baker.hasSeestarS50Response(instrument: "Seestar S50"))
        XCTAssertTrue(Baker.hasSeestarS50Response(instrument: " seestar s50 "))
        for other in ["Seestar S30", "Seestar S50 Pro", "ZWO ASI462MC", "", nil] as [String?] {
            XCTAssertFalse(Baker.hasSeestarS50Response(instrument: other), "\(other ?? "nil")")
        }
        // Without the S50 response the narrowband path is neutralisation only:
        // the line ratio the sensor recorded is left alone.
        let w = 40, h = 40
        var image = [Float](repeating: 0, count: w * h * 3)
        for p in 0..<(w * h) { image[p*3] = 0.03; image[p*3+1] = 0.02; image[p*3+2] = 0.01 }
        image[0] = 0.5; image[1] = 0.1; image[2] = 0.05            // an Ha-bright pixel
        let neutralised = Baker.nativeWhiteBalance(image, h: h, w: w, c: 3, broadband: false,
                                                   duoBandResponse: false)
        let recombined = Baker.nativeWhiteBalance(image, h: h, w: w, c: 3, broadband: false,
                                                  duoBandResponse: true)
        XCTAssertEqual(neutralised[3], neutralised[4], accuracy: 1e-6, "sky neutralised")
        XCTAssertEqual(neutralised[0] - neutralised[1], (0.5 - 0.03) - (0.1 - 0.02), accuracy: 1e-5,
                       "signal above the sky is untouched")
        XCTAssertNotEqual(neutralised[1], recombined[1], accuracy: 1e-4, "the S50 path does unmix")
    }

    // MARK: - Denoise domain

    func testWithinUnitRangeIsExactForScaleEquivariantStages() throws {
        let small: [Float] = [0.2, 0.9, 1.0]
        XCTAssertEqual(try Baker.withinUnitRange(small) { $0 }, small, "identity at ≤ 1")
        // A stage defined on [0,1] that clips its output (like the denoiser).
        let stage: ([Float]) -> [Float] = { $0.map { min(max($0 * 0.9, 0), 1) } }
        var seen: [Float] = []
        let out = Baker.withinUnitRange([2.0, 1.0, 0.5]) { seen = $0; return stage($0) }
        XCTAssertEqual(seen.max(), 1, "the stage only ever sees [0, 1]")
        XCTAssertEqual(out[0], 1.8, accuracy: 1e-6, "result returned on the original scale, unclipped")
        XCTAssertEqual(out[1], 0.9, accuracy: 1e-6)
        XCTAssertEqual(out[2], 0.45, accuracy: 1e-6)
    }

    // MARK: - Background removal parameter

    func testBackgroundCorrectionParameterIsMeaningfulAndOnByDefault() {
        XCTAssertTrue(Baker().applyBackgroundCorrection, "the app and CLI bake with it on")
        XCTAssertTrue(Baker.wantsBackgroundCorrection(true, environment: [:]))
        XCTAssertFalse(Baker.wantsBackgroundCorrection(false, environment: [:]),
                       "false now actually disables it")
        XCTAssertFalse(Baker.wantsBackgroundCorrection(true, environment: ["NEBULA_BACKGROUND_CORRECTION": "0"]))
        XCTAssertTrue(Baker.wantsBackgroundCorrection(false, environment: ["NEBULA_BACKGROUND_CORRECTION": "1"]))
    }

    // MARK: - Baking into an existing folder

    func testStaleOutputsAreClearedButLogsAndReusableStackKept() throws {
        let fm = FileManager.default
        let names = ["manifest.json", "quality.json", "thumb.png", "source.txt"]
            + Baker.layerNames.map { "\($0).fits" }
        for name in names { try Data("old".utf8).write(to: tmp.appendingPathComponent(name)) }
        let work = tmp.appendingPathComponent("_work")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: work.appendingPathComponent("master_stack.fits"))
        Baker.removeStaleOutputs(in: tmp)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["_work", "source.txt"])
        XCTAssertTrue(fm.fileExists(atPath: work.appendingPathComponent("master_stack.fits").path))
    }

    // MARK: - StarNet image bridge

    private let w = 4, h = 3
    private func expected(_ bits: Int) -> [Float] {
        let maxV = Float((1 << bits) - 1)
        return (0..<(w * h * 3)).map { Float(($0 * 4099 + 17) % (1 << bits)) / maxV }
    }

    private func image16(_ order: CGBitmapInfo, alpha: CGImageAlphaInfo, alphaFirst: Bool,
                         alphaValue: UInt16 = 65535) -> CGImage {
        let values = expected(16)
        var bytes = [UInt8]()
        func put(_ v: UInt16) {
            let s = order == .byteOrder16Little ? v.littleEndian : v.bigEndian
            withUnsafeBytes(of: s) { bytes.append(contentsOf: $0) }
        }
        for p in 0..<(w * h) {
            if alphaFirst { put(alphaValue) }
            for ch in 0..<3 {
                let v = UInt16((values[p*3+ch] * 65535).rounded())
                // Premultiplied storage: colour × alpha.
                put(alpha == .premultipliedLast || alpha == .premultipliedFirst
                    ? UInt16((Float(v) * Float(alphaValue) / 65535).rounded()) : v)
            }
            if !alphaFirst { put(alphaValue) }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                       space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue).union(order),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func assertDecodes(_ img: CGImage, _ want: [Float], tolerance: Float,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try Baker.decodeRGB(img, w: w, h: h)
        XCTAssertEqual(got.count, want.count, file: file, line: line)
        for i in want.indices {
            XCTAssertEqual(got[i], want[i], accuracy: tolerance, "sample \(i)", file: file, line: line)
        }
    }

    func testBigEndian16BitSamplesAreSwappedCorrectly() throws {
        // The bug: byte order is an enum field, and 0x3000 (16Big) "contains"
        // 0x1000 (16Little) as a bit flag — big-endian read as little.
        XCTAssertTrue(CGBitmapInfo.byteOrder16Big.contains(.byteOrder16Little))
        try assertDecodes(image16(.byteOrder16Big, alpha: .noneSkipLast, alphaFirst: false),
                          expected(16), tolerance: 1e-7)
        try assertDecodes(image16([], alpha: .noneSkipLast, alphaFirst: false),
                          expected(16), tolerance: 1e-7)
        try assertDecodes(image16(.byteOrder16Little, alpha: .noneSkipLast, alphaFirst: false),
                          expected(16), tolerance: 1e-7)
    }

    func testAlphaFirstAndPremultipliedLayoutsDecode() throws {
        try assertDecodes(image16(.byteOrder16Little, alpha: .first, alphaFirst: true),
                          expected(16), tolerance: 1e-7)
        try assertDecodes(image16(.byteOrder16Big, alpha: .noneSkipFirst, alphaFirst: true),
                          expected(16), tolerance: 1e-7)
        try assertDecodes(image16(.byteOrder16Big, alpha: .premultipliedLast, alphaFirst: false,
                                  alphaValue: 32768),
                          expected(16), tolerance: 2.0 / 32768)
    }

    func testEightBitLayoutsDecode() throws {
        let want = expected(8)
        // Packed RGB, 24 bpp.
        let rgb = want.map { UInt8(($0 * 255).rounded()) }
        let packed = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: w * 3,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(),
                             provider: CGDataProvider(data: Data(rgb) as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
        try assertDecodes(packed, want, tolerance: 1e-7)
        // BGRA in memory: premultipliedFirst + 32-bit little (the common
        // Core Graphics native layout).
        var bgra = [UInt8]()
        for p in 0..<(w * h) { bgra += [rgb[p*3+2], rgb[p*3+1], rgb[p*3], 255] }
        let native = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                .union(.byteOrder32Little),
                             provider: CGDataProvider(data: Data(bgra) as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
        try assertDecodes(native, want, tolerance: 1e-7)
    }

    func testUnusualLayoutsAreRedrawnNotMisread() throws {
        // 32-bit float RGBA: not an integer layout, so it takes the redraw path.
        let want = expected(16)
        var floats = [Float]()
        for p in 0..<(w * h) { floats += [want[p*3], want[p*3+1], want[p*3+2], 1] }
        let data = floats.withUnsafeBytes { Data($0) }
        let img = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                          space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                            .union([.floatComponents, .byteOrder32Little]),
                          provider: CGDataProvider(data: data as CFData)!, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent)!
        try assertDecodes(img, want, tolerance: 3.0 / 65535)
    }

    func testBigEndianTIFFFileRoundTrips() throws {
        let url = tmp.appendingPathComponent("be16.tiff")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image16(.byteOrder16Big, alpha: .noneSkipLast, alphaFirst: false), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let back = try Baker.readTIFF16(url, w: w, h: h)
        let want = expected(16)
        for i in want.indices { XCTAssertEqual(back[i], want[i], accuracy: 1e-7, "sample \(i)") }
    }
}

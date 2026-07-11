import Foundation

/// Minimal reader/writer for the float32 FITS layers the bake emits (design §4
/// step 9). Deliberately narrow: it handles exactly what Nebula produces —
/// `BITPIX=-32`, big-endian, 2-D (H,W) mono or 3-D (3,H,W) plane-separated RGB —
/// rather than the whole FITS standard. This honours the manifest's FITS
/// interchange contract without pulling in a dependency.
public struct FITSImage: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int          // 1 or 3
    /// Interleaved RGBA float pixels (row-major, `height * width * 4`), alpha = 1.
    /// Mono layers are broadcast to R=G=B so the shader path is uniform.
    public var rgba: [Float]

    public init(width: Int, height: Int, channels: Int, rgba: [Float]) {
        self.width = width; self.height = height; self.channels = channels; self.rgba = rgba
    }

    /// Row-major HxWxC (C = `channels`) — the layout the AI pipelines work in.
    public func hwcPixels() -> [Float] {
        let n = width * height
        var out = [Float](repeating: 0, count: n * channels)
        for p in 0..<n { for ch in 0..<channels { out[p * channels + ch] = rgba[p * 4 + ch] } }
        return out
    }

    /// Build from row-major HxWxC (mono broadcast to R=G=B, alpha = 1).
    public static func fromHWC(_ hwc: [Float], width: Int, height: Int, channels: Int) -> FITSImage {
        let n = width * height
        var rgba = [Float](repeating: 1, count: n * 4)
        for p in 0..<n {
            if channels == 1 {
                let v = hwc[p]; rgba[p*4] = v; rgba[p*4+1] = v; rgba[p*4+2] = v
            } else {
                for ch in 0..<min(channels, 3) { rgba[p*4+ch] = hwc[p*channels+ch] }
            }
        }
        return FITSImage(width: width, height: height, channels: channels, rgba: rgba)
    }

    /// Read just the header cards (KEYWORD -> value string) — for capture metadata
    /// without decoding pixels.
    public static func readHeaderCards(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        var cards: [String: String] = [:]
        var offset = 0
        while offset + 2880 <= data.count {
            var sawEnd = false
            for i in stride(from: offset, to: offset + 2880, by: 80) {
                let card = String(decoding: data[i..<i+80], as: UTF8.self)
                let key = card.prefix(8).trimmingCharacters(in: .whitespaces)
                if key == "END" { sawEnd = true; break }
                if let eq = card.firstIndex(of: "="), key != "COMMENT", key != "HISTORY" {
                    let rawVal = card[card.index(after: eq)...]
                    let val = rawVal.split(separator: "/").first.map {
                        $0.trimmingCharacters(in: CharacterSet(charactersIn: " '"))
                    } ?? ""
                    cards[key] = val
                }
            }
            offset += 2880
            if sawEnd { break }
        }
        return cards
    }

    public enum FITSError: Error { case badHeader(String), truncated }

    public static func read(_ url: URL) throws -> FITSImage {
        let data = try Data(contentsOf: url)

        // FITS headers are 2880-byte blocks of 80-char "KEYWORD = value" cards,
        // ending at the `END` card; data starts at the next 2880 boundary.
        var cards: [String: String] = [:]
        var offset = 0
        var sawEnd = false
        headerScan: while offset + 2880 <= data.count {
            for i in stride(from: offset, to: offset + 2880, by: 80) {
                let card = String(decoding: data[i..<i+80], as: UTF8.self)
                let key = card.prefix(8).trimmingCharacters(in: .whitespaces)
                if key == "END" { sawEnd = true }
                if let eq = card.firstIndex(of: "="), key != "COMMENT", key != "HISTORY" {
                    let rawVal = card[card.index(after: eq)...]
                    let val = rawVal.split(separator: "/").first.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? ""
                    cards[key] = val
                }
            }
            offset += 2880
            if sawEnd { break headerScan }
        }
        guard sawEnd else { throw FITSError.badHeader("no END card") }

        func intCard(_ k: String) throws -> Int {
            guard let s = cards[k], let v = Int(s) else { throw FITSError.badHeader("missing \(k)") }
            return v
        }
        guard try intCard("BITPIX") == -32 else { throw FITSError.badHeader("expected BITPIX=-32") }
        let naxis = try intCard("NAXIS")
        let w = try intCard("NAXIS1")
        let h = try intCard("NAXIS2")
        let ch = naxis == 3 ? try intCard("NAXIS3") : 1
        guard ch == 1 || ch == 3 else { throw FITSError.badHeader("NAXIS3=\(ch) unsupported") }

        let count = w * h * ch
        guard offset + count * 4 <= data.count else { throw FITSError.truncated }

        // Big-endian float32, plane-separated (all of R, then G, then B).
        var planes = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: offset)
            for i in 0..<count {
                let be = base.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).bigEndian
                planes[i] = Float(bitPattern: be)
            }
        }

        // Repack plane-separated -> interleaved RGBA.
        var rgba = [Float](repeating: 1, count: w * h * 4)
        let plane = w * h
        for y in 0..<h {
            for x in 0..<w {
                let p = y * w + x
                let o = p * 4
                if ch == 1 {
                    let v = planes[p]
                    rgba[o] = v; rgba[o+1] = v; rgba[o+2] = v
                } else {
                    rgba[o]   = planes[p]
                    rgba[o+1] = planes[plane + p]
                    rgba[o+2] = planes[2 * plane + p]
                }
            }
        }
        return FITSImage(width: w, height: h, channels: ch, rgba: rgba)
    }

    /// Write the same narrow float32 FITS the bake consumes: `BITPIX=-32`,
    /// big-endian, 2-D `(H,W)` mono or 3-D `(3,H,W)` plane-separated RGB. Round-
    /// trips with `read` and is read by the Python bake's astropy.
    public func write(_ url: URL) throws {
        // --- Header: 80-char cards, `END`, padded to a 2880-byte block. ---
        func card(_ keyword: String, _ value: String) -> String {
            let kv = keyword.padding(toLength: 8, withPad: " ", startingAt: 0)
                + "= " + String(repeating: " ", count: max(0, 20 - value.count)) + value
            return kv.padding(toLength: 80, withPad: " ", startingAt: 0)
        }
        var header = ""
        header += card("SIMPLE", "T")
        header += card("BITPIX", "-32")
        header += card("NAXIS", channels == 3 ? "3" : "2")
        header += card("NAXIS1", String(width))
        header += card("NAXIS2", String(height))
        if channels == 3 { header += card("NAXIS3", "3") }
        header += "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        while header.count % 2880 != 0 { header += String(repeating: " ", count: 80) }

        var data = Data(header.utf8)

        // --- Data: plane-separated big-endian float32 (all R, then G, then B). ---
        let plane = width * height
        let planeCount = channels == 3 ? 3 : 1
        var floats = [UInt32](repeating: 0, count: plane * planeCount)
        for p in 0..<plane {
            for c in 0..<planeCount {
                let v = rgba[p * 4 + c]              // mono: c==0 (R==G==B)
                floats[c * plane + p] = v.bitPattern.bigEndian
            }
        }
        floats.withUnsafeBytes { data.append(contentsOf: $0) }

        // Pad the data unit to a 2880-byte block.
        let rem = data.count % 2880
        if rem != 0 { data.append(Data(count: 2880 - rem)) }

        try data.write(to: url)
    }
}

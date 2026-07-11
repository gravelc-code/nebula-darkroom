import Foundation

/// Minimal reader/writer for the float32 FITS layers the bake emits (design §4
/// step 9). Deliberately narrow: it handles exactly what Nebula produces —
/// `BITPIX=-32`, big-endian, 2-D (H,W) mono or 3-D (3,H,W) plane-separated RGB —
/// rather than the whole FITS standard. This honours the manifest's FITS
/// interchange contract without pulling in a dependency.
struct FITSImage {
    let width: Int
    let height: Int
    let channels: Int          // 1 or 3
    /// Interleaved RGBA float pixels (row-major, `height * width * 4`), alpha = 1.
    /// Mono layers are broadcast to R=G=B so the shader path is uniform.
    var rgba: [Float]

    enum FITSError: Error { case badHeader(String), truncated }

    static func read(_ url: URL) throws -> FITSImage {
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
}

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// Reads only the primary header of a FITS file: 2880-byte blocks up to the
/// `END` card, never the pixels.
///
/// Light selection needs four keywords per sub, but reading whole files cost
/// ~4 MB per Seestar sub — about 0.8 GB for 200 subs before the stack even
/// started, over the telescope's Wi-Fi share. A Seestar header is one block.
enum FITSHeader {
    enum Failure: Error, Equatable {
        case notFITS, noEnd
    }

    /// A header longer than this is not something Nebula can stack, and the
    /// cap stops a large non-FITS file with a `.fit` name being read to the end
    /// (100 blocks = 3,600 cards, ~290 KB).
    static let maxBlocks = 100

    /// `KEYWORD -> value` with string quotes removed and comments stripped —
    /// the same values `FITSImage.readHeaderCards` returns for ordinary cards.
    static func read(_ url: URL) throws -> [String: String] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var cards: [String: String] = [:]
        for block in 0..<maxBlocks {
            guard let data = try handle.read(upToCount: 2880), data.count == 2880 else {
                throw block == 0 ? Failure.notFITS : Failure.noEnd
            }
            let bytes = [UInt8](data)
            // A FITS primary header must open with `SIMPLE  =` (FITS 4.0
            // §4.4.1.1); an AppleDouble `._x.fit` or a renamed JPEG does not.
            if block == 0, !bytes.starts(with: Array("SIMPLE  =".utf8)) { throw Failure.notFITS }
            for start in stride(from: 0, to: 2880, by: 80) {
                let card = bytes[start..<start + 80]
                let key = String(decoding: card.prefix(8), as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if key == "END" { return cards }
                guard let value = parseValue(card), key != "COMMENT", key != "HISTORY" else { continue }
                cards[key] = value
            }
        }
        throw Failure.noEnd
    }

    /// A card's value per FITS 4.0 §4.2: a value indicator `= ` in columns
    /// 9-10, then either a quoted string (`''` is an escaped quote; trailing
    /// spaces are not significant) or a fixed-format value ended by `/`.
    static func parseValue(_ card: ArraySlice<UInt8>) -> String? {
        let b = Array(card)
        guard b.count == 80, b[8] == UInt8(ascii: "="), b[9] == UInt8(ascii: " ") else { return nil }
        var i = 10
        while i < 80, b[i] == UInt8(ascii: " ") { i += 1 }
        guard i < 80 else { return "" }
        if b[i] == UInt8(ascii: "'") {
            var out: [UInt8] = []
            i += 1
            while i < 80 {
                if b[i] == UInt8(ascii: "'") {
                    if i + 1 < 80, b[i + 1] == UInt8(ascii: "'") { out.append(b[i]); i += 2; continue }
                    break
                }
                out.append(b[i]); i += 1
            }
            return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
        let rest = String(decoding: b[i...], as: UTF8.self)
        let value = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return value.trimmingCharacters(in: .whitespaces)
    }
}

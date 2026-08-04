// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaEngine

/// The Siril seam, native in Swift (Phase 3). Select compatible lights, register,
/// stack, and attempt catalogue photometric colour calibration
/// via a bundled/pinned Siril subprocess — a faithful port of the proven Python
/// `nebula_proto/siril.py`, including its two hard-won gotchas: Siril's `-out=`
/// can't express spaces (so run those writes in a space-free scratch dir), and a
/// Seestar `_sub` folder interleaves FITS lights with preview JPEGs (so stage
/// only the FITS). Classical DSP stays wrapped in Siril per the design.
public struct SirilStage {
    public enum SirilError: Error, CustomStringConvertible {
        case notFound, noMaster(String)
        public var description: String {
            switch self {
            case .notFound: return "Siril not found (install with `brew install siril` or set SIRIL_BIN)"
            case .noMaster(let s): return "Siril produced no master: \(s)"
            }
        }
    }

    let sirilBin: String
    let memGB: Double

    public struct Light: Sendable {
        public let url: URL
        public let filter: String
        public let exposure: Double
        public let width: Int
        public let height: Int
        public let header: [String: String]
    }

    /// Compatible lights selected for one stack. Different exposure lengths are
    /// safe under Siril's additive-scale normalisation; different filters are not.
    public struct LightSelection: Sendable {
        public let lights: [Light]
        public let filter: String
        public let skippedIncompatible: Int
        public var exposures: Set<Double> { Set(lights.map(\.exposure)) }
        public var integrationSeconds: Double { lights.reduce(0) { $0 + $1.exposure } }
        /// True drizzle needs broad sub-pixel coverage. A conservative frame
        /// threshold avoids sparse output and excess noise on short captures.
        public var supportsTwoXDrizzle: Bool { lights.count >= 60 && integrationSeconds >= 600 }
    }

    public init(sirilBin: String? = nil, memGB: Double = 4.0) throws {
        guard let bin = sirilBin ?? Self.discover() else { throw SirilError.notFound }
        self.sirilBin = bin
        self.memGB = memGB
    }

    static func discover() -> String? {
        let fm = FileManager.default
        if let e = ProcessInfo.processInfo.environment["SIRIL_BIN"], fm.isExecutableFile(atPath: e) { return e }
        // Shipped app: Siril bundled in Nebula.app/Contents/Resources/siril/siril.
        if let u = Bundle.main.resourceURL?.appendingPathComponent("siril/siril"),
           fm.isExecutableFile(atPath: u.path) { return u.path }
        let dev = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("build/Nebula.app/Contents/Resources/siril/siril")
        if fm.isExecutableFile(atPath: dev.path) { return dev.path }
        for p in ["/opt/homebrew/bin/siril", "/usr/local/bin/siril", "/usr/bin/siril"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Select the filter group with the greatest total integration. This avoids
    /// silently mixing IRCUT and duo/LP response curves in one colour stack.
    public static func selectLights(in subsDir: URL) throws -> LightSelection {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: subsDir, includingPropertiesForKeys: nil)
            .filter { ["fit", "fits"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lights: [Light] = urls.map { url in
            let h = (try? FITSImage.readHeaderCards(url)) ?? [:]
            let rawFilter = (h["FILTER"] ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines)
            let exposure = Double(h["EXPTIME"] ?? h["EXPOSURE"] ?? "") ?? 10
            let width = Int(h["NAXIS1"] ?? "") ?? 0
            let height = Int(h["NAXIS2"] ?? "") ?? 0
            return Light(url: url, filter: rawFilter.uppercased(), exposure: exposure,
                         width: width, height: height, header: h)
        }
        guard !lights.isEmpty else { throw SirilError.noMaster("no FITS light frames") }
        let totals = Dictionary(grouping: lights) { "\($0.filter)|\($0.width)x\($0.height)" }
            .mapValues { $0.reduce(0) { $0 + $1.exposure } }
        let chosenKey = totals.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }!.key
        let accepted = lights.filter { "\($0.filter)|\($0.width)x\($0.height)" == chosenKey }
        return LightSelection(lights: accepted, filter: accepted[0].filter,
                              skippedIncompatible: lights.count - accepted.count)
    }

    /// Register + stack `subsDir` into a colour-corrected master, returned as a
    /// FITS in `workDir`. Throws `SirilError.noMaster` if Siril yields nothing.
    public func stack(subsDir: URL, workDir: URL, selection supplied: LightSelection? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let selection = try supplied ?? Self.selectLights(in: subsDir)
        // `convert -debayer` creates an RGB sequence, while Siril true drizzle
        // accepts only mono/CFA input. Enabling it here aborts long OSC bakes.
        // Stay native until CFA drizzle is implemented before debayering.

        // Siril's `-out=` can't contain a space; use a space-free scratch when
        // the cache/work path does (real targets like "M 83").
        let sirilWork = workDir.path.contains(" ")
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nebula-siril-\(UUID().uuidString)", isDirectory: true)
            : workDir
        let processDir = sirilWork.appendingPathComponent("process", isDirectory: true)
        // Registration caches and old staged links must never leak into a new bake.
        try? fm.removeItem(at: processDir)
        try? fm.removeItem(at: sirilWork.appendingPathComponent("lights", isDirectory: true))
        try fm.createDirectory(at: processDir, withIntermediateDirectories: true)

        let lightsDir = try stageFitsLights(selection: selection, into: sirilWork)
        let masterOut = sirilWork.appendingPathComponent("master")   // Siril appends .fits

        let selectionSummary = "Accepted \(selection.lights.count) \(selection.filter) frame(s), "
            + "\(String(format: "%.1f", selection.integrationSeconds)) s total; "
            + "skipped \(selection.skippedIncompatible) frame(s) with another filter or size; "
            + "registration=native OSC-safe.\n"
        try selectionSummary.write(to: workDir.appendingPathComponent("selection.log"),
                                   atomically: true, encoding: .utf8)

        // NB: cd/load/save accept quotes (spaces ok); convert/stack `-out=` do not
        // (space-free scratch guarantees that). `-debayer` is mandatory for the
        // Seestar OSC CFA. Colour calibration runs as its own fallback-aware step
        // after the stack; gradient removal runs in-process in Baker.
        //
        // Stacking choices:
        // · `force_16bit=0` — the layers are float32 and `FITSImage` requires
        //   BITPIX=-32; without this the bake depends on the user's Siril config.
        // · `-filter-wfwhm=3k` (sigma) not `90%` (percentile): a percentile
        //   ALWAYS discards the worst tenth even when every frame is good —
        //   ~10% of hard-won integration thrown away on a clean night.
        // · `-weight=noise` not `wfwhm`: Seestar sessions mix 10 s and 30 s
        //   subs, and a 30 s sub carries 3× the signal regardless of its star
        //   shape. Noise weighting is the SNR-correct choice.
        let ssf = """
        requires 1.2.0
        set core.mem_mode=1
        set core.mem_amount=\(memGB)
        set core.force_16bit=0
        setext fits
        cd "\(lightsDir.path)"
        convert light -debayer -out=\(processDir.path)
        cd "\(processDir.path)"
        register light -2pass
        seqapplyreg light -framing=cog -interp=lanczos4
        stack r_light rej w 3 3 -filter-round=2.5k -filter-wfwhm=3k -weight=noise -norm=addscale -output_norm -out=\(masterOut.path)

        """
        let ssfURL = workDir.appendingPathComponent("bake_native.ssf")
        try ssf.write(to: ssfURL, atomically: true, encoding: .utf8)

        let logURL = workDir.appendingPathComponent("siril.log")
        let status = try runScript(ssfURL, logURL: logURL, timeout: 1800)

        let produced = sirilWork.appendingPathComponent("master.fits")
        guard fm.fileExists(atPath: produced.path) else {
            throw SirilError.noMaster("exit \(status); check subs are registrable FITS")
        }
        // Hand the master back inside workDir (no-op when sirilWork == workDir).
        let finalMaster = workDir.appendingPathComponent("master_stack.fits")
        if produced.standardizedFileURL != finalMaster.standardizedFileURL {
            try? fm.removeItem(at: finalMaster)
            try fm.copyItem(at: produced, to: finalMaster)
        }
        return finalMaster
    }

    /// Try plate-solving and catalogue-based photometric colour calibration.
    /// The output is accepted only if PCC actually changed pixel values; a
    /// failed catalogue/solve that merely saves the input falls through cleanly.
    public func photometricColour(master: URL, workDir: URL) throws -> URL? {
        let stem = workDir.appendingPathComponent("master_pcc")
        let output = workDir.appendingPathComponent("master_pcc.fits")
        try? FileManager.default.removeItem(at: output)
        let ssf = """
        requires 1.4.0
        setext fits
        load "\(master.path)"
        platesolve -catalog=gaia -noflip
        pcc -catalog=gaia
        save "\(stem.path)"

        """
        let script = workDir.appendingPathComponent("colour_pcc.ssf")
        try ssf.write(to: script, atomically: true, encoding: .utf8)
        let status = try runScript(script, logURL: workDir.appendingPathComponent("colour_pcc.log"),
                                   timeout: 120)
        guard status == 0, FileManager.default.fileExists(atPath: output.path),
              let before = try? FITSImage.read(master), let after = try? FITSImage.read(output),
              before.width == after.width, before.height == after.height,
              before.channels == after.channels else { return nil }
        let validation = CorrectionValidator.accept(before: before.hwcPixels(),
                                                    after: after.hwcPixels(),
                                                    channels: before.channels)
        if !validation.0 {
            try? ("PCC output rejected: " + validation.1.joined(separator: ", ") + "\n")
                .write(to: workDir.appendingPathComponent("colour_validation.log"),
                       atomically: true, encoding: .utf8)
            return nil
        }
        return output
    }

    private func runScript(_ script: URL, logURL: URL, timeout: TimeInterval) throws -> Int32 {
        let fm = FileManager.default
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sirilBin)
        p.arguments = ["-s", script.path]
        p.standardOutput = log; p.standardError = log
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Task.isCancelled { p.terminate(); try? log.close(); throw CancellationError() }
            if Date() >= deadline { p.terminate(); break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if p.isRunning { p.waitUntilExit() }
        try? log.close()
        return p.terminationStatus
    }

    /// Symlink only the FITS lights (sequential names) into a clean dir, so
    /// Siril's `convert` never ingests the Seestar preview/thumbnail JPEGs.
    private func stageFitsLights(selection: LightSelection, into workDir: URL) throws -> URL {
        let fm = FileManager.default
        let lightsDir = workDir.appendingPathComponent("lights", isDirectory: true)
        try fm.createDirectory(at: lightsDir, withIntermediateDirectories: true)
        for (i, light) in selection.lights.enumerated() {
            let ext = light.url.pathExtension.lowercased()
            let link = lightsDir.appendingPathComponent(String(format: "light_%05d.%@", i, ext))
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: light.url)
        }
        return lightsDir
    }
}

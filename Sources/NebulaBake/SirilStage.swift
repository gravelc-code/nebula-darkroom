// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore
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
        case notFound, noMaster(String), timedOut(seconds: Int)
        public var description: String {
            switch self {
            case .notFound: return "Siril not found (install with `brew install siril` or set SIRIL_BIN)"
            case .noMaster(let s): return "Siril produced no master: \(s)"
            case .timedOut(let s):
                return "Siril stopped responding while stacking (no result after \(s / 60) min)"
            }
        }
    }

    let sirilBin: String
    let memGB: Double
    /// Test seam: replaces the computed per-attempt stacking budget.
    var timeoutOverride: TimeInterval?

    public struct Light: Sendable {
        public let url: URL
        public let filter: String
        public let exposure: Double
        public let width: Int
        public let height: Int
        /// Size of the pixel data the header declares — what `convert` reads.
        public let dataBytes: Int
        public let header: [String: String]
    }

    /// Compatible lights selected for one stack. Different exposure lengths are
    /// safe under Siril's additive-scale normalisation; different filters are not.
    public struct LightSelection: Sendable {
        public let lights: [Light]
        public let filter: String
        public let skippedIncompatible: Int
        /// `.fit`/`.fits` entries that are not readable FITS images (AppleDouble
        /// `._*` files, truncated copies, zero-size frames).
        public let skippedUnreadable: Int
        public var exposures: Set<Double> { Set(lights.map(\.exposure)) }
        public var integrationSeconds: Double { lights.reduce(0) { $0 + $1.exposure } }
    }

    /// One stacking result: the master and how it was obtained.
    public struct StackResult: Sendable {
        public let master: URL
        public let outcome: StageOutcome
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
    ///
    /// Only each sub's header is read (one 2880-byte block on a Seestar sub),
    /// and entries that aren't usable FITS images are skipped rather than
    /// grouped: macOS leaves AppleDouble `._Light_….fit` files on non-HFS
    /// shares, and those used to form an "UNKNOWN|0x0" group with a made-up
    /// 10 s exposure.
    public static func selectLights(in subsDir: URL) throws -> LightSelection {
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: subsDir, includingPropertiesForKeys: [.isDirectoryKey],
                                              options: [.skipsHiddenFiles])
            .filter { url in
                ["fit", "fits"].contains(url.pathExtension.lowercased())
                    && !url.lastPathComponent.hasPrefix(".")
                    && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var unreadable = 0
        let lights: [Light] = urls.compactMap { url in
            guard let h = try? FITSHeader.read(url),
                  let naxis = Int(h["NAXIS"] ?? ""), naxis >= 2,
                  let width = Int(h["NAXIS1"] ?? ""), width > 0,
                  let height = Int(h["NAXIS2"] ?? ""), height > 0,
                  let bitpix = Int(h["BITPIX"] ?? ""), [8, 16, 32, 64, -32, -64].contains(bitpix)
            else { unreadable += 1; return nil }
            let planes = naxis >= 3 ? max(Int(h["NAXIS3"] ?? "") ?? 1, 1) : 1
            let rawFilter = (h["FILTER"] ?? "UNKNOWN").trimmingCharacters(in: .whitespacesAndNewlines)
            let exposure = Double(h["EXPTIME"] ?? h["EXPOSURE"] ?? "") ?? 10
            return Light(url: url, filter: rawFilter.uppercased(), exposure: exposure,
                         width: width, height: height,
                         dataBytes: abs(bitpix) / 8 * width * height * planes, header: h)
        }
        guard !lights.isEmpty else { throw SirilError.noMaster("no readable FITS light frames") }
        let totals = Dictionary(grouping: lights) { "\($0.filter)|\($0.width)x\($0.height)" }
            .mapValues { $0.reduce(0) { $0 + $1.exposure } }
        let chosenKey = totals.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }!.key
        let accepted = lights.filter { "\($0.filter)|\($0.width)x\($0.height)" == chosenKey }
        return LightSelection(lights: accepted, filter: accepted[0].filter,
                              skippedIncompatible: lights.count - accepted.count,
                              skippedUnreadable: unreadable)
    }

    // MARK: - Stack time budget

    /// Measured stacking cost, seconds per megapixel of sub: Siril 1.4.4 on an
    /// Apple M5 (10-core, local SSD) ran this file's full stack script —
    /// convert -debayer, register -2pass, seqapplyreg, rejection stack — on
    /// synthetic Seestar-format subs (1080×1920 16-bit GRBG CFA, ~250 stars) in
    /// 4.18 s for 40 frames and 12.93 s for 120: linear, 0.108 s per frame =
    /// 0.052 s/MP (2026-10-27, `/usr/bin/time` wall clock).
    static let measuredStackSecondsPerMegapixel = 0.052
    /// A timeout exists only to catch a Siril that has stopped making progress,
    /// so it must never fire on a slow but working Mac: older and base
    /// Apple-silicon Macs are several times slower at multi-core work than the
    /// machine measured, and an 8 GB Mac stacking under memory pressure slower
    /// again. 20× the measured rate covers both with margin.
    static let stackComputeHeadroom = 20.0
    /// `convert` reads every sub once, often straight off the telescope's
    /// Wi-Fi share; budget it at a deliberately pessimistic 1 MB/s.
    static let pessimisticReadBytesPerSecond = 1_000_000.0
    /// Siril start-up plus small sets (a 1-sub folder, a short test session).
    static let stackTimeoutFloor: TimeInterval = 600

    /// The time one stacking attempt may take before it is treated as hung:
    /// ~6.3 s per S50 sub, so ~21 min for 200 subs and ~1.75 h for a 1,000-sub
    /// multi-night folder (the old fixed 30 min allowed ~285 subs at this
    /// reading rate).
    static func stackTimeout(for lights: [Light]) -> TimeInterval {
        var total = 0.0
        for light in lights {
            let megapixels = Double(light.width * light.height) / 1_000_000
            total += megapixels * measuredStackSecondsPerMegapixel * stackComputeHeadroom
                + Double(light.dataBytes) / pessimisticReadBytesPerSecond
        }
        return max(stackTimeoutFloor, total)
    }

    // MARK: - Register + stack, with a fallback ladder

    /// Register + stack `subsDir` into a master FITS in `workDir`.
    ///
    /// Never a dead end. The full quality-filtered registered stack is tried
    /// first; if Siril can't produce it, the ladder steps down, and the
    /// returned outcome records which rung produced the master:
    ///  1. one sub only — that sub, debayered, is the master;
    ///  2. registered but the quality filters left too little to stack —
    ///     stack the registered frames unfiltered;
    ///  3. registration failed — stack the frames as captured. Registration
    ///     fails when Siril can't find or match enough stars (cloud, dew,
    ///     twilight, a lens cap): there is then little point-source detail for
    ///     residual drift or field rotation to smear, while averaging still
    ///     cuts the noise by √N — better than any single one of those frames;
    ///  4. anything else (including a hung stack) — the first sub alone.
    /// Throws only if not even one sub can be converted, or on Cancel.
    public func stack(subsDir: URL, workDir: URL, selection supplied: LightSelection? = nil) throws -> StackResult {
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
        let usesScratch = sirilWork != workDir
        let processDir = sirilWork.appendingPathComponent("process", isDirectory: true)
        let lightLinks = sirilWork.appendingPathComponent("lights", isDirectory: true)
        // Siril's converted and registered copies of every sub (two full-res
        // copies per frame: gigabytes per target) are only needed until the
        // master exists. Clear them however the stack ends: done, failed or
        // cancelled.
        defer {
            if usesScratch {
                try? fm.removeItem(at: sirilWork)
            } else {
                try? fm.removeItem(at: processDir)
                try? fm.removeItem(at: lightLinks)
            }
        }
        // Registration caches and old staged links must never leak into a new bake.
        try? fm.removeItem(at: processDir)
        try? fm.removeItem(at: lightLinks)
        try fm.createDirectory(at: processDir, withIntermediateDirectories: true)

        let lightsDir = try stageFitsLights(selection: selection, into: sirilWork)
        let masterOut = sirilWork.appendingPathComponent("master")   // Siril appends .fits
        let produced = sirilWork.appendingPathComponent("master.fits")
        // A master left by an earlier run must never pass for this run's.
        try? fm.removeItem(at: produced)

        let budget = timeoutOverride ?? Self.stackTimeout(for: selection.lights)
        let selectionSummary = "Accepted \(selection.lights.count) \(selection.filter) frame(s), "
            + "\(String(format: "%.1f", selection.integrationSeconds)) s total; "
            + "skipped \(selection.skippedIncompatible) frame(s) with another filter or size"
            + " and \(selection.skippedUnreadable) unreadable file(s); "
            + "registration=native OSC-safe; time budget per attempt \(Int(budget)) s.\n"
        try selectionSummary.write(to: workDir.appendingPathComponent("selection.log"),
                                   atomically: true, encoding: .utf8)

        let logURL = workDir.appendingPathComponent("siril.log")
        fm.createFile(atPath: logURL.path, contents: nil)   // fresh log; attempts append
        var lastEnding = ChildProcess.Ending.exited(0)
        func run(_ name: String, _ body: String, timeout: TimeInterval) throws -> Bool {
            try? fm.removeItem(at: produced)
            let script = Self.preamble(memGB: memGB) + body
            let ssfURL = workDir.appendingPathComponent("bake_\(name).ssf")
            try script.write(to: ssfURL, atomically: true, encoding: .utf8)
            Baker.appendLog("=== \(name) ===\n", to: logURL)
            let ending = try runScript(ssfURL, logURL: logURL, timeout: timeout)
            lastEnding = ending
            return ending == .exited(0) && fm.fileExists(atPath: produced.path)
        }
        func finish(_ outcome: StageOutcome) throws -> StackResult {
            // Move the master out of Siril's working area before that is cleared.
            let finalMaster = workDir.appendingPathComponent("master_stack.fits")
            try? fm.removeItem(at: finalMaster)
            try fm.moveItem(at: produced, to: finalMaster)
            return StackResult(master: finalMaster, outcome: outcome)
        }
        let single = { try self.singleFrameScript(selection.lights[0], in: processDir, masterOut: masterOut) }

        if selection.lights.count == 1 {
            if try run("single", single(), timeout: budget) {
                return try finish(StageOutcome(stage: "register+stack", succeeded: true,
                                               fallback: "single-sub-unstacked"))
            }
            throw lastEnding == .timedOut ? SirilError.timedOut(seconds: Int(budget))
                : SirilError.noMaster("the sub couldn't be read (\(Self.describe(lastEnding)))")
        }

        if try run("stack", Self.registeredStackScript(lightsDir: lightsDir, processDir: processDir,
                                                       masterOut: masterOut),
                   timeout: budget) {
            return try finish(StageOutcome(stage: "register+stack", succeeded: true))
        }
        var timedOut = lastEnding == .timedOut
        if !timedOut {
            // Nothing converted means Siril couldn't read the subs at all;
            // every later rung would fail the same way.
            guard fm.fileExists(atPath: processDir.appendingPathComponent("light_.seq").path) else {
                throw SirilError.noMaster("the subs couldn't be read (\(Self.describe(lastEnding)))")
            }
            let registered = fm.fileExists(atPath: processDir.appendingPathComponent("r_light_.seq").path)
            if try run(registered ? "stack-unfiltered" : "stack-unregistered",
                       Self.fallbackStackScript(sequence: registered ? "r_light" : "light",
                                                processDir: processDir, masterOut: masterOut),
                       timeout: budget) {
                return try finish(StageOutcome(stage: "register+stack", succeeded: false, fallback:
                    registered ? "quality-filters-failed-unfiltered-stack"
                               : "registration-failed-unregistered-stack"))
            }
            timedOut = lastEnding == .timedOut
        }
        // Last rung: one frame, with its own (single-frame) budget.
        if try run("single", single(), timeout: timeoutOverride ?? Self.stackTimeout(for: [selection.lights[0]])) {
            return try finish(StageOutcome(stage: "register+stack", succeeded: false,
                                           fallback: timedOut ? "stack-timed-out-single-frame"
                                                              : "stack-failed-single-frame"))
        }
        throw timedOut ? SirilError.timedOut(seconds: Int(budget))
            : SirilError.noMaster("no stack or single frame could be made (\(Self.describe(lastEnding)))")
    }

    static func preamble(memGB: Double) -> String {
        """
        requires 1.2.0
        set core.mem_mode=1
        set core.mem_amount=\(memGB)
        set core.force_16bit=0
        setext fits

        """
    }

    /// NB: cd/load/save accept quotes (spaces ok); convert/stack `-out=` do not
    /// (space-free scratch guarantees that). `-debayer` is mandatory for the
    /// Seestar OSC CFA. Colour calibration runs as its own fallback-aware step
    /// after the stack; gradient removal runs in-process in Baker.
    ///
    /// Stacking choices:
    /// · `force_16bit=0` (preamble) — the layers are float32 and `FITSImage`
    ///   requires BITPIX=-32; without this the bake depends on the user's
    ///   Siril config.
    /// · `-filter-wfwhm=3k` (sigma) not `90%` (percentile): a percentile
    ///   ALWAYS discards the worst tenth even when every frame is good —
    ///   ~10% of hard-won integration thrown away on a clean night.
    /// · `-weight=noise` not `wfwhm`: Seestar sessions mix 10 s and 30 s
    ///   subs, and a 30 s sub carries 3× the signal regardless of its star
    ///   shape. Noise weighting is the SNR-correct choice.
    static func registeredStackScript(lightsDir: URL, processDir: URL, masterOut: URL) -> String {
        """
        cd "\(lightsDir.path)"
        convert light -debayer -out=\(processDir.path)
        cd "\(processDir.path)"
        register light -2pass
        seqapplyreg light -framing=cog -interp=lanczos4
        stack r_light rej w 3 3 -filter-round=2.5k -filter-wfwhm=3k -weight=noise -norm=addscale -output_norm -out=\(masterOut.path)

        """
    }

    /// The same rejection, normalisation and weighting as the main stack,
    /// without the `-filter-*` quality filters: those rank frames by the
    /// FWHM/roundness that registration measures, so they either had nothing
    /// to work with (unregistered) or are what left too little to stack.
    /// It runs on the sequence the first attempt already converted (for
    /// Seestar CFA subs, local debayered copies), so nothing is converted twice.
    static func fallbackStackScript(sequence: String, processDir: URL, masterOut: URL) -> String {
        """
        cd "\(processDir.path)"
        stack \(sequence) rej w 3 3 -weight=noise -norm=addscale -output_norm -out=\(masterOut.path)

        """
    }

    /// Debayer one sub on its own. Siril's `stack` refuses a one-image
    /// sequence, and `load`/`save` keeps the 16-bit integer depth of the
    /// converted sub (verified, Siril 1.4.4), which `FITSImage` can't read.
    /// PixelMath evaluates in float, so `pm` writes BITPIX=-32 with
    /// STACKCNT=1 / LIVETIME and the original header (RA/DEC for the plate
    /// solve). `-rescale` maps it to [0, 1] min-to-max — the same scaling
    /// `-output_norm` gives the stacked master (measured: 0.0 … 1.0).
    func singleFrameScript(_ light: Light, in processDir: URL, masterOut: URL) throws -> String {
        let fm = FileManager.default
        let input = processDir.appendingPathComponent("single_in", isDirectory: true)
        let output = processDir.appendingPathComponent("single_out", isDirectory: true)
        try? fm.removeItem(at: input)
        try? fm.removeItem(at: output)
        try fm.createDirectory(at: input, withIntermediateDirectories: true)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: input.appendingPathComponent("light_00000.\(light.url.pathExtension.lowercased())"),
                                  withDestinationURL: light.url)
        return """
        cd "\(input.path)"
        convert light -debayer -out=\(output.path)
        cd "\(output.path)"
        pm "$light_00001$" -rescale
        save "\(masterOut.path)"

        """
    }

    static func describe(_ ending: ChildProcess.Ending) -> String {
        switch ending {
        case .exited(let code): return "exit \(code)"
        case .signalled(let signal): return "killed by signal \(signal)"
        case .timedOut: return "timed out"
        case .cancelled: return "cancelled"
        }
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
        let logURL = workDir.appendingPathComponent("colour_pcc.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let ending = try runScript(script, logURL: logURL, timeout: 120)
        guard ending == .exited(0), FileManager.default.fileExists(atPath: output.path),
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

    /// Run one Siril script in its own process group, output appended to
    /// `logURL`. A timeout stops the whole group (SIGTERM, then SIGKILL) and
    /// is reported as `.timedOut`; Cancel stops it the same way and throws.
    /// Either way Siril has exited before this returns, so nothing it was
    /// writing can race the scratch cleanup.
    private func runScript(_ script: URL, logURL: URL, timeout: TimeInterval) throws -> ChildProcess.Ending {
        try Task.checkCancellation()
        let child = try ChildProcess(executable: sirilBin, arguments: ["-s", script.path], log: logURL)
        let ending = child.wait(until: Date().addingTimeInterval(timeout))
        if ending == .cancelled { throw CancellationError() }
        if ending == .timedOut {
            Baker.appendLog("Nebula: stopped Siril after \(Int(timeout)) s with no result\n", to: logURL)
        }
        return ending
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

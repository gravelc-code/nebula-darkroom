// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore
import NebulaEngine
import NebulaAI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The native Swift bake orchestrator (Phase 3) — replaces the Python
/// `bake.py` seam. Register + stack via Siril (subprocess, classical DSP stays
/// wrapped), then background-removal + denoise **in-process** via `NebulaAI`
/// (no subprocess, no FITS round-trip), then emit the five layers + a typed
/// manifest. Never a dead end: each stage falls into a good-enough fallback.
public struct Baker {
    public struct Progress: Sendable { public let fraction: Double; public let status: String }

    /// The current bake pipeline version. Bumped whenever the bake changes in a
    /// way that improves cached layers (e.g. the star-separation halo fix, the
    /// StarNet PNG bridge) so the Library can flag older targets for re-develop.
    public static let pipelineVersion = 8

    let denoiseModel: String?
    let bgeModel: String?
    let sirilBin: String?
    /// A FITS-in/out star-removal command with `{input}` / `{output}` placeholders
    /// (e.g. a user-supplied StarNet2 CLI). StarNet's model is proprietary, so it
    /// stays pluggable rather than bundled; nil / env-unset falls back to the
    /// classical star mask so star controls keep working.
    let starnetCmd: String?
    /// Background removal is ON by default (the reference pipelines run it
    /// unconditionally). `NEBULA_BACKGROUND_CORRECTION` overrides the
    /// parameter when set (`0` off, anything else on) for debugging. The
    /// untouched registered stack is always kept as `master`, so the
    /// correction remains a separately-blendable layer, never a bake-in.
    let applyBackgroundCorrection: Bool
    let applyNativeWhiteBalance: Bool

    public init(denoiseModel: String? = nil, bgeModel: String? = nil,
                sirilBin: String? = nil, starnetCmd: String? = nil,
                applyBackgroundCorrection: Bool = true,
                applyNativeWhiteBalance: Bool = true) {
        self.denoiseModel = denoiseModel
        self.bgeModel = bgeModel
        self.sirilBin = sirilBin
        self.starnetCmd = starnetCmd
        self.applyBackgroundCorrection = applyBackgroundCorrection
        self.applyNativeWhiteBalance = applyNativeWhiteBalance
    }

    public func bake(subsDir: URL, outDir: URL,
                     onProgress: (Progress) -> Void = { _ in }) throws -> Manifest {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var outcomes: [StageOutcome] = []
        let workDir = outDir.appendingPathComponent("_work", isDirectory: true)
        let siril = try? SirilStage(sirilBin: sirilBin)

        // Dev hook: `NEBULA_REUSE_STACK=1` re-runs everything downstream of the
        // stack from a cached `_work/master_stack.fits`, so colour/star work can
        // iterate with the source subs offline.
        let cachedStack = workDir.appendingPathComponent("master_stack.fits")
        let reuseStack = ProcessInfo.processInfo.environment["NEBULA_REUSE_STACK"] == "1"
            && fm.fileExists(atPath: cachedStack.path)

        var target: Target
        var instrument: String?
        let masterStack: URL
        if reuseStack {
            onProgress(Progress(fraction: 0.10, status: "Reusing cached stack…"))
            // Read before the stale outputs below are cleared: the previous
            // manifest is where a reused stack's target metadata comes from.
            target = reusableTarget(outDir: outDir, subsDir: subsDir, master: cachedStack)
            Self.removeStaleOutputs(in: outDir)
            masterStack = cachedStack
            outcomes.append(StageOutcome(stage: "register+stack", succeeded: true,
                                         fallback: "reused-cached-stack"))
            outcomes.append(StageOutcome(stage: "resolution", succeeded: true,
                                         fallback: "native-sampling-osc-safe"))
        } else {
            Self.removeStaleOutputs(in: outDir)
            let selection = try SirilStage.selectLights(in: subsDir)
            target = makeTarget(subsDir: subsDir, selection: selection)
            instrument = selection.lights.first?.header["INSTRUME"]

            // --- 1. Siril: compatible-filter selection, register + stack ----
            onProgress(Progress(fraction: 0.10, status: "Registering & stacking…"))
            guard let siril else { throw SirilStage.SirilError.notFound }
            let stack = try siril.stack(subsDir: subsDir, workDir: workDir, selection: selection)
            masterStack = stack.master
            outcomes.append(stack.outcome)
            outcomes.append(StageOutcome(stage: "resolution", succeeded: true,
                                         fallback: "native-sampling-osc-safe"))
            var skipped: [String] = []
            if selection.skippedIncompatible > 0 { skipped.append("excluded-\(selection.skippedIncompatible)-incompatible") }
            if selection.skippedUnreadable > 0 { skipped.append("skipped-\(selection.skippedUnreadable)-unreadable") }
            if !skipped.isEmpty {
                outcomes.append(StageOutcome(stage: "frame-selection", succeeded: true,
                                             fallback: skipped.joined(separator: ",")))
            }
        }

        let rawStack = try FITSImage.read(masterStack)
        let (w, h, c) = (rawStack.width, rawStack.height, rawStack.channels)
        let masterHWC = rawStack.hwcPixels()

        // What the stacker actually used. Registration drops frames it can't
        // solve and the stack filters the worst, so this is routinely 10-35%
        // below the accepted count — report the honest figure, never the input.
        if let cards = try? FITSHeader.read(masterStack) {
            if let n = Int(cards["STACKCNT"] ?? ""), n > 0 {
                target.capture.stackedFrameCount = min(n, target.capture.frameCount)
            }
            if let live = Double(cards["LIVETIME"] ?? ""), live > 0 {
                target.capture.stackedIntegrationSeconds = live
            }
            // Siril carries the reference sub's INSTRUME into the master.
            if instrument == nil { instrument = cards["INSTRUME"] }
        }

        // --- 2. Background removal FIRST — the reference-pipeline order:
        // a gradient biases the photometric colour fit (Siril itself warns
        // "correct the image gradient first" when PCC runs on a raw master).
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.30, status: "Removing sky gradient…"))
        let backgroundCorrected: [Float]
        var bgeRan = false
        if Self.wantsBackgroundCorrection(applyBackgroundCorrection),
           let bge = bgeModel ?? discover("bge-ai-models", "NEBULA_BGE_MODEL") {
            // GraXpert's own default smoothing (0.5): without it the background
            // model follows real nebulosity and eats frame-filling targets.
            let stage = try Self.aiStage("background-removal", input: masterHWC, workDir: workDir) {
                try BgExtractor(modelPath: bge).extract(pixels: masterHWC, h: h, w: w, c: c, smoothing: 0.5)
            }
            backgroundCorrected = stage.pixels
            bgeRan = stage.outcome.succeeded
            outcomes.append(stage.outcome)
        } else {
            backgroundCorrected = masterHWC
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true,
                                         fallback: "disabled-master-preserved"))
        }

        // --- 3. Catalogue colour on the gradient-free master ----------------
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.42, status: "Balancing colour…"))
        var colourMethod = ColourMethod.nativeWhiteBalance
        var calibrated = backgroundCorrected
        if target.capture.isBroadband, let siril {
            // Hand Siril the bg-removed pixels under the ORIGINAL header so the
            // plate solve keeps its astrometry seed.
            var solveInput: URL? = masterStack
            if bgeRan {
                let bgURL = workDir.appendingPathComponent("master_bg.fits")
                do {
                    try FITSImage.writeReplacingPixels(template: masterStack, to: bgURL,
                                                       hwc: backgroundCorrected,
                                                       width: w, height: h, channels: c)
                    solveInput = bgURL
                } catch {
                    // Never fall back to PCC on the raw master here: its
                    // output would REPLACE the gradient-removed pixels — the
                    // removal silently undone while the outcome still said
                    // it ran, and the colour fit biased by the very gradient
                    // Siril warns about. The native balance below runs on the
                    // gradient-free pixels instead.
                    solveInput = nil
                    Self.appendLog("colour: couldn't hand the gradient-free master to Siril: \(error)\n",
                                   to: workDir.appendingPathComponent("colour_pcc.log"))
                }
            }
            if let solveInput,
               let pcc = try Self.attempt({ try siril.photometricColour(master: solveInput, workDir: workDir) }),
               let pccImage = try? FITSImage.read(pcc) {
                // Siril normalises the largest PCC gain to 1, so calibration is
                // always a net dimming (M 42 lost half its red flux). A single
                // scalar restores the pre-PCC luminance scale; the calibrated
                // channel RATIOS — the actual colour — are untouched.
                calibrated = Self.renormaliseLuminance(reference: backgroundCorrected,
                                                       calibrated: pccImage.hwcPixels(), c: c)
                colourMethod = .pcc
                outcomes.append(StageOutcome(stage: "colour", succeeded: true))
            } else {
                outcomes.append(StageOutcome(stage: "colour", succeeded: solveInput != nil, fallback:
                    solveInput == nil ? "gradient-handoff-failed-native-balance"
                                      : "catalogue-unavailable-native-balance"))
            }
        } else {
            outcomes.append(StageOutcome(stage: "colour", succeeded: true,
                                         fallback: "narrowband-master-preserved"))
        }
        if colourMethod != .pcc && applyNativeWhiteBalance {
            let duoBand = !target.capture.isBroadband && Self.hasSeestarS50Response(instrument: instrument)
            calibrated = Self.nativeWhiteBalance(calibrated, h: h, w: w, c: c,
                                                 broadband: target.capture.isBroadband,
                                                 saturationReference: masterHWC,
                                                 duoBandResponse: duoBand)
            if !target.capture.isBroadband && !duoBand {
                outcomes.append(StageOutcome(stage: "duo-band-recombine", succeeded: true,
                                             fallback: "unknown-instrument-neutralise-only"))
            }
        }
        let validation = CorrectionValidator.accept(before: masterHWC, after: calibrated, channels: c)
        // A correction is only an optional alternative layer. If numerical
        // safeguards reject it, step back one correction at a time. The
        // validator judged gradient removal AND colour together, so a
        // rejection does not condemn the gradient removal: it is a separate
        // step with its own model, and is kept if it passes on its own.
        // Only if it doesn't is corrected an exact master passthrough.
        var correctedHWC = calibrated
        if !validation.0 {
            let notes = validation.1.joined(separator: ",")
            if bgeRan, CorrectionValidator.accept(before: masterHWC, after: backgroundCorrected,
                                                  channels: c).0 {
                correctedHWC = backgroundCorrected
                outcomes.append(StageOutcome(stage: "correction-validation", succeeded: false,
                                             fallback: notes + ";colour-dropped-gradient-removal-kept"))
            } else {
                correctedHWC = masterHWC
                outcomes.append(StageOutcome(stage: "correction-validation", succeeded: false,
                                             fallback: notes + ";master-preserved"))
            }
            // The layer no longer holds the catalogue colour, so don't claim
            // it did. (`ColourMethod` has no "uncalibrated" case; the outcome
            // above records exactly what the layer holds.)
            colourMethod = .nativeWhiteBalance
        }

        // --- 4. Denoise (in-process) -> its own layer ----------------------
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.55, status: "Denoising…"))
        let denoisedHWC: [Float]
        if let dn = denoiseModel ?? discover("denoise-ai-models", "NEBULA_DENOISE_MODEL") {
            let stage = try Self.aiStage("denoise", input: correctedHWC, workDir: workDir) {
                try Self.withinUnitRange(correctedHWC) { unit in
                    try Denoiser(modelPath: dn).denoise(pixels: unit, h: h, w: w, c: c, strength: 1.0)
                }
            }
            denoisedHWC = stage.pixels
            outcomes.append(stage.outcome)
        } else {
            denoisedHWC = correctedHWC
            outcomes.append(StageOutcome(stage: "denoise", succeeded: true,
                                         fallback: "model-unavailable-master-preserved"))
        }

        // --- 5. Star separation: neural model or classical mask, both GATED ---
        // A separator that "succeeds" can still eat the subject (a galaxy is a
        // big fuzzy star to a model; a nebula filament trips a threshold). Every
        // candidate must pass the extended-flux validator: the wide-blur
        // above-sky flux — the subject — has to survive in the starless layer.
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.72, status: "Separating stars…"))
        var starlessHWC: [Float]?
        var separationDetail = "separation-unavailable"
        /// Constrain a separator's result to compact flux, then accept it if the
        /// subject survives. The constraint is unconditional because a star
        /// layer must contain only compact sources by definition: whatever
        /// extended structure a separator pulled out is subject, not stars.
        /// (StarNet routinely takes a galaxy's nucleus as one big star, which
        /// then gets treated as a star everywhere downstream — dimmed by the
        /// Stars slider, eroded by Star Size, whitened as a saturated core.)
        func accepted(_ candidate: [Float], _ label: String) -> Bool {
            let refined = Self.compactOnlyStarless(master: correctedHWC, starless: candidate,
                                                   h: h, w: w, c: c, radius: 16)
            let v = Self.extendedFluxRetention(master: correctedHWC, starless: refined,
                                               h: h, w: w, c: c)
            guard !v.meaningful || v.retention >= 0.70 else { return false }
            starlessHWC = refined
            separationDetail = String(format: "%@-retention=%.2f", label, min(v.retention, 1))
            return true
        }
        if let cmd = starnetCmd ?? ProcessInfo.processInfo.environment["NEBULA_STARNET"] ?? Self.discoverStarNet() {
            if let sep = try Self.attempt({
                try runStarSeparation(cmd, masterHWC: correctedHWC, w: w, h: h, c: c, workDir: workDir)
            }) {
                if !accepted(sep, "model") {
                    outcomes.append(StageOutcome(stage: "star-separation-model", succeeded: false,
                                                 fallback: "subject-flux-lost-classical-star-mask"))
                }
            } else {
                outcomes.append(StageOutcome(stage: "star-separation-model", succeeded: false,
                                             fallback: "model-failed-classical-star-mask"))
            }
        }
        if starlessHWC == nil {
            _ = accepted(Self.classicalStarless(master: correctedHWC, detection: denoisedHWC,
                                                h: h, w: w, c: c), "classical")
        }
        if starlessHWC == nil {
            let conservative = Self.classicalStarless(master: correctedHWC, detection: denoisedHWC,
                                                      h: h, w: w, c: c,
                                                      knee: 6.5, radiusCap: 4, regain: 1.5)
            if !accepted(conservative, "conservative") {
                // Never a dead end: fade the gentlest candidate back toward the
                // master until the subject demonstrably survives. Star controls
                // keep working (weaker) and the subject can no longer be destroyed.
                var cand = conservative
                for _ in 0..<4 where starlessHWC == nil {
                    for i in 0..<cand.count { cand[i] = (cand[i] + correctedHWC[i]) * 0.5 }
                    _ = accepted(cand, "scaled")
                }
                if starlessHWC == nil { starlessHWC = correctedHWC }
            }
        }
        outcomes.append(StageOutcome(stage: "star-separation", succeeded: true,
                                     fallback: separationDetail))
        // stars = max(master - starless, 0)
        var starsHWC = [Float](repeating: 0, count: masterHWC.count)
        for i in 0..<starsHWC.count { starsHWC[i] = max(correctedHWC[i] - starlessHWC![i], 0) }

        // --- 5. Write the five layers --------------------------------------
        // Last cancel point: past here the layers and manifest get written.
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.85, status: "Writing layers…"))
        func writeLayer(_ hwc: [Float], _ name: String) throws -> LayerRef {
            let url = outDir.appendingPathComponent("\(name).fits")
            try FITSImage.fromHWC(hwc, width: w, height: h, channels: c).write(url)
            return LayerRef(layer: BakedLayer(rawValue: name)!, path: "\(name).fits",
                            format: .fits, width: w, height: h)
        }
        let layers = [
            try writeLayer(masterHWC, "master"),
            try writeLayer(correctedHWC, "corrected"),
            try writeLayer(denoisedHWC, "denoised"),
            try writeLayer(starlessHWC!, "starless"),
            try writeLayer(starsHWC, "stars"),
        ]

        let quality = ImageQualityReport(
            raw: ImageQualityStats.measure(masterHWC, channels: c),
            corrected: ImageQualityStats.measure(correctedHWC, channels: c),
            correctionAccepted: validation.0,
            colourMethod: colourMethod.rawValue,
            notes: validation.1)
        let qualityData = try JSONEncoder.quality.encode(quality)
        try qualityData.write(to: outDir.appendingPathComponent("quality.json"), options: .atomic)

        // --- 6. Manifest — LAST, atomically: its presence is what says the
        // layers beside it are complete and belong together. ---------------
        let manifest = Manifest(target: target, look: target.profile.initialLook,
                                colourMethod: colourMethod, layers: layers,
                                stageOutcomes: outcomes + [StageOutcome(stage: "pipeline-v\(Self.pipelineVersion)", succeeded: true)])
        try manifest.jsonData().write(to: outDir.appendingPathComponent("manifest.json"), options: .atomic)
        onProgress(Progress(fraction: 1.0, status: "Done"))
        return manifest
    }

    // MARK: - Target metadata from the first sub's header

    /// Whether a `FILTER` header names an emission-line filter, whose data must
    /// NOT go through photometric colour calibration.
    ///
    /// The Seestar's **"LP" filter is dual-narrowband** (Ha ~20 nm + OIII
    /// ~30 nm) — it is named for what it rejects, not for a broad passband.
    /// PCC derives a white balance from star photometry assuming a broadband
    /// response; applied to emission-line data it scaled M 8's red by 0.55 and
    /// took the nebula from R/G 1.82 to 1.11 — Ha rendered as grey. Narrowband
    /// data gets background neutralisation only, so its line ratios survive.
    static func isNarrowband(filter: String?) -> Bool {
        let f = (filter ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if f.isEmpty { return false }
        return f == "lp" || f.contains("duo") || f.contains("narrow")
            || f.contains("ha") || f.contains("oiii")
    }

    /// Whether the data came from a Seestar **S50**, whose duo-band response
    /// matrix `duoBandRecombine` inverts. That matrix is computed from
    /// Siril's SPCC profiles for the S50's own sensor × LP filter, so it is
    /// only valid there. The S30 has a different sensor (Sony IMX662 vs the
    /// S50's IMX462) and writes `INSTRUME = 'Seestar S30'` (S50 subs write
    /// `'Seestar S50'`); "S50 Pro"-style variants and third-party duo-band
    /// data are not known to share the response either. An exact match keeps
    /// everything else on background neutralisation only, which preserves
    /// whatever line ratio the sensor recorded.
    static func hasSeestarS50Response(instrument: String?) -> Bool {
        (instrument ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Seestar S50") == .orderedSame
    }

    /// The parameter decides; `NEBULA_BACKGROUND_CORRECTION`, when set, is a
    /// debugging override (`0` = off, anything else = on).
    static func wantsBackgroundCorrection(_ parameter: Bool,
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let override = environment["NEBULA_BACKGROUND_CORRECTION"] else { return parameter }
        return override != "0"
    }

    /// The five layers a bake writes, by file stem.
    static let layerNames = ["master", "corrected", "denoised", "starless", "stars"]

    /// Clear what a previous bake left in `outDir` before this one starts, so
    /// a bake that fails or is interrupted can never leave an old manifest
    /// describing new (or half-written) layers. Staged app bakes start in an
    /// empty folder; this matters when baking straight into a folder (the
    /// CLI). Logs, `_work/` (a reusable stack) and `source.txt` are kept.
    static func removeStaleOutputs(in outDir: URL) {
        let fm = FileManager.default
        for name in ["manifest.json", "quality.json", "thumb.png"] + layerNames.map({ "\($0).fits" }) {
            try? fm.removeItem(at: outDir.appendingPathComponent(name))
        }
    }

    /// Run `body` on pixels guaranteed to lie in [0, 1], and return its result
    /// on the original scale. Float layers are no longer clamped at 1, but
    /// the GraXpert denoise pipeline is defined on [0, 1] and clips its output
    /// there. That pipeline normalises by the channel median and MAD — both
    /// scale exactly with the input — and its keep-bright threshold is
    /// expressed in those units, so dividing by the peak and multiplying back
    /// is exact everywhere except the final clip it avoids. Identity when
    /// nothing exceeds 1 (the usual case).
    static func withinUnitRange(_ pixels: [Float], _ body: ([Float]) throws -> [Float]) rethrows -> [Float] {
        var peak: Float = 0
        for v in pixels where v.isFinite { peak = max(peak, v) }
        guard peak > 1 else { return try body(pixels) }
        let scaled = try body(pixels.map { $0 / peak })
        return scaled.map { $0 * peak }
    }

    /// Test seam for the header→`Target` classification (filter, band, profile).
    func makeTargetForTesting(subsDir: URL, selection: SirilStage.LightSelection) -> Target {
        makeTarget(subsDir: subsDir, selection: selection)
    }

    private func makeTarget(subsDir: URL, selection: SirilStage.LightSelection) -> Target {
        let cards = selection.lights.first?.header ?? [:]
        let exposures = selection.lights.map(\.exposure).sorted()
        let exposure = exposures.isEmpty ? 10 : exposures[exposures.count / 2]
        let filter = selection.filter == "UNKNOWN" ? nil : selection.filter
        let object = cards["OBJECT"]
        let name = object ?? cleanName(subsDir)
        let profile = Profile.guess(filter: filter, objectType: object)
        let narrow = Self.isNarrowband(filter: filter)
        let capture = CaptureStats(
            frameCount: selection.lights.count, subExposureSeconds: exposure,
            totalIntegrationSeconds: selection.integrationSeconds,
            hasMixedExposures: selection.exposures.count > 1, filter: filter,
            isBroadband: !narrow,
            raDegrees: Double(cards["RA"] ?? ""), decDegrees: Double(cards["DEC"] ?? ""),
            sensorTemperatureC: Double(cards["CCD-TEMP"] ?? ""))
        return Target(name: name, subsPath: subsDir.path, capture: capture, profile: profile)
    }

    /// Target metadata for a `NEBULA_REUSE_STACK` re-bake, where the source
    /// subs may be offline: the previous manifest when present, else a minimal
    /// stand-in derived from the folder name.
    private func reusableTarget(outDir: URL, subsDir: URL, master: URL? = nil) -> Target {
        if let data = try? Data(contentsOf: outDir.appendingPathComponent("manifest.json")),
           let manifest = try? Manifest(jsonData: data) {
            // Re-derive the band from the stored filter rather than trusting the
            // old manifest's verdict: classification rules change (the Seestar's
            // "LP" is dual-narrowband, not broadband), and a reused bake must
            // pick that up or it silently repeats the previous mistake.
            var target = manifest.target
            target.capture.isBroadband = !Self.isNarrowband(filter: target.capture.filter)
            return target
        }
        // No manifest: take what the stacked master's own header knows. The
        // filter in particular decides whether photometric calibration may run
        // at all, so guessing "broadband" would silently mis-calibrate any
        // duo-band stack handed to us directly.
        let cards = master.flatMap { try? FITSHeader.read($0) } ?? [:]
        let filter = cards["FILTER"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = cards["OBJECT"]
        let frames = Int(cards["STACKCNT"] ?? "") ?? 1
        let exposure = Double(cards["EXPTIME"] ?? "") ?? 10
        let capture = CaptureStats(frameCount: frames, subExposureSeconds: exposure,
                                   totalIntegrationSeconds: Double(cards["LIVETIME"] ?? ""),
                                   hasMixedExposures: false,
                                   filter: filter?.isEmpty == false ? filter : nil,
                                   isBroadband: !Self.isNarrowband(filter: filter),
                                   raDegrees: nil, decDegrees: nil,
                                   sensorTemperatureC: Double(cards["CCD-TEMP"] ?? ""))
        return Target(name: object ?? cleanName(subsDir), subsPath: subsDir.path,
                      capture: capture,
                      profile: Profile.guess(filter: filter, objectType: object))
    }

    private func cleanName(_ dir: URL) -> String {
        var n = dir.lastPathComponent
        for s in ["_mosaic_sub", "_mosaic_subs", "_subs", "_sub"] where n.hasSuffix(s) {
            n = String(n.dropLast(s.count)); break
        }
        return n.isEmpty ? dir.lastPathComponent : n
    }

    private func discover(_ base: String, _ env: String) -> String? {
        Self.discoverModel(base, env)
    }

    /// Locate a GraXpert ONNX model: env override → app bundle → Nebula's own
    /// Models folder → dev build path → the GraXpert app's cache (newest version,
    /// compared numerically). The models are never redistributed with Nebula;
    /// installing GraXpert (free, GPL) once populates its cache and Nebula finds
    /// them there automatically. Delegates to NebulaAI's `ModelLocator`, which the
    /// `nebula-ai` CLI shares, so app and CLI can't disagree. (The model's version
    /// travels in its path; `Denoiser(modelPath:)` reads it for the threshold.)
    static func discoverModel(_ base: String, _ env: String) -> String? {
        ModelLocator.locate(graxpertDirectory: base, environmentVariable: env)?.path
    }

    /// True when both AI models (sky-gradient removal + denoise) are locatable.
    /// The app uses this to offer first-run guidance before a bake that would
    /// otherwise silently fall back to the non-AI path.
    public static func aiModelsAvailable() -> Bool {
        ModelLocator.locate(.backgroundExtraction) != nil && ModelLocator.locate(.denoise) != nil
    }

    /// Run a StarNet-style star remover and return the starless HWC in LINEAR
    /// space. Two impedance mismatches are bridged here:
    ///   1. StarNet CLIs read TIFF/PNG, not FITS.
    ///   2. StarNet is trained on *stretched* images; the near-black linear
    ///      master would hide all but the brightest stars.
    /// So we apply the same invertible per-channel MTF autostretch the engine
    /// uses, hand StarNet a 16-bit TIFF, then invert the stretch on the returned
    /// starless — restoring linear space where `stars = master - starless` holds.
    /// The command template uses `{input}`/`{output}` (TIFF paths), e.g.
    /// `starnet2 -i {input} -o {output}`.
    private func runStarSeparation(_ template: String, masterHWC: [Float],
                                   w: Int, h: Int, c: Int, workDir: URL) throws -> [Float] {
        guard c == 3 else {
            throw NSError(domain: "NebulaBake", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "star separation needs RGB"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        // The command template goes through `bash -c` with no reliable quoting
        // convention, and every real cache dir has a space ("M 42"). Keep the
        // image round trip in a space-free scratch dir so any template works.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nebula-starnet-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let inURL = scratch.appendingPathComponent("starnet_in.tiff")
        let outURL = scratch.appendingPathComponent("starnet_out.tiff")

        // Invertible per-channel autostretch (linear → display), matching the
        // live engine, so StarNet sees a normal-looking astrophoto.
        // StarNet is trained on screen-stretched data, so hand it the classic
        // 0.25 background rather than Nebula's darker finished-image default.
        let stretch = AutoStretch(base: FITSImage.fromHWC(masterHWC, width: w, height: h, channels: c),
                                  targetBG: 0.25)
        let sh = [stretch.shadow.0, stretch.shadow.1, stretch.shadow.2]
        let mt = [stretch.midtone.0, stretch.midtone.1, stretch.midtone.2]
        var stretched = [Float](repeating: 0, count: masterHWC.count)
        for pix in 0..<(w * h) {
            for ch in 0..<3 {
                stretched[pix*3+ch] = Self.forwardStretch(masterHWC[pix*3+ch], shadow: sh[ch], midtone: mt[ch])
            }
        }
        try Self.writeTIFF16(stretched, w: w, h: h, to: inURL)

        let cmd = template
            .replacingOccurrences(of: "{input}", with: inURL.path)
            .replacingOccurrences(of: "{output}", with: outURL.path)
        // starnet2 builds resolve their weights relative to the working
        // directory, so run from the binary's own directory when we can tell.
        var cwd: URL?
        if let bin = Self.commandBinaryPath(template), fm.isExecutableFile(atPath: bin) {
            cwd = URL(fileURLWithPath: bin).deletingLastPathComponent()
        }
        let logURL = workDir.appendingPathComponent("star-separation.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        var sample: [Float] = []
        sample.reserveCapacity(stretched.count / 64 + 1)
        var si = 0
        while si < stretched.count { sample.append(stretched[si]); si += 64 }
        sample.sort()
        let p99 = sample[Int(Float(sample.count) * 0.99)]
        Self.appendLog(cmd + "\n" + String(format: "input-p99=%.3f\n", p99), to: logURL)
        try Self.runStarCommand(cmd, workingDirectory: cwd, log: logURL,
                                timeout: Self.starSeparationTimeout(width: w, height: h))
        guard fm.fileExists(atPath: outURL.path) else {
            throw NSError(domain: "NebulaBake", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "starnet produced no output"])
        }
        // Invert the stretch so the starless returns to linear space.
        let starlessStretched = try Self.readTIFF16(outURL, w: w, h: h)
        var out = [Float](repeating: 0, count: masterHWC.count)
        for pix in 0..<(w * h) {
            for ch in 0..<3 {
                out[pix*3+ch] = Self.inverseStretch(starlessStretched[pix*3+ch], shadow: sh[ch], midtone: mt[ch])
            }
        }
        return out
    }

    /// Locate a StarNet2 CLI so star removal "just works" once the user installs
    /// it — no `NEBULA_STARNET` needed. Only the modern `starnet2` build
    /// (Nebulophotos, `-i`/`-o` interface) is auto-wired; other CLIs (different
    /// argument syntax) use the env override. A GUI app's PATH usually omits
    /// `/usr/local/bin`, so the common install locations are checked directly.
    static func discoverStarNet() -> String? {
        let fm = FileManager.default
        let candidates = ["/usr/local/bin/starnet2", "/opt/homebrew/bin/starnet2", "/usr/bin/starnet2"]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return "'\(path)' -i {input} -o {output}"
        }
        return nil
    }

    /// First token of a shell command template, unquoted — used to locate the
    /// StarNet binary so it can run from its own directory (weights live there).
    static func commandBinaryPath(_ template: String) -> String? {
        let t = template.trimmingCharacters(in: .whitespaces)
        var bin = t
        if t.hasPrefix("'") {
            let rest = t.dropFirst()
            guard let close = rest.firstIndex(of: "'") else { return nil }
            bin = String(rest[..<close])
        } else if let space = t.firstIndex(of: " ") {
            bin = String(t[..<space])
        }
        return bin.hasPrefix("/") ? bin : nil
    }

    /// How long a star-separation command may run before it is treated as
    /// hung. Measured (2026-10-27): `/usr/local/bin/starnet2` (CoreML model
    /// package) separated a 1080×1920 S50-size frame in 3.93 s wall on an
    /// Apple M5 = 1.9 s per megapixel. A build or Mac without that
    /// acceleration runs the same network on the CPU, so the budget allows
    /// 60 s/MP (~30× the measured rate), with a 5-minute floor for model
    /// load — an S50 frame (124 s by rate) gets the floor. Observed in
    /// testing: the same binary once sat in "Loading CoreML model package"
    /// past 300 s on a run where it otherwise takes 2–4 s; the deadline is
    /// what turned that into the classical-mask fallback instead of a bake
    /// that never finished.
    static func starSeparationTimeout(width: Int, height: Int) -> TimeInterval {
        max(300, 60 * Double(width * height) / 1_000_000)
    }

    /// Run a star-separation shell template in its own process group with a
    /// deadline, and require it to succeed.
    ///
    /// · `pipefail`: bash otherwise reports only a pipeline's last stage, so
    ///   a failed StarNet piped into anything read as success.
    /// · Exit status 0 is required — a non-zero exit (StarNet exits 255 on an
    ///   image smaller than its window) can still leave a partial or stale
    ///   output file, which must never be decoded as the starless layer.
    /// · Cancel and timeout stop the whole group, not just bash, and return
    ///   only once it has exited, so nothing still writes into the scratch dir
    ///   when it is deleted.
    static func runStarCommand(_ cmd: String, workingDirectory: URL?, log: URL,
                               timeout: TimeInterval, shell: String = "/bin/bash") throws {
        try Task.checkCancellation()
        let child = try ChildProcess(executable: shell, arguments: ["-o", "pipefail", "-c", cmd],
                                     workingDirectory: workingDirectory, log: log)
        let ending = child.wait(until: Date().addingTimeInterval(timeout))
        switch ending {
        case .cancelled:
            throw CancellationError()
        case .exited(0):
            return
        default:
            let what = ending == .timedOut ? "timed out after \(Int(timeout)) s"
                                           : SirilStage.describe(ending)
            appendLog("Nebula: star separation \(what)\n", to: log)
            throw NSError(domain: "NebulaBake", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "star separation \(what)"])
        }
    }

    // MARK: - Invertible MTF autostretch (the same closed form the shader uses)

    static func mtf(_ x: Float, _ m: Float) -> Float {
        // The midtone floor must sit well below the ~1e-3 midtones linear astro
        // data needs, and its ceiling near 1 so `1 - midtone` stays invertible.
        let xx = min(max(x, 0), 1), mm = min(max(m, 0.0001), 0.9999)
        let d = (2*mm - 1)*xx - mm
        if abs(d) < 1e-6 { return xx }
        return min(max(((mm - 1)*xx) / d, 0), 1)
    }
    static func forwardStretch(_ x: Float, shadow: Float, midtone: Float) -> Float {
        let s = max((x - shadow) / max(1 - shadow, 1e-4), 0)
        return mtf(s, midtone)
    }
    static func inverseStretch(_ y: Float, shadow: Float, midtone: Float) -> Float {
        // The MTF's inverse is the MTF with the complementary midtone.
        let s = mtf(min(max(y, 0), 1), 1 - midtone)
        return s * (1 - shadow) + shadow
    }

    // MARK: - 16-bit TIFF bridge for StarNet (RGB, top-row-first)

    /// Encode HWC RGB floats (0…1) as a 16-bit TIFF.
    static func writeTIFF16(_ rgb: [Float], w: Int, h: Int, to url: URL) throws {
        var px = [UInt16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            for ch in 0..<3 { px[i*4+ch] = UInt16(min(max(rgb[i*3+ch], 0), 1) * 65535 + 0.5) }
            px[i*4+3] = 65535
        }
        let data = px.withUnsafeBytes { Data($0) }
        let cs = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64,
                                bytesPerRow: w * 8, space: cs, bitmapInfo: info, provider: provider,
                                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil)
        else {
            throw NSError(domain: "NebulaBake", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "cannot encode StarNet input"])
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "NebulaBake", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "cannot write StarNet input"])
        }
    }

    /// Decode a StarNet output image (TIFF or PNG) to HWC RGB floats at the
    /// expected size.
    static func readTIFF16(_ url: URL, w: Int, h: Int) throws -> [Float] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw NSError(domain: "NebulaBake", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read StarNet output"])
        }
        return try decodeRGB(img, w: w, h: h)
    }

    /// RGB samples of a decoded image as HWC floats in [0, 1].
    ///
    /// The usual case — 8- or 16-bit integer RGB(A) — is read straight from
    /// the decoded samples, so the round trip is exact (a CGContext draw
    /// colour-manages). That needs the layout decoded properly:
    /// · byte order is an enum FIELD of `CGBitmapInfo`, not a set of flags:
    ///   `.byteOrder16Big` (0x3000) "contains" `.byteOrder16Little` (0x1000),
    ///   so a flag test decoded big-endian samples unswapped. Compare
    ///   `intersection(.byteOrderMask)` instead. For 16-bit samples the
    ///   default order is big-endian; a 32-bit little order on 8-bit samples
    ///   reverses each 4-byte pixel (BGRA/ABGR in memory);
    /// · alpha may come first or last, premultiplied or not.
    /// Anything else (float or 32-bit samples, grey, indexed) is redrawn into
    /// a known 16-bit RGBX context — colour-managed, so approximate, but
    /// never misread.
    static func decodeRGB(_ img: CGImage, w: Int, h: Int) throws -> [Float] {
        guard img.width == w, img.height == h else {
            throw NSError(domain: "NebulaBake", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected StarNet output size"])
        }
        if let exact = decodeIntegerRGB(img) { return exact }
        let space = img.colorSpace?.model == .rgb ? img.colorSpace!
            : (CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16,
                                  bytesPerRow: w * 8, space: space, bitmapInfo: info) else {
            throw NSError(domain: "NebulaBake", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected StarNet output format"])
        }
        ctx.interpolationQuality = .none
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else {
            throw NSError(domain: "NebulaBake", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected StarNet output format"])
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        let samples = base.bindMemory(to: UInt16.self, capacity: w * h * 4)
        for p in 0..<(w * h) { for ch in 0..<3 {
            out[p*3+ch] = Float(UInt16(littleEndian: samples[p*4+ch])) / 65535
        } }
        return out
    }

    /// Exact read of 8/16-bit integer RGB(A) samples; nil for any other layout.
    private static func decodeIntegerRGB(_ img: CGImage) -> [Float]? {
        let bpc = img.bitsPerComponent
        let info = img.bitmapInfo
        guard bpc == 8 || bpc == 16, !info.contains(.floatComponents),
              img.colorSpace?.model == .rgb,
              let raw = img.dataProvider?.data as Data? else { return nil }
        let alpha = img.alphaInfo
        let comps = alpha == .none ? 3 : 4
        guard img.bitsPerPixel == comps * bpc else { return nil }
        let alphaFirst = [.first, .premultipliedFirst, .noneSkipFirst].contains(alpha)
        let premultiplied = alpha == .premultipliedFirst || alpha == .premultipliedLast
        let order = info.intersection(.byteOrderMask)
        // Logical component index (in the declared RGBA/ARGB order) → index
        // of that component in memory.
        var memoryIndex = Array(0..<comps)
        var littleSamples = false
        switch (bpc, order) {
        case (16, .byteOrder16Little): littleSamples = true
        case (16, .byteOrder16Big), (16, []): break
        case (8, .byteOrder32Little) where comps == 4: memoryIndex = [3, 2, 1, 0]
        case (8, .byteOrder32Big), (8, []): break
        default: return nil
        }
        let colourBase = alphaFirst ? 1 : 0
        let alphaIndex = alpha == .none ? nil : (alphaFirst ? 0 : 3)
        let (w, h, rowBytes) = (img.width, img.height, img.bytesPerRow)
        let maxValue: Float = bpc == 16 ? 65535 : 255
        guard rowBytes >= w * comps * bpc / 8, raw.count >= rowBytes * (h - 1) + w * comps * bpc / 8 else {
            return nil
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            func sample(_ row: UnsafeRawPointer, _ x: Int, _ logical: Int) -> Float {
                let m = memoryIndex[logical]
                if bpc == 16 {
                    let v = row.loadUnaligned(fromByteOffset: (x * comps + m) * 2, as: UInt16.self)
                    return Float(littleSamples ? UInt16(littleEndian: v) : UInt16(bigEndian: v)) / maxValue
                }
                return Float(row.load(fromByteOffset: x * comps + m, as: UInt8.self)) / maxValue
            }
            let base = buf.baseAddress!
            for y in 0..<h {
                let row = base + y * rowBytes
                for x in 0..<w {
                    let a: Float = premultiplied ? alphaIndex.map { sample(row, x, $0) } ?? 1 : 1
                    for ch in 0..<3 {
                        let v = sample(row, x, colourBase + ch)
                        out[(y*w+x)*3+ch] = premultiplied ? (a > 0 ? min(v / a, 1) : 0) : v
                    }
                }
            }
        }
        return out
    }

    // MARK: - Safe fallbacks

    /// Undo PCC's net attenuation without touching its colour: Siril scales the
    /// largest calibration gain to 1, so every other channel is only ever
    /// dimmed. One scalar restores the pre-calibration above-sky luminance
    /// scale (measured robustly at P95); the calibrated channel ratios — the
    /// actual photometric colour — pass through unchanged.
    ///
    /// No clamp at 1: `min(v·s, 1)` per channel broke exactly that promise —
    /// with s up to 3, a bright core's strongest channel stopped at 1 while
    /// the others kept rising, shifting its hue toward white/yellow. Nothing
    /// downstream needs layers ≤ 1: they are float32 FITS; the engine's base
    /// stretch maps luminance ≥ 1 to white by scaling all three channels by
    /// one factor (`withLuminance`) and its highlight guard brings any
    /// remaining out-of-gamut channel in by desaturating, not clipping; the
    /// validator counts ≥ 0.999 as white either way; and the denoiser is fed
    /// through `withinUnitRange`.
    static func renormaliseLuminance(reference: [Float], calibrated: [Float],
                                     c: Int) -> [Float] {
        guard c == 3, calibrated.count == reference.count else { return calibrated }
        func p95AboveSky(_ a: [Float]) -> Float {
            let n = a.count / 3
            var lums: [Float] = []
            lums.reserveCapacity(n / 16 + 1)
            var i = 0
            while i < n {
                lums.append(a[i*3] * 0.2126 + a[i*3+1] * 0.7152 + a[i*3+2] * 0.0722)
                i += 16
            }
            lums.sort()
            return max(lums[Int(Float(lums.count) * 0.95)] - lums[lums.count / 2], 1e-6)
        }
        // PCC can only have dimmed, so the factor is ≥ 1; the cap bounds a
        // degenerate fit from ever amplifying noise more than 3×.
        let s = min(max(p95AboveSky(reference) / p95AboveSky(calibrated), 1), 3)
        return calibrated.map { $0 * s }
    }

    /// Run one in-process AI stage without letting it end the bake. Discovery
    /// already handles a *missing* model; this covers one that is found but
    /// can't be used — a partial download, a corrupt file, or a newer GraXpert
    /// release with a different input shape. The stage then passes its input
    /// through unchanged, so the layer still exists and the sliders still work,
    /// and the reason goes to `_work/ai.log`. Cancel is the one error that
    /// must still propagate.
    static func aiStage(_ stage: String, input: [Float], workDir: URL,
                        _ run: () throws -> [Float]) throws -> (pixels: [Float], outcome: StageOutcome) {
        do {
            let out = try run()
            guard out.count == input.count else {
                throw NSError(domain: "NebulaBake", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "model returned \(out.count) values for \(input.count)"])
            }
            return (out, StageOutcome(stage: stage, succeeded: true))
        } catch let cancel as CancellationError {
            throw cancel
        } catch {
            appendLog("\(stage): \(error)\n", to: workDir.appendingPathComponent("ai.log"))
            return (input, StageOutcome(stage: stage, succeeded: false,
                                        fallback: "model-failed-input-preserved"))
        }
    }

    /// `try?` for an optional stage that must still honour Cancel: an ordinary
    /// failure means "use the fallback" (nil), but a cancellation propagates.
    /// A bare `try?` swallowed it, so a cancelled bake ran on and was cached.
    static func attempt<T>(_ body: () throws -> T?) throws -> T? {
        do { return try body() }
        catch let cancel as CancellationError { throw cancel }
        catch { return nil }
    }

    static func appendLog(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Neutralise the background, then use a robust sample of unsaturated bright
    /// pixels as a grey-world reference for broadband data. Narrowband data only
    /// receives background neutralisation so its line ratios are preserved;
    /// duo-band data from an instrument whose response is known
    /// (`duoBandResponse`, the Seestar S50) is then unmixed and recombined.
    ///
    /// `saturationReference` is the unprocessed master: saturation is a
    /// property of the RECORDED value — a core at the stack's full scale is
    /// clipped however much sky sits under it — so the guard tests those
    /// values, not the sky-subtracted signal. Testing the signal let a clipped
    /// core (1.0) over a 0.15 sky pass as 0.85 and enter the white reference,
    /// where its clipped channels bias the gains. Defaults to `hwc` itself.
    static func nativeWhiteBalance(_ hwc: [Float], h: Int, w: Int, c: Int,
                                   broadband: Bool, saturationReference: [Float]? = nil,
                                   duoBandResponse: Bool = false) -> [Float] {
        guard c == 3 else { return hwc }
        var samples = [[Float]](repeating: [], count: 3)
        for ch in 0..<3 { samples[ch].reserveCapacity(h * w / 16) }
        var p = 0
        while p < h * w {
            for ch in 0..<3 { samples[ch].append(hwc[p * c + ch]) }
            p += 16
        }
        for ch in 0..<3 { samples[ch].sort() }
        let bg = (0..<3).map { samples[$0][samples[$0].count / 2] }
        let commonBG = (bg[0] + bg[1] + bg[2]) / 3
        var gains = [Float](repeating: 1, count: 3)
        if broadband {
            var sums = [Double](repeating: 0, count: 3), count = 0
            var lumas: [Float] = []; lumas.reserveCapacity(samples[0].count)
            p = 0
            while p < h * w {
                let r = max(hwc[p*3] - bg[0], 0), g = max(hwc[p*3+1] - bg[1], 0)
                let b = max(hwc[p*3+2] - bg[2], 0)
                lumas.append(0.2126*r + 0.7152*g + 0.0722*b); p += 16
            }
            let sorted = lumas.sorted()
            let threshold = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.985))]
            let recorded = saturationReference?.count == hwc.count ? saturationReference! : hwc
            p = 0
            while p < h * w {
                let signal = (0..<3).map { max(hwc[p*3+$0] - bg[$0], 0) }
                let lum = 0.2126*signal[0] + 0.7152*signal[1] + 0.0722*signal[2]
                let unsaturated = recorded[p*3] < 0.9 && recorded[p*3+1] < 0.9 && recorded[p*3+2] < 0.9
                if lum >= threshold && unsaturated {
                    for ch in 0..<3 { sums[ch] += Double(signal[ch]) }
                    count += 1
                }
                p += 16
            }
            if count > 8 {
                let means = sums.map { Float($0 / Double(count)) }
                let target = (means[0] + means[1] + means[2]) / 3
                for ch in 0..<3 { gains[ch] = min(1.8, max(0.55, target / max(means[ch], 1e-6))) }
            }
        }
        // Floor at 0 (sub-sky noise), but no ceiling: a per-channel clamp at 1
        // would undo the gains on exactly the bright pixels, changing their
        // hue (see `renormaliseLuminance` for why nothing downstream needs ≤ 1).
        var out = hwc
        for i in 0..<(h*w) { for ch in 0..<3 {
            out[i*3+ch] = max(commonBG + (hwc[i*3+ch] - bg[ch]) * gains[ch], 0)
        } }
        return broadband || !duoBandResponse ? out : duoBandRecombine(out, h: h, w: w, c: c)
    }

    /// Recombine duo-band (Ha + OIII) data so both emission lines are legible.
    ///
    /// The Seestar's "LP" filter is dual-narrowband, and the sensor's response
    /// to the two lines is wildly asymmetric. Computed from Siril's own SPCC
    /// profiles for this exact sensor and filter (`ZWO_Seestar_S50` x
    /// `ZWO_Seestar_LP`), a unit photon flux in each line arrives as:
    ///
    ///          Ha      OIII
    ///     R [ 0.795   0.042 ]
    ///     G [ 0.245   0.739 ]
    ///     B [ 0.122   0.391 ]
    ///
    /// So pure Ha lands as RGB (1.00, 0.31, 0.15) — red collects 4.3x what the
    /// other two do together. An untreated stack therefore renders as one flat
    /// red *however good the data is*; the OIII structure is present but buried.
    ///
    /// Simply boosting green and blue — the obvious fix, and the one tried
    /// here first — lifts Ha's **leakage** into them along with the OIII, which
    /// washes the frame pink instead of revealing anything. So: unmix (recover
    /// the two lines by inverting the matrix above), align their sky pedestals,
    /// and recompose with the standard HOO weights. The measured line ratio is
    /// rendered as-is — see the pedestal-alignment comment in the body for why
    /// the reference tools' amplitude equalisation is deliberately NOT applied.
    ///
    /// A flat continuum source unmixes to Ha ≈ OIII and therefore renders
    /// neutral — which is physically right (M 1's synchrotron interior).
    static func duoBandRecombine(_ hwc: [Float], h: Int, w: Int, c: Int) -> [Float] {
        guard c == 3 else { return hwc }
        let n = h * w
        // Least-squares inverse of the response matrix above. Verified: a pure
        // Ha input yields (Ha 1, OIII 0), and pure OIII yields (0, 1).
        var ha = [Float](repeating: 0, count: n)
        var o3 = [Float](repeating: 0, count: n)
        for p in 0..<n {
            let r = hwc[p*3], g = hwc[p*3+1], b = hwc[p*3+2]
            ha[p] = max(1.280 * r - 0.051 * g - 0.039 * b, 0)
            o3[p] = max(-0.420 * r + 1.074 * g + 0.573 * b, 0)
        }
        func median(_ a: [Float]) -> Float {
            var s: [Float] = []
            s.reserveCapacity(n / 8 + 1)
            var i = 0
            while i < n { s.append(a[i]); i += 8 }
            s.sort()
            return s[s.count / 2]
        }
        // Align the PEDESTALS only — no amplitude boost.
        //
        // The reference tools (Siril's shipped script, Blanshan's
        // NarrowbandNormalization, VeraLux) equalise OIII's amplitude to Ha's,
        // but that is a convention for imagers who chose to shoot OIII and
        // want to see what they captured. Applied automatically it is wrong
        // twice over: it amplifies OIII *noise* into a teal wash on targets
        // with little real OIII (IC 2944 went teal), and it forces every
        // object to the same line ratio, erasing the real differences the
        // published spectra predict (M 27 at OIII/Ha 2.45 vs M 8 at 0.20).
        //
        // Rendering the MEASURED ratio through the standard composition below
        // reproduces the professional palette on its own: M 42's core
        // (ratio ~0.97) comes out neutral-white — matching ESO's reference,
        // which measures R/G = 1.03 there — M 27's body reads teal, and M 8 /
        // IC 2944 stay correctly red. Pedestal alignment is kept because the
        // two bands collect different amounts of sky (30 nm vs 20 nm), and
        // matching medians is exactly background neutralisation.
        let haSky = median(ha), o3Sky = median(o3)
        for p in 0..<n { o3[p] = max(o3[p] - o3Sky + haSky, 0) }

        // Recompose. Green carries mostly OIII with a little Ha so red regions
        // stay warm rather than going magenta; blue is nearly pure OIII.
        // Unclamped, like every float layer: a per-channel clip at 1 would
        // shift the hue of bright line emission (Ha clipped while OIII rises).
        var out = [Float](repeating: 0, count: hwc.count)
        for p in 0..<n {
            let a = ha[p], o = o3[p]
            out[p*3]     = a
            out[p*3 + 1] = 0.20 * a + 0.80 * o
            out[p*3 + 2] = 0.15 * a + 0.85 * o
        }
        return out
    }

    /// The star-split acceptance metric: how much of the **extended** above-sky
    /// flux — the subject — survives in the starless layer.
    ///
    /// Extended flux is isolated with a morphological opening, not a blur: a
    /// blur conserves total flux (it only spreads a star out), so in a
    /// star-dense field a blur-based measure punishes legitimate star removal.
    /// An opening with an element wider than any star deletes stars outright
    /// while leaving galaxies and nebulosity essentially intact.
    ///
    /// `meaningful` is false when the frame has no real extended signal (an
    /// open cluster, a bare star field), where any split is acceptable.
    static func extendedFluxRetention(master: [Float], starless: [Float],
                                      h: Int, w: Int, c: Int,
                                      radius: Int = 12) -> (retention: Float, meaningful: Bool) {
        guard c == 3, starless.count == master.count, h > 4 * radius, w > 4 * radius else {
            return (1, false)
        }
        let n = h * w
        func extended(_ a: [Float]) -> [Float] {
            var lum = [Float](repeating: 0, count: n)
            for i in 0..<n { lum[i] = a[i*3]*0.2126 + a[i*3+1]*0.7152 + a[i*3+2]*0.0722 }
            return dilate(erode(lum, h: h, w: w, radius: radius), h: h, w: w, radius: radius)
        }
        let om = extended(master), os = extended(starless)
        var sample: [Float] = []
        sample.reserveCapacity(n / 16 + 1)
        var i = 0
        while i < n { sample.append(om[i]); i += 16 }
        sample.sort()
        let sky = sample[sample.count / 2]
        // Noise floor from the same robust sample, so faint fields aren't judged
        // on sky ripple: only flux clearly above the sky counts as subject.
        var dev = sample.map { abs($0 - sky) }
        dev.sort()
        let floor = sky + 3 * 1.4826 * dev[dev.count / 2]
        var em = 0.0, es = 0.0
        for p in 0..<n {
            em += Double(max(om[p] - floor, 0))
            es += Double(max(os[p] - floor, 0))
        }
        let meaningful = em > Double(max(sky, 1e-6)) * 0.002 * Double(n)
        return (em > 0 ? Float(es / em) : 1, meaningful)
    }

    /// Repair a separator that took the subject along with the stars: keep only
    /// the **compact** part of what it removed. A morphological top-hat of the
    /// removed flux (removed − opening(removed)) passes point-like stars intact
    /// while an element wider than any star zeroes out galaxy/nebula structure,
    /// so extended signal returns to the starless layer and real star removal is
    /// preserved. This is what lets StarNet stay useful on galaxy fields, where
    /// it otherwise treats the galaxy itself as one big star.
    static func compactOnlyStarless(master: [Float], starless: [Float],
                                    h: Int, w: Int, c: Int, radius: Int = 10) -> [Float] {
        guard c == 3, starless.count == master.count, h > 4 * radius, w > 4 * radius else {
            return starless
        }
        let n = h * w
        var out = starless
        for ch in 0..<3 {
            var removed = [Float](repeating: 0, count: n)
            for i in 0..<n { removed[i] = max(master[i*3+ch] - starless[i*3+ch], 0) }
            let opened = dilate(erode(removed, h: h, w: w, radius: radius),
                                h: h, w: w, radius: radius)
            for i in 0..<n {
                let compact = max(removed[i] - opened[i], 0)
                out[i*3+ch] = max(master[i*3+ch] - compact, 0)
            }
        }
        return out
    }

    /// Classical star separation for when no StarNet command is configured
    /// (the shipping default): detect compact bright peaks against a
    /// star-resistant local background, then replace them with that background
    /// under a feathered mask. Cruder than a neural separator, but it keeps the
    /// Stars / Star Size controls functional — the design forbids an empty
    /// star layer. `detection` is the cleanest available view of the same data
    /// (the denoised layer when present) so noise doesn't trip the threshold.
    /// `knee`/`radiusCap`/`regain` trade removal aggressiveness for subject
    /// safety — the bake's validator ladder calls this at descending strengths.
    static func classicalStarless(master: [Float], detection: [Float],
                                  h: Int, w: Int, c: Int,
                                  knee: Float = 5, radiusCap: Int = 8,
                                  regain: Float = 2) -> [Float] {
        guard c == 3, h > 32, w > 32, detection.count == master.count else { return master }
        let n = h * w
        var lum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            lum[i] = detection[i*3]*0.2126 + detection[i*3+1]*0.7152 + detection[i*3+2]*0.0722
        }
        // Star-resistant background: morphological opening (erode→dilate)
        // then blur. Clip-and-blur let a bright star's own halo inflate the
        // estimate (~3x plateau measured on M 8: starless 0.027 over a 0.008
        // sky), which rendered as a bright ring around any star the user
        // shrank or dimmed. An erosion element larger than the halo removes
        // the star outright — it cannot contribute to its own background —
        // and the dilation restores the surrounding structure's extent.
        // Element sized to a stellar disc, not to broad structure: a 1080-wide
        // frame gets ~5 px (the old min(w,h)/96 = 11 px read 23 px-wide nebular
        // filaments and galaxy cores as "stars" and removed them).
        let radius = min(max(5, min(w, h) / 200), radiusCap)
        func localBackground(_ src: [Float]) -> [Float] {
            let opened = Self.dilate(Self.erode(src, h: h, w: w, radius: radius),
                                     h: h, w: w, radius: radius)
            return boxBlur(opened, h: h, w: w, c: 1, radius: radius)
        }
        let bg = localBackground(lum)
        // Robust residual scale via MAD on a sparse sample.
        var deviations: [Float] = []
        deviations.reserveCapacity(n / 16 + 1)
        var i = 0
        while i < n { deviations.append(abs(lum[i] - bg[i])); i += 16 }
        deviations.sort()
        let sigma = max(1.4826 * deviations[deviations.count / 2], 1e-5)
        // Soft mask over the positive residual: extended nebulosity varies
        // slowly and stays under the lower knee; compact star peaks saturate it.
        var mask = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = (lum[i] - bg[i]) / sigma
            let x = min(max((t - knee) / 6.0, 0), 1)
            mask[i] = x * x * (3 - 2 * x)
        }
        // Blur + regain ≈ dilate-and-feather: the halo around each star is
        // removed too, with no hard edge where the replacement begins.
        let feathered = boxBlur(mask, h: h, w: w, c: 1, radius: 2)
        for i in 0..<n { mask[i] = min(feathered[i] * regain, 1) }
        var out = master
        for ch in 0..<3 {
            var chan = [Float](repeating: 0, count: n)
            for i in 0..<n { chan[i] = master[i*3+ch] }
            let cbg = localBackground(chan)
            for i in 0..<n {
                out[i*3+ch] = master[i*3+ch] * (1 - mask[i]) + cbg[i] * mask[i]
            }
        }
        return out
    }

    /// Separable sliding-window minimum (greyscale erosion), single channel.
    /// The window is clamped at the edges (it shrinks rather than padding), and
    /// each pass runs in O(pixels) via a monotonic deque — the naive form was
    /// O(pixels × radius), which dominated bake time at useful element sizes.
    static func erode(_ src: [Float], h: Int, w: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return src }
        func pass(_ s: [Float], length: Int, count: Int, stride: Int, base: (Int) -> Int) -> [Float] {
            var out = s
            var deque = [Int](repeating: 0, count: length)   // indices, values ascending
            for line in 0..<count {
                let b = base(line)
                var head = 0, tail = 0, next = 0
                for i in 0..<length {
                    let hi = min(length - 1, i + radius)
                    while next <= hi {
                        let v = s[b + next*stride]
                        while tail > head && s[b + deque[tail-1]*stride] >= v { tail -= 1 }
                        deque[tail] = next; tail += 1; next += 1
                    }
                    let lo = i - radius
                    while deque[head] < lo { head += 1 }
                    out[b + i*stride] = s[b + deque[head]*stride]
                }
            }
            return out
        }
        let horizontal = pass(src, length: w, count: h, stride: 1) { $0 * w }
        return pass(horizontal, length: h, count: w, stride: w) { $0 }
    }

    /// Separable sliding-window maximum (greyscale dilation), single channel.
    static func dilate(_ src: [Float], h: Int, w: Int, radius: Int) -> [Float] {
        var negated = src
        for i in negated.indices { negated[i] = -negated[i] }
        var out = erode(negated, h: h, w: w, radius: radius)
        for i in out.indices { out[i] = -out[i] }
        return out
    }

    static func boxBlur(_ src: [Float], h: Int, w: Int, c: Int, radius: Int) -> [Float] {
        var dst = [Float](repeating: 0, count: src.count)
        for ch in 0..<c {
            var integral = [Double](repeating: 0, count: (h+1)*(w+1))
            for y in 0..<h {
                var row: Double = 0
                for x in 0..<w {
                    row += Double(src[(y*w+x)*c+ch])
                    integral[(y+1)*(w+1)+x+1] = integral[y*(w+1)+x+1] + row
                }
            }
            for y in 0..<h { for x in 0..<w {
                let x0=max(0,x-radius), x1=min(w-1,x+radius)
                let y0=max(0,y-radius), y1=min(h-1,y+radius)
                let sum = integral[(y1+1)*(w+1)+x1+1] - integral[y0*(w+1)+x1+1]
                    - integral[(y1+1)*(w+1)+x0] + integral[y0*(w+1)+x0]
                dst[(y*w+x)*c+ch] = Float(sum / Double((x1-x0+1)*(y1-y0+1)))
            } }
        }
        return dst
    }
}

private extension JSONEncoder {
    static var quality: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

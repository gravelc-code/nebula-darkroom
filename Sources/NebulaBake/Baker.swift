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
/// (no subprocess, no FITS round-trip), then emit the four layers + a typed
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
    /// unconditionally); `NEBULA_BACKGROUND_CORRECTION=0` disables it for
    /// debugging. The untouched registered stack is always kept as `master`,
    /// so the correction remains a separately-blendable layer, never a bake-in.
    let applyBackgroundCorrection: Bool
    let applyNativeWhiteBalance: Bool

    public init(denoiseModel: String? = nil, bgeModel: String? = nil,
                sirilBin: String? = nil, starnetCmd: String? = nil,
                applyBackgroundCorrection: Bool = false,
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
        let masterStack: URL
        if reuseStack {
            onProgress(Progress(fraction: 0.10, status: "Reusing cached stack…"))
            target = reusableTarget(outDir: outDir, subsDir: subsDir)
            masterStack = cachedStack
            outcomes.append(StageOutcome(stage: "register+stack", succeeded: true,
                                         fallback: "reused-cached-stack"))
            outcomes.append(StageOutcome(stage: "resolution", succeeded: true,
                                         fallback: "native-sampling-osc-safe"))
        } else {
            let selection = try SirilStage.selectLights(in: subsDir)
            target = makeTarget(subsDir: subsDir, selection: selection)

            // --- 1. Siril: compatible-filter selection, register + stack ----
            onProgress(Progress(fraction: 0.10, status: "Registering & stacking…"))
            guard let siril else { throw SirilStage.SirilError.notFound }
            masterStack = try siril.stack(subsDir: subsDir, workDir: workDir, selection: selection)
            outcomes.append(StageOutcome(stage: "register+stack", succeeded: true))
            outcomes.append(StageOutcome(stage: "resolution", succeeded: true,
                                         fallback: "native-sampling-osc-safe"))
            if selection.skippedIncompatible > 0 {
                outcomes.append(StageOutcome(stage: "frame-selection", succeeded: true,
                                             fallback: "excluded-\(selection.skippedIncompatible)-incompatible"))
            }
        }

        let rawStack = try FITSImage.read(masterStack)
        let (w, h, c) = (rawStack.width, rawStack.height, rawStack.channels)
        let masterHWC = rawStack.hwcPixels()

        // What the stacker actually used. Registration drops frames it can't
        // solve and the stack filters the worst, so this is routinely 10-35%
        // below the accepted count — report the honest figure, never the input.
        if let cards = try? FITSImage.readHeaderCards(masterStack) {
            if let n = Int(cards["STACKCNT"] ?? ""), n > 0 {
                target.capture.stackedFrameCount = min(n, target.capture.frameCount)
            }
            if let live = Double(cards["LIVETIME"] ?? ""), live > 0 {
                target.capture.stackedIntegrationSeconds = live
            }
        }

        // --- 2. Background removal FIRST — the reference-pipeline order:
        // a gradient biases the photometric colour fit (Siril itself warns
        // "correct the image gradient first" when PCC runs on a raw master).
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.30, status: "Removing sky gradient…"))
        let backgroundCorrected: [Float]
        var bgeRan = false
        let wantsBackground = applyBackgroundCorrection
            || ProcessInfo.processInfo.environment["NEBULA_BACKGROUND_CORRECTION"] != "0"
        if wantsBackground,
           let bge = bgeModel ?? discover("bge-ai-models", "NEBULA_BGE_MODEL") {
            // GraXpert's own default smoothing (0.5): without it the background
            // model follows real nebulosity and eats frame-filling targets.
            backgroundCorrected = try BgExtractor(modelPath: bge)
                .extract(pixels: masterHWC, h: h, w: w, c: c, smoothing: 0.5)
            bgeRan = true
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true))
        } else {
            backgroundCorrected = masterHWC
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true,
                                         fallback: "disabled-master-preserved"))
        }

        // --- 3. Catalogue colour on the gradient-free master ----------------
        onProgress(Progress(fraction: 0.42, status: "Balancing colour…"))
        var colourMethod = ColourMethod.nativeWhiteBalance
        var calibrated = backgroundCorrected
        if target.capture.isBroadband, let siril {
            // Hand Siril the bg-removed pixels under the ORIGINAL header so the
            // plate solve keeps its astrometry seed.
            var solveInput = masterStack
            if bgeRan {
                let bgURL = workDir.appendingPathComponent("master_bg.fits")
                if (try? FITSImage.writeReplacingPixels(template: masterStack, to: bgURL,
                                                        hwc: backgroundCorrected,
                                                        width: w, height: h, channels: c)) != nil {
                    solveInput = bgURL
                }
            }
            if let pcc = try? siril.photometricColour(master: solveInput, workDir: workDir),
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
                outcomes.append(StageOutcome(stage: "colour", succeeded: true,
                                             fallback: "catalogue-unavailable-native-balance"))
            }
        } else {
            outcomes.append(StageOutcome(stage: "colour", succeeded: true,
                                         fallback: "narrowband-master-preserved"))
        }
        if colourMethod != .pcc && applyNativeWhiteBalance {
            calibrated = Self.nativeWhiteBalance(calibrated, h: h, w: w, c: c,
                                                 broadband: target.capture.isBroadband)
        }
        let validation = CorrectionValidator.accept(before: masterHWC, after: calibrated, channels: c)
        // A correction is only an optional alternative layer. If numerical
        // safeguards reject it, corrected becomes an exact master passthrough.
        let correctedHWC = validation.0 ? calibrated : masterHWC
        if !validation.0 {
            outcomes.append(StageOutcome(stage: "correction-validation", succeeded: false,
                                         fallback: validation.1.joined(separator: ",")))
        }

        // --- 4. Denoise (in-process) -> its own layer ----------------------
        onProgress(Progress(fraction: 0.55, status: "Denoising…"))
        let denoisedHWC: [Float]
        if let dn = denoiseModel ?? discover("denoise-ai-models", "NEBULA_DENOISE_MODEL") {
            denoisedHWC = try Denoiser(modelPath: dn).denoise(pixels: correctedHWC, h: h, w: w, c: c, strength: 1.0)
            outcomes.append(StageOutcome(stage: "denoise", succeeded: true))
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
            if let sep = try? runStarSeparation(cmd, masterHWC: correctedHWC, w: w, h: h, c: c, workDir: workDir) {
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
            _ = accepted(Self.classicalStarless(master: correctedHWC, detection: denoisedHWC,
                                                h: h, w: w, c: c,
                                                knee: 6.5, radiusCap: 4, regain: 1.5), "conservative")
        }
        if starlessHWC == nil {
            // Never a dead end: fade the gentlest candidate back toward the
            // master until the subject demonstrably survives. Star controls
            // keep working (weaker) and the subject can no longer be destroyed.
            var cand = Self.classicalStarless(master: correctedHWC, detection: denoisedHWC,
                                              h: h, w: w, c: c,
                                              knee: 6.5, radiusCap: 4, regain: 1.5)
            for _ in 0..<4 where starlessHWC == nil {
                for i in 0..<cand.count { cand[i] = (cand[i] + correctedHWC[i]) * 0.5 }
                _ = accepted(cand, "scaled")
            }
            if starlessHWC == nil { starlessHWC = correctedHWC }
        }
        outcomes.append(StageOutcome(stage: "star-separation", succeeded: true,
                                     fallback: separationDetail))
        // stars = max(master - starless, 0)
        var starsHWC = [Float](repeating: 0, count: masterHWC.count)
        for i in 0..<starsHWC.count { starsHWC[i] = max(correctedHWC[i] - starlessHWC![i], 0) }

        // --- 5. Write the four layers --------------------------------------
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

        // --- 6. Manifest ---------------------------------------------------
        let manifest = Manifest(target: target, look: target.profile.initialLook,
                                colourMethod: colourMethod, layers: layers,
                                stageOutcomes: outcomes + [StageOutcome(stage: "pipeline-v\(Self.pipelineVersion)", succeeded: true)])
        try manifest.jsonData().write(to: outDir.appendingPathComponent("manifest.json"))
        onProgress(Progress(fraction: 1.0, status: "Done"))
        return manifest
    }

    // MARK: - Target metadata from the first sub's header

    private func makeTarget(subsDir: URL, selection: SirilStage.LightSelection) -> Target {
        let cards = selection.lights.first?.header ?? [:]
        let exposures = selection.lights.map(\.exposure).sorted()
        let exposure = exposures.isEmpty ? 10 : exposures[exposures.count / 2]
        let filter = selection.filter == "UNKNOWN" ? nil : selection.filter
        let object = cards["OBJECT"]
        let name = object ?? cleanName(subsDir)
        let profile = Profile.guess(filter: filter, objectType: object)
        let lowerFilter = filter?.lowercased() ?? ""
        let narrow = lowerFilter.contains("duo") || lowerFilter.contains("narrow")
            || lowerFilter.contains("ha") || lowerFilter.contains("oiii")
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
    private func reusableTarget(outDir: URL, subsDir: URL) -> Target {
        if let data = try? Data(contentsOf: outDir.appendingPathComponent("manifest.json")),
           let manifest = try? Manifest(jsonData: data) {
            return manifest.target
        }
        let capture = CaptureStats(frameCount: 1, subExposureSeconds: 10,
                                   totalIntegrationSeconds: nil, hasMixedExposures: false,
                                   filter: nil, isBroadband: true,
                                   raDegrees: nil, decDegrees: nil, sensorTemperatureC: nil)
        return Target(name: cleanName(subsDir), subsPath: subsDir.path, capture: capture,
                      profile: Profile.guess(filter: nil, objectType: nil))
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
    /// Models folder → dev build path → the GraXpert app's cache. The models are
    /// never redistributed with Nebula; installing GraXpert (free, GPL) once
    /// populates its cache and Nebula finds them there automatically.
    static func discoverModel(_ base: String, _ env: String) -> String? {
        let fm = FileManager.default
        if let e = ProcessInfo.processInfo.environment[env], fm.fileExists(atPath: e) { return e }
        // Shipped app: a model bundled in Nebula.app/Contents/Resources/Models.
        let bundled = base.contains("denoise") ? "denoise" : "bge"
        if let u = Bundle.main.url(forResource: bundled, withExtension: "onnx", subdirectory: "Models") {
            return u.path
        }
        // A model dropped into Nebula's own model home by the user.
        let home = NSString(string: "~/Library/Application Support/Nebula/Models/\(bundled).onnx")
            .expandingTildeInPath
        if fm.fileExists(atPath: home) { return home }
        let dev = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("build/Nebula.app/Contents/Resources/Models/\(bundled).onnx")
        if fm.fileExists(atPath: dev.path) { return dev.path }
        // The GraXpert app's model cache.
        let root = NSString(string: "~/Library/Application Support/GraXpert/\(base)").expandingTildeInPath
        guard let versions = try? fm.contentsOfDirectory(atPath: root) else { return nil }
        for v in versions.sorted(by: >) {
            let cand = "\(root)/\(v)/model.onnx"
            if fm.fileExists(atPath: cand) { return cand }
        }
        return nil
    }

    /// True when both AI models (sky-gradient removal + denoise) are locatable.
    /// The app uses this to offer first-run guidance before a bake that would
    /// otherwise silently fall back to the non-AI path.
    public static func aiModelsAvailable() -> Bool {
        discoverModel("bge-ai-models", "NEBULA_BGE_MODEL") != nil
            && discoverModel("denoise-ai-models", "NEBULA_DENOISE_MODEL") != nil
    }

    /// Run a StarNet-style star remover and return the starless HWC in LINEAR
    /// space. Two impedance mismatches are bridged here:
    ///   1. StarNet CLIs read TIFF/PNG, not FITS.
    ///   2. StarNet is trained on *stretched* images; the near-black linear
    ///      master would hide all but the brightest stars.
    /// So we apply the same invertible per-channel MTF autostretch the engine
    /// uses, hand StarNet a 16-bit PNG, then invert the stretch on the returned
    /// starless — restoring linear space where `stars = master - starless` holds.
    /// The command template uses `{input}`/`{output}` (now PNG paths), e.g.
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
        try Self.writePNG16(stretched, w: w, h: h, to: inURL)

        let cmd = template
            .replacingOccurrences(of: "{input}", with: inURL.path)
            .replacingOccurrences(of: "{output}", with: outURL.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        // starnet2 builds resolve their weights relative to the working
        // directory, so run from the binary's own directory when we can tell.
        if let bin = Self.commandBinaryPath(template), fm.isExecutableFile(atPath: bin) {
            p.currentDirectoryURL = URL(fileURLWithPath: bin).deletingLastPathComponent()
        }
        let logURL = workDir.appendingPathComponent("star-separation.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        try? log.write(contentsOf: Data((cmd + "\n").utf8))
        var sample: [Float] = []
        sample.reserveCapacity(stretched.count / 64 + 1)
        var si = 0
        while si < stretched.count { sample.append(stretched[si]); si += 64 }
        sample.sort()
        let p99 = sample[Int(Float(sample.count) * 0.99)]
        try? log.write(contentsOf: Data(String(format: "input-p99=%.3f\n", p99).utf8))
        p.standardOutput = log; p.standardError = log
        try p.run()
        while p.isRunning {
            if Task.isCancelled { p.terminate(); try? log.close(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? log.close()
        guard fm.fileExists(atPath: outURL.path) else {
            throw NSError(domain: "NebulaBake", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "starnet produced no output"])
        }
        // Invert the stretch so the starless returns to linear space.
        let starlessStretched = try Self.readPNG16(outURL, w: w, h: h)
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

    // MARK: - 16-bit PNG bridge for StarNet (RGB, top-row-first)

    /// Encode HWC RGB floats (0…1) as a 16-bit PNG.
    static func writePNG16(_ rgb: [Float], w: Int, h: Int, to url: URL) throws {
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

    /// Decode a StarNet output image to HWC RGB floats at the expected size.
    /// Reads the decoded image's raw samples directly (no CGContext draw, which
    /// colour-manages and resamples) so the round trip is exact. Handles 16- or
    /// 8-bit, RGB or RGBA, whatever StarNet emitted.
    static func readPNG16(_ url: URL, w: Int, h: Int) throws -> [Float] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let provider = img.dataProvider, let raw = provider.data as Data? else {
            throw NSError(domain: "NebulaBake", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "cannot read StarNet output"])
        }
        let bpc = img.bitsPerComponent
        let comps = img.bitsPerPixel / bpc          // 3 (RGB) or 4 (RGBA/RGBX)
        let rowBytes = img.bytesPerRow
        let little = img.bitmapInfo.contains(.byteOrder16Little) || img.bitmapInfo.contains(.byteOrder32Little)
        guard bpc == 16 || bpc == 8, comps >= 3, img.width == w, img.height == h else {
            throw NSError(domain: "NebulaBake", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "unexpected StarNet output format"])
        }
        var out = [Float](repeating: 0, count: w * h * 3)
        raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let base = buf.baseAddress!
            for y in 0..<h {
                let row = base + y * rowBytes
                for x in 0..<w {
                    for ch in 0..<3 {
                        let o = (y*w+x)*3+ch
                        if bpc == 16 {
                            let p = row.load(fromByteOffset: (x*comps+ch)*2, as: UInt16.self)
                            out[o] = Float(little ? p : p.byteSwapped) / 65535
                        } else {
                            let v = row.load(fromByteOffset: x*comps+ch, as: UInt8.self)
                            out[o] = Float(v) / 255
                        }
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
        var out = calibrated
        for i in 0..<out.count { out[i] = min(out[i] * s, 1) }
        return out
    }

    static func fallbackBackground(_ hwc: [Float], h: Int, w: Int, c: Int) -> [Float] {
        hwc
    }

    static func fallbackDenoise(_ hwc: [Float], h: Int, w: Int, c: Int) -> [Float] {
        hwc
    }

    /// Neutralise the background, then use a robust sample of unsaturated bright
    /// pixels as a grey-world reference for broadband data. Narrowband data only
    /// receives background neutralisation so its line ratios are preserved.
    static func nativeWhiteBalance(_ hwc: [Float], h: Int, w: Int, c: Int,
                                   broadband: Bool) -> [Float] {
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
            p = 0
            while p < h * w {
                let signal = (0..<3).map { max(hwc[p*3+$0] - bg[$0], 0) }
                let lum = 0.2126*signal[0] + 0.7152*signal[1] + 0.0722*signal[2]
                if lum >= threshold && signal.max()! < 0.9 {
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
        var out = hwc
        for i in 0..<(h*w) { for ch in 0..<3 {
            out[i*3+ch] = min(max(commonBG + (hwc[i*3+ch] - bg[ch]) * gains[ch], 0), 1)
        } }
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

// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore
import NebulaEngine
import NebulaAI

/// The native Swift bake orchestrator (Phase 3) — replaces the Python
/// `bake.py` seam. Register + stack via Siril (subprocess, classical DSP stays
/// wrapped), then background-removal + denoise **in-process** via `NebulaAI`
/// (no subprocess, no FITS round-trip), then emit the four layers + a typed
/// manifest. Never a dead end: each stage falls into a good-enough fallback.
public struct Baker {
    public struct Progress: Sendable { public let fraction: Double; public let status: String }

    let denoiseModel: String?
    let bgeModel: String?
    let sirilBin: String?
    /// A FITS-in/out star-removal command with `{input}` / `{output}` placeholders
    /// (e.g. a user-supplied StarNet2 CLI). StarNet's model is proprietary, so it
    /// stays pluggable rather than bundled; nil / env-unset falls back to the
    /// classical star mask so star controls keep working.
    let starnetCmd: String?
    /// Corrections that alter the linear master are explicit opt-ins. The
    /// untouched registered stack is the safe baseline and can always be
    /// re-rendered; model-derived layers remain separately adjustable.
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
        let selection = try SirilStage.selectLights(in: subsDir)
        let target = makeTarget(subsDir: subsDir, selection: selection)

        // --- 1. Siril: compatible-filter selection, register + stack --------
        onProgress(Progress(fraction: 0.10, status: "Registering & stacking…"))
        let workDir = outDir.appendingPathComponent("_work", isDirectory: true)
        let siril = try SirilStage(sirilBin: sirilBin)
        let masterStack = try siril.stack(subsDir: subsDir, workDir: workDir, selection: selection)
        outcomes.append(StageOutcome(stage: "register+stack", succeeded: true))
        outcomes.append(StageOutcome(stage: "resolution", succeeded: true,
                                     fallback: "native-sampling-osc-safe"))
        if selection.skippedIncompatible > 0 {
            outcomes.append(StageOutcome(stage: "frame-selection", succeeded: true,
                                         fallback: "excluded-\(selection.skippedIncompatible)-incompatible"))
        }

        // --- 2. Catalogue colour when available ----------------------------
        onProgress(Progress(fraction: 0.28, status: "Balancing colour…"))
        let colourInput: URL
        let colourMethod: ColourMethod
        if target.capture.isBroadband,
           let pcc = try? siril.photometricColour(master: masterStack, workDir: workDir) {
            colourInput = pcc
            colourMethod = .pcc
            outcomes.append(StageOutcome(stage: "colour", succeeded: true))
        } else {
            colourInput = masterStack
            colourMethod = .nativeWhiteBalance
            outcomes.append(StageOutcome(stage: "colour", succeeded: true,
                                         fallback: target.capture.isBroadband
                                            ? "catalogue-unavailable-master-preserved"
                                            : "narrowband-master-preserved"))
        }

        let rawStack = try FITSImage.read(masterStack)
        let correctionInput = try FITSImage.read(colourInput)
        let (w, h, c) = (rawStack.width, rawStack.height, rawStack.channels)
        let masterHWC = rawStack.hwcPixels()
        let correctionHWC = correctionInput.hwcPixels()

        // --- 3. Background removal (in-process) -> the master layer ---------
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.35, status: "Removing sky gradient…"))
        let backgroundCorrected: [Float]
        let wantsBackground = applyBackgroundCorrection
            || ProcessInfo.processInfo.environment["NEBULA_BACKGROUND_CORRECTION"] != "0"
        if wantsBackground,
           let bge = bgeModel ?? discover("bge-ai-models", "NEBULA_BGE_MODEL") {
            backgroundCorrected = try BgExtractor(modelPath: bge).extract(pixels: correctionHWC, h: h, w: w, c: c)
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true))
        } else {
            backgroundCorrected = correctionHWC
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true,
                                         fallback: "disabled-master-preserved"))
        }
        let shouldBalance = applyNativeWhiteBalance && colourMethod != .pcc
        let balanced = shouldBalance
            ? Self.nativeWhiteBalance(backgroundCorrected, h: h, w: w, c: c,
                                      broadband: target.capture.isBroadband)
            : backgroundCorrected
        // Protect strong signal from the WHOLE correction chain (PCC + BGE +
        // white balance), relative to the raw stack. PCC's global white point
        // is right for the sky and stars, but on an emission target it also
        // neutralises the nebula itself — M8's H-alpha lost a third of its
        // R/G ratio to calibration alone. Backgrounds calibrate fully; the
        // nebula body keeps its native colour.
        let protected = Self.protectSignal(master: masterHWC, corrected: balanced,
                                           h: h, w: w, c: c)
        let validation = CorrectionValidator.accept(before: masterHWC, after: protected, channels: c)
        // A correction is only an optional alternative layer. If numerical
        // safeguards reject it, corrected becomes an exact master passthrough.
        let correctedHWC = validation.0 ? protected : masterHWC
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

        // --- 5. Star separation: real model or classical star-mask fallback ---
        onProgress(Progress(fraction: 0.72, status: "Separating stars…"))
        var starlessHWC: [Float]?
        if let cmd = starnetCmd ?? ProcessInfo.processInfo.environment["NEBULA_STARNET"] {
            if let sep = try? runStarSeparation(cmd, masterHWC: correctedHWC, w: w, h: h, c: c, workDir: workDir) {
                starlessHWC = sep
                outcomes.append(StageOutcome(stage: "star-separation", succeeded: true))
            } else {
                outcomes.append(StageOutcome(stage: "star-separation-model", succeeded: false,
                                             fallback: "model-failed-classical-star-mask"))
            }
        }
        if starlessHWC == nil {
            // Never an empty star layer: without a neural separator, a feathered
            // classical mask keeps the Stars / Star Size controls functional.
            starlessHWC = Self.classicalStarless(master: correctedHWC, detection: denoisedHWC,
                                                 h: h, w: w, c: c)
            outcomes.append(StageOutcome(stage: "star-separation", succeeded: true,
                                         fallback: "classical-star-mask"))
        }
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
                                stageOutcomes: outcomes + [StageOutcome(stage: "pipeline-v5", succeeded: true)])
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

    /// Run a FITS-in/out star-removal command and return the starless HWC.
    private func runStarSeparation(_ template: String, masterHWC: [Float],
                                   w: Int, h: Int, c: Int, workDir: URL) throws -> [Float] {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let inURL = workDir.appendingPathComponent("_starnet_in.fits")
        let outURL = workDir.appendingPathComponent("_starnet_out.fits")
        try? fm.removeItem(at: outURL)
        try FITSImage.fromHWC(masterHWC, width: w, height: h, channels: c).write(inURL)

        let cmd = template
            .replacingOccurrences(of: "{input}", with: inURL.path)
            .replacingOccurrences(of: "{output}", with: outURL.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", cmd]
        let logURL = workDir.appendingPathComponent("star-separation.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
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
        let image = try FITSImage.read(outURL)
        guard image.width == w, image.height == h, image.channels == c else {
            throw NSError(domain: "NebulaBake", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "star separator changed image dimensions"])
        }
        return image.hwcPixels()
    }

    // MARK: - Safe fallbacks

    /// Background extraction on a frame-filling target subtracts real
    /// nebulosity as "gradient" (M8's H-alpha loses ~half its red). Fade the
    /// correction out over strong signal: gradients are a sky-level problem,
    /// and the nebula body must keep its calibrated colour.
    static func protectSignal(master: [Float], corrected: [Float],
                              h: Int, w: Int, c: Int) -> [Float] {
        guard c == 3, corrected.count == master.count else { return corrected }
        let n = h * w
        // Per-channel sky level from sparse medians. Signal is judged per
        // channel: an emission nebula can triple the red channel while barely
        // moving luminance, so a luminance test would leave it unprotected.
        var sky = [Float](repeating: 1e-5, count: 3)
        for ch in 0..<3 {
            var sample: [Float] = []
            sample.reserveCapacity(n / 16 + 1)
            var i = ch
            while i < n * 3 { sample.append(master[i]); i += 48 }
            sample.sort()
            sky[ch] = max(sample[sample.count / 2], 1e-5)
        }
        var ratio = [Float](repeating: 0, count: n)
        for p in 0..<n {
            var t: Float = 0
            for ch in 0..<3 { t = max(t, master[p*3+ch] / sky[ch]) }
            ratio[p] = t
        }
        // Blur the signal map so pixel noise can't modulate the smooth correction.
        let smooth = boxBlur(ratio, h: h, w: w, c: 1, radius: 2)
        var out = corrected
        for p in 0..<n {
            // Full correction at sky level, smoothly fading to 15% by 3.5× sky.
            let t = min(max((smooth[p] - 1.4) / 2.1, 0), 1)
            let keep = 1 - 0.85 * t * t * (3 - 2 * t)
            for ch in 0..<3 {
                let m = master[p*3+ch]
                out[p*3+ch] = m + (corrected[p*3+ch] - m) * keep
            }
        }
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

    /// Classical star separation for when no StarNet command is configured
    /// (the shipping default): detect compact bright peaks against a
    /// star-resistant local background, then replace them with that background
    /// under a feathered mask. Cruder than a neural separator, but it keeps the
    /// Stars / Star Size controls functional — the design forbids an empty
    /// star layer. `detection` is the cleanest available view of the same data
    /// (the denoised layer when present) so noise doesn't trip the threshold.
    static func classicalStarless(master: [Float], detection: [Float],
                                  h: Int, w: Int, c: Int) -> [Float] {
        guard c == 3, h > 32, w > 32, detection.count == master.count else { return master }
        let n = h * w
        var lum = [Float](repeating: 0, count: n)
        for i in 0..<n {
            lum[i] = detection[i*3]*0.2126 + detection[i*3+1]*0.7152 + detection[i*3+2]*0.0722
        }
        // Star-resistant background: blur, clip peaks down to it, blur again —
        // bright stars can't inflate their own local background estimate.
        let radius = max(6, min(w, h) / 96)
        func localBackground(_ src: [Float]) -> [Float] {
            let first = boxBlur(src, h: h, w: w, c: 1, radius: radius)
            var clipped = src
            for i in 0..<n { clipped[i] = min(src[i], first[i]) }
            return boxBlur(clipped, h: h, w: w, c: 1, radius: radius)
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
            let x = min(max((t - 3.5) / 6.5, 0), 1)
            mask[i] = x * x * (3 - 2 * x)
        }
        // Blur + regain ≈ dilate-and-feather: the halo around each star is
        // removed too, with no hard edge where the replacement begins.
        let feathered = boxBlur(mask, h: h, w: w, c: 1, radius: 2)
        for i in 0..<n { mask[i] = min(feathered[i] * 5, 1) }
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

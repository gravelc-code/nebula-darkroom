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
    /// stays pluggable rather than bundled; nil / env-unset -> starless = master.
    let starnetCmd: String?

    public init(denoiseModel: String? = nil, bgeModel: String? = nil,
                sirilBin: String? = nil, starnetCmd: String? = nil) {
        self.denoiseModel = denoiseModel
        self.bgeModel = bgeModel
        self.sirilBin = sirilBin
        self.starnetCmd = starnetCmd
    }

    public func bake(subsDir: URL, outDir: URL,
                     onProgress: (Progress) -> Void = { _ in }) throws -> Manifest {
        let fm = FileManager.default
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        var outcomes: [StageOutcome] = []

        // --- 1. Siril: register + stack + native colour --------------------
        onProgress(Progress(fraction: 0.10, status: "Registering & stacking…"))
        let workDir = outDir.appendingPathComponent("_work", isDirectory: true)
        let masterStack = try SirilStage(sirilBin: sirilBin).stack(subsDir: subsDir, workDir: workDir)
        outcomes.append(StageOutcome(stage: "register+stack", succeeded: true))
        outcomes.append(StageOutcome(stage: "colour", succeeded: true, fallback: "native-white-balance"))

        let stack = try FITSImage.read(masterStack)
        let (w, h, c) = (stack.width, stack.height, stack.channels)
        let stackHWC = stack.hwcPixels()

        // --- 2. Background removal (in-process) -> the master layer ---------
        try Task.checkCancellation()
        onProgress(Progress(fraction: 0.35, status: "Removing sky gradient…"))
        let masterHWC: [Float]
        if let bge = bgeModel ?? discover("bge-ai-models", "NEBULA_BGE_MODEL") {
            masterHWC = try BgExtractor(modelPath: bge).extract(pixels: stackHWC, h: h, w: w, c: c)
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true))
        } else {
            masterHWC = Self.fallbackBackground(stackHWC, h: h, w: w, c: c)
            outcomes.append(StageOutcome(stage: "background-removal", succeeded: true,
                                         fallback: "numerical-pedestal-subtraction"))
        }

        // --- 3. Denoise (in-process) -> its own layer ----------------------
        onProgress(Progress(fraction: 0.55, status: "Denoising…"))
        let denoisedHWC: [Float]
        if let dn = denoiseModel ?? discover("denoise-ai-models", "NEBULA_DENOISE_MODEL") {
            denoisedHWC = try Denoiser(modelPath: dn).denoise(pixels: masterHWC, h: h, w: w, c: c, strength: 1.0)
            outcomes.append(StageOutcome(stage: "denoise", succeeded: true))
        } else {
            denoisedHWC = Self.fallbackDenoise(masterHWC, h: h, w: w, c: c)
            outcomes.append(StageOutcome(stage: "denoise", succeeded: true, fallback: "box-blur-fallback"))
        }

        // --- 4. Star separation via a pluggable StarNet command, else fallback -
        onProgress(Progress(fraction: 0.72, status: "Separating stars…"))
        var starlessHWC = masterHWC
        if let cmd = starnetCmd ?? ProcessInfo.processInfo.environment["NEBULA_STARNET"] {
            if let sep = try? runStarSeparation(cmd, masterHWC: masterHWC, w: w, h: h, c: c, workDir: workDir) {
                starlessHWC = sep
                outcomes.append(StageOutcome(stage: "star-separation", succeeded: true))
            } else {
                outcomes.append(StageOutcome(stage: "star-separation", succeeded: true,
                                             fallback: "starnet-failed-starless-equals-master"))
            }
        } else {
            outcomes.append(StageOutcome(stage: "star-separation", succeeded: true,
                                         fallback: "no-separation-starless-equals-master"))
        }
        // stars = max(master - starless, 0)
        var starsHWC = [Float](repeating: 0, count: masterHWC.count)
        for i in 0..<starsHWC.count { starsHWC[i] = max(masterHWC[i] - starlessHWC[i], 0) }

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
            try writeLayer(denoisedHWC, "denoised"),
            try writeLayer(starlessHWC, "starless"),
            try writeLayer(starsHWC, "stars"),
        ]

        // --- 6. Manifest ---------------------------------------------------
        let target = try makeTarget(subsDir: subsDir)
        let manifest = Manifest(target: target, look: target.profile.initialLook,
                                colourMethod: .nativeWhiteBalance, layers: layers,
                                stageOutcomes: outcomes)
        try manifest.jsonData().write(to: outDir.appendingPathComponent("manifest.json"))
        onProgress(Progress(fraction: 1.0, status: "Done"))
        return manifest
    }

    // MARK: - Target metadata from the first sub's header

    private func makeTarget(subsDir: URL) throws -> Target {
        let fm = FileManager.default
        let fits = (try? fm.contentsOfDirectory(atPath: subsDir.path))?
            .filter { $0.lowercased().hasSuffix(".fit") || $0.lowercased().hasSuffix(".fits") }
            .sorted() ?? []
        let cards = fits.first.flatMap { try? FITSImage.readHeaderCards(subsDir.appendingPathComponent($0)) } ?? [:]
        let exposure = Double(cards["EXPTIME"] ?? cards["EXPOSURE"] ?? "") ?? 10
        let filter = cards["FILTER"]
        let object = cards["OBJECT"]
        let name = object ?? cleanName(subsDir)
        let profile = Profile.guess(filter: filter, objectType: object)
        let capture = CaptureStats(
            frameCount: fits.count, subExposureSeconds: exposure, filter: filter,
            isBroadband: !(filter?.lowercased().contains("ha") ?? false),
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
        if let e = ProcessInfo.processInfo.environment[env], FileManager.default.fileExists(atPath: e) { return e }
        let root = NSString(string: "~/Library/Application Support/GraXpert/\(base)").expandingTildeInPath
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for v in versions.sorted(by: >) {
            let cand = "\(root)/\(v)/model.onnx"
            if FileManager.default.fileExists(atPath: cand) { return cand }
        }
        return nil
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
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        guard fm.fileExists(atPath: outURL.path) else {
            throw NSError(domain: "NebulaBake", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "starnet produced no output"])
        }
        return try FITSImage.read(outURL).hwcPixels()
    }

    // MARK: - Fallbacks (mirror ai.py so the bake never dead-ends)

    static func fallbackBackground(_ hwc: [Float], h: Int, w: Int, c: Int) -> [Float] {
        var out = hwc
        for ch in 0..<c {
            var vals: [Float] = []; vals.reserveCapacity(h * w)
            var i = ch; while i < hwc.count { vals.append(hwc[i]); i += c }
            vals.sort()
            let pedestal = vals[Int(Double(vals.count) * 0.05)]
            var j = ch; while j < out.count { out[j] = max(out[j] - pedestal, 0); j += c }
        }
        return out
    }

    static func fallbackDenoise(_ hwc: [Float], h: Int, w: Int, c: Int) -> [Float] {
        var out = hwc
        func at(_ r: Int, _ x: Int, _ ch: Int) -> Float {
            hwc[(min(max(r, 0), h - 1) * w + min(max(x, 0), w - 1)) * c + ch]
        }
        for r in 0..<h { for x in 0..<w { for ch in 0..<c {
            var acc: Float = 0
            for dy in -1...1 { for dx in -1...1 { acc += at(r + dy, x + dx, ch) } }
            out[(r * w + x) * c + ch] = acc / 9
        } } }
        return out
    }
}

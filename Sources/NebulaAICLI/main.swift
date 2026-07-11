import Foundation
import NebulaAI
import NebulaEngine

// nebula-ai: native in-process replacement for the GraXpert subprocess.
//   nebula-ai denoise <in.fits> <out.fits> [--strength S] [--model P]
//   nebula-ai bg      <in.fits> <out.fits> [--model P]
// Models default to the GraXpert model cache; override with --model or the
// NEBULA_DENOISE_MODEL / NEBULA_BGE_MODEL env vars.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1)
}

/// Newest `model.onnx` under a GraXpert `*-ai-models` dir (versions sort desc).
func discoverModel(base: String, env: String) -> String? {
    if let e = ProcessInfo.processInfo.environment[env],
       FileManager.default.fileExists(atPath: e) { return e }
    let root = (NSString(string: "~/Library/Application Support/GraXpert/\(base)")
        .expandingTildeInPath)
    guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
    for v in versions.sorted(by: >) {
        let cand = "\(root)/\(v)/model.onnx"
        if FileManager.default.fileExists(atPath: cand) { return cand }
    }
    return nil
}

/// FITSImage (interleaved RGBA) -> row-major HxWxC used by the AI pipelines.
func toHWC(_ img: FITSImage) -> [Float] {
    let n = img.width * img.height, c = img.channels
    var out = [Float](repeating: 0, count: n * c)
    for p in 0..<n { for ch in 0..<c { out[p * c + ch] = img.rgba[p * 4 + ch] } }
    return out
}

/// HxWxC -> a FITSImage (broadcast mono to R=G=B, alpha=1) ready to write.
func fromHWC(_ hwc: [Float], width: Int, height: Int, channels: Int) -> FITSImage {
    let n = width * height
    var rgba = [Float](repeating: 1, count: n * 4)
    for p in 0..<n {
        if channels == 1 {
            let v = hwc[p]; rgba[p*4] = v; rgba[p*4+1] = v; rgba[p*4+2] = v
        } else {
            for ch in 0..<3 { rgba[p*4+ch] = hwc[p*channels+ch] }
        }
    }
    return FITSImage(width: width, height: height, channels: channels, rgba: rgba)
}

func optValue(_ args: [String], _ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    die("usage: nebula-ai <denoise|bg> <in.fits> <out.fits> [--strength S] [--model P]")
}
let cmd = args[1], inPath = args[2], outPath = args[3]

do {
    let img = try FITSImage.read(URL(fileURLWithPath: inPath))
    let hwc = toHWC(img)
    let result: [Float]

    switch cmd {
    case "denoise":
        guard let model = optValue(args, "--model")
            ?? discoverModel(base: "denoise-ai-models", env: "NEBULA_DENOISE_MODEL")
        else { die("denoise model not found (set --model or NEBULA_DENOISE_MODEL)") }
        let strength = Float(optValue(args, "--strength") ?? "1.0") ?? 1.0
        result = try Denoiser(modelPath: model)
            .denoise(pixels: hwc, h: img.height, w: img.width, c: img.channels, strength: strength)
    case "bg":
        guard let model = optValue(args, "--model")
            ?? discoverModel(base: "bge-ai-models", env: "NEBULA_BGE_MODEL")
        else { die("bge model not found (set --model or NEBULA_BGE_MODEL)") }
        result = try BgExtractor(modelPath: model)
            .extract(pixels: hwc, h: img.height, w: img.width, c: img.channels, smoothing: 0)
    default:
        die("unknown command '\(cmd)' (expected denoise|bg)")
    }

    try fromHWC(result, width: img.width, height: img.height, channels: img.channels)
        .write(URL(fileURLWithPath: outPath))
    print("nebula-ai \(cmd): \(inPath) -> \(outPath)")
} catch {
    die("nebula-ai \(cmd) failed: \(error)")
}

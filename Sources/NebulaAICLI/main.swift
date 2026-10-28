// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaAI
import NebulaEngine

// nebula-ai: native in-process replacement for the GraXpert subprocess — and a
// drop-in for the bake's own AI stages: same model discovery (ModelLocator),
// same defaults (denoise strength 1.0, background smoothing 0.5).

let usage = """
usage: nebula-ai denoise  <in.fits> <out.fits> [--strength S] [--batch N] [--model PATH]
       nebula-ai bg       <in.fits> <out.fits> [--smoothing S] [--model PATH]
       nebula-ai superres <in.fits> <out.fits> --model PATH

  --strength S   denoise blend, 0…1 (default 1.0, as the bake)
  --smoothing S  background-model smoothing, 0…1 (default 0.5: GraXpert's default, as the bake)
  --batch N      denoise tiles per model run, 1…32 (default: 4 below 16 GB RAM, else 8;
                 changes memory/speed only, never pixels)
  --model PATH   an explicit .onnx. Otherwise NEBULA_DENOISE_MODEL / NEBULA_BGE_MODEL, the
                 app bundle, ~/Library/Application Support/Nebula/Models, then GraXpert's
                 cache (newest version) — the same search the app uses. superres uses
                 --model or NEBULA_SUPERRES_MODEL.

exit status: 0 success, 1 processing failed, 2 bad arguments
"""

func die(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(code)
}

/// A usage error: message + usage on stderr, exit 2.
func usageError(_ msg: String) -> Never {
    die("nebula-ai: \(msg)\n\n\(usage)", code: 2)
}

struct Options {
    var command = "", input = "", output = ""
    var strength: Float = 1.0
    var smoothing: Float = 0.5
    var batch: Int?
    var model: String?
}

/// Strict parse: every flag must be known for the command, have a value, and
/// that value must parse and be in range. Nothing silently falls back.
func parse(_ argv: [String]) -> Options {
    if argv.contains("-h") || argv.contains("--help") { print(usage); exit(0) }
    var opts = Options()
    var positional: [String] = []
    let allowed: [String: Set<String>] = [
        "denoise": ["--strength", "--batch", "--model"],
        "bg": ["--smoothing", "--model"],
        "superres": ["--model"],
    ]
    guard let cmd = argv.first else { usageError("missing command") }
    guard let flags = allowed[cmd] else { usageError("unknown command '\(cmd)' (expected denoise|bg|superres)") }
    opts.command = cmd

    func unit(_ flag: String, _ text: String) -> Float {
        // Float("0,5") is nil and Float("nan") is NaN — both are errors, never 1.0.
        guard let v = Float(text), v.isFinite, (0...1).contains(v) else {
            usageError("\(flag) needs a number from 0 to 1 (got '\(text)')")
        }
        return v
    }

    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("--") {
            guard flags.contains(a) else { usageError("'\(a)' is not an option of '\(cmd)'") }
            guard i + 1 < argv.count else { usageError("\(a) needs a value") }
            let v = argv[i + 1]
            switch a {
            case "--strength": opts.strength = unit(a, v)
            case "--smoothing": opts.smoothing = unit(a, v)
            case "--batch":
                guard let n = Int(v), (1...32).contains(n) else {
                    usageError("--batch needs a whole number from 1 to 32 (got '\(v)')")
                }
                opts.batch = n
            case "--model":
                guard FileManager.default.fileExists(atPath: v) else { usageError("--model: no file at '\(v)'") }
                opts.model = v
            default: usageError("unhandled option '\(a)'")
            }
            i += 2
        } else {
            positional.append(a); i += 1
        }
    }
    guard positional.count == 2 else {
        usageError(positional.count < 2 ? "expected <in.fits> <out.fits>"
                                        : "unexpected argument '\(positional[2])'")
    }
    opts.input = positional[0]; opts.output = positional[1]
    return opts
}

let opts = parse(Array(CommandLine.arguments.dropFirst()))

/// `--model` wins (its version, if any, read from a GraXpert-layout path);
/// otherwise the app's own search order.
func resolve(_ kind: AIModel) -> LocatedModel {
    if let path = opts.model {
        return LocatedModel(explicitPath: path)
    }
    guard let found = ModelLocator.locate(kind) else {
        die("nebula-ai: \(kind.rawValue) model not found (pass --model, set \(kind.environmentVariable), "
            + "or install GraXpert once so its model cache exists)")
    }
    return found
}

do {
    let img = try FITSImage.read(URL(fileURLWithPath: opts.input))
    let hwc = img.hwcPixels()
    let result: [Float]
    var outputWidth = img.width, outputHeight = img.height

    switch opts.command {
    case "denoise":
        let model = resolve(.denoise)
        let dn = try Denoiser(model: model, batchSize: opts.batch)
        FileHandle.standardError.write(Data(("denoise model \(model.path) (version \(model.version?.description ?? "unknown"), "
            + "threshold \(dn.modelThreshold), batch \(dn.batchSize))\n").utf8))
        result = try dn.denoise(pixels: hwc, h: img.height, w: img.width, c: img.channels,
                                strength: opts.strength)
    case "bg":
        let model = resolve(.backgroundExtraction)
        FileHandle.standardError.write(Data("bge model \(model.path) (smoothing \(opts.smoothing))\n".utf8))
        result = try BgExtractor(model: model)
            .extract(pixels: hwc, h: img.height, w: img.width, c: img.channels, smoothing: opts.smoothing)
    default: // "superres" (parse() admits nothing else)
        guard img.channels == 3 else { die("nebula-ai: superres requires an RGB FITS image") }
        guard let model = opts.model ?? ProcessInfo.processInfo.environment["NEBULA_SUPERRES_MODEL"]
        else { die("nebula-ai: super-resolution model not found (pass --model or set NEBULA_SUPERRES_MODEL)") }
        let upscaled = try SuperResolver(modelPath: model)
            .upscale(pixels: hwc, h: img.height, w: img.width)
        result = upscaled.0; outputHeight = upscaled.1; outputWidth = upscaled.2
    }

    try FITSImage.fromHWC(result, width: outputWidth, height: outputHeight, channels: img.channels)
        .write(URL(fileURLWithPath: opts.output))
    print("nebula-ai \(opts.command): \(opts.input) -> \(opts.output)")
} catch {
    die("nebula-ai \(opts.command) failed: \(error)")
}

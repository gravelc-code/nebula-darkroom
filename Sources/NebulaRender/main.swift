// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaCore
import NebulaEngine
import NebulaAI

// nebula-render <layers_dir> <base> <out.png> [slider=value ...]
//   layers_dir : a bake output dir with master/denoised/starless/stars .fits
//   base       : default (the developed opening look) | neutral (truthful)
//   out.png    : where to write the rendered frame
//   slider=v   : optional overrides (0…1), e.g. detail=1 denoise=0 background=0.9
//   enhance=s  : AI super-resolution at strength s (needs NEBULA_SUPERRES_MODEL or
//                ~/Library/Application Support/Nebula/Models/superres.onnx)
//
// Headless export path — the same ChainRenderer the live app uses, so the PNG
// here equals what the interactive preview shows.

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data(
        "usage: nebula-render <layers_dir> <default|neutral> <out.png> [slider=value ...]\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
let baseLook: LookState
switch args[2] {
case "default": baseLook = .default
case "neutral", "auto": baseLook = .neutral
default:
    FileHandle.standardError.write(Data("unknown base look '\(args[2])' (use default|neutral)\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[3])

// Apply any `slider=value` overrides to the base look (dev/testing).
var look = baseLook
var exportScale = 1
var enhanceStrength: Float?
for kv in args.dropFirst(4) {
    let parts = kv.split(separator: "=")
    if parts.count == 2, parts[0] == "upscale", let value = Int(parts[1]), (1...2).contains(value) {
        exportScale = value; continue
    }
    if parts.count == 2, parts[0] == "enhance", let value = Float(parts[1]) {
        enhanceStrength = min(max(value, 0), 1); continue
    }
    guard parts.count == 2, let s = Slider(rawValue: String(parts[0])),
          let v = Double(parts[1]) else {
        FileHandle.standardError.write(Data("bad override '\(kv)'\n".utf8)); exit(2)
    }
    look[s] = v
}

func layer(_ name: String) throws -> FITSImage {
    try FITSImage.read(dir.appendingPathComponent("\(name).fits"))
}

func superResolutionModel() -> String? {
    let fm = FileManager.default
    if let path = ProcessInfo.processInfo.environment["NEBULA_SUPERRES_MODEL"],
       fm.fileExists(atPath: path) { return path }
    let user = NSString(string: "~/Library/Application Support/Nebula/Models/superres.onnx")
        .expandingTildeInPath
    return fm.fileExists(atPath: user) ? user : nil
}

do {
    let renderer = try ChainRenderer()
    let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
        .flatMap { try? Manifest(jsonData: $0) }
    let bundle = renderer.makeBundle(
        master: try layer("master"), corrected: try? layer("corrected"),
        denoised: try layer("denoised"),
        starless: try layer("starless"), stars: try layer("stars"),
        profile: manifest?.target.profile)
    if let strength = enhanceStrength {
        guard let model = superResolutionModel() else {
            FileHandle.standardError.write(Data("error: no super-resolution model found\n".utf8))
            exit(1)
        }
        let started = Date()
        let rendered = try renderer.renderImage(bundle: bundle, params: look.engineParams)
        let result = try SuperResolver(modelPath: model).upscale(
            pixels: rendered.hwcPixels(), h: rendered.height, w: rendered.width,
            strength: strength) { p in
                FileHandle.standardError.write(Data(String(format: "\renhance %3.0f%%", p * 100).utf8))
            }
        FileHandle.standardError.write(Data("\n".utf8))
        let enlarged = FITSImage.fromHWC(result.0, width: result.2, height: result.1, channels: 3)
        try renderer.writePNG(enlarged, to: out)
        print("rendered \(args[2]) + AI ×\(result.1 / rendered.height) → \(out.path)  "
              + "(\(result.2)×\(result.1), \(Int(-started.timeIntervalSinceNow))s)")
    } else {
        try renderer.renderPNG(bundle: bundle, params: look.engineParams, scale: exportScale, to: out)
        print("rendered \(args[2]) → \(out.path)  (\(bundle.width)×\(bundle.height))")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

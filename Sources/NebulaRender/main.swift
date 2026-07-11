import Foundation
import NebulaCore
import NebulaEngine

// nebula-render <layers_dir> <preset> <out.png> [slider=value ...]
//   layers_dir : a bake output dir with master/denoised/starless/stars .fits
//   preset     : auto | natural | vivid | deep
//   out.png    : where to write the rendered frame
//   slider=v   : optional overrides (0…1), e.g. detail=1 denoise=0 background=0.9
//
// Headless export path — the same ChainRenderer the live app uses, so the PNG
// here equals what the interactive preview shows.

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data(
        "usage: nebula-render <layers_dir> <preset> <out.png> [slider=value ...]\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
guard let preset = Preset(rawValue: args[2]) else {
    FileHandle.standardError.write(Data("unknown preset '\(args[2])'\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[3])

// Apply any `slider=value` overrides to the preset's look (dev/testing).
var look = preset.look
for kv in args.dropFirst(4) {
    let parts = kv.split(separator: "=")
    guard parts.count == 2, let s = Slider(rawValue: String(parts[0])),
          let v = Double(parts[1]) else {
        FileHandle.standardError.write(Data("bad override '\(kv)'\n".utf8)); exit(2)
    }
    look[s] = v
}

func layer(_ name: String) throws -> FITSImage {
    try FITSImage.read(dir.appendingPathComponent("\(name).fits"))
}

do {
    let renderer = try ChainRenderer()
    let bundle = renderer.makeBundle(
        master: try layer("master"), denoised: try layer("denoised"),
        starless: try layer("starless"), stars: try layer("stars"))
    try renderer.renderPNG(bundle: bundle, params: look.engineParams, to: out)
    print("rendered \(preset.displayName) → \(out.path)  (\(bundle.width)×\(bundle.height))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

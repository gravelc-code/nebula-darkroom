import Foundation
import NebulaCore
import NebulaEngine

// nebula-render <layers_dir> <preset> <out.png>
//   layers_dir : a bake output dir with master/denoised/starless/stars .fits
//   preset     : auto | natural | vivid | deep
//   out.png    : where to write the rendered frame
//
// Headless export path — the same ChainRenderer the live app uses, so the PNG
// here equals what the interactive preview shows.

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data(
        "usage: nebula-render <layers_dir> <preset> <out.png>\n".utf8))
    exit(2)
}
let dir = URL(fileURLWithPath: args[1])
guard let preset = Preset(rawValue: args[2]) else {
    FileHandle.standardError.write(Data("unknown preset '\(args[2])'\n".utf8))
    exit(2)
}
let out = URL(fileURLWithPath: args[3])

func layer(_ name: String) throws -> FITSImage {
    try FITSImage.read(dir.appendingPathComponent("\(name).fits"))
}

do {
    let renderer = try ChainRenderer()
    let bundle = renderer.makeBundle(
        master: try layer("master"), denoised: try layer("denoised"),
        starless: try layer("starless"), stars: try layer("stars"))
    try renderer.renderPNG(bundle: bundle, params: preset.look.engineParams, to: out)
    print("rendered \(preset.displayName) → \(out.path)  (\(bundle.width)×\(bundle.height))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

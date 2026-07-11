import Foundation
import NebulaCore

// nebula-render <layers_dir> <preset> <out.png>
//   layers_dir : a bake output dir with master/denoised/starless/stars .fits
//   preset     : auto | natural | vivid | deep
//   out.png    : where to write the rendered frame
//
// Phase 1 kernel de-risk: prove the Metal Stage-B chain on real baked layers,
// driven purely by EngineParams. Same code path as preview and (future) export.

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
    let master   = try layer("master")
    let denoised = try layer("denoised")
    let starless = try layer("starless")
    let stars    = try layer("stars")

    let params = preset.look.engineParams
    let renderer = try Renderer()
    try renderer.render(master: master, denoised: denoised, starless: starless,
                        stars: stars, params: params, to: out)
    print("rendered \(preset.displayName) → \(out.path)  (\(master.width)×\(master.height))")
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

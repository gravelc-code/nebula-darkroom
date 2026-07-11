import Foundation
import NebulaBake
import NebulaCore

// nebula-bake-native <subs_dir> <out_dir>
// Native Swift bake: Siril stack + in-process AI + manifest, no Python.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: nebula-bake-native <subs_dir> <out_dir>\n".utf8))
    exit(2)
}
let subs = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])

do {
    let manifest = try Baker().bake(subsDir: subs, outDir: out) { p in
        print(String(format: "  [%3.0f%%] %@", p.fraction * 100, p.status))
    }
    print("✓ baked \(manifest.target.name): \(manifest.layers.count) layers, "
          + "\(manifest.target.capture.frameCount) subs, colour \(manifest.colourMethod.rawValue)")
    for o in manifest.stageOutcomes {
        print("  · \(o.stage): " + (o.fallback.map { "fallback=\($0)" } ?? "ok"))
    }
} catch {
    FileHandle.standardError.write(Data("✗ bake failed: \(error)\n".utf8))
    exit(1)
}

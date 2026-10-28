// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import NebulaBake
import NebulaCore

// nebula-bake-native <subs_dir> <out_dir>
// Native Swift bake: Siril stack + in-process AI + manifest, no Python.
// Debug: NEBULA_CANCEL_AFTER=<seconds> cancels the bake to test interruption.
let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: nebula-bake-native <subs_dir> <out_dir>\n".utf8))
    exit(2)
}
let subs = URL(fileURLWithPath: args[1])
let out = URL(fileURLWithPath: args[2])

// The CLI bakes straight into <out_dir> (the app builds in a private staging
// folder instead), so two bakes into one folder would interleave their layers
// and share `_work/`. An advisory lock makes the second one refuse; the kernel
// drops it when this process exits, however it exits.
do {
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("✗ cannot create \(out.path): \(error)\n".utf8))
    exit(1)
}
let lockFD = open(out.appendingPathComponent(".bake.lock").path, O_CREAT | O_RDWR, 0o644)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    FileHandle.standardError.write(Data("✗ another bake is already writing to \(out.path)\n".utf8))
    exit(4)
}

let bakeTask = Task.detached(priority: .userInitiated) { () -> Manifest in
    try Baker().bake(subsDir: subs, outDir: out) { p in
        print(String(format: "  [%3.0f%%] %@", p.fraction * 100, p.status))
    }
}

if let s = ProcessInfo.processInfo.environment["NEBULA_CANCEL_AFTER"], let sec = Double(s) {
    Task { try? await Task.sleep(nanoseconds: UInt64(sec * 1_000_000_000)); print("… cancelling"); bakeTask.cancel() }
}

do {
    let manifest = try await bakeTask.value
    print("✓ baked \(manifest.target.name): \(manifest.layers.count) layers, "
          + "\(manifest.target.capture.frameCount) subs, colour \(manifest.colourMethod.rawValue)")
    for o in manifest.stageOutcomes {
        print("  · \(o.stage): " + (o.succeeded ? "" : "FAILED ")
              + (o.fallback.map { "fallback=\($0)" } ?? "ok"))
    }
} catch is CancellationError {
    FileHandle.standardError.write(Data("✗ bake cancelled\n".utf8))
    exit(3)
} catch {
    FileHandle.standardError.write(Data("✗ bake failed: \(error)\n".utf8))
    exit(1)
}

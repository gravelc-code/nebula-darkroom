// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import NebulaCore
import NebulaEngine
import NebulaBake

/// One-at-a-time access for async work (thumbnail renders): each render reads
/// five full-resolution layers, so a Library of cards without thumbnails must
/// not load them all at once.
@MainActor
final class SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

/// Thumbnail file IO and rendering, off the main thread.
enum ThumbnailIO {
    /// Serialises every read/write/delete of thumbnails and look saves, so a
    /// delete or save queued earlier can never land after a later write.
    static let queue = DispatchQueue(label: "app.nebula.cache-io", qos: .utility)

    static let maxDimension = 480

    static func pngData(_ cg: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Read a thumbnail file, in order with queued writes.
    static func read(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? Data(contentsOf: url)) }
        }
    }

    static func write(_ data: Data, to url: URL) {
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    static func remove(_ url: URL) {
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Persist the user's look into `dir/manifest.json`, stamped with the
    /// engine version it was authored for. Patches only the look, so fields a
    /// newer Nebula wrote survive.
    static func saveLook(_ look: LookState, in dir: URL) {
        queue.async {
            let url = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url),
                  let patched = try? Manifest.updatingLook(look, lookVersion: Baker.pipelineVersion,
                                                           in: data)
            else { return }
            try? patched.write(to: url, options: .atomic)
        }
    }

    /// Block until everything queued so far has hit the disk (quitting).
    static func flush() { queue.sync {} }

    /// Render a target's thumbnail from its layers on disk.
    static func render(dir: URL, renderer: ChainRenderer) -> CGImage? {
        func layer(_ name: String) -> FITSImage? {
            try? FITSImage.read(dir.appendingPathComponent("\(name).fits"))
        }
        guard let m = layer("master"), let d = layer("denoised"),
              let s = layer("starless"), let st = layer("stars") else { return nil }
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            .flatMap { try? Manifest(jsonData: $0) }
        let bundle = renderer.makeBundle(master: m, corrected: layer("corrected"), denoised: d,
                                         starless: s, stars: st, profile: manifest?.target.profile)
        let look = manifest?.look(forPipelineVersion: Baker.pipelineVersion) ?? .default
        return try? renderer.renderThumbnail(bundle: bundle, params: look.engineParams,
                                             maxDimension: maxDimension)
    }
}

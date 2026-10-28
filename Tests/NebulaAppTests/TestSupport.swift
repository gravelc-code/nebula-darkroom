// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation
import XCTest
@testable import NebulaApp
@testable import NebulaBake
import NebulaCore

/// A scratch cache + subs area, removed afterwards.
struct Sandbox {
    let root: URL
    var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-app-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A subs folder with `frames` fake FITS lights (plus a preview JPEG).
    @discardableResult
    func subs(_ name: String, frames: Int = 2, in parent: URL? = nil) throws -> URL {
        let dir = (parent ?? root).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<frames { try addFrame(to: dir, index: i) }
        try Data("jpeg".utf8).write(to: dir.appendingPathComponent("preview.jpg"))
        return dir
    }

    func addFrame(to dir: URL, index: Int) throws {
        try Data(repeating: UInt8(index & 0xff), count: 2880 + index)
            .write(to: dir.appendingPathComponent(String(format: "Light_%04d.fit", index)))
    }
}

/// What a finished bake leaves behind, as far as the app can tell: all five
/// layers and a current-pipeline manifest.
func writeFinishedBake(_ dir: URL, marker: String, subs: URL? = nil,
                       look: LookState = .default, lookVersion: Int? = nil) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["master", "corrected", "denoised", "starless", "stars"] {
        try Data(marker.utf8).write(to: dir.appendingPathComponent("\(name).fits"))
    }
    let target = Target(name: marker, subsPath: subs?.path ?? "/nowhere",
                        capture: CaptureStats(frameCount: 2, subExposureSeconds: 10),
                        profile: .broadbandNebula)
    let manifest = Manifest(target: target, look: look, colourMethod: .pcc, layers: [],
                            stageOutcomes: [StageOutcome(stage: "pipeline-v\(Baker.pipelineVersion)",
                                                         succeeded: true)],
                            lookVersion: lookVersion)
    try manifest.jsonData().write(to: dir.appendingPathComponent("manifest.json"))
}

func contents(_ url: URL) -> String? {
    (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
}

/// Thread-safe bookkeeping for stand-in bakes: who started, how many at once,
/// and which ones may finish.
final class BakeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var _maxConcurrent = 0
    private var _started: [String] = []
    private var _sawCancel: [String] = []
    private var released: Set<String> = []
    private var releaseAll = false

    var started: [String] { lock.withLock { _started } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    var sawCancel: [String] { lock.withLock { _sawCancel } }

    func release(_ name: String) { lock.withLock { _ = released.insert(name) } }
    func releaseEverything() { lock.withLock { releaseAll = true } }

    /// A stand-in bake: registers, waits until released (polling for Cancel
    /// like the real Baker does), then writes a finished bake.
    func work(progress fraction: Double = 0.5) -> BakeRunner.Work {
        { subs, out, report in
            let name = subs.lastPathComponent
            self.lock.withLock {
                self.running += 1
                self._maxConcurrent = max(self._maxConcurrent, self.running)
                self._started.append(name)
            }
            defer { self.lock.withLock { self.running -= 1 } }
            report(.init(fraction: fraction, status: "Working"))
            let giveUp = Date().addingTimeInterval(20)
            while !self.lock.withLock({ self.releaseAll || self.released.contains(name) }) {
                if Task.isCancelled {
                    self.lock.withLock { self._sawCancel.append(name) }
                    throw CancellationError()
                }
                if Date() > giveUp { throw CocoaError(.featureUnsupported) }   // never hang the suite
                Thread.sleep(forTimeInterval: 0.005)
            }
            try writeFinishedBake(out, marker: name, subs: subs)
        }
    }
}

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: TimeInterval = 10, _ message: String = "condition",
                file: StaticString = #filePath, line: UInt = #line,
                _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { XCTFail("timed out waiting for \(message)", file: file, line: line); return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

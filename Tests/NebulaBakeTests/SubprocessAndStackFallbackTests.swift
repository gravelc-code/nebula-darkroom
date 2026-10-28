// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import XCTest
@testable import NebulaBake
import NebulaEngine

/// External tools must be stoppable as a whole, bounded in time, and believed
/// only when they succeed; and a stack Siril can't register still ends in an
/// image.
final class SubprocessAndStackFallbackTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nebula-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private var log: URL { tmp.appendingPathComponent("star-separation.log") }

    private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    /// Wait (bounded) for a helper to have written its pid.
    private func pid(in file: URL) -> pid_t? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let s = try? String(contentsOf: file, encoding: .utf8),
               let p = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return p }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    // MARK: - StarNet command: exit status, pipefail, deadline, process group

    func testSuccessfulCommandRunsInTheRequestedDirectory() throws {
        let out = tmp.appendingPathComponent("cwd.txt")
        try Baker.runStarCommand("pwd > '\(out.path)'", workingDirectory: tmp, log: log, timeout: 30)
        let cwd = try String(contentsOf: out, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path,
                       tmp.resolvingSymlinksInPath().path)
    }

    func testFailingCommandIsAFailureEvenIfItLeftAnOutputFile() throws {
        // StarNet exits 255 on a too-small image; a partial file must not count.
        let partial = tmp.appendingPathComponent("starnet_out.tiff")
        XCTAssertThrowsError(try Baker.runStarCommand("echo partial > '\(partial.path)'; exit 255",
                                                      workingDirectory: nil, log: log, timeout: 30))
        XCTAssertThrowsError(try Baker.runStarCommand("false | cat", workingDirectory: nil,
                                                      log: log, timeout: 30),
                             "a failed stage inside a pipeline is still a failure")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("exit 255") && text.contains("exit 1"), text)
    }

    func testTimeoutStopsTheWholePipelineNotJustTheShell() throws {
        // The worker sits behind a pipe, so it is a grandchild: terminating
        // bash alone (the old Process.terminate) left it running.
        let pidFile = tmp.appendingPathComponent("worker.pid")
        let start = Date()
        XCTAssertThrowsError(try Baker.runStarCommand(
            "sh -c 'echo $$ > \"\(pidFile.path)\"; exec sleep 60' | cat",
            workingDirectory: nil, log: log, timeout: 1)) { error in
            XCTAssertTrue("\(error)".contains("timed out"), "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        let worker = try XCTUnwrap(pid(in: pidFile))
        XCTAssertFalse(isAlive(worker), "the grandchild was stopped with its group")
    }

    func testCancelStopsTheGroupAndThrowsCancellation() async throws {
        let pidFile = tmp.appendingPathComponent("worker.pid")
        let log = self.log
        let task = Task.detached { () throws -> Void in
            try Baker.runStarCommand("sh -c 'echo $$ > \"\(pidFile.path)\"; exec sleep 60' | cat",
                                     workingDirectory: nil, log: log, timeout: 120)
        }
        let worker = try XCTUnwrap(pid(in: pidFile))
        XCTAssertTrue(isAlive(worker))
        task.cancel()
        do {
            try await task.value
            XCTFail("a cancelled run must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(isAlive(worker), "nothing keeps writing after the cancel returns")
    }

    func testAWorkerThatIgnoresSIGTERMIsKilled() throws {
        let pidFile = tmp.appendingPathComponent("worker.pid")
        let child = try ChildProcess(executable: "/bin/bash", arguments: ["-c",
            "trap '' TERM; sh -c 'echo $$ > \"\(pidFile.path)\"; exec sleep 60'"], log: log)
        let worker = try XCTUnwrap(pid(in: pidFile))
        let ending = child.stop(grace: 0.5)
        XCTAssertEqual(ending, .signalled(SIGKILL), "escalated to SIGKILL")
        XCTAssertFalse(isAlive(worker))
    }

    func testExitStatusDecoding() {
        XCTAssertEqual(ChildProcess.decode(0), .exited(0))
        XCTAssertEqual(ChildProcess.decode(255 << 8), .exited(255))
        XCTAssertEqual(ChildProcess.decode(SIGKILL), .signalled(SIGKILL))
    }

    // MARK: - Siril stack fallback ladder (real Siril; skipped where absent)

    /// Float RGB subs Siril can convert (it symlinks FITS) with a little noise,
    /// so normalisation and rejection have something to work with.
    private func writeSubs(_ count: Int, in dir: URL, stars: Bool, size: Int = 96) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var seed: UInt64 = 42
        for i in 0..<count {
            var px = [Float](repeating: 0, count: size * size * 3)
            for p in 0..<(size * size) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Float((seed >> 40) % 1000) / 1000 * 0.004
                var v = 0.05 + noise
                if stars {
                    for (cx, cy) in [(20, 30), (70, 15), (50, 60), (15, 80), (80, 75)] {
                        let d = Float((p % size - cx) * (p % size - cx) + (p / size - cy) * (p / size - cy))
                        v += 0.6 * exp(-d / 3)
                    }
                }
                for ch in 0..<3 { px[p*3+ch] = v }
            }
            try FITSImage.fromHWC(px, width: size, height: size, channels: 3)
                .write(dir.appendingPathComponent("light_\(i).fits"))
        }
    }

    private func assertUsableMaster(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let master = try FITSImage.read(url)       // BITPIX = -32, the layers' contract
        let px = master.hwcPixels()
        XCTAssertEqual(master.channels, 3, file: file, line: line)
        XCTAssertEqual(px.max() ?? 0, 1, accuracy: 1e-4, "scaled like -output_norm", file: file, line: line)
        XCTAssertGreaterThanOrEqual(px.min() ?? -1, 0, file: file, line: line)
    }

    func testASingleSubBecomesTheMaster() throws {
        guard let siril = try? SirilStage() else { throw XCTSkip("Siril not installed") }
        let subs = tmp.appendingPathComponent("One_sub")
        try writeSubs(1, in: subs, stars: true)
        let result = try siril.stack(subsDir: subs, workDir: tmp.appendingPathComponent("work with space"))
        XCTAssertTrue(result.outcome.succeeded)
        XCTAssertEqual(result.outcome.fallback, "single-sub-unstacked")
        try assertUsableMaster(result.master)
        let header = try FITSHeader.read(result.master)
        XCTAssertEqual(header["STACKCNT"], "1")
    }

    func testFramesSirilCannotRegisterAreStackedUnregistered() throws {
        guard let siril = try? SirilStage() else { throw XCTSkip("Siril not installed") }
        let subs = tmp.appendingPathComponent("Starless_sub")
        try writeSubs(4, in: subs, stars: false)
        let result = try siril.stack(subsDir: subs, workDir: tmp.appendingPathComponent("work"))
        XCTAssertFalse(result.outcome.succeeded, "registration did fail")
        XCTAssertEqual(result.outcome.fallback, "registration-failed-unregistered-stack")
        try assertUsableMaster(result.master)
        XCTAssertEqual(try FITSHeader.read(result.master)["STACKCNT"], "4", "all four frames averaged")
        let log = try String(contentsOf: tmp.appendingPathComponent("work/siril.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("=== stack ===") && log.contains("=== stack-unregistered ==="))
    }

    func testAHungStackIsReportedAsATimeoutAndLeavesNoSirilRunning() throws {
        guard var siril = try? SirilStage() else { throw XCTSkip("Siril not installed") }
        siril.timeoutOverride = 0.05
        let subs = tmp.appendingPathComponent("Slow_sub")
        try writeSubs(3, in: subs, stars: true)
        XCTAssertThrowsError(try siril.stack(subsDir: subs, workDir: tmp.appendingPathComponent("work"))) {
            guard case SirilStage.SirilError.timedOut = $0 else {
                return XCTFail("a timeout is its own error, not 'no master': \($0)")
            }
            XCTAssertTrue("\($0)".contains("stopped responding"))
        }
        let log = try String(contentsOf: tmp.appendingPathComponent("work/siril.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("stopped Siril"), log)
        // Every Siril this test started had our work dir in its arguments.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", tmp.lastPathComponent]
        try pgrep.run(); pgrep.waitUntilExit()
        XCTAssertEqual(pgrep.terminationStatus, 1, "no Siril outlives the timeout")
    }
}

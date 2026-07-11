import Foundation

/// Runs the Nebula bake (Siril + AI) as a subprocess and streams its progress,
/// so the app can go straight from a `<Target>_subs` folder to the finished
/// layers without the user touching a terminal (design §6, Phase 4).
///
/// This is the "wrapper" seam: the heavy lifting stays in the proven
/// `prototype/nebula-bake.sh` pipeline; the app just drives it and shows
/// progress. When Phase 3 ports the bake to native Swift, only this file
/// changes — the UI above it stays put.
@MainActor
final class BakeRunner {
    struct Progress { var fraction: Double; var status: String }
    enum Outcome { case success(URL); case failure(String) }

    private var process: Process?

    /// A parsed bake stage and the progress fraction it maps to. The bake prints
    /// `●`-prefixed stage lines; we surface the newest as status text and step a
    /// coarse bar (exact per-frame progress isn't available from the tools).
    private static func fraction(for line: String) -> Double? {
        if line.contains("Capture:")  { return 0.08 }
        if line.contains("Siril:")    { return 0.15 }
        if line.contains("AI:")       { return 0.55 }
        if line.contains("Manifest:") { return 0.92 }
        if line.hasPrefix("✓")        { return 1.0 }
        return nil
    }

    /// Locate the durable bake entry script. Honours `NEBULA_BAKE`, else searches
    /// up from the CWD (the repo root when run via `swift run`).
    static func locateScript() -> URL? {
        if let e = ProcessInfo.processInfo.environment["NEBULA_BAKE"] {
            let u = URL(fileURLWithPath: e)
            if FileManager.default.isExecutableFile(atPath: u.path) { return u }
        }
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("prototype/nebula-bake.sh")
            if FileManager.default.isExecutableFile(atPath: cand.path) { return cand }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// A stable per-target bake cache: `~/Library/Caches/Nebula/<target>`.
    static func cacheDir(forTarget target: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula", isDirectory: true)
            .appendingPathComponent(target, isDirectory: true)
    }

    nonisolated static func hasAllLayers(in dir: URL) -> Bool {
        ["master", "starless", "stars", "denoised"].allSatisfy {
            FileManager.default.fileExists(atPath:
                dir.appendingPathComponent("\($0).fits").path)
        }
    }

    /// Bake `subsDir` into a layers dir, streaming progress via `onProgress`
    /// (called on the main actor). Returns the output dir or a failure message.
    /// If a complete bake already exists in the cache, returns it immediately.
    func bake(subsDir: URL, target: String,
              onProgress: @MainActor (Progress) -> Void) async -> Outcome {
        let out = Self.cacheDir(forTarget: target)
        if Self.hasAllLayers(in: out) {
            onProgress(Progress(fraction: 1.0, status: "Loaded cached bake"))
            return .success(out)
        }
        guard let script = Self.locateScript() else {
            return .failure("Bake script not found. Set NEBULA_BAKE or run from the repo root.")
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path, subsDir.path, "--out", out.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let readHandle = pipe.fileHandleForReading

        do { try p.run() } catch {
            return .failure("Could not start bake: \(error.localizedDescription)")
        }
        process = p

        // Stream stdout line-by-line. This whole method is @MainActor, so the
        // async iteration resumes on the main actor — `onProgress` is safe and
        // there's no cross-thread capture.
        var lastFraction = 0.02
        do {
            for try await raw in readHandle.bytes.lines {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("●") || line.hasPrefix("✓") || line.hasPrefix("✗")
                else { continue }
                let text = line.replacingOccurrences(of: "● ", with: "")
                    .replacingOccurrences(of: "●", with: "")
                if let f = Self.fraction(for: line) { lastFraction = f }
                onProgress(Progress(fraction: lastFraction, status: text))
            }
        } catch { /* pipe closed / read error → fall through to exit check */ }

        p.waitUntilExit()   // EOF already reached, so this returns promptly
        process = nil
        if p.terminationStatus == 0, Self.hasAllLayers(in: out) {
            return .success(out)
        }
        return .failure("Bake failed (exit \(p.terminationStatus)). See Console for details.")
    }

    func cancel() {
        process?.terminate()
        process = nil
    }
}

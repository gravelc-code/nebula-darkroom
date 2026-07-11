import Foundation

/// The Siril seam, native in Swift (Phase 3). Register + stack + native colour
/// via a bundled/pinned Siril subprocess — a faithful port of the proven Python
/// `nebula_proto/siril.py`, including its two hard-won gotchas: Siril's `-out=`
/// can't express spaces (so run those writes in a space-free scratch dir), and a
/// Seestar `_sub` folder interleaves FITS lights with preview JPEGs (so stage
/// only the FITS). Classical DSP stays wrapped in Siril per the design.
public struct SirilStage {
    public enum SirilError: Error, CustomStringConvertible {
        case notFound, noMaster(String)
        public var description: String {
            switch self {
            case .notFound: return "Siril not found (install with `brew install siril` or set SIRIL_BIN)"
            case .noMaster(let s): return "Siril produced no master: \(s)"
            }
        }
    }

    let sirilBin: String
    let memGB: Double

    public init(sirilBin: String? = nil, memGB: Double = 4.0) throws {
        guard let bin = sirilBin ?? Self.discover() else { throw SirilError.notFound }
        self.sirilBin = bin
        self.memGB = memGB
    }

    static func discover() -> String? {
        let fm = FileManager.default
        if let e = ProcessInfo.processInfo.environment["SIRIL_BIN"], fm.isExecutableFile(atPath: e) { return e }
        for p in ["/opt/homebrew/bin/siril", "/usr/local/bin/siril", "/usr/bin/siril"]
        where fm.isExecutableFile(atPath: p) { return p }
        return nil
    }

    /// Register + stack `subsDir` into a colour-corrected master, returned as a
    /// FITS in `workDir`. Throws `SirilError.noMaster` if Siril yields nothing.
    public func stack(subsDir: URL, workDir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // Siril's `-out=` can't contain a space; use a space-free scratch when
        // the cache/work path does (real targets like "M 83").
        let sirilWork = workDir.path.contains(" ")
            ? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nebula-siril-\(UUID().uuidString)", isDirectory: true)
            : workDir
        let processDir = sirilWork.appendingPathComponent("process", isDirectory: true)
        try fm.createDirectory(at: processDir, withIntermediateDirectories: true)

        let lightsDir = try stageFitsLights(subsDir: subsDir, into: sirilWork)
        let masterOut = sirilWork.appendingPathComponent("master")   // Siril appends .fits

        // NB: cd/load/save accept quotes (spaces ok); convert/stack `-out=` do not
        // (space-free scratch guarantees that). `-debayer` is mandatory for the
        // Seestar OSC CFA; native colour = subsky + rmgreen.
        let ssf = """
        requires 1.2.0
        set core.mem_mode=1
        set core.mem_amount=\(memGB)
        setext fits
        cd "\(lightsDir.path)"
        convert light -debayer -out=\(processDir.path)
        cd "\(processDir.path)"
        register light
        stack r_light rej w 3 3 -filter-round=2.5k -filter-fwhm=90% -norm=addscale -output_norm -out=\(masterOut.path)
        load "\(masterOut.path)"
        subsky 1
        rmgreen
        save "\(masterOut.path)"

        """
        let ssfURL = workDir.appendingPathComponent("bake_native.ssf")
        try ssf.write(to: ssfURL, atomically: true, encoding: .utf8)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: sirilBin)
        p.arguments = ["-s", ssfURL.path]
        // Redirect Siril's (voluminous) logs to a file. A Pipe we don't drain
        // would fill its ~64KB buffer and deadlock Siril mid-stack.
        let logURL = workDir.appendingPathComponent("siril.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        // Poll instead of waitUntilExit so a cancelled bake can terminate Siril.
        while p.isRunning {
            if Task.isCancelled { p.terminate(); try? logHandle.close(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        try? logHandle.close()

        let produced = sirilWork.appendingPathComponent("master.fits")
        guard fm.fileExists(atPath: produced.path) else {
            throw SirilError.noMaster("exit \(p.terminationStatus); check subs are registrable FITS")
        }
        // Hand the master back inside workDir (no-op when sirilWork == workDir).
        let finalMaster = workDir.appendingPathComponent("master_stack.fits")
        if produced.standardizedFileURL != finalMaster.standardizedFileURL {
            try? fm.removeItem(at: finalMaster)
            try fm.copyItem(at: produced, to: finalMaster)
        }
        return finalMaster
    }

    /// Symlink only the FITS lights (sequential names) into a clean dir, so
    /// Siril's `convert` never ingests the Seestar preview/thumbnail JPEGs.
    private func stageFitsLights(subsDir: URL, into workDir: URL) throws -> URL {
        let fm = FileManager.default
        let names = (try fm.contentsOfDirectory(atPath: subsDir.path))
            .filter { $0.lowercased().hasSuffix(".fit") || $0.lowercased().hasSuffix(".fits") }
            .sorted()
        guard !names.isEmpty else { return subsDir }
        let lightsDir = workDir.appendingPathComponent("lights", isDirectory: true)
        try fm.createDirectory(at: lightsDir, withIntermediateDirectories: true)
        for (i, name) in names.enumerated() {
            let ext = (name as NSString).pathExtension.lowercased()
            let link = lightsDir.appendingPathComponent(String(format: "light_%05d.%@", i, ext))
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: subsDir.appendingPathComponent(name))
        }
        return lightsDir
    }
}

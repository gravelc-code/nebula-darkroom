// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import Foundation

/// A GraXpert model version such as `3.0.2`, compared **numerically** component
/// by component (so `1.10.0 > 1.9.0`, which a string sort gets wrong). Missing
/// trailing components count as zero (`3.0 == 3.0.0`).
///
/// Upstream recognises a version directory by `re.search(r"\d\.\d\.\d", f)`
/// and orders them with `packaging.version.parse` (GraXpert
/// `graxpert/ai_model_handling.py:74,96`), so we likewise require at least three
/// dot-separated numeric components; an optional leading `v` is tolerated.
public struct ModelVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ text: String) {
        var s = Substring(text)
        if let first = s.first, first == "v" || first == "V" { s = s.dropFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        var comps: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0 >= "0" && $0 <= "9" }), let n = Int(p) else { return nil }
            comps.append(n)
        }
        components = comps
    }

    public init(_ major: Int, _ minor: Int, _ patch: Int) { components = [major, minor, patch] }

    /// Components without trailing zeros — the canonical form for == / hashing.
    private var trimmed: ArraySlice<Int> {
        var end = components.count
        while end > 0 && components[end - 1] == 0 { end -= 1 }
        return components[0..<end]
    }

    public static func == (a: ModelVersion, b: ModelVersion) -> Bool { a.trimmed == b.trimmed }
    public func hash(into hasher: inout Hasher) { hasher.combine(Array(trimmed)) }

    public static func < (a: ModelVersion, b: ModelVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public var description: String { components.map(String.init).joined(separator: ".") }
}

/// The two GraXpert models Nebula runs in-process.
public enum AIModel: String, CaseIterable, Sendable {
    case backgroundExtraction = "bge"
    case denoise = "denoise"

    /// GraXpert's cache sub-directory (`~/Library/Application Support/GraXpert/<this>/<version>/model.onnx`).
    public var graxpertDirectory: String { "\(rawValue)-ai-models" }
    /// Env override pointing straight at a `.onnx` file.
    public var environmentVariable: String {
        self == .denoise ? "NEBULA_DENOISE_MODEL" : "NEBULA_BGE_MODEL"
    }
    /// Unversioned file name in the app bundle / Nebula's own Models folder.
    public var fileName: String { rawValue }
}

/// A located model: where it is and — when knowable — which GraXpert release.
public struct LocatedModel: Equatable, Sendable {
    public enum Source: String, Sendable { case environment, bundle, nebulaModels, devBuild, graxpertCache }
    public let path: String
    /// `nil` = unknown (an unversioned `bge.onnx`/`denoise.onnx`): callers then
    /// keep the current-model behaviour.
    public let version: ModelVersion?
    public let source: Source

    public init(path: String, version: ModelVersion?, source: Source) {
        self.path = path; self.version = version; self.source = source
    }

    /// An explicit path (a `--model` flag): version read from a GraXpert-layout path, if any.
    public init(explicitPath path: String) {
        self.init(path: path, version: ModelLocator.version(ofModelAt: path), source: .environment)
    }
}

/// The single model-discovery policy shared by the bake (`Baker`), the app's
/// first-run check, and the `nebula-ai` CLI, so they can never disagree.
///
/// Search order: env override → app bundle → Nebula's own Models folder → dev
/// build path → the GraXpert app's cache (newest version, numeric order). The
/// models are never redistributed or downloaded by Nebula (see NOTICES.md);
/// installing GraXpert once populates its cache and Nebula finds them there.
public enum ModelLocator {
    /// Where to look. `standard` is the real machine; tests point it at a temp dir.
    public struct SearchPaths: Sendable {
        public var environment: [String: String]
        /// `Contents/Resources` of the running app (models would sit in `Models/`).
        public var bundleResources: URL?
        /// `~/Library/Application Support/Nebula/Models`
        public var nebulaModels: String
        /// `<cwd>/build/Nebula.app/Contents/Resources/Models` (a local dev build).
        public var devBuildModels: String?
        /// `~/Library/Application Support/GraXpert`
        public var graxpertData: String

        public init(environment: [String: String], bundleResources: URL?, nebulaModels: String,
                    devBuildModels: String?, graxpertData: String) {
            self.environment = environment; self.bundleResources = bundleResources
            self.nebulaModels = nebulaModels; self.devBuildModels = devBuildModels
            self.graxpertData = graxpertData
        }

        public static var standard: SearchPaths {
            let support = NSString(string: "~/Library/Application Support").expandingTildeInPath
            return SearchPaths(
                environment: ProcessInfo.processInfo.environment,
                bundleResources: Bundle.main.resourceURL,
                nebulaModels: "\(support)/Nebula/Models",
                devBuildModels: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("build/Nebula.app/Contents/Resources/Models").path,
                graxpertData: "\(support)/GraXpert")
        }
    }

    public static func locate(_ model: AIModel, in paths: SearchPaths = .standard) -> LocatedModel? {
        locate(graxpertDirectory: model.graxpertDirectory, environmentVariable: model.environmentVariable,
               fileName: model.fileName, in: paths)
    }

    /// The general form (`Baker.discoverModel(base, env)` keeps its signature
    /// and calls this). `fileName` defaults the way discovery always has:
    /// `denoise` for a denoise directory, `bge` otherwise.
    public static func locate(graxpertDirectory: String, environmentVariable: String,
                              fileName: String? = nil,
                              in paths: SearchPaths = .standard) -> LocatedModel? {
        let fm = FileManager.default
        let name = fileName ?? (graxpertDirectory.contains("denoise") ? "denoise" : "bge")
        if let e = paths.environment[environmentVariable], fm.fileExists(atPath: e) {
            // An explicit path can still be a GraXpert cache path; read its version if so.
            return LocatedModel(path: e, version: version(ofModelAt: e), source: .environment)
        }
        if let res = paths.bundleResources {
            let p = res.appendingPathComponent("Models/\(name).onnx").path
            if fm.fileExists(atPath: p) { return LocatedModel(path: p, version: nil, source: .bundle) }
        }
        let home = "\(paths.nebulaModels)/\(name).onnx"
        if fm.fileExists(atPath: home) { return LocatedModel(path: home, version: nil, source: .nebulaModels) }
        if let dev = paths.devBuildModels {
            let p = "\(dev)/\(name).onnx"
            if fm.fileExists(atPath: p) { return LocatedModel(path: p, version: nil, source: .devBuild) }
        }
        if let newest = graxpertVersions(in: "\(paths.graxpertData)/\(graxpertDirectory)").first {
            return LocatedModel(path: newest.path, version: newest.version, source: .graxpertCache)
        }
        return nil
    }

    /// Every `<version>/model.onnx` under a GraXpert `*-ai-models` directory,
    /// newest first by numeric version. Non-version entries are ignored.
    public static func graxpertVersions(in directory: String) -> [(version: ModelVersion, path: String)] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        var found: [(version: ModelVersion, path: String)] = []
        for entry in entries {
            guard let v = ModelVersion(entry) else { continue }
            let p = "\(directory)/\(entry)/model.onnx"
            if fm.fileExists(atPath: p) { found.append((v, p)) }
        }
        // Newest first; ties (e.g. "3.0" vs "3.0.0") broken by name for determinism.
        return found.sorted { $0.version != $1.version ? $0.version > $1.version : $0.path < $1.path }
    }

    /// The GraXpert version implied by a model path laid out as
    /// `…/<version>/model.onnx`; `nil` for an unversioned file.
    public static func version(ofModelAt path: String) -> ModelVersion? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return ModelVersion(parent)
    }
}

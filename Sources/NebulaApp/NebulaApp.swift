// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Nebula contributors
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import MetalKit
import NebulaCore
import NebulaEngine
import NebulaAI
import NebulaBake

/// Disambiguate the look control from `SwiftUI.Slider`.
private typealias Control = NebulaCore.Slider

// The Nebula app (design §6, Phase 4): a photo-app, not a debug panel. Point it
// at a Seestar `<Target>_subs` folder → it bakes (Siril + AI) with a progress
// screen → then opens on the finished image in the live 120fps Metal editor.
//
// Three phases: launch (drop a folder) → baking (progress) → editing (hero +
// sliders + export). A folder that's already a bake dir opens straight into the
// editor; a `_subs` folder is baked first (cached, so re-opens are instant).

// An unbundled SwiftPM executable launched from a shell doesn't get a normal
// app activation, so its window never draws. Force a regular activation policy
// and bring it to the front on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

@main
struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EngineModel()
    var body: some Scene {
        WindowGroup("Nebula") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class EngineModel: ObservableObject {
    enum Phase: Equatable { case launch, baking, editing, failed(String) }

    let renderer: ChainRenderer?           // device + pipelines; layer-independent
    @Published var phase: Phase = .launch
    @Published var bundle: ChainRenderer.LayerBundle?
    @Published var progress = BakeRunner.Progress(fraction: 0, status: "")
    @Published var targetName = ""

    @Published var look: LookState = .default
    @Published var compare = false
    @Published var divider: Float = 0.5
    @Published var showClipping = false

    // The Library grid: previously-developed targets and their (lazy) thumbnails.
    @Published var libraryTargets: [CachedTarget] = []
    private var thumbCache: [String: NSImage] = [:]

    // Watch mode: auto-develop new `_sub` folders that land in a watched folder.
    @Published var watchRoot: URL?
    @Published var autoBaking: Set<String> = []      // target names currently baking
    private var watcher: FolderWatcher?

    // First-run guidance: Nebula never ships GraXpert's AI models. When a bake
    // can't find them, offer the one-time "install GraXpert" explainer instead
    // of silently developing at reduced quality. Watch-mode bakes never pop UI.
    @Published var showModelGuidance = false
    private var pendingBakeSubs: URL?
    var aiModelsInstalled: Bool { Baker.aiModelsAvailable() }
    static let graxpertURL = URL(string: "https://graxpert.com")!

    private let baker = BakeRunner()
    private var currentBakeDir: URL?
    private var lookSaveTask: Task<Void, Never>?
    var params: EngineParams { look.engineParams }

    init() {
        // The renderer needs no layers, so build it once up front. If Metal or
        // the shaders fail, that's a hard failure — surface it immediately.
        do { renderer = try ChainRenderer() }
        catch { renderer = nil; phase = .failed("Metal engine failed: \(error)"); return }

        refreshLibrary()

        // Launch argument / env: a bake dir opens straight into the editor; a
        // subs folder is baked. Otherwise show the launch screen.
        let args = CommandLine.arguments
        if args.count > 1 {
            open(URL(fileURLWithPath: args[1]))
        } else if let e = ProcessInfo.processInfo.environment["NEBULA_LAYERS"] {
            open(URL(fileURLWithPath: e))
        }
        // Watch a folder from launch (also used to smoke-test watch mode).
        if let w = ProcessInfo.processInfo.environment["NEBULA_WATCH"] {
            startWatching(URL(fileURLWithPath: w))
        }
    }

    /// Strip Seestar folder suffixes to a clean target name for the cache key.
    private static func targetName(from dir: URL) -> String {
        var n = dir.lastPathComponent
        for suffix in ["_mosaic_sub", "_mosaic_subs", "_subs", "_sub"] {
            if n.hasSuffix(suffix) { n = String(n.dropLast(suffix.count)); break }
        }
        return n.isEmpty ? dir.lastPathComponent : n
    }

    private static func containsLights(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return items.contains { $0.lowercased().hasSuffix(".fit") || $0.lowercased().hasSuffix(".fits") }
    }

    /// Seestar exposes both `<Target>/` (a handful of already-stacked products)
    /// and `<Target>_sub/` (the real light frames). People naturally choose the
    /// former. Redirect it to the matching raw folder instead of trying to align
    /// incompatible session stacks; mosaic result folders map to mosaic subs.
    private static func rawSubsSibling(for dir: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.lowercased().hasPrefix("stacked_")
                  && ($0.lowercased().hasSuffix(".fit") || $0.lowercased().hasSuffix(".fits")) })
        else { return nil }
        let parent = dir.deletingLastPathComponent()
        let base = dir.lastPathComponent
        for suffix in ["_sub", "_subs"] {
            let candidate = parent.appendingPathComponent(base + suffix, isDirectory: true)
            if containsLights(candidate) { return candidate }
        }
        return nil
    }

    /// Decide what a dropped/chosen folder is and route accordingly.
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            phase = .failed("Not a folder: \(url.lastPathComponent)"); return
        }
        let input = Self.rawSubsSibling(for: url) ?? url
        targetName = Self.targetName(from: input)
        if BakeRunner.hasAllLayers(in: input) {
            loadLayers(from: input)                  // already a bake dir
        } else if Self.containsLights(input) {
            startBake(subsDir: input)                // a subs folder → bake it
        } else {
            phase = .failed("No FITS light frames or bake layers in \(input.lastPathComponent).")
        }
    }

    private func startBake(subsDir: URL) {
        // One-time model guidance: only for user-initiated bakes, only until
        // the user answers ("Develop without AI" remembers the choice), and
        // never once the models are installed.
        if !Baker.aiModelsAvailable(),
           !UserDefaults.standard.bool(forKey: "modelGuidanceAnswered") {
            pendingBakeSubs = subsDir
            showModelGuidance = true
            return
        }
        beginBake(subsDir: subsDir)
    }

    /// Sheet actions. `proceed` continues the pending develop; "without AI"
    /// additionally remembers the answer so the sheet never nags again.
    func modelGuidanceProceed(rememberWithoutAI: Bool) {
        if rememberWithoutAI {
            UserDefaults.standard.set(true, forKey: "modelGuidanceAnswered")
        }
        showModelGuidance = false
        if let subs = pendingBakeSubs { pendingBakeSubs = nil; beginBake(subsDir: subs) }
    }

    func modelGuidanceDismiss() {
        showModelGuidance = false
        pendingBakeSubs = nil
    }

    private func beginBake(subsDir: URL) {
        progress = BakeRunner.Progress(fraction: 0.02, status: "Preparing…")
        phase = .baking
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.baker.bake(
                subsDir: subsDir, target: self.targetName,
                onProgress: { p in self.progress = p })
            switch outcome {
            case .success(let dir): self.loadLayers(from: dir)
            case .failure(let msg): self.phase = .failed(msg)
            }
        }
    }

    private func loadLayers(from dir: URL) {
        guard let renderer else { phase = .failed("No engine"); return }
        do {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? Manifest(jsonData: $0) }
            func layer(_ n: String) throws -> FITSImage {
                try FITSImage.read(dir.appendingPathComponent("\(n).fits"))
            }
            let b = renderer.makeBundle(
                master: try layer("master"), corrected: try? layer("corrected"),
                denoised: try layer("denoised"),
                starless: try layer("starless"), stars: try layer("stars"),
                profile: manifest?.target.profile)
            invalidateAIPreview()
            bundle = b
            currentBakeDir = dir
            look = manifest?.look ?? .default
            phase = .editing
            // Pre-warm the Library thumbnail from the freshly-loaded bundle so a
            // just-baked target shows a card instantly next time (no reload).
            writeThumb(from: b, params: look.engineParams,
                       to: dir.appendingPathComponent("thumb.png"))
        } catch {
            phase = .failed("Failed to load layers: \(error)")
        }
    }

    func cancelBake() { baker.cancel(); reset() }
    func reset() {
        invalidateAIPreview()
        bundle = nil; currentBakeDir = nil; refreshLibrary(); phase = .launch
    }

    // MARK: - Library

    func refreshLibrary() { libraryTargets = Library.cachedTargets() }

    // MARK: - Watch mode

    /// Start watching `url` for new `_sub` folders; each is auto-developed in the
    /// background and appears in the Library. Also develops any already present.
    func startWatching(_ url: URL) {
        watchRoot = url
        Notifier.requestAuthorization()
        let w = FolderWatcher(root: url) { [weak self] subs in self?.autoBake(subsDir: subs) }
        watcher = w
        w.start()
        // Kick off anything already sitting in the folder that isn't baked yet.
        for subs in FolderWatcher.subTargets(in: url) { autoBake(subsDir: subs) }
    }

    func stopWatching() { watcher?.stop(); watcher = nil; watchRoot = nil }

    /// Develop a subs folder into the cache in the background — no phase change,
    /// so it doesn't disturb whatever the user is looking at. Refreshes the
    /// Library when done.
    private func autoBake(subsDir: URL) {
        let name = Self.targetName(from: subsDir)
        let out = BakeRunner.cacheDir(forTarget: name)
        if BakeRunner.hasCurrentPipeline(in: out) { return }  // already developed with current pipeline
        if autoBaking.contains(name) { return }               // already in flight
        autoBaking.insert(name)
        Task { [weak self] in
            let runner = BakeRunner()
            let outcome = await runner.bake(subsDir: subsDir, target: name, onProgress: { _ in })
            guard let self else { return }
            self.autoBaking.remove(name)
            self.refreshLibrary()
            if case .success = outcome {
                // Warm the Library thumbnail, then notify with it.
                if let target = self.libraryTargets.first(where: { $0.name == name }) {
                    _ = await self.thumbnail(for: target)
                }
                Notifier.developed(name, thumbURL: BakeRunner.cacheDir(forTarget: name)
                    .appendingPathComponent("thumb.png"))
            }
        }
    }

    /// Open a previously-developed target straight into the editor (already baked).
    func openCached(_ t: CachedTarget) {
        targetName = t.name
        loadLayers(from: t.dir)
    }

    /// Wipe a target's cached bake and re-run it from its remembered subs folder.
    /// (Removing the layers forces a real bake instead of a cache hit.)
    func redevelop(_ t: CachedTarget) {
        guard let src = t.sourceSubs else { return }
        try? FileManager.default.removeItem(at: t.dir)
        thumbCache[t.id] = nil
        targetName = t.name
        startBake(subsDir: src)
    }

    /// Forget a target: delete its cached bake and drop it from the grid.
    func deleteTarget(_ t: CachedTarget) {
        try? FileManager.default.removeItem(at: t.dir)
        thumbCache[t.id] = nil
        refreshLibrary()
    }

    /// Load the disk thumbnail for a card, rendering + caching it on first sight.
    /// FITS reads happen off the main actor; the quick GPU render stays on main.
    func thumbnail(for t: CachedTarget) async -> NSImage? {
        if let cached = thumbCache[t.id] { return cached }
        if let disk = NSImage(contentsOf: t.thumbURL) {
            thumbCache[t.id] = disk; return disk
        }
        guard let renderer else { return nil }
        let dir = t.dir
        let layers: (FITSImage, FITSImage?, FITSImage, FITSImage, FITSImage, Manifest?)? =
            await Task.detached(priority: .utility) {
                guard let m = try? FITSImage.read(dir.appendingPathComponent("master.fits")),
                      let d = try? FITSImage.read(dir.appendingPathComponent("denoised.fits")),
                      let s = try? FITSImage.read(dir.appendingPathComponent("starless.fits")),
                      let st = try? FITSImage.read(dir.appendingPathComponent("stars.fits"))
                else { return nil }
                let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
                    .flatMap { try? Manifest(jsonData: $0) }
                let corrected = try? FITSImage.read(dir.appendingPathComponent("corrected.fits"))
                return (m, corrected, d, s, st, manifest)
            }.value
        guard let (m, corrected, d, s, st, manifest) = layers else { return nil }
        let b = renderer.makeBundle(master: m, corrected: corrected, denoised: d, starless: s, stars: st,
                                    profile: manifest?.target.profile)
        guard let cg = try? renderer.renderThumbnail(
            bundle: b, params: (manifest?.look ?? .default).engineParams, maxDimension: 480)
        else { return nil }
        writeCGImagePNG(cg, to: t.thumbURL)
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache[t.id] = img
        return img
    }

    private func writeThumb(from bundle: ChainRenderer.LayerBundle, params: EngineParams, to url: URL) {
        guard let renderer,
              let cg = try? renderer.renderThumbnail(
                bundle: bundle, params: params, maxDimension: 480)
        else { return }
        writeCGImagePNG(cg, to: url)
    }

    private func writeCGImagePNG(_ cg: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Reset every control to the developed default look.
    func resetLook() {
        look = .default
        invalidateAIPreview()
        scheduleLookSave()
    }
    func edited() {
        invalidateAIPreview()
        scheduleLookSave()
    }

    // MARK: - In-app AI enhancement (same Real-ESRGAN pass as the AI 2× export)

    @Published var aiPreview: CGImage?
    @Published var aiWorking = false
    @Published var aiProgress: Double = 0
    private var aiTask: Task<Void, Never>?

    /// Run the AI enhancement on the CURRENT look and show it in the workspace.
    /// Tapping again (or editing any slider) returns to the live view.
    func toggleAIPreview() {
        if aiPreview != nil || aiWorking { invalidateAIPreview(); return }
        guard let renderer, let bundle else { return }
        guard let modelPath = Self.superResolutionModel() else {
            exportError = "AI enhancement model not found. Set NEBULA_SUPERRES_MODEL "
                + "or install superres.onnx in Nebula's Models folder."
            return
        }
        let lookParams = params, strength = Float(aiStrength)
        aiWorking = true; aiProgress = 0
        let owner = self
        aiTask = Task { [weak self] in
            do {
                let cg = try await Task.detached(priority: .userInitiated) { () -> CGImage in
                    let rendered = try renderer.renderImage(bundle: bundle, params: lookParams)
                    let result = try SuperResolver(modelPath: modelPath).upscale(
                        pixels: rendered.hwcPixels(), h: rendered.height, w: rendered.width,
                        strength: strength) { p in
                            Task { @MainActor in owner.aiProgress = p }
                        }
                    try Task.checkCancellation()
                    let enlarged = FITSImage.fromHWC(result.0, width: result.2,
                                                     height: result.1, channels: 3)
                    return try ChainRenderer.displayImage(enlarged)
                }.value
                guard !Task.isCancelled else { self?.aiWorking = false; return }
                self?.aiPreview = cg
            } catch is CancellationError {
                // User cancelled — quietly return to the live view.
            } catch {
                self?.exportError = "\(error)"
            }
            self?.aiWorking = false
        }
    }

    /// Drop the enhanced still and return to the live Metal view. Called on any
    /// look edit — the enhancement belongs to the look it was computed from.
    func invalidateAIPreview() {
        aiTask?.cancel(); aiTask = nil
        aiWorking = false; aiPreview = nil; aiProgress = 0
    }

    /// Persist the eight-float look after a short drag debounce. Cached layers
    /// remain immutable; only the manifest and derived thumbnail are refreshed.
    private func scheduleLookSave() {
        guard let dir = currentBakeDir else { return }
        let savedLook = look
        lookSaveTask?.cancel()
        lookSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let url = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: url), var manifest = try? Manifest(jsonData: data) else { return }
            manifest.look = savedLook
            try? manifest.jsonData().write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("thumb.png"))
            self?.thumbCache[dir.path] = nil
        }
    }

    /// Export the current look to a full-res 16-bit PNG via the SAME renderer as
    /// the live preview, so what you see is exactly what you save. Surfaces the
    /// outcome so the editor can confirm success or show the failure.
    @Published var lastSaved: URL?
    @Published var exportError: String?
    @Published var exportScale = 1
    @Published var aiStrength: Double = 0.65
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    private var exportTask: Task<Void, Never>?

    func export(to url: URL) {
        guard let renderer, let bundle else {
            exportError = "Nothing to export."; return
        }
        let scale = exportScale, lookParams = params, strength = Float(aiStrength)
        let model = scale == 3 ? Self.superResolutionModel() : nil
        if scale == 3 && model == nil {
            exportError = "AI enlargement model not found. Set NEBULA_SUPERRES_MODEL or install superres.onnx in Nebula's Models folder."
            return
        }
        exportTask?.cancel()
        isExporting = true; exportProgress = 0
        let owner = self
        exportTask = Task { [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    if scale == 3, let model {
                        let rendered = try renderer.renderImage(bundle: bundle, params: lookParams)
                        let result = try SuperResolver(modelPath: model).upscale(
                            pixels: rendered.hwcPixels(), h: rendered.height, w: rendered.width,
                            strength: strength) { progress in
                                Task { @MainActor in owner.exportProgress = progress }
                            }
                        try Task.checkCancellation()
                        let enlarged = FITSImage.fromHWC(result.0, width: result.2,
                                                        height: result.1, channels: 3)
                        try renderer.writePNG(enlarged, to: url)
                    } else {
                        try renderer.renderPNG(bundle: bundle, params: lookParams,
                                               scale: scale, to: url)
                    }
                }.value
                guard !Task.isCancelled else { self?.isExporting = false; return }
                self?.lastSaved = url
            } catch is CancellationError {
                // Cancellation is user intent, not an error dialog.
            } catch {
                self?.exportError = "\(error)"
            }
            self?.isExporting = false
            self?.exportProgress = 0
        }
    }

    func cancelExport() { exportTask?.cancel(); exportTask = nil; isExporting = false }

    private static func superResolutionModel() -> String? {
        let fm = FileManager.default
        if let path = ProcessInfo.processInfo.environment["NEBULA_SUPERRES_MODEL"],
           fm.fileExists(atPath: path) { return path }
        if let bundled = Bundle.main.url(forResource: "superres", withExtension: "onnx",
                                         subdirectory: "Models"),
           fm.fileExists(atPath: bundled.path) { return bundled.path }
        let user = NSString(string: "~/Library/Application Support/Nebula/Models/superres.onnx")
            .expandingTildeInPath
        return fm.fileExists(atPath: user) ? user : nil
    }
}

struct ContentView: View {
    @EnvironmentObject var model: EngineModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.phase {
            case .launch:            LaunchView()
            case .baking:            BakingView()
            case .editing:           EditorView()
            case .failed(let msg):   FailedView(message: msg)
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        // The UI is designed dark (black canvas). Pin the scheme so system
        // light mode can't render .secondary/.tertiary text dark-on-black.
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showModelGuidance) { ModelGuidanceView() }
    }
}

/// One-time explainer shown when a develop can't find the AI models. Nebula
/// never bundles them (they're GraXpert's to distribute) — installing GraXpert
/// once and opening it populates a cache Nebula reads automatically.
struct ModelGuidanceView: View {
    @EnvironmentObject var model: EngineModel
    @State private var checkedAndMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("One more thing for the best results", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("""
            Nebula cleans up sky glow and noise with free AI from GraXpert, \
            an open-source astrophotography tool. It's a one-time set-up:
            """)
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("1.  Install GraXpert (free) from graxpert.com")
                Text("2.  Open it once and run any image — it fetches its AI models")
                Text("3.  Come back — Nebula finds them automatically")
            }
            .font(.callout).foregroundStyle(.secondary)
            if checkedAndMissing {
                Text("Not found yet — open GraXpert and let it download its models, then check again.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Get GraXpert") { NSWorkspace.shared.open(EngineModel.graxpertURL) }
                    .buttonStyle(.borderedProminent)
                Button("Check Again") {
                    if model.aiModelsInstalled {
                        model.modelGuidanceProceed(rememberWithoutAI: false)
                    } else {
                        checkedAndMissing = true
                    }
                }
                Spacer()
                Button("Develop Without AI") { model.modelGuidanceProceed(rememberWithoutAI: true) }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(false)
        .onExitCommand { model.modelGuidanceDismiss() }
    }
}

// MARK: - Launch

/// The home screen: a Library grid of previously-developed targets once any
/// exist, or a first-run drop zone when the cache is empty. Dropping a folder
/// (or "＋ Develop") always works — the photo-app "home", not a dead end.
struct LaunchView: View {
    @EnvironmentObject var model: EngineModel
    @State private var targeted = false

    var body: some View {
        Group {
            if model.libraryTargets.isEmpty {
                emptyState
            } else {
                library
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { handleDrop($0) }
    }

    // First run — the original big drop target.
    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(.white.opacity(0.9))
            Text("Nebula").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
            Text("Drop a Seestar “…_subs” folder to develop it.")
                .font(.title3).foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? .white : .white.opacity(0.35))
                .frame(width: 380, height: 150)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 30, weight: .light))
                        Text(targeted ? "Release to develop" : "Drop folder here")
                    }.foregroundStyle(.secondary)
                )
                .background(.white.opacity(targeted ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 18))

            Button("Choose Folder…") { chooseFolder() }
                .controlSize(.large).buttonStyle(.borderedProminent)
            if !model.aiModelsInstalled {
                (Text("For the best results Nebula uses GraXpert's free AI — ")
                 + Text("get GraXpert").underline()
                 + Text(" and open it once."))
                    .font(.caption).foregroundStyle(.tertiary)
                    .onTapGesture { NSWorkspace.shared.open(EngineModel.graxpertURL) }
            }
            Spacer()
        }
        .padding(40)
    }

    // Populated Library — a grid of finished-look thumbnails.
    private var library: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Nebula").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                if !model.autoBaking.isEmpty {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Developing \(model.autoBaking.count)…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                watchButton
                Button { chooseFolder() } label: {
                    Label("Develop", systemImage: "plus")
                }
                .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 16)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)],
                    spacing: 18
                ) {
                    ForEach(model.libraryTargets) { target in
                        LibraryCard(target: target)
                            .onTapGesture { model.openCached(target) }
                    }
                }
                .padding(24)
            }
            .background(targeted ? Color.white.opacity(0.05) : .clear)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.open(url) }
        }
        return true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Develop"
        if panel.runModal() == .OK, let url = panel.url { model.open(url) }
    }

    // Watch-mode toggle: pick a parent folder once, new "…_sub" folders auto-develop.
    @ViewBuilder private var watchButton: some View {
        if let root = model.watchRoot {
            Button {
                model.stopWatching()
            } label: {
                Label("Watching \(root.lastPathComponent)", systemImage: "eye.fill")
            }
            .buttonStyle(.borderless).foregroundStyle(.white)
            .help("Click to stop watching")
        } else {
            Button { chooseWatchFolder() } label: { Label("Watch Folder…", systemImage: "eye") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
        }
    }

    private func chooseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Watch"
        panel.message = "New “…_subs” folders that land here will develop automatically."
        if panel.runModal() == .OK, let url = panel.url { model.startWatching(url) }
    }
}

/// One Library cell: the cached finished-look thumbnail (rendered + cached on
/// first sight) over the target name.
struct LibraryCard: View {
    @EnvironmentObject var model: EngineModel
    let target: CachedTarget
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            // Drive the cell size from a fixed 3:4 rectangle (Seestar is portrait)
            // and hang the thumbnail as a clipped overlay, so a non-portrait image
            // (e.g. synthetic subs) centre-crops into the frame instead of pushing
            // the cell wider and overlapping neighbours.
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.06))
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1))

            Text(target.name)
                .font(.callout).foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
        .task(id: target.id) { image = await model.thumbnail(for: target) }
        .contextMenu {
            Button("Open") { model.openCached(target) }
            if target.sourceSubs != nil {
                Button("Re-develop") { model.redevelop(target) }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([target.dir])
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteTarget(target) }
        }
    }
}

// MARK: - Baking

struct BakingView: View {
    @EnvironmentObject var model: EngineModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.4)
            Text("Developing \(model.targetName)")
                .font(.title2.weight(.semibold)).foregroundStyle(.white)
            ProgressView(value: max(0.02, model.progress.fraction))
                .frame(width: 340).tint(.white)
            Text(model.progress.status.isEmpty ? "Starting…" : model.progress.status)
                .font(.callout).foregroundStyle(.secondary)
                .frame(height: 20)
            Text("Registering, stacking and cleaning your subs. This runs once — "
                 + "re-opening is instant.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Cancel") { model.cancelBake() }
                .buttonStyle(.borderless).foregroundStyle(.secondary).padding(.top, 8)
            Spacer()
        }
        .padding(40)
    }
}

// MARK: - Failed

struct FailedView: View {
    @EnvironmentObject var model: EngineModel
    let message: String
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.yellow)
            Text("Couldn’t develop this folder").font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(message).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Try Another Folder") { model.reset() }
                .controlSize(.large).buttonStyle(.borderedProminent).padding(.top, 8)
            Spacer()
        }.padding(40)
    }
}

// MARK: - Editor (the hero image + live sliders)

struct EditorView: View {
    @EnvironmentObject var model: EngineModel
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var liveZoom: CGFloat = 1
    @GestureState private var livePan: CGSize = .zero

    var body: some View {
        ZStack {
            if let renderer = model.renderer, let bundle = model.bundle {
                HStack(spacing: 0) {
                    imageWorkspace(renderer: renderer, bundle: bundle)
                    inspector
                }
                if let saved = model.lastSaved { savedToast(saved) }
            }
        }
        .background(Color(red: 0.035, green: 0.04, blue: 0.052))
        .alert("Export failed", isPresented: Binding(
            get: { model.exportError != nil },
            set: { if !$0 { model.exportError = nil } })
        ) {
            Button("OK", role: .cancel) { model.exportError = nil }
        } message: { Text(model.exportError ?? "") }
    }

    /// Brief confirmation after a successful export; tap to reveal the file.
    private func savedToast(_ url: URL) -> some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Saved — Show in Finder", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Color.green.opacity(0.82), in: Capsule())
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(22).padding(.trailing, 360)
        .transition(.opacity)
        .task(id: url) {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if model.lastSaved == url { model.lastSaved = nil }
        }
    }

    private func imageWorkspace(renderer: ChainRenderer,
                                bundle: ChainRenderer.LayerBundle) -> some View {
        GeometryReader { workspace in
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.reset() } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                VStack(spacing: 1) {
                    Text(model.targetName).font(.headline).foregroundStyle(.white)
                    Text("\(bundle.width) × \(bundle.height)")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    model.toggleAIPreview()
                } label: {
                    Label(model.aiPreview != nil ? "Enhanced" : "Enhance",
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.aiPreview != nil || model.aiWorking
                                 ? Color.accentColor : .secondary)
                .help("Add AI detail to the current look, right in the preview")
                Divider().frame(height: 18)
                Button {
                    model.compare.toggle()
                } label: {
                    Label(model.compare ? "Comparing" : "Compare",
                          systemImage: model.compare ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.compare ? Color.accentColor : .secondary)
                Divider().frame(height: 18)
                Button { zoom = max(0.5, zoom / 1.35) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    zoom = 1; pan = .zero
                } label: { Text("Fit") }
                    .buttonStyle(.plain).foregroundStyle(zoom == 1 ? Color.accentColor : .secondary)
                Button {
                    let fit = min((workspace.size.width - 48) / CGFloat(bundle.width),
                                  (workspace.size.height - 106) / CGFloat(bundle.height))
                    zoom = max(1, 1 / max(fit, 0.001)); pan = .zero
                } label: { Text("1:1") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Button { zoom = min(8, zoom * 1.35) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { model.showClipping.toggle() } label: {
                    Image(systemName: model.showClipping
                          ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.showClipping ? .orange : .secondary)
                .help("Show clipped shadows in blue and highlights in red")
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 20).frame(height: 58)
            .background(Color(red: 0.06, green: 0.067, blue: 0.083))

            ZStack {
                Canvas { context, size in
                    let cell: CGFloat = 18
                    for y in stride(from: CGFloat(0), to: size.height, by: cell) {
                        for x in stride(from: CGFloat(0), to: size.width, by: cell) {
                            let even = (Int(x / cell) + Int(y / cell)).isMultiple(of: 2)
                            context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                         with: .color(.white.opacity(even ? 0.018 : 0.008)))
                        }
                    }
                }
                GeometryReader { geo in
                    Group {
                        // The enhanced still replaces the live view for the look
                        // it was computed from; comparing always shows live.
                        if let ai = model.aiPreview, !model.compare {
                            Image(decorative: ai, scale: 1)
                                .resizable()
                                .interpolation(.high)
                        } else {
                            HeroView(renderer: renderer, bundle: bundle, model: model)
                        }
                    }
                        .aspectRatio(CGFloat(bundle.width) / CGFloat(bundle.height), contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                        .scaleEffect(min(8, max(0.5, zoom * liveZoom)))
                        .offset(x: pan.width + livePan.width, y: pan.height + livePan.height)
                        .simultaneousGesture(MagnificationGesture()
                            .updating($liveZoom) { value, state, _ in state = value }
                            .onEnded { value in zoom = min(8, max(0.5, zoom * value)) })
                        .simultaneousGesture(DragGesture()
                            .updating($livePan) { value, state, _ in
                                if !model.compare && zoom > 1 { state = value.translation }
                            }
                            .onEnded { value in
                                if !model.compare && zoom > 1 {
                                    pan.width += value.translation.width
                                    pan.height += value.translation.height
                                }
                            })
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard model.compare else { return }
                            model.divider = Float(max(0, min(1, value.location.x / geo.size.width)))
                        })
                }
                if model.aiWorking { enhancingOverlay }
            }
        }
        }
    }

    /// Progress chip while the AI enhancement runs; tap ✕ to keep the live view.
    private var enhancingOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView(value: model.aiProgress)
                    .frame(width: 140).tint(.accentColor)
                Text("Enhancing… \(Int((model.aiProgress * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.9))
                Button {
                    model.invalidateAIPreview()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.black.opacity(0.72), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .padding(.bottom, 26)
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    sectionCard("ESSENTIALS") {
                        VStack(spacing: 10) {
                            ForEach(Control.headline, id: \.self) { sliderRow($0) }
                        }
                    }

                    sectionCard("REFINE") {
                        VStack(spacing: 10) {
                            ForEach(Control.advanced, id: \.self) { sliderRow($0) }
                        }
                    }

                    Button {
                        model.resetLook()
                    } label: {
                        Label("Reset to developed look", systemImage: "arrow.counterclockwise")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
            }

            exportControls
        }
        .frame(width: 360)
        .background(Color(red: 0.065, green: 0.073, blue: 0.09))
    }

    /// One compact bar: size picker + export button on a single row; the AI
    /// strength and progress rows only appear when relevant.
    private var exportControls: some View {
        VStack(spacing: 8) {
            if model.exportScale == 3 { aiStrengthControl }
            if model.isExporting { ProgressView(value: model.exportProgress).tint(.accentColor) }
            HStack(spacing: 10) {
                Picker("Export size", selection: $model.exportScale) {
                    Text("Native").tag(1)
                    Text("2×").tag(2)
                    Text("AI 2×").tag(3)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 170)
                .help("Export size")
                Button {
                    if model.isExporting { model.cancelExport() } else { exportImage() }
                } label: {
                    Label(model.isExporting ? "Cancel" : "Export",
                          systemImage: model.isExporting ? "xmark.circle" : "square.and.arrow.up")
                        .font(.callout.weight(.semibold)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(SwiftUI.Color(red: 0.025, green: 0.028, blue: 0.035))
    }

    private var aiStrengthControl: some View {
        VStack(spacing: 6) {
            HStack {
                Text("AI detail").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((model.aiStrength * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            SwiftUI.Slider(value: $model.aiStrength, in: 0...1).tint(.accentColor)
        }
    }

    private func sectionCard<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption2.weight(.bold)).tracking(1.2).foregroundStyle(.tertiary)
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.targetName).png"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    /// One compact row: name · slider · value. Everything stays visible at once
    /// — no disclosure, no scrolling to reach a control.
    private func sliderRow(_ s: Control) -> some View {
        HStack(spacing: 10) {
            Text(s.displayName)
                .font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.92))
                .frame(width: 84, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.8)
            SwiftUI.Slider(value: Binding(
                get: { model.look[s] },
                set: { model.look[s] = $0; model.edited() }), in: 0...1)
                .tint(.accentColor)
            Text("\(model.look.percent(s))")
                .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// SwiftUI wrapper around a continuously-rendering MTKView.
struct HeroView: NSViewRepresentable {
    let renderer: ChainRenderer
    let bundle: ChainRenderer.LayerBundle
    let model: EngineModel

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer, bundle: bundle, model: model) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = ChainRenderer.drawablePixelFormat
        view.colorspace = ChainRenderer.outputColorSpace
        view.framebufferOnly = true
        view.isPaused = false                 // free-running display-link loop
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 120   // ProMotion; always draws current params
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.bundle = bundle
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: ChainRenderer
        var bundle: ChainRenderer.LayerBundle
        let model: EngineModel
        init(renderer: ChainRenderer, bundle: ChainRenderer.LayerBundle, model: EngineModel) {
            self.renderer = renderer; self.bundle = bundle; self.model = model
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            renderer.draw(bundle: bundle, params: model.params,
                          compare: model.compare, divider: model.divider,
                          clipping: model.showClipping, in: view)
        }
    }
}

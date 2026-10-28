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
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here (not by a view) so quitting can reach the bakes in flight.
    let model = EngineModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so a notification tap that launched us lands.
        NotificationRouter.shared.install { [weak model] dir in model?.openFromNotification(dir) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    /// Quitting mid-develop used to leave Siril (and StarNet) running with no
    /// parent. Cancel every bake and give them a few seconds to stop their
    /// child processes; never hang the quit for longer than that.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.flushLookSave()
        guard model.hasWorkInFlight else {
            ThumbnailIO.flush()
            return .terminateNow
        }
        let model = self.model
        Task { @MainActor in
            await model.stopEverything(timeout: .seconds(6))
            ThumbnailIO.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct NebulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Nebula") {
            ContentView().environmentObject(delegate.model)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

/// What a dropped/chosen folder is. Decided off the main thread — on a network
/// share even a directory listing can stall.
enum OpenRoute: Sendable, Equatable {
    case notFound(String)
    case notAFolder(String)
    case bakeDir(URL)
    case subs(URL)
    /// A folder of several `…_sub` captures (e.g. the Seestar's MyWorks).
    case parentOfSubs(URL, [String])
    case nothing(String)

    static func classify(_ url: URL) -> OpenRoute {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .notFound(url.lastPathComponent)
        }
        guard isDir.boolValue else { return .notAFolder(url.lastPathComponent) }
        let input = rawSubsSibling(for: url) ?? url
        if BakeRunner.hasAllLayers(in: input) { return .bakeDir(input) }
        if containsLights(input) { return .subs(input) }
        let children = FolderWatcher.subTargets(in: input)
        if children.count == 1 { return .subs(children[0]) }
        if children.count > 1 { return .parentOfSubs(input, children.map(\.lastPathComponent)) }
        return .nothing(input.lastPathComponent)
    }

    static func containsLights(_ dir: URL) -> Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return false }
        return items.contains(where: SourceFingerprint.isLight)
    }

    /// Seestar exposes both `<Target>/` (a handful of already-stacked products)
    /// and `<Target>_sub/` (the real light frames). People naturally choose the
    /// former. Redirect it to the matching raw folder instead of trying to align
    /// incompatible session stacks; mosaic result folders map to mosaic subs.
    static func rawSubsSibling(for dir: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              names.contains(where: { $0.lowercased().hasPrefix("stacked_") && SourceFingerprint.isLight($0) })
        else { return nil }
        let parent = dir.deletingLastPathComponent()
        let base = dir.lastPathComponent
        for suffix in ["_sub", "_subs"] {
            let candidate = parent.appendingPathComponent(base + suffix, isDirectory: true)
            if containsLights(candidate) { return candidate }
        }
        return nil
    }
}

/// A bake opened for editing: everything `loadLayers` prepares off the main thread.
struct LoadedTarget: Sendable {
    let bundle: ChainRenderer.LayerBundle
    let manifest: Manifest?
    let look: LookState
    let thumbnail: CGImage?
    let thumbnailPNG: Data?

    static func load(dir: URL, renderer: ChainRenderer) throws -> LoadedTarget {
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            .flatMap { try? Manifest(jsonData: $0) }
        func layer(_ n: String) throws -> FITSImage {
            try FITSImage.read(dir.appendingPathComponent("\(n).fits"))
        }
        let bundle = renderer.makeBundle(
            master: try layer("master"), corrected: try? layer("corrected"),
            denoised: try layer("denoised"),
            starless: try layer("starless"), stars: try layer("stars"),
            profile: manifest?.target.profile)
        let look = manifest?.look(forPipelineVersion: Baker.pipelineVersion) ?? .default
        // Pre-render the Library thumbnail from the fresh bundle, before the
        // live view starts drawing into it.
        let thumb = try? renderer.renderThumbnail(bundle: bundle, params: look.engineParams,
                                                  maxDimension: ThumbnailIO.maxDimension)
        return LoadedTarget(bundle: bundle, manifest: manifest, look: look, thumbnail: thumb,
                            thumbnailPNG: thumb.flatMap(ThumbnailIO.pngData))
    }
}

@MainActor
final class EngineModel: ObservableObject {
    enum Phase: Equatable { case launch, opening, baking, editing, failed(UserMessage) }

    let renderer: ChainRenderer?           // device + pipelines; layer-independent
    @Published var phase: Phase = .launch
    @Published var bundle: ChainRenderer.LayerBundle?
    @Published var progress = BakeRunner.Progress(fraction: 0, status: "")
    @Published var targetName = ""
    /// What this image is actually made of (integration, frames, band) plus a
    /// note when frames were dropped — shown in the editor so the user always
    /// sees the honest figure, never the pre-cull import count.
    @Published var captureSummary = ""

    @Published var look: LookState = .default
    @Published var compare = false
    @Published var divider: Float = 0.5
    @Published var showClipping = false

    // The Library grid: previously-developed targets and their (lazy) thumbnails.
    @Published var libraryTargets: [CachedTarget] = []
    @Published private(set) var libraryLoaded = false
    /// Bumped whenever a target's thumbnail goes stale (look edited, re-developed,
    /// deleted). A render started under an older revision is never shown or saved.
    @Published private(set) var thumbRevisions: [String: Int] = [:]
    private var thumbCache: [String: NSImage] = [:]
    private var thumbInFlight: [String: Task<NSImage?, Never>] = [:]
    private let thumbGate = SerialGate()
    private var libraryRefresh = 0

    // Watch mode: auto-develop new `_sub` folders that land in a watched folder.
    @Published var watchRoot: URL?
    @Published var autoBaking: Set<String> = []      // targets developing or queued
    private var watcher: FolderWatcher?

    // First-run guidance: Nebula never ships GraXpert's AI models. When a bake
    // can't find them, offer the one-time "install GraXpert" explainer instead
    // of silently developing at reduced quality. Watch-mode bakes never pop UI.
    @Published var showModelGuidance = false
    private var pendingBake: (subs: URL, key: String, force: Bool)?
    var aiModelsInstalled: Bool { Baker.aiModelsAvailable() }
    static let graxpertURL = URL(string: "https://graxpert.com")!

    /// The one place bakes start: the user's and watch mode's.
    let coordinator: BakeCoordinator
    /// Bumped by every new open/develop, cancel and return to the Library. An
    /// open's, load's or develop's result only applies while its generation is
    /// current, so a cancelled or superseded one can never drive the progress
    /// bar, pull the user into its editor or clobber a newer selection.
    private var bakeGeneration = 0
    private var currentBakeDir: URL?
    private var lookSaveTask: Task<Void, Never>?
    private var pendingLookSave: (look: LookState, dir: URL)?
    private var lookEditedSinceOpen = false
    var params: EngineParams { look.engineParams }

    init() {
        coordinator = BakeCoordinator()
        // The renderer needs no layers, so build it once up front. If Metal or
        // the shaders fail, that's a hard failure — surface it immediately.
        do { renderer = try ChainRenderer() }
        catch { renderer = nil; phase = .failed(.engineUnavailable(error)); return }

        coordinator.onChange = { [weak self] in
            guard let self else { return }
            let keys = self.coordinator.watchKeys
            if keys != self.autoBaking { self.autoBaking = keys }
        }
        coordinator.onWatchFinished = { [weak self] key, outcome, joined in
            self?.watchBakeFinished(key: key, outcome: outcome, joined: joined)
        }
        superResolutionAvailable = Self.superResolutionModel() != nil

        // No bake is running yet, so any staging folder is a leftover from a
        // force-quit or crash. (Synchronous: it must finish before a bake stages.)
        StagedBake.removeAbandoned(in: coordinator.cacheRoot)
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

    // MARK: - Opening & developing

    /// Decide what a dropped/chosen folder is and route accordingly.
    func open(_ url: URL) {
        bakeGeneration += 1
        let generation = bakeGeneration
        targetName = url.lastPathComponent
        phase = .opening
        Task { [weak self] in
            let route = await blockingIO(qos: .userInitiated) { OpenRoute.classify(url) }
            guard let self, self.bakeGeneration == generation else { return }
            switch route {
            case .notFound(let name):
                self.phase = .failed(UserMessage(
                    title: "That folder couldn’t be found",
                    body: "“\(name)” may have been moved, renamed or disconnected."))
            case .notAFolder(let name):
                self.phase = .failed(.notAFolder(name))
            case .bakeDir(let dir):
                self.targetName = CacheKey.baseName(for: dir)
                self.loadLayers(from: dir, generation: generation)
            case .subs(let subs):
                let key = await self.coordinator.resolveKey(for: subs)
                guard self.bakeGeneration == generation else { return }
                self.targetName = key
                self.startBake(subs: subs, key: key)
            case .parentOfSubs(let parent, let names):
                self.phase = .failed(.chooseOneSubFolder(in: parent, names: names))
            case .nothing(let name):
                self.phase = .failed(.nothingToDevelop(in: name))
            }
        }
    }

    private func startBake(subs: URL, key: String, force: Bool = false) {
        // One-time model guidance: only for user-initiated bakes, only until
        // the user answers ("Develop without AI" remembers the choice), and
        // never once the models are installed.
        if !Baker.aiModelsAvailable(),
           !UserDefaults.standard.bool(forKey: "modelGuidanceAnswered") {
            pendingBake = (subs, key, force)
            showModelGuidance = true
            return
        }
        beginBake(subs: subs, key: key, force: force)
    }

    /// Sheet actions. `proceed` continues the pending develop; "without AI"
    /// additionally remembers the answer so the sheet never nags again.
    func modelGuidanceProceed(rememberWithoutAI: Bool) {
        if rememberWithoutAI {
            UserDefaults.standard.set(true, forKey: "modelGuidanceAnswered")
        }
        showModelGuidance = false
        if let pending = pendingBake {
            pendingBake = nil
            beginBake(subs: pending.subs, key: pending.key, force: pending.force)
        }
    }

    func modelGuidanceDismiss() {
        showModelGuidance = false
        pendingBake = nil
        if phase == .opening { reset() }
    }

    private func beginBake(subs: URL, key: String, force: Bool) {
        // One interactive bake at a time: a new develop replaces any in flight
        // (the coordinator cancels it), and joins watch mode's if it's already
        // developing this very folder.
        bakeGeneration += 1
        let generation = bakeGeneration
        targetName = key
        progress = BakeRunner.Progress(fraction: 0.02, status: "Preparing…")
        phase = .baking
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.coordinator.bakeManually(subs: subs, key: key, force: force) {
                [weak self] p in
                guard let self, self.bakeGeneration == generation else { return }
                self.progress = p
            }
            // Cancelled, superseded, or the user has moved on: not wanted any more.
            guard self.bakeGeneration == generation, self.phase == .baking else { return }
            switch outcome {
            case .success(let dir):
                self.invalidateThumb(dir.path)
                self.progress = BakeRunner.Progress(fraction: 1, status: "Opening…")
                self.loadLayers(from: dir, generation: generation)
            case .failure(let failure):
                self.phase = .failed(.developFailed(failure))
            case .cancelled:
                self.reset()
            }
        }
    }

    /// Read the layers, build the GPU bundle and pre-render the thumbnail off
    /// the main thread; only the hand-over happens here, and only if nothing
    /// newer was opened meanwhile.
    private func loadLayers(from dir: URL, generation: Int) {
        guard let renderer else { phase = .failed(.engineUnavailable(nil)); return }
        if phase != .baking { phase = .opening }
        let name = targetName
        let revision = thumbRevisions[dir.path, default: 0]
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<LoadedTarget, any Error> in
                do { return .success(try LoadedTarget.load(dir: dir, renderer: renderer)) }
                catch { return .failure(error) }
            }.value
            guard let self, self.bakeGeneration == generation else { return }
            switch result {
            case .failure(let error):
                self.phase = .failed(.cantOpen(name, error: error))
            case .success(let loaded):
                self.present(loaded, from: dir, thumbRevision: revision)
            }
        }
    }

    private func present(_ loaded: LoadedTarget, from dir: URL, thumbRevision revision: Int) {
        invalidateAIPreview()
        bundle = loaded.bundle
        currentBakeDir = dir
        lookEditedSinceOpen = false
        captureSummary = loaded.manifest.map { m in
            [m.target.capture.placardMeta, m.target.capture.stackedFramesNote]
                .compactMap { $0 }.joined(separator: " · ")
        } ?? ""
        look = loaded.look
        superResolutionAvailable = Self.superResolutionModel() != nil
        if !superResolutionAvailable && exportScale == 3 { exportScale = 1 }
        phase = .editing
        // Warm the Library thumbnail so the card is instant next time.
        if let cg = loaded.thumbnail, let png = loaded.thumbnailPNG,
           thumbRevisions[dir.path, default: 0] == revision {
            ThumbnailIO.write(png, to: dir.appendingPathComponent("thumb.png"))
            thumbCache[dir.path] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    func cancelBake() {
        bakeGeneration += 1
        coordinator.cancelManual()
        reset()
    }

    /// Back to the Library.
    func reset() {
        closeEditor()
        bakeGeneration += 1                  // drop any open or load still in flight
        refreshLibrary()
        phase = .launch
    }

    /// Leaving the editor: save the look now and re-render the target's card
    /// from the image already on the GPU, so the Library shows the look just
    /// made, never the one from before the edit.
    private func closeEditor() {
        if let dir = currentBakeDir, let bundle {
            flushLookSave()
            renderThumbnail(dir: dir, bundle: bundle, look: look)
        }
        invalidateAIPreview()
        bundle = nil
        currentBakeDir = nil
    }

    /// A tapped "Developed …" notification. Never abandons a develop the user
    /// is watching; otherwise opens the target.
    func openFromNotification(_ dir: URL) {
        guard phase != .baking else { return }
        closeEditor()
        bakeGeneration += 1
        targetName = dir.lastPathComponent
        loadLayers(from: dir, generation: bakeGeneration)
    }

    // MARK: - Library

    func refreshLibrary() {
        libraryRefresh += 1
        let token = libraryRefresh, root = coordinator.cacheRoot
        Task { [weak self] in
            let targets = await blockingIO { Library.cachedTargets(in: root) }
            guard let self, self.libraryRefresh == token else { return }
            self.libraryTargets = targets
            self.libraryLoaded = true
        }
    }

    /// Open a previously-developed target straight into the editor (already baked).
    func openCached(_ t: CachedTarget) {
        bakeGeneration += 1
        targetName = t.name
        loadLayers(from: t.dir, generation: bakeGeneration)
    }

    /// Re-run a target's bake from its remembered subs folder. The existing
    /// image stays in place until the new bake is complete, so cancelling, or
    /// the subs going offline mid-bake, leaves it exactly as it was.
    func redevelop(_ t: CachedTarget) {
        guard let src = t.sourceSubs else { return }
        targetName = t.name
        startBake(subs: src, key: t.name, force: true)
    }

    /// Forget a target: delete its cached bake and drop it from the grid.
    func deleteTarget(_ t: CachedTarget) {
        coordinator.cancelWatchBake(key: t.name)
        invalidateThumb(t.id)
        libraryTargets.removeAll { $0.id == t.id }
        let dir = t.dir
        Task { [weak self] in
            await blockingIO { _ = try? FileManager.default.removeItem(at: dir) }
            self?.refreshLibrary()
        }
    }

    // MARK: - Thumbnails

    /// Identity for a card's thumbnail load: changes when the image must be
    /// fetched again.
    func thumbnailID(for t: CachedTarget) -> String {
        "\(t.id)#\(thumbRevisions[t.id, default: 0])#\(t.modified.timeIntervalSince1970)"
    }

    /// Mark a target's thumbnail stale; returns the new revision.
    @discardableResult
    private func invalidateThumb(_ id: String) -> Int {
        let revision = thumbRevisions[id, default: 0] + 1
        thumbRevisions[id] = revision
        thumbCache[id] = nil
        thumbInFlight[id] = nil
        return revision
    }

    /// Load the disk thumbnail for a card, rendering + caching it on first
    /// sight. Renders run one at a time, entirely off the main thread, and a
    /// render that started before the look last changed is dropped, not saved.
    func thumbnail(for t: CachedTarget) async -> NSImage? {
        let id = t.id
        if let cached = thumbCache[id] { return cached }
        if let running = thumbInFlight[id] { return await running.value }
        guard let renderer else { return nil }
        let revision = thumbRevisions[id, default: 0]
        let dir = t.dir, thumbURL = t.thumbURL, gate = thumbGate
        let task = Task { [weak self] () -> NSImage? in
            if let data = await ThumbnailIO.read(thumbURL), let image = NSImage(data: data) {
                guard let self, self.thumbRevisions[id, default: 0] == revision else { return nil }
                self.thumbCache[id] = image
                return image
            }
            await gate.acquire()
            guard self?.thumbRevisions[id, default: 0] == revision else { gate.release(); return nil }
            let rendered = await Task.detached(priority: .utility) { () -> (CGImage, Data)? in
                guard let cg = ThumbnailIO.render(dir: dir, renderer: renderer),
                      let png = ThumbnailIO.pngData(cg) else { return nil }
                return (cg, png)
            }.value
            gate.release()
            guard let self, let rendered, self.thumbRevisions[id, default: 0] == revision else { return nil }
            ThumbnailIO.write(rendered.1, to: thumbURL)
            let image = NSImage(cgImage: rendered.0,
                                size: NSSize(width: rendered.0.width, height: rendered.0.height))
            self.thumbCache[id] = image
            return image
        }
        thumbInFlight[id] = task
        let image = await task.value
        if thumbInFlight[id] == task { thumbInFlight[id] = nil }
        return image
    }

    /// Re-render a target's card from a bundle already in memory.
    private func renderThumbnail(dir: URL, bundle: ChainRenderer.LayerBundle, look: LookState) {
        guard let renderer else { return }
        let id = dir.path
        let revision = invalidateThumb(id)
        let params = look.engineParams
        let task = Task { [weak self] () -> NSImage? in
            let rendered = await Task.detached(priority: .userInitiated) { () -> (CGImage, Data)? in
                guard let cg = try? renderer.renderThumbnail(bundle: bundle, params: params,
                                                             maxDimension: ThumbnailIO.maxDimension),
                      let png = ThumbnailIO.pngData(cg) else { return nil }
                return (cg, png)
            }.value
            guard let self, let rendered, self.thumbRevisions[id, default: 0] == revision else { return nil }
            ThumbnailIO.write(rendered.1, to: dir.appendingPathComponent("thumb.png"))
            let image = NSImage(cgImage: rendered.0,
                                size: NSSize(width: rendered.0.width, height: rendered.0.height))
            self.thumbCache[id] = image
            return image
        }
        thumbInFlight[id] = task
        Task { [weak self] in
            _ = await task.value
            if self?.thumbInFlight[id] == task { self?.thumbInFlight[id] = nil }
        }
    }

    // MARK: - Watch mode

    /// Start watching `url` for `_sub` folders; each one is auto-developed in
    /// the background once its files have stopped arriving, and again whenever
    /// it later gains frames. Folders already there are included.
    func startWatching(_ url: URL) {
        stopWatching()
        watchRoot = url
        Notifier.requestAuthorization()
        let w = FolderWatcher(root: url) { [weak self] arrival in
            guard let self else { return }
            Task { await self.coordinator.watchArrived(arrival) }
        }
        watcher = w
        w.start()
    }

    func stopWatching() { watcher?.stop(); watcher = nil; watchRoot = nil }

    private func watchBakeFinished(key: String, outcome: BakeRunner.Outcome, joined: Bool) {
        let dir = coordinator.cacheDir(forKey: key)
        guard case .success = outcome else { return }
        invalidateThumb(dir.path)
        refreshLibrary()
        // The user who followed this develop in the foreground gets it opened.
        guard !joined else { return }
        Task { [weak self] in
            guard let self else { return }
            let card = CachedTarget(name: key, dir: dir, modified: Date(), sourceSubs: nil,
                                    pipelineVersion: nil)
            _ = await self.thumbnail(for: card)
            // After the thumbnail write queued above has landed.
            ThumbnailIO.queue.async {
                Notifier.developed(key, targetDir: dir, thumbURL: card.thumbURL)
            }
        }
    }

    // MARK: - Quitting

    var hasWorkInFlight: Bool { coordinator.isBusy || exportTask != nil || aiTask != nil }

    /// Cancel every develop, export and enhancement, waiting up to `timeout`
    /// for the bakes to stop their child processes.
    func stopEverything(timeout: Duration) async {
        stopWatching()
        cancelExport()
        invalidateAIPreview()
        await coordinator.cancelEverythingAndWait(timeout: timeout)
    }

    // MARK: - Look

    /// Reset every control to the developed default look.
    func resetLook() {
        look = .default
        edited()
    }

    func edited() {
        invalidateAIPreview()
        if !lookEditedSinceOpen, let dir = currentBakeDir {
            // The card's thumbnail no longer shows this look: drop it now, so
            // even a quit from the editor can't leave a stale one behind.
            lookEditedSinceOpen = true
            invalidateThumb(dir.path)
            ThumbnailIO.remove(dir.appendingPathComponent("thumb.png"))
        }
        scheduleLookSave()
    }

    /// Persist the look after a short drag debounce. Cached layers remain
    /// immutable; only the manifest's look (stamped with the engine version it
    /// was made in) changes.
    private func scheduleLookSave() {
        guard let dir = currentBakeDir else { return }
        pendingLookSave = (look, dir)
        lookSaveTask?.cancel()
        lookSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.flushLookSave()
        }
    }

    /// Write any debounced look save now (leaving the editor, quitting).
    func flushLookSave() {
        lookSaveTask?.cancel()
        lookSaveTask = nil
        guard let pending = pendingLookSave else { return }
        pendingLookSave = nil
        ThumbnailIO.saveLook(pending.look, in: pending.dir)
    }

    // MARK: - In-app AI enhancement (same Real-ESRGAN pass as the AI 2× export)

    /// Whether the optional detail-enhancement model is installed. Enhance and
    /// the "AI 2×" export are hidden without it.
    @Published private(set) var superResolutionAvailable = false
    @Published var aiPreview: CGImage?
    @Published var aiWorking = false
    @Published var aiProgress: Double = 0
    private var aiTask: Task<Void, Never>?
    private var aiRun = 0

    /// Run the AI enhancement on the CURRENT look and show it in the workspace.
    /// Tapping again (or editing any slider) returns to the live view.
    func toggleAIPreview() {
        if aiPreview != nil || aiWorking { invalidateAIPreview(); return }
        guard let renderer, let bundle else { return }
        guard let modelPath = Self.superResolutionModel() else {
            superResolutionAvailable = false
            alert = .enhanceUnavailable
            return
        }
        let lookParams = params, strength = Float(aiStrength)
        aiRun += 1
        let run = aiRun
        aiWorking = true; aiProgress = 0
        let owner = self
        aiTask = Task { [weak self] in
            do {
                // Cancelling this task (✕, any edit) cancels the upscale itself.
                let cg = try await runDetached { () -> CGImage in
                    let rendered = try renderer.renderImage(bundle: bundle, params: lookParams)
                    let result = try SuperResolver(modelPath: modelPath).upscale(
                        pixels: rendered.hwcPixels(), h: rendered.height, w: rendered.width,
                        strength: strength) { p in
                            Task { @MainActor in if owner.aiRun == run { owner.aiProgress = p } }
                        }
                    try Task.checkCancellation()
                    let enlarged = FITSImage.fromHWC(result.0, width: result.2,
                                                     height: result.1, channels: 3)
                    return try ChainRenderer.displayImage(enlarged)
                }
                guard let self, self.aiRun == run else { return }
                self.aiPreview = cg
                self.aiWorking = false
                self.aiTask = nil
            } catch {
                // Superseded runs leave the newer run's state alone.
                guard let self, self.aiRun == run else { return }
                self.aiWorking = false
                self.aiTask = nil
                if !(error is CancellationError) { self.alert = .enhanceFailed(error) }
            }
        }
    }

    /// Drop the enhanced still and return to the live Metal view. Called on any
    /// look edit — the enhancement belongs to the look it was computed from.
    func invalidateAIPreview() {
        guard aiTask != nil || aiWorking || aiPreview != nil || aiProgress != 0 else { return }
        aiRun += 1
        aiTask?.cancel(); aiTask = nil
        aiWorking = false; aiPreview = nil; aiProgress = 0
    }

    // MARK: - Export

    /// Export the current look to a full-res 16-bit PNG via the SAME renderer as
    /// the live preview, so what you see is exactly what you save. Surfaces the
    /// outcome so the editor can confirm success or show the failure.
    @Published var lastSaved: URL?
    /// A problem to show in the editor (export, enhancement).
    @Published var alert: UserMessage?
    @Published var exportScale = 1
    @Published var aiStrength: Double = 0.65
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    private var exportTask: Task<Void, Never>?
    private var exportRun = 0

    func export(to url: URL) {
        guard let renderer, let bundle else { alert = .nothingToExport; return }
        let scale = exportScale, lookParams = params, strength = Float(aiStrength)
        let model = scale == 3 ? Self.superResolutionModel() : nil
        if scale == 3 && model == nil {
            superResolutionAvailable = false
            exportScale = 1
            alert = .enhanceUnavailable
            return
        }
        exportTask?.cancel()
        exportRun += 1
        let run = exportRun
        isExporting = true; exportProgress = 0
        let owner = self
        exportTask = Task { [weak self] in
            var failure: (any Error)?
            do {
                // Cancel reaches the upscale (it stops between tiles) and the
                // file is only moved into place if the export wasn't cancelled.
                try await runDetached {
                    try Self.writeExport(renderer: renderer, bundle: bundle, params: lookParams,
                                         scale: scale, model: model, strength: strength, to: url) { p in
                        Task { @MainActor in if owner.exportRun == run { owner.exportProgress = p } }
                    }
                }
            } catch {
                failure = error
            }
            // A cancelled or superseded export leaves the newer one's state alone.
            guard let self, self.exportRun == run else { return }
            self.isExporting = false
            self.exportProgress = 0
            self.exportTask = nil
            if let failure {
                if !(failure is CancellationError) { self.alert = .exportFailed(failure) }
            } else {
                self.lastSaved = url
            }
        }
    }

    func cancelExport() {
        exportRun += 1
        exportTask?.cancel(); exportTask = nil
        isExporting = false; exportProgress = 0
    }

    /// Render into a temporary file beside the destination, then move it into
    /// place — a cancelled export never leaves (or overwrites) a file.
    nonisolated static func writeExport(renderer: ChainRenderer, bundle: ChainRenderer.LayerBundle,
                                        params: EngineParams, scale: Int, model: String?,
                                        strength: Float, to url: URL,
                                        progress: @escaping @Sendable (Double) -> Void) throws {
        let fm = FileManager.default
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: url.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: scratch) }
        let tmp = scratch.appendingPathComponent(url.lastPathComponent)
        if scale == 3, let model {
            let rendered = try renderer.renderImage(bundle: bundle, params: params)
            let result = try SuperResolver(modelPath: model).upscale(
                pixels: rendered.hwcPixels(), h: rendered.height, w: rendered.width,
                strength: strength, progress: progress)
            try Task.checkCancellation()
            let enlarged = FITSImage.fromHWC(result.0, width: result.2, height: result.1, channels: 3)
            try renderer.writePNG(enlarged, to: tmp)
        } else {
            try renderer.renderPNG(bundle: bundle, params: params, scale: scale, to: tmp)
        }
        try Task.checkCancellation()
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }

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
            case .opening:           OpeningView()
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
            if !model.libraryLoaded {
                Color.clear                      // don't flash the first-run screen
            } else if model.libraryTargets.isEmpty {
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
            // Watching with nothing developed yet: say so, or it looks idle.
            if model.watchRoot != nil {
                HStack(spacing: 8) {
                    if !model.autoBaking.isEmpty { ProgressView().controlSize(.small) }
                    watchButton
                }
                Text(model.autoBaking.isEmpty
                     ? "New captures develop automatically once they’ve finished copying."
                     : "Developing \(model.autoBaking.count)…")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                .overlay(alignment: .topTrailing) {
                    if target.needsRedevelop {
                        Button { model.redevelop(target) } label: {
                            Label("Update", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.accentColor, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(8)
                        .help("Develop again with Nebula’s latest improvements")
                    }
                }

            Text(target.name)
                .font(.callout).foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).truncationMode(.middle)
        }
        // Re-fetched whenever the card's image goes stale (edited, re-developed);
        // the old image stays up until the new one is ready.
        .task(id: model.thumbnailID(for: target)) {
            if let fresh = await model.thumbnail(for: target) { image = fresh }
        }
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
    let message: UserMessage
    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light)).foregroundStyle(.yellow)
            Text(message.title).font(.title2.weight(.semibold))
                .foregroundStyle(.white).multilineTextAlignment(.center)
            Text(message.body).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 12) {
                if case .watch(let folder)? = message.action {
                    Button("Watch This Folder") {
                        model.reset()
                        model.startWatching(folder)
                    }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                    Button("Back to Library") { model.reset() }.controlSize(.large)
                } else {
                    Button("Try Another Folder") { model.reset() }
                        .controlSize(.large).buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 8)
            if let details = message.details { detailsDisclosure(details) }
            Spacer()
        }.padding(40)
    }

    /// The technical text, out of the way, for bug reports.
    private func detailsDisclosure(_ details: String) -> some View {
        DisclosureGroup("Details", isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(details).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(details, forType: .string)
                    }
                    if let logs = message.logsFolder {
                        Button("Show Log") { NSWorkspace.shared.activateFileViewerSelecting([logs]) }
                    }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: 440)
        .padding(.top, 12)
    }
}

/// Reading a target's layers and preparing them for the GPU (a second or two).
struct OpeningView: View {
    @EnvironmentObject var model: EngineModel
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Opening \(model.targetName)…").font(.callout).foregroundStyle(.secondary)
        }
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
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } })
        ) {
            Button("OK", role: .cancel) { model.alert = nil }
        } message: { Text(model.alert?.body ?? "") }
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
                    Text(model.captureSummary.isEmpty
                         ? "\(bundle.width) × \(bundle.height)"
                         : model.captureSummary)
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .help(model.captureSummary)
                Spacer()
                // Only offered when the optional enhancement model is installed.
                if model.superResolutionAvailable {
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
                }
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
                            HeroView(renderer: renderer, bundle: bundle, state: .init(
                                look: model.look, compare: model.compare,
                                divider: model.divider, clipping: model.showClipping))
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
                    if model.superResolutionAvailable { Text("AI 2×").tag(3) }
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

/// SwiftUI wrapper around the live MTKView. Draws on demand — when the look,
/// compare/divider, clipping overlay, layers or size change — instead of
/// re-running the full-resolution chain 120 times a second while idle. A slider
/// move still redraws on the very next display refresh.
struct HeroView: NSViewRepresentable {
    /// Everything a frame depends on besides the layers.
    struct RenderState: Equatable {
        var look: LookState
        var compare: Bool
        var divider: Float
        var clipping: Bool
    }

    let renderer: ChainRenderer
    let bundle: ChainRenderer.LayerBundle
    let state: RenderState

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer, bundle: bundle, state: state) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = ChainRenderer.drawablePixelFormat
        view.colorspace = ChainRenderer.outputColorSpace
        view.framebufferOnly = true
        view.isPaused = true                  // no display-link loop…
        view.enableSetNeedsDisplay = true     // …draw when marked dirty
        view.delegate = context.coordinator
        view.needsDisplay = true
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let c = context.coordinator
        guard c.bundle !== bundle || c.state != state else { return }
        c.bundle = bundle
        c.state = state
        view.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: ChainRenderer
        var bundle: ChainRenderer.LayerBundle
        var state: RenderState
        init(renderer: ChainRenderer, bundle: ChainRenderer.LayerBundle, state: RenderState) {
            self.renderer = renderer; self.bundle = bundle; self.state = state
        }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.needsDisplay = true
        }
        func draw(in view: MTKView) {
            renderer.draw(bundle: bundle, params: state.look.engineParams,
                          compare: state.compare, divider: state.divider,
                          clipping: state.clipping, in: view)
        }
    }
}

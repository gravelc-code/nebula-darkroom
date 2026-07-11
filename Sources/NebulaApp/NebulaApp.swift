import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MetalKit
import NebulaCore
import NebulaEngine

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

    @Published var look: LookState = Preset.auto.look
    @Published var activePreset: Preset? = .auto
    @Published var compare = false
    @Published var divider: Float = 0.5

    private let baker = BakeRunner()
    var params: EngineParams { look.engineParams }

    init() {
        // The renderer needs no layers, so build it once up front. If Metal or
        // the shaders fail, that's a hard failure — surface it immediately.
        do { renderer = try ChainRenderer() }
        catch { renderer = nil; phase = .failed("Metal engine failed: \(error)"); return }

        // Launch argument / env: a bake dir opens straight into the editor; a
        // subs folder is baked. Otherwise show the launch screen.
        let args = CommandLine.arguments
        if args.count > 1 {
            open(URL(fileURLWithPath: args[1]))
        } else if let e = ProcessInfo.processInfo.environment["NEBULA_LAYERS"] {
            open(URL(fileURLWithPath: e))
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

    /// Decide what a dropped/chosen folder is and route accordingly.
    func open(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            phase = .failed("Not a folder: \(url.lastPathComponent)"); return
        }
        targetName = Self.targetName(from: url)
        if BakeRunner.hasAllLayers(in: url) {
            loadLayers(from: url)                    // already a bake dir
        } else if Self.containsLights(url) {
            startBake(subsDir: url)                  // a subs folder → bake it
        } else {
            phase = .failed("No FITS light frames or bake layers in \(url.lastPathComponent).")
        }
    }

    private func startBake(subsDir: URL) {
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
            func layer(_ n: String) throws -> FITSImage {
                try FITSImage.read(dir.appendingPathComponent("\(n).fits"))
            }
            bundle = renderer.makeBundle(
                master: try layer("master"), denoised: try layer("denoised"),
                starless: try layer("starless"), stars: try layer("stars"))
            look = Preset.auto.look; activePreset = .auto
            phase = .editing
        } catch {
            phase = .failed("Failed to load layers: \(error)")
        }
    }

    func cancelBake() { baker.cancel(); reset() }
    func reset() { bundle = nil; phase = .launch }

    func apply(_ preset: Preset) { look = preset.look; activePreset = preset }
    func edited() { activePreset = Preset.matching(look) }

    /// Export the current look to a full-res 16-bit PNG via the SAME renderer as
    /// the live preview, so what you see is exactly what you save.
    func export(to url: URL) {
        guard let renderer, let bundle else { return }
        try? renderer.renderPNG(bundle: bundle, params: params, to: url)
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
        .frame(minWidth: 560, minHeight: 780)
    }
}

// MARK: - Launch

struct LaunchView: View {
    @EnvironmentObject var model: EngineModel
    @State private var targeted = false

    var body: some View {
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
            Spacer()
        }
        .padding(40)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers)
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
    @State private var showAdvanced = true

    var body: some View {
        ZStack {
            if let renderer = model.renderer, let bundle = model.bundle {
                GeometryReader { geo in
                    HeroView(renderer: renderer, bundle: bundle, model: model)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                            if model.compare {
                                model.divider = Float(max(0, min(1, v.location.x / geo.size.width)))
                            }
                        })
                }
                .aspectRatio(CGFloat(bundle.width) / CGFloat(bundle.height),
                             contentMode: .fit)
                .ignoresSafeArea()
                controls
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    model.reset()
                } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.borderless).foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
                Text(model.targetName).foregroundStyle(.white.opacity(0.9))
                    .font(.headline).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.45), in: Capsule())
                Spacer()
                // spacer symmetry
                Color.clear.frame(width: 88, height: 1)
            }
            .padding(.horizontal, 16).padding(.top, 14)

            Spacer()
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    ForEach(Preset.allCases, id: \.self) { p in
                        Button(p.displayName) { model.apply(p) }
                            .buttonStyle(.borderless)
                            .foregroundStyle(model.activePreset == p ? .white : .secondary)
                            .fontWeight(model.activePreset == p ? .semibold : .regular)
                    }
                    Spacer()
                    Button(model.compare ? "Compare ✓" : "Compare") { model.compare.toggle() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(model.compare ? .white : .secondary)
                    Button("Export…") { exportImage() }
                        .buttonStyle(.borderless).foregroundStyle(.white)
                }
                ForEach(Control.headline, id: \.self) { sliderRow($0) }
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    ForEach(Control.advanced, id: \.self) { sliderRow($0) }
                }
                .font(.callout).tint(.secondary)
            }
            .padding(16)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: 460)
            .padding(.bottom, 24)
        }
    }

    private func exportImage() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.targetName).png"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    private func sliderRow(_ s: Control) -> some View {
        HStack {
            Text(s.displayName).frame(width: 92, alignment: .leading)
                .font(.callout).foregroundStyle(.white)
            SwiftUI.Slider(
                value: Binding(
                    get: { model.look[s] },
                    set: { model.look[s] = $0; model.edited() }),
                in: 0...1)
            Text("\(model.look.percent(s))").frame(width: 34, alignment: .trailing)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
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
                          compare: model.compare, divider: model.divider, in: view)
        }
    }
}

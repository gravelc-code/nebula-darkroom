import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MetalKit
import NebulaCore
import NebulaEngine

/// Disambiguate the look control from `SwiftUI.Slider`.
private typealias Control = NebulaCore.Slider

// The interactive Stage-B app. A SwiftUI window with a full-bleed hero image
// (MTKView) rendered by the native Metal engine, and floating sliders. The
// render loop draws the *current* look every vsync, so slider drags feel
// weightless (design §5/§6).
//
// Layers come from a bake dir: `swift run NebulaApp <layers_dir>` or the
// NEBULA_LAYERS env var (a dir with master/denoised/starless/stars .fits).

@main
struct NebulaApp: App {
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
    let renderer: ChainRenderer?
    let bundle: ChainRenderer.LayerBundle?
    let loadError: String?
    @Published var look: LookState = Preset.auto.look
    @Published var activePreset: Preset? = .auto
    @Published var compare = false
    @Published var divider: Float = 0.5

    var params: EngineParams { look.engineParams }

    init() {
        func findDir() -> URL? {
            let args = CommandLine.arguments
            if args.count > 1 { return URL(fileURLWithPath: args[1]) }
            if let e = ProcessInfo.processInfo.environment["NEBULA_LAYERS"] {
                return URL(fileURLWithPath: e)
            }
            return nil
        }
        guard let dir = findDir() else {
            renderer = nil; bundle = nil
            loadError = "No layers dir. Pass one as an argument or set NEBULA_LAYERS."
            return
        }
        do {
            let r = try ChainRenderer()
            func layer(_ n: String) throws -> FITSImage {
                try FITSImage.read(dir.appendingPathComponent("\(n).fits"))
            }
            bundle = r.makeBundle(master: try layer("master"), denoised: try layer("denoised"),
                                  starless: try layer("starless"), stars: try layer("stars"))
            renderer = r; loadError = nil
        } catch {
            renderer = nil; bundle = nil
            loadError = "Failed to load layers: \(error)"
        }
    }

    func apply(_ preset: Preset) { look = preset.look; activePreset = preset }
    func edited() { activePreset = Preset.matching(look) }

    /// Export the current look to a full-res PNG via the SAME renderer as the
    /// live preview, so what you see is exactly what you save.
    func export(to url: URL) {
        guard let renderer, let bundle else { return }
        try? renderer.renderPNG(bundle: bundle, params: params, to: url)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: EngineModel
    @State private var showAdvanced = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
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
            } else {
                Text(model.loadError ?? "No engine")
                    .foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 520, minHeight: 760)
    }

    private var controls: some View {
        VStack {
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
        panel.nameFieldStringValue = "Nebula.png"
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

    func updateNSView(_ view: MTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: ChainRenderer
        let bundle: ChainRenderer.LayerBundle
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

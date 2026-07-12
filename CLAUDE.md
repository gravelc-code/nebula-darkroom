# Nebula — repo guide for AI agents

Nebula is a **macOS 14+ / Apple-Silicon app that turns a folder of Seestar
telescope sub-frames into a finished deep-sky image with one tap**, then exposes
~8 plain-language sliders that respond instantly. It should feel like a photo
app, not a telescope tool. GPL-3.0.

This file orients you fast. Deeper detail lives in:
- **`seestar-autoprocess-design.md`** — the design of record (architecture, UX §6, the slider→engine table).
- **`HANDOFF.md`** — current build status per phase + hard-won gotchas. Read this to see what's done.
- **`prototype/README.md`**, **`prototype/ai_native/README.md`** — the throwaway Python reference + the AI-parity spikes.

## The one architectural idea: bake once, play forever

1. **Bake** (slow, once per target, cached): register + stack the subs, remove
   the sky gradient, denoise, separate stars → **five float FITS layers**
   (`master · corrected · denoised · starless · stars`) + a typed `manifest.json`.
2. **Play** (instant, interactive): the Metal engine composites those layers
   under the current slider look at 120 fps. **Preview == export** — the same
   shaders drive the live view and the 16-bit PNG.

Division of labour (hold this line):
- **Classical DSP stays wrapped in Siril** (register/stack/colour) — a subprocess. Do NOT reimplement astrometry/stacking.
- **AI runs in-process** via **onnxruntime** (GraXpert's ONNX models), NOT a converted CoreML model (coremltools can't ingest ONNX). ORT uses the CoreML EP under the hood where it helps.
- **The interactive layer is native Metal.** SwiftUI is the shell.
- **Never a dead end:** every bake stage falls back to a good-enough result; the user always lands on an image.

## Module map (`Package.swift` → `Sources/…`)

Data flows top-to-bottom. Deps point downward.

| Target | Kind | Role |
|--------|------|------|
| `NebulaCore` | lib | Pure, tested, no deps. The `LookState` (10 normalized floats), `Slider`/`Profile`, `EngineParams` (slider→shader mapping), `Target`, and the `Manifest` bake↔play contract. **Single source of truth** shared by engine, bake, UI. `LookState.neutral` (truthful "before") + `LookState.default` (the developed opening look) replace the old preset system. |
| `NebulaEngine` | lib | The Metal "Stage-B" engine: `ChainRenderer` (shader chain → live `MTKView` + 16-bit PNG), `Shaders.swift` (GHS stretch etc.), `FITSImage` (narrow float-FITS read/**write** + HWC helpers). |
| `NebulaAI` | lib | In-process AI via onnxruntime (`onnxruntime` SPM pkg, imported as `OnnxRuntimeBindings`). `OrtModel` (persistent session), `Denoiser` + `BgExtractor` — faithful Swift ports of GraXpert's pipelines, validated bit-exact/visually-identical against the Python spikes. |
| `NebulaBake` | lib | The **native bake orchestrator** (replaces Python `bake.py`). `SirilStage` selects one compatible filter group, then registers/stacks and attempts PCC; `Baker` runs in-process background removal + denoise and emits 4 layers + `Manifest`. A pluggable StarNet hook (`NEBULA_STARNET`) is preferred; otherwise a feathered classical star mask keeps star controls functional. |
| `NebulaApp` | exe | The SwiftUI app. `NebulaApp.swift` (phases: Library grid → baking → editor), `BakeRunner` (drives `Baker` off-main, `AsyncStream` progress, cancellable), `Library`, `FolderWatcher` (watch mode), `Notifier`. |
| `NebulaRender` | exe | `nebula-render <bakeDir> <preset> <out.png>` — headless export, proves the chain with no UI. |
| `nebula-ai` (`NebulaAICLI`) | exe | FITS-in/out `denoise`/`bg` CLI — a drop-in for the GraXpert subprocess; models auto-discovered. |
| `nebula-bake-native` (`NebulaBakeCLI`) | exe | Drives `Baker` from the CLI (`<subs> <out>`). `NEBULA_CANCEL_AFTER=<s>` tests cancellation. |
| `nebula-ai-probe` (`NebulaAIProbe`) | exe | Dev: prove ORT links/loads/infers from Swift. |

`prototype/` is the **dev-only Python reference** (Phase 0). Never shipped. `prototype/ai_native/*.py` are the parity spikes the Swift AI was validated against.

## Build / test / run / package

```bash
# IMPORTANT: this repo lives under Dropbox → in-tree .build codesigning is flaky.
# Always build/test with a scratch path OUTSIDE the synced folder:
scripts/swift-xcode.sh build --scratch-path /tmp/nebula-build
scripts/swift-xcode.sh test  --scratch-path /tmp/nebula-build

scripts/swift-xcode.sh build --product NebulaApp --scratch-path /tmp/nebula-build
/tmp/nebula-build/debug/NebulaApp                      # Library / drop a "…_subs" folder
/tmp/nebula-build/debug/NebulaApp <folder>             # open a subs folder or bake dir directly

# Native bake from the CLI (no app):
/tmp/nebula-build/debug/nebula-bake-native "<…_sub folder>" <out_dir>

# Ship: a self-contained app + DMG (bundles onnxruntime + Siril; GraXpert's
# bge/denoise models are NEVER bundled — see NOTICES.md):
scripts/build-app.sh      # → build/Nebula.app  (needs Homebrew siril + dylibbundler)
scripts/build-dmg.sh      # → build/Nebula.dmg  (drag-to-Applications, ~100 MB)
```

Dev prerequisites: Xcode 26+/Swift 6+, `brew install siril dylibbundler`. GraXpert's
ONNX models are auto-discovered (env override → app bundle → `~/Library/Application
Support/Nebula/Models` → GraXpert's own cache) but **never redistributed** — the
shipping app shows a one-time "install GraXpert" explainer instead (see NOTICES.md).
Bakes cache to `~/Library/Caches/Nebula/<target>/`.

Launch env hooks (useful for headless testing): `NEBULA_WATCH=<dir>` (start watch
mode), `NEBULA_LAYERS=<bakeDir>` (open straight into editor).

## Invariants — don't break these
- **`LookState` is 10 normalized floats** and the single source of truth; the slider→shader mapping is `EngineParams` (design §6 table). Saved in the manifest, shareable. There are no user-facing presets — targets open on `LookState.default` and a Reset restores it.
- **Preview == export**: both go through `ChainRenderer.encodeChain`. Any look change must be in the shader chain, not a one-off.
- **No Python in the shipping build.** `prototype/` is reference only; `NebulaBake` is what ships.
- **No jargon in UI strings** (there's a test for this): the user sees Glow/Saturation/Vibrance/Tint/Stars/Contrast/Background/Detail/Star Size/Denoise, never "GHS"/"SPCC"/"starless".
- **Star Size is bidirectional**: 50 = the captured profiles bit-exactly; below erodes the real star flux (star reduction), above blooms. Don't reintroduce always-on bloom.
- **GraXpert models and StarNet are never bundled or auto-downloaded** (licence terms; even Siril requires a GraXpert install to get the models — their S3 credentials are private).

## Gotchas that cost real time (all fixed in code — keep them fixed)
- **Siril `-out=` can't express a space or a quote** → run its `-out=` writes in a space-free scratch dir (real targets are "M 83"). (`SirilStage`)
- **A Seestar `_sub` folder mixes FITS lights with preview/thumbnail JPEGs** → stage only the FITS before `convert`. (`SirilStage`)
- **Don't hand Siril a `Pipe` you never drain** → it deadlocks at ~64 KB mid-stack; log to a file. (`SirilStage`)
- **Bundling Siril:** dylibbundler misses versioned-name stragglers (libde265/openblas/tbb) → a static dep-closure loop; then **dedupe `LC_RPATH`** (dyld rejects duplicate `@executable_path/libs/`). (`scripts/build-app.sh`)
- **AI runtime:** CoreML EP is a dead end for these models (denoise won't compile; bge slower). Use the CPU EP — it's bit-exact and comparable to GraXpert's own speed.

## Status
The 6-phase roadmap (see `HANDOFF.md`) is **complete except notarisation** — the
DMG is ad-hoc signed; a notarised build needs an Apple Developer ID
(`codesign --options runtime` + `xcrun notarytool submit` + `stapler staple`).
The whole develop pipeline — Siril + in-process AI + Metal — runs from the bundle
with **no external tools**.

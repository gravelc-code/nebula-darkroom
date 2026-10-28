# Nebula — repo guide for AI agents

Nebula is a **macOS 26+ / Apple-Silicon app that turns a folder of Seestar
telescope sub-frames into a finished deep-sky image with one tap**, then exposes
11 plain-language sliders that respond instantly. It should feel like a photo
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
- **AI runs in-process** via **onnxruntime** (GraXpert's ONNX models) on its **CPU execution provider** — NOT a converted CoreML model (coremltools can't ingest ONNX), and not ORT's CoreML EP (see Gotchas). onnxruntime is a static xcframework, linked into the executable.
- **The interactive layer is native Metal.** SwiftUI is the shell.
- **Never a dead end:** every bake stage falls back to a good-enough result; the user always lands on an image.

## Module map (`Package.swift` → `Sources/…`)

Data flows top-to-bottom. Deps point downward.

| Target | Kind | Role |
|--------|------|------|
| `NebulaCore` | lib | Pure, tested, no deps. The `LookState` (11 normalized floats), `Slider`/`Profile`, `EngineParams` (slider→shader mapping), `Target`, and the `Manifest` bake↔play contract. **Single source of truth** shared by engine, bake, UI. `LookState.neutral` (truthful "before") + `LookState.default` (the developed opening look) replace the old preset system. |
| `NebulaEngine` | lib | The Metal "Stage-B" engine: `ChainRenderer` (shader chain → live `MTKView` + 16-bit PNG), `Shaders.swift` (GHS stretch etc.), `FITSImage` (narrow float-FITS read/**write** + HWC helpers). |
| `NebulaAI` | lib | In-process AI via onnxruntime (`onnxruntime` SPM pkg, imported as `OnnxRuntimeBindings`). `OrtModel` (persistent session), `Denoiser` + `BgExtractor` — faithful Swift ports of GraXpert's pipelines, validated bit-exact/visually-identical against the Python spikes. |
| `NebulaBake` | lib | The **native bake orchestrator** (replaces Python `bake.py`). `SirilStage` selects one compatible filter group, then registers/stacks and attempts PCC; `Baker` runs in-process background removal + denoise and emits the 5 layers + `Manifest`. A user-installed StarNet is preferred (`NEBULA_STARNET`, or a `starnet2` auto-discovered in `/usr/local/bin`, `/opt/homebrew/bin`, `/usr/bin`); otherwise a feathered classical star mask keeps star controls functional. |
| `NebulaApp` | exe | The SwiftUI app. `NebulaApp.swift` (phases: Library grid → baking → editor), `BakeCoordinator` (one claim per cache key shared by manual opens and the serial watch queue), `BakeRunner` (stages one bake on its own thread via `BakeExecutor`, cancellable), `CacheKey`, `UserMessage` (every error → plain language), `Library`, `FolderWatcher` (watch mode: a folder is developed only after 60 s with no new frames, and re-developed when its fingerprint changes), `Thumbnails`, `Notifier`. |
| `NebulaRender` | exe | `nebula-render <bakeDir> <default\|neutral> <out.png> [slider=value …]` — headless export, proves the chain with no UI. |
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

# Ship: a self-contained app + DMG (Siril + its dylib closure + every licence
# text; GraXpert's bge/denoise models are NEVER bundled — see NOTICES.md).
# Release signing/notarisation/source tarball: docs/RELEASING.md.
scripts/build-app.sh      # → build/Nebula.app  (needs Homebrew siril + dylibbundler)
scripts/build-dmg.sh      # → build/Nebula.dmg  (drag-to-Applications, ~130 MB)
scripts/verify-bundle.sh build/Nebula.app   # closure + per-Mach-O signature check
```

Dev prerequisites: full Xcode 16+ (Swift 6; the package is swift-tools 6.0, CI
uses Xcode 16), `brew install siril dylibbundler`. GraXpert's
ONNX models are auto-discovered (env override → app bundle → `~/Library/Application
Support/Nebula/Models` → GraXpert's own cache) but **never redistributed** — the
shipping app shows a one-time "install GraXpert" explainer instead (see NOTICES.md).
Bakes cache to `~/Library/Caches/Nebula/<key>/`: the target name, `"M 42 mosaic"`
for mosaic folders, `"M 42 (2)"` when a different subs folder already owns the
name. Each bake records its source in `source.txt` + `source.json` (frame count,
bytes, newest mtime) so a folder that gains subs is re-developed.

Launch env hooks (useful for headless testing): `NEBULA_WATCH=<dir>` (start watch
mode), `NEBULA_LAYERS=<bakeDir>` (open straight into editor).

## Invariants — don't break these
- **`LookState` is 11 normalized floats** and the single source of truth; the slider→shader mapping is `EngineParams` (design §6 table). Saved in the manifest, shareable. There are no user-facing presets — targets open on `LookState.default` and a Reset restores it.
- **Preview == export**: both go through `ChainRenderer.encodeChain`. Any look change must be in the shader chain, not a one-off.
- **No Python in the shipping build.** `prototype/` is reference only; `NebulaBake` is what ships.
- **No jargon in UI strings** (there's a test for this): the user sees Glow/Saturation/Vibrance/Tint/Warmth/Stars/Contrast/Background/Detail/Star Size/Denoise, never "GHS"/"SPCC"/"starless".
- **Star Size is bidirectional**: 50 = the captured profiles bit-exactly; below erodes the real star flux (star reduction), above blooms. Don't reintroduce always-on bloom.
- **GraXpert models and StarNet are never bundled or auto-downloaded** (licence terms; even Siril requires a GraXpert install to get the models — their S3 credentials are private).
- **Bakes are staged, never in place**: `BakeRunner` builds in `Caches/Nebula/.staging/<uuid>` and `StagedBake.commit()` swaps it in only on success. Never delete a target's cache before re-baking it; Cancel discards the result and changes nothing.
- **A bake stage never ends the bake except Cancel**: AI stages go through `Baker.aiStage` (an unusable model passes its input through), optional stages through `Baker.attempt` — never a bare `try?`, which swallows `CancellationError`.

## Gotchas that cost real time (all fixed in code — keep them fixed)
- **Siril `-out=` can't express a space or a quote** → run its `-out=` writes in a space-free scratch dir (real targets are "M 83"). (`SirilStage`)
- **A Seestar `_sub` folder mixes FITS lights with preview/thumbnail JPEGs** → stage only the FITS before `convert`. (`SirilStage`)
- **Don't hand Siril a `Pipe` you never drain** → it deadlocks at ~64 KB mid-stack; log to a file. (`SirilStage`)
- **Bundling Siril:** dylibbundler misses versioned-name stragglers (libde265/openblas/tbb) → a static dep-closure loop; then **dedupe `LC_RPATH`** (dyld rejects duplicate `@executable_path/libs/`). (`scripts/build-app.sh`)
- **Bundled Siril needs the build Mac's macOS:** Homebrew bottles target the host OS (currently `minos 26.0`), so the app can't run below that whatever `Package.swift` says. `build-app.sh` sets `LSMinimumSystemVersion` from the highest `minos` in the bundle — never hard-code a lower one.
- **Every child process goes through `ChildProcess`** (posix_spawn in its own process group): cancel/timeout SIGTERMs the whole group, SIGKILLs after a grace period and reaps before returning. `Process.terminate()` on a `bash -c` template only killed bash and left StarNet running. (`NebulaBake`)
- **Siril's `stack` refuses a single image** → a one-sub folder is developed with `pm "$light_00001$" -rescale` (float, [0,1], like `-output_norm`). (`SirilStage` fallback ladder)
- **AI runtime:** CoreML EP is a dead end for these models (denoise won't compile; bge slower). Use the CPU EP — it's bit-exact and comparable to GraXpert's own speed.
- **Siril lives in `Contents/Resources`** (the app runs `Resources/siril/siril`), so `codesign --verify --deep` treats its ~94 Mach-Os as sealed data and never checks their signatures — the notary service does. `scripts/verify-bundle.sh` checks each one (and the dependency closure); build-app/build-dmg/notarize all run it.
- **Licence compliance is part of the build:** `gen-notices.sh` attributes every bundled binary to its Homebrew keg by LC_UUID (exact formula + version), copies licence texts into `Resources/Licenses`, and records source URLs/SHA-256s; `fetch-sources.sh` turns that into the per-release source tarball (GPL-3.0 §6). Release builds fail if anything can't be attributed.

## Status
The 6-phase roadmap (see `HANDOFF.md`) is **complete except notarisation**. The
latest release build is Developer ID signed (hardened runtime + secure
timestamp on every Mach-O) but not yet notarised; the flow is
`NEBULA_SIGN_ID=… build-app.sh → notarize.sh app → build-dmg.sh → notarize.sh dmg
→ fetch-sources.sh` (docs/RELEASING.md). The whole develop pipeline — Siril +
in-process AI + Metal — runs from the bundle with **no external tools**.

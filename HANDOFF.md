# Nebula — build handoff

Snapshot of progress so work can resume on another machine. Full roadmap is in
[`README.md`](README.md); design of record is
[`seestar-autoprocess-design.md`](seestar-autoprocess-design.md); the executable
plan lives outside the repo at `~/.claude/plans/have-a-look-at-floating-narwhal.md`.

## Where things stand

| Phase | Status |
|-------|--------|
| **−1 · Scaffolding** | ✅ Done & tested |
| **0 · Prove the bake** | ✅ **Acceptance met.** Proven end-to-end on real subs (M83, 67×30s) with real GraXpert (bg+denoise) + StarNet (separation); decisively beat the Seestar JPEG. Recipe below. |
| **1 · Metal engine** | ✅ **Done.** `NebulaEngine` (shared) drives a headless CLI (`nebula-render`) and a live SwiftUI app (`NebulaApp`): 120fps `MTKView` loop, 8 sliders, presets, in-app Export (**16-bit PNG**, no banding), mipmapped faithful preview, before/after divider. Real star-layer stretch + native bilateral Denoise. Deferred by design: **tiled export** — not needed, a 1080×1920 frame renders whole in one pass (revisit only for mosaics / input-streaming); **exact published GHS** — a *look* change, folded into look-tuning (deferred to last per user). |
| **2 · Native AI** | 🟢 **bg-removal + denoise now run natively in-process.** GraXpert's ONNX models (bge 1.0.1, denoise 3.0.2) are driven via **onnxruntime** (SwiftPM `OnnxRuntimeBindings`, pinned 1.19.2) — Swift ports in `Sources/NebulaAI` (`Denoiser`, `BgExtractor`) match GraXpert bit-exactly (denoise 1.9e-9) / visually (bg ~6e-5). Exposed as a `nebula-ai` FITS-in/out CLI that the bake prefers over GraXpert.app (`prototype/nebula-bake.sh`), so the external app is no longer required. **Runtime decision: ORT, not a converted `.mlmodel`** — coremltools 9 can't ingest ONNX; ORT runs the same models on the ANE/GPU via its CoreML EP (see `prototype/ai_native/README.md`). Speed: runs on ORT's **CPU EP** — denoise ~2.3 min/frame, comparable to GraXpert's own runtime (its from-master bg+denoise took ~1:51). **CoreML EP is a dead end for these models** (denoise graph won't compile — Espresso broadcast error; bge is *slower* on CoreML than CPU due to compile overhead); a future ~30% win is tile-batching. Remaining: **StarNet** star-separation still subprocess/fallback. |
| **3 · Robust bake orchestrator** | 🟢 **Native Swift bake, wired into the app.** `Sources/NebulaBake` (`SirilStage` + `Baker`) ports the Python bake: Siril register/stack + native colour as a subprocess (classical DSP stays wrapped), then **background-removal + denoise in-process** via NebulaAI (no subprocess, no FITS round-trip), then the four layers + a typed `NebulaCore.Manifest`. `BakeRunner` now drives it off the main actor (progress via `AsyncStream`) — **no Python, no `nebula-bake.sh`, no GraXpert.app**. Star-separation is a pluggable FITS-in/out hook (`NEBULA_STARNET`), else `starless = master`. Validated: app-baked M27 (Dumbbell) & M83 end-to-end; native master layer matches the Python bake to ~2e-5. **Gotcha reproduced:** don't hand Siril a `Pipe` you never drain — it fills the ~64KB buffer and deadlocks mid-stack; write logs to a file (`_work/siril.log`). Remaining: bundle/pin Siril for shipping; mid-bake cancellation (stages don't yet poll). |
| **4 · SwiftUI app** | 🟢 **Substantially done.** `NebulaApp` is now a photo-app, not a debug panel: **home** (a real **Library grid** of previously-developed targets — finished-look thumbnails rendered through the *same* GPU chain, disk-cached in each bake dir; drop / "＋ Develop" for new ones) → **baking** (live progress, streamed from the bake subprocess, per-target cached for instant re-open) → **editing** (the Phase-1 hero + 8 sliders + 16-bit Export) → the "Library" button returns to the grid. A folder that's already a bake dir opens straight into the editor. Remaining: watch mode (Phase 5), look-tuning polish. |
| **5 · Watch mode + DMG** | 🟢 **Fully self-contained app + watch mode done.** `scripts/build-app.sh` assembles `Nebula.app` with **everything bundled — no external tools**: release exe, `onnxruntime.framework`, the ONNX models (`Resources/Models`), and **Siril + its 93-dylib closure** (`Resources/siril`; dylibbundler + a static dep-closure loop for versioned-name stragglers + LC_RPATH dedupe). Verified: bundled Siril runs the full convert/register/stack under `env -i` (zero Homebrew). Discovery is bundle-aware (`Bundle.main` for Siril + models), so a shipped app needs no `brew install siril` and no GraXpert.app. **Watch mode** (`FolderWatcher`): a "Watch Folder…" toggle auto-develops new `_sub` folders in the background + posts a thumbnail notification. Remaining: a **notarised DMG** (needs an Apple Developer ID; dylibs are ad-hoc signed for now). |

### Phase 0 real-AI recipe (dev-only tools, reproduced 2026-07-11)
- **Siril**: `convert -debayer` (mandatory for Seestar CFA) → register → stack → native colour.
- **GraXpert 3.0.2 arm64** DMG, headless: `-cli -cmd background-extraction` and `-cmd denoising`
  (`-output <base>` appends `.fits`, so wrap to normalise the extension).
- **StarNet++ v2** (`starnet2`+libtorch, bundled in NEPaladin/StarNetPro.app): TIFF-only,
  needs a *stretched* image → wrap linear FITS ↔ invertible-MTF 16-bit TIFF; `imagecodecs`
  to read its LZW output. Binary is hardened-runtime signed w/ rpath `/usr/local/lib`; to run
  a copy, retarget rpath to `@loader_path/lib` + ad-hoc re-sign.
- **Finish**: Siril `autostretch` on the GraXpert master — **not** a hand-rolled numpy stretch.

## What exists

### `Sources/NebulaCore/` — pure, tested core (SwiftPM library)
The single source of truth shared by engine, UI, and manifest. No Metal/Siril/UI deps.
- `Slider.swift` — 8 controls, labels, headline/advanced split, `actsOn` layer map.
- `LookState.swift` — the ~8 normalised floats; flat stable `Codable`; clamped.
- `Preset.swift` — Auto/Natural/Vivid/Deep (values from the mockup).
- `Profile.swift` — Galaxy/Broadband/Narrowband/Cluster + per-type initial look + header `guess()`.
- `EngineParams.swift` — pure slider→shader-param mapping (GHS D/SP, black point, saturation, star weight/size). **This is what Phase 1's Metal shaders consume.**
- `Target.swift` / `CaptureStats` — capture metadata + placard string.
- `Manifest.swift` — typed bake↔play IPC contract; fallback-aware; JSON round-trip.

### `prototype/` — Phase 0 bake (dev-only Python, never shipped)
Proves the Siril seam before it's ported to Swift (Phase 3). See `prototype/README.md`.
- `bake.py` — orchestrator + `--health-check` + `--from-master`.
- `nebula_proto/{headers,siril,ai,manifest}.py` — the four bake stages.
- `make_synthetic.py` — synthetic subs/master for plumbing tests.

### Tests — 19 passing
`Tests/NebulaCoreTests/` incl. `ManifestFixtureTests` which decodes a **real
Siril-produced** `manifest.json` fixture, proving Python↔Swift schema agreement.

## How to resume on a new machine

```bash
# Prereqs: Xcode 26+ / Swift 6+, Homebrew.
git clone <repo> && cd seestar

# 1. Core library + tests
swift test                       # if CodeSign error under Dropbox: --scratch-path /tmp/nebula-build

# 2. Phase 0 prototype
brew install siril
python3 -m venv prototype/.venv
prototype/.venv/bin/pip install -r prototype/requirements.txt
prototype/.venv/bin/python prototype/bake.py --health-check
# smoke test on synthetic data:
prototype/.venv/bin/python prototype/make_synthetic.py subs --out prototype/synthetic/M42_subs
prototype/.venv/bin/python prototype/bake.py prototype/synthetic/M42_subs --out prototype/out/M42
```

### Environment notes (this machine)
- macOS 27, arm64, Xcode 27 / Swift 6.4, Siril 1.4.4 (Homebrew).
- Repo lives under Dropbox/CloudStorage → `.build` codesigning is flaky; build
  with `--scratch-path` outside the synced folder.

## Hard-won Siril 1.4 gotchas (must reproduce in the Phase 3 Swift port)
1. **Set a fixed memory ceiling** — `set core.mem_mode=1` + `set core.mem_amount=<GB>`.
   Otherwise `host_statistics64()` can fail → 0 MB → stacking aborts *silently*.
2. **`-out=` can't express a space *or* a quote** (`convert`/`stack`). It takes a
   quote literally AND splits the value on spaces — so a path like
   `…/Nebula/M 83/_work/process` silently truncates at the space and `convert`
   writes nowhere → no master. Real target names ("M 83", "NGC 3372") always hit
   this. Fix: run Siril's `-out=` writes in a **space-free scratch dir**, then
   relocate the master into the (possibly spaced) work dir (`siril.py::run_stack`).
3. **`convert -out=<dir>` needs the dir to pre-exist.**
4. **Wipe the work dir** when input subs change — stale `cache/*.lst` star lists persist.
5. **`convert -debayer`** is mandatory for Seestar CFA subs (OSC), else mono.
6. **A Seestar `<Target>_sub` folder is not all lights.** It interleaves the FITS
   lights with on-board preview JPEGs *and* 148×264 `_thn.jpg` thumbnails.
   `convert light` ingests every supported file, so the sequence mixes full
   frames with thumbnails and registration/stacking silently yields no master.
   Fix: stage symlinks to **only `*.fit`/`*.fits`** into a clean dir and convert
   that (`siril.py::_stage_fits_lights`). (Synthetic subs never hit this — they're
   FITS-only — which is why it only surfaced on the first real bake.)

## Running the Metal engine (Phase 1)
```bash
swift build --product nebula-render --scratch-path /tmp/nebula-build
/tmp/nebula-build/debug/nebula-render <bake_out_dir> vivid out.png
# <bake_out_dir> = a bake dir with master/denoised/starless/stars .fits
```
Engine = `Sources/NebulaRender/`. Same shaders drive the live view + 16-bit export.

## Running the app (Phase 4)
```bash
swift build --product NebulaApp --scratch-path /tmp/nebula-build
/tmp/nebula-build/debug/NebulaApp            # home: Library grid / drop a "…_subs" folder
/tmp/nebula-build/debug/NebulaApp <folder>   # or open a subs folder / bake dir directly
```
**AI tools ("simple to install"):** the app **auto-discovers GraXpert** at the
standard `/Applications/GraXpert.app` (drag-install the 3.0.2 arm64 DMG —
`BakeRunner.toolEnvironment()`), so background-removal + denoise "just work" with
zero setup. Each AI step still falls back to a numerical stand-in if its tool is
absent, so the app always runs end-to-end. StarNet star-separation is not yet
auto-discovered — set `STARNET_BIN` / `STARNET_WEIGHTS` to enable it (until then
it falls back to `starless = master`, i.e. no independent star control). An
explicit env var always overrides discovery (dev override).
The app shells out to **`prototype/nebula-bake.sh`** (found via `NEBULA_BAKE` or by
walking up from the CWD to the repo root). That script wires the durable,
env-configured AI wrappers in **`prototype/aitools/`** (`gx_bg.sh`, `gx_denoise.sh`,
`starnet_fits.py`) into `bake.py`. Bakes are cached at `~/Library/Caches/Nebula/<target>`
so re-opening a target is instant. The bake driver lives in
`Sources/NebulaApp/BakeRunner.swift` — the one file Phase 3 replaces.

## Immediate next steps
1. **Phase 4 · the real app** — evolve `NebulaApp` from debug panel into the
   photo-app hero UI (import a `_subs` folder → bake → open on the finished
   image), watch mode, polish. Or finish Phase 1 tail (tiled export, exact GHS).
2. **Phase 3 · robust bake orchestrator** — port the Python bake seam to Swift
   (bundled/pinned Siril, typed manifest, fallbacks, health check, cancellation).
3. **Phase 2 · CoreML** — convert the in-hand GraXpert 1.0.1 / StarNet2 weights to
   CoreML to drop the subprocess tools.

## Blocked-on-assets checklist
- [x] Real Seestar `<Target>_subs/` FITS lights — using `/Volumes/Seestar/MyWorks/*_sub`
- [x] GraXpert + StarNet binaries (Phase 0 real AI) — GraXpert 3.0.2 DMG + StarNetPro's starnet2
- [ ] GraXpert/StarNet **ONNX weights** for in-process CoreML (Phase 2)
- [ ] Apple Developer ID for notarisation (Phase 5)

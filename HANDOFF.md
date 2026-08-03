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
| **3 · Robust bake orchestrator** | 🟢 **Native Swift bake, wired into the app.** `Sources/NebulaBake` (`SirilStage` + `Baker`) selects a single compatible filter group, uses two-pass/COG registration, attempts catalogue PCC with native neutralisation fallback, then runs **background-removal + denoise in-process** via NebulaAI. Star separation prefers the pluggable `NEBULA_STARNET` hook and otherwise uses a feathered classical star mask—never an empty layer. The v2 renderer uses the actual denoised layer, linked-luminance stretching, protected highlights, and subject-aware framing. Validated end-to-end on synthetic M42 and 126-frame mixed-session M83. |
| **4 · SwiftUI app** | 🟢 **Substantially done.** `NebulaApp` is now a photo-app, not a debug panel: **home** (a real **Library grid** of previously-developed targets — finished-look thumbnails rendered through the *same* GPU chain, disk-cached in each bake dir; drop / "＋ Develop" for new ones) → **baking** (live progress, streamed from the bake subprocess, per-target cached for instant re-open) → **editing** (the Phase-1 hero + 8 sliders + 16-bit Export) → the "Library" button returns to the grid. A folder that's already a bake dir opens straight into the editor. Remaining: watch mode (Phase 5), look-tuning polish. |
| **5 · Watch mode + DMG** | 🟢 **Fully self-contained app + watch mode done.** `scripts/build-app.sh` assembles `Nebula.app` with **everything bundled — no external tools**: release exe, `onnxruntime.framework`, the ONNX models (`Resources/Models`), and **Siril + its 93-dylib closure** (`Resources/siril`; dylibbundler + a static dep-closure loop for versioned-name stragglers + LC_RPATH dedupe). Verified: bundled Siril runs the full convert/register/stack under `env -i` (zero Homebrew). Discovery is bundle-aware (`Bundle.main` for Siril + models), so a shipped app needs no `brew install siril` and no GraXpert.app. **Watch mode** (`FolderWatcher`): a "Watch Folder…" toggle auto-develops new `_sub` folders in the background + posts a thumbnail notification. **DMG:** `scripts/build-dmg.sh` produces a 694 MB drag-to-Applications `Nebula.dmg` (verified: mounts, valid bundle). Only remaining: **notarisation** (Apple Developer ID) — the DMG is unsigned/ad-hoc, so first launch on another Mac is right-click → Open. |

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
auto-discovered — set `STARNET_BIN` / `STARNET_WEIGHTS` to enable it; otherwise
the native classical star-mask fallback provides independent star control. An
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
- [x] Real Seestar `<Target>_subs/` FITS lights — copied from the Seestar's MyWorks share
- [x] GraXpert + StarNet binaries (Phase 0 real AI) — GraXpert 3.0.2 DMG + StarNetPro's starnet2
- [ ] GraXpert/StarNet **ONNX weights** for in-process CoreML (Phase 2)
- [ ] Apple Developer ID for notarisation (Phase 5)

## 2026-07-12 · Star fix + open-source release prep

- **Big blurry stars fixed at the engine**: Star Size is now bidirectional —
  50 reproduces the captured profiles bit-exactly, below 50 erodes the real
  star flux in linear space (continuous greyscale erosion, radius 0→3 px), and
  above 50 blooms as before. Presets re-tuned (Auto 50 · Natural 45 · Vivid 55
  · Deep 35). Verified on M 8: halos pull in cleanly, dark lanes untouched, no
  ring artefacts even at Star Size 0.
- **Drizzle investigated and rejected**: 2× CFA drizzle (Siril 1.4
  `register -2pass` + `seqapplyreg -drizzle -scale=2` on non-debayered lights)
  gives an identical native-unit PSF on Seestar data (FWHM 4.04 vs 4.06 px on
  the same M 8 subs, measured with `findstar`) — the stack is seeing-limited,
  so drizzle just costs 4× pixels/AI time. Star sharpness work stays render-side.
- **Model licensing settled**: GraXpert's model endpoint is private (embedded
  S3 credentials; even Siril requires a GraXpert install), so the DMG no
  longer bundles bge/denoise (~700 MB → ~100 MB). First develop without models
  shows a one-time "install GraXpert" sheet; discovery also reads
  `~/Library/Application Support/Nebula/Models`. The `starnet2` Homebrew cask
  is currently broken upstream (checksum mismatch) — StarNet stays a
  `NEBULA_STARNET` user hook only.
- **Publish prep**: personal paths scrubbed, `Package.resolved` committed,
  SPDX `GPL-3.0-only` headers on all sources, README/NOTICES rewritten
  (accurate architecture; models downloaded-not-shipped), CONTRIBUTING.md,
  GitHub Actions CI (`.github/workflows/ci.yml`), `docs/RELEASING.md`,
  `scripts/gen-notices.sh` (bundled-dylib licence inventory at DMG build).

## 2026-08-03 · Output quality overhaul (pipeline v8)

The one-tap result was losing to the Seestar phone app: dim, muddy, desaturated.
Root-caused to compounding defects rather than one bug; every fix below was
verified on the real cached bakes (`~/Library/Caches/Nebula/`).

**Render (the big ones)**
- **The auto stretch never reached its target.** `mtfPivot`/`Baker.mtf` clamped
  the MTF midtone to ≥0.01, but linear deep-sky data needs ~1e-3 — so the base
  stretch silently under-delivered on every image. Floor is now 1e-4.
- **The stretch was derived from the wrong layer.** `AutoStretch` measured the
  raw master while the chain renders the *corrected* layer (PCC rescales
  channels, BGE re-pedestals them). On M 83 that put the black point above the
  corrected red pedestal and crushed **94 % of the red channel to zero** — the
  cyan sky the Warmth/shadow-neutralise sliders were invented to hide. Now
  measured on `corrected`, with a P0.5 clip guard; the raw master keeps its own
  stretch for the truthful "before".
- **`targetBG` 0.25 → 0.12.** 0.25 is Siril/PixInsight's *screen* convention for
  inspecting linear data; it compresses everything above it (M 83's nucleus
  arrived at 0.91 before a slider moved, so it could only render white).
  Finished images sit darker and the GHS above does the shaping. StarNet still
  gets 0.25 — it is trained on screen-stretched data.
- **`protectHighlights` ran three times** (0.82 shoulder, composed) so nothing
  could exceed **0.887** — no white star cores, no sparkle. Now applied once, as
  a hue-preserving overflow guard only.
- **Published GHS replaces the ad-hoc curve.** `asinh` + a 0.5-pivot logistic
  (which *darkened* essentially the whole astro image) are gone. `GHS.swift` is
  the closed form from ghsastro.co.uk / Siril `ght.c`, mirrored bit-for-bit in
  the shader and unit-tested for monotonicity, C1 continuity and endpoints
  across the whole slider range. Glow = D (log-domain, `expm1`), Contrast = the
  symmetry point, applied to the *above-sky* signal so the sky floor is
  invariant. Background is now an analytic black point with a `skyFloor` uniform
  the tone and colour stages anchor on.
- **Colour**: SCNR was a permanent 0.7 green kill; now a 0.25 average-neutral
  trim with lightness preserved (Siril's `rmgreen` convention), full strength
  only as Tint moves toward magenta. Shadow-neutralise and the chroma gate are
  anchored to the sky floor instead of fixed constants, Warmth's slope halved.
  Saturated star cores whiten (gated on linear "starness"), so cores go white
  while halos keep colour.

**Bake**
- **Star separation was eating the subject.** StarNet takes a galaxy nucleus for
  one big star (M 83 kept 22 % of its extended flux); the classical mask used a
  23 px opening that read nebular filaments as stars. Now: the star layer is
  unconditionally constrained to **compact** flux (morphological top-hat), then
  gated by an **extended-flux retention validator** (≥0.70) with a fallback
  ladder. M 83 now accepts StarNet at 0.94. Note the validator measures an
  *opening*, not a blur — a blur conserves a star's flux and so reads legitimate
  star removal in a rich field as subject loss (there is a regression test).
- **Colour order fixed**: background extraction now runs **before** PCC (Siril
  was warning "correct the image gradient first" on every single bake), on a
  header-preserving FITS copy so the plate solve keeps its seed. PCC normalises
  its largest gain to 1, so calibration is always a *net dimming* (M 42 lost
  58 % of its red flux); a scalar luminance renormalisation restores the scale
  and leaves the calibrated ratios alone. `protectSignal` — which left the
  subject 85 % uncalibrated on a neutralised sky, the textbook "muddy" signature
  — is gone. BGE now uses GraXpert's own 0.5 smoothing instead of 0.
- **Stacking**: `-filter-wfwhm=90%` was a *percentile* — it always binned the
  worst 10 % even on a clean night. Now `=3k` (sigma). `-weight=noise` replaces
  `-weight=wfwhm` (SNR-correct for mixed 10 s/30 s Seestar sessions), and
  `force_16bit=0` is set explicitly rather than inherited from the user's config.
- **Honest integration**: `STACKCNT`/`LIVETIME` are read from the master, so the
  UI reports what was *stacked* (M 83: 112 frames / 2380 s) rather than what was
  imported (126 / 2600) — the old figure over-claimed by 10–37 %.
- **`BakeRunner` never reused a cache** (it tested for the literal
  `"pipeline-v6"` while `pipelineVersion` was 7), so every open silently re-ran
  the entire bake. It now compares `Baker.pipelineVersion`, and refuses to delete
  layers it cannot rebuild when the source subs are offline.
- **StarNet had never actually run** on a real target: the discovered command
  left `{input}`/`{output}` unquoted through `bash -c`, and every cache dir has a
  space in it ("M 42"). It now runs in a space-free scratch dir from the binary's
  own directory (weights load relative to CWD).
- `erode`/`dilate` were O(pixels × radius) and dominated bake time; now O(pixels)
  via a monotonic deque (bit-exact against the naive form, tested).

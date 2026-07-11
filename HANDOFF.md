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
| **1 · Metal engine** | 🟢 **Substantially done.** `NebulaEngine` (shared) drives a headless CLI (`nebula-render`) and a live SwiftUI app (`NebulaApp`): 120fps `MTKView` loop, 8 sliders, presets, in-app Export, mipmapped faithful preview, before/after divider. Real star-layer stretch + native bilateral Denoise. ⬜ Remaining (low priority): tiled export (not needed at 1080×1920), exact published GHS. |
| **2 · Native AI (CoreML)** | ⬜ Blocked on model weights (ONNX from GraXpert 1.0.1 / StarNet2 in hand as reference) |
| **3 · Robust bake orchestrator** | ⬜ Not started |
| **4 · SwiftUI app** | ⬜ Not started |
| **5 · Watch mode + DMG** | ⬜ Blocked on Apple Developer ID |

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
2. **`-out=` rejects quotes** (`convert`/`stack`), unlike `cd`/`load`/`save`.
3. **`convert -out=<dir>` needs the dir to pre-exist.**
4. **Wipe the work dir** when input subs change — stale `cache/*.lst` star lists persist.
5. **`convert -debayer`** is mandatory for Seestar CFA subs (OSC), else mono.

## Running the Metal engine (Phase 1)
```bash
swift build --product nebula-render --scratch-path /tmp/nebula-build
/tmp/nebula-build/debug/nebula-render <bake_out_dir> vivid out.png
# <bake_out_dir> = a bake dir with master/denoised/starless/stars .fits
```
Engine = `Sources/NebulaRender/`. Same shaders will drive the live view + export.

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

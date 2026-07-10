# Nebula — build handoff

Snapshot of progress so work can resume on another machine. Full roadmap is in
[`README.md`](README.md); design of record is
[`seestar-autoprocess-design.md`](seestar-autoprocess-design.md); the executable
plan lives outside the repo at `~/.claude/plans/have-a-look-at-floating-narwhal.md`.

## Where things stand

| Phase | Status |
|-------|--------|
| **−1 · Scaffolding** | ✅ Done & tested |
| **0 · Prove the bake** | ✅ Skeleton done & proven end-to-end through real Siril. ⏳ Acceptance test (beat the JPEG) blocked on real subs + AI binaries. |
| **1 · Metal engine** | ⬜ Not started (next) |
| **2 · Native AI (CoreML)** | ⬜ Blocked on model weights |
| **3 · Robust bake orchestrator** | ⬜ Not started |
| **4 · SwiftUI app** | ⬜ Not started |
| **5 · Watch mode + DMG** | ⬜ Blocked on Apple Developer ID |

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

## Immediate next steps
1. **Phase 1 · Metal engine** — create the Xcode app target; implement the shader
   chain from design §5 (GHS in-shader) driven by `EngineParams`; `CVDisplayLink`
   render loop; tiled export == preview; debug slider panel. Can start against
   synthetic layers from the prototype (`prototype/out/M42/*.fits`).
2. **Close Phase 0 acceptance** — get a real `<Target>_subs/` folder + GraXpert/
   StarNet binaries; run `bake.py` with `--graxpert`/`--starnet`; hand-stretch and
   confirm it beats the Seestar JPEG.

## Blocked-on-assets checklist
- [ ] Real Seestar `<Target>_subs/` FITS lights (Phase 0 acceptance, Phase 1 real layers)
- [ ] GraXpert + StarNet ONNX weights / binaries (Phase 0 real AI, Phase 2 CoreML)
- [ ] Apple Developer ID for notarisation (Phase 5)

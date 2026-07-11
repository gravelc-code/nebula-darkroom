# Nebula

**Deep-sky, done for you.** A macOS app that turns a folder of Seestar sub-frames
into a finished, gorgeous deep-sky image with one tap — then lets anyone refine it
with a handful of plain-language sliders that respond instantly. It looks like a
photo app, not a telescope tool.

- **Platform:** macOS 14+, Apple Silicon
- **Interactive core:** native Metal · **AI steps:** in-process onnxruntime (GraXpert models) · **Classical DSP:** bundled headless Siril
- **UI:** SwiftUI · **Licence:** GPL-3.0 · **Install:** one DMG, drag to Applications, zero external dependencies (notarisation pending an Apple Developer ID)

**Working on this repo?** Start with [`CLAUDE.md`](CLAUDE.md) (module map, build/run,
invariants, gotchas). See [`seestar-autoprocess-design.md`](seestar-autoprocess-design.md)
for the full design, [`HANDOFF.md`](HANDOFF.md) for current status, and
[`seestar-ui-mockup.html`](seestar-ui-mockup.html) for the UI mockup.

## Architecture — bake once, play forever

```
IMPORT _subs folder
   │
   ▼  STAGE A · BAKE (headless, invisible, one time)
   Siril: register → stack → plate-solve → colour
   CoreML: background removal → denoise → star separation
   → emits 4 float layers:  master · denoised · starless · stars
   │
   ▼  STAGE B · PLAY (native Metal, ~120 Hz)
   shader chain on latest slider state → hero preview (== tiled export)
   │
   ▼  SwiftUI: hero image + 3 sliders (+ Advanced), presets, menubar watch
```

Stage A runs the science once and hands Stage B four floating-point layers. Stage B
never calls Siril or CoreML again while you drag sliders — it's pure GPU. That is why
it can be both faithful and instant.

## Repository layout

```
Nebula/                 App source (Xcode app target wraps these)
  App/                  SwiftUI entry, window, menubar scene
  Bake/                 Bake orchestrator, Siril wrapper, CoreML stages, manifest
  Engine/               Metal renderer, shader chain, texture residency
  UI/                   Hero view, sliders, presets, before/after, baking & menubar screens
  Model/                Profile, LookState (the ~8 floats), Target, Manifest
Sources/NebulaCore/     Pure, testable core logic (SwiftPM library)
Tests/NebulaCoreTests/  Unit tests + sample-subs fixtures
prototype/              Phase 0 Python prototyping (dev-only, never shipped)
Vendor/                 Bundled engine artifacts (git-ignored / LFS)
Package.swift           SwiftPM manifest for the core library + tests
```

The pure logic (the 8-float look model, slider↔engine mapping, manifest, profiles)
lives in the `NebulaCore` SwiftPM library so it builds and tests with `swift test`
independent of the Xcode app target and Metal.

## Build phases

| Phase | Deliverable |
|-------|-------------|
| −1 | Repo & project scaffolding |
| 0  | Prove the bake — Siril + AI → 4 layers, beats the Seestar JPEG |
| 1  | Metal engine — shader chain + display-link loop, export == preview |
| 2  | Native AI — bg/denoise/starnet in-process CoreML |
| 3  | Robust bake orchestrator — bundled Siril, fallbacks, health check |
| 4  | The app — SwiftUI hero UI, 3+5 sliders, presets, import |
| 5  | Watch mode + notarised DMG distribution |

## Development

```bash
# Core library + tests (no Xcode needed)
swift build
swift test

# Phase 0 prototyping prerequisites (dev-only, not shipped)
brew install siril cmake
```

> **Note:** this repo lives under a Dropbox/CloudStorage folder, whose file
> provider intermittently breaks codesigning of the `.build/*.xctest` bundle.
> If `swift test` fails with a `CodeSign ... failed` error, build to a path
> outside the synced folder, e.g.
> `swift test --scratch-path /tmp/nebula-build`.

## Licence

GPL-3.0 — see [`LICENSE`](LICENSE). Third-party attributions in [`NOTICES.md`](NOTICES.md).

# Nebula

**Deep-sky, done for you.** Nebula is a macOS app that turns a folder of
[Seestar](https://www.seestar.com) telescope sub-frames into a finished deep-sky
image with one tap — then lets you refine it with eight plain-language sliders
that respond instantly, at up to 120 fps. It looks and feels like a photo app,
not a telescope tool.

![Nebula editing a target](docs/screenshot.png)

- **Platform:** macOS 14+, Apple Silicon
- **UI:** SwiftUI · **Interactive core:** native Metal · **AI:** in-process onnxruntime · **Classical DSP:** bundled headless [Siril](https://siril.org)
- **Licence:** [GPL-3.0](LICENSE) · third-party attributions in [NOTICES.md](NOTICES.md)

## Install (users)

1. Download `Nebula.dmg` from the [latest release](../../releases/latest) and
   drag **Nebula** to Applications.
2. First launch: **right-click → Open** (the app is not yet notarised, so
   double-clicking shows a Gatekeeper warning the first time).
3. For the best results, install [GraXpert](https://graxpert.com) (free, open
   source) and open it once so it fetches its AI models — Nebula finds and uses
   them automatically for sky-gradient removal and denoising. Nebula develops
   images without them too, at reduced quality, and will offer this step the
   first time it needs it.
4. Drop a Seestar `…_sub` folder onto the window. That's it.

Everything else is self-contained: Siril and the Metal engine ship inside the
app — no Homebrew, no Python, no external tools.

## What it does

- **One-tap develop:** register → stack → colour-calibrate (Siril, bundled) →
  AI sky-gradient removal + denoise (GraXpert's open models via onnxruntime,
  in-process) → star separation → four adjustable image layers, cached per
  target so re-opening is instant.
- **Instant editing:** Glow, Colour, Stars, Contrast, Background, Detail,
  Star Size, Denoise. Star Size is bidirectional — below the midpoint it
  *tightens* bloated stars (morphological reduction on the real star flux),
  above it adds bloom. Presets (Auto/Natural/Vivid/Deep), before/after wipe,
  clipping view.
- **Preview == export.** The same GPU shader chain renders the live view and
  the 16-bit PNG export. What you see is exactly what you save. Optional AI 2×
  enlargement (Real-ESRGAN) on export.
- **Library & watch mode:** a grid of everything you've developed; point watch
  mode at your Seestar folder and new targets develop themselves and notify you.

## Architecture — bake once, play forever

```
IMPORT  <Target>_sub folder
   │
   ▼  STAGE A · BAKE  (headless, cached, once per target)
   Siril: select compatible lights → register → stack → colour calibration
   onnxruntime (in-process): background extraction → denoise
   star separation (neural via NEBULA_STARNET hook, or classical fallback)
   → five float FITS layers: master · corrected · denoised · starless · stars
   → manifest.json (typed bake↔play contract, saved look, stage outcomes)
   │
   ▼  STAGE B · PLAY  (native Metal, ~120 Hz)
   shader chain over the resident layers → live preview == 16-bit export
```

Stage A runs the science once. Stage B is pure GPU — dragging sliders never
re-runs Siril or the AI, which is why it can be both faithful and instant.
Every bake stage has a graceful fallback (recorded in the manifest), so the
user always lands on an image.

## Repository layout

| Path | What it is |
|------|------------|
| `Sources/NebulaCore` | Pure, tested core: `LookState` (8 floats), sliders/presets/profiles, `EngineParams` (slider→shader mapping), `Manifest` |
| `Sources/NebulaEngine` | Metal engine: `ChainRenderer`, shaders, float-FITS read/write |
| `Sources/NebulaAI` | In-process AI via onnxruntime: denoise, background extraction, super-resolution |
| `Sources/NebulaBake` | Native bake orchestrator: Siril stage, AI stages, star separation, fallbacks |
| `Sources/NebulaApp` | The SwiftUI app: Library, baking progress, editor, watch mode |
| `Sources/NebulaRender` | `nebula-render` — headless CLI export (same chain, no UI) |
| `Sources/NebulaBakeCLI` | `nebula-bake-native` — run a bake from the CLI |
| `Sources/NebulaAICLI` | `nebula-ai` — FITS-in/out denoise/bg CLI |
| `prototype/` | Phase-0 Python reference (dev-only, never shipped) |

Deeper docs: [`CLAUDE.md`](CLAUDE.md) (contributor quick-start: build/run,
invariants, gotchas), [`seestar-autoprocess-design.md`](seestar-autoprocess-design.md)
(design of record), [`HANDOFF.md`](HANDOFF.md) (status log).

## Build from source (developers)

Prerequisites: Xcode 16+ (full Xcode — the Command Line Tools alone lack the
SwiftUI macros), and for app packaging `brew install siril dylibbundler`.

```bash
# Build + test (use an out-of-tree scratch path; see note below)
scripts/swift-xcode.sh build --scratch-path /tmp/nebula-build
scripts/swift-xcode.sh test  --scratch-path /tmp/nebula-build

# Run the app
scripts/swift-xcode.sh build --product NebulaApp --scratch-path /tmp/nebula-build
/tmp/nebula-build/debug/NebulaApp                # or: NebulaApp <subs folder>

# Package a self-contained app + DMG (bundles Siril + onnxruntime)
scripts/build-app.sh      # → build/Nebula.app
scripts/build-dmg.sh      # → build/Nebula.dmg
```

> **Note:** if this repo lives under a synced folder (Dropbox/iCloud), the file
> provider can break codesigning inside `.build` — always pass a scratch path
> outside the synced folder, as above.

AI models for development are discovered from GraXpert's cache
(`~/Library/Application Support/GraXpert/…`) or `~/Library/Application
Support/Nebula/Models/`, or via `NEBULA_BGE_MODEL` / `NEBULA_DENOISE_MODEL`.
An external neural star remover (e.g. StarNet) can be plugged in with
`NEBULA_STARNET='cmd {input} {output}'` (FITS in/out); without one, a classical
star mask keeps the star controls functional.

## Licensing & models

Nebula is GPL-3.0. It bundles Siril (GPL-3.0) and onnxruntime (MIT), plus a
Real-ESRGAN x2 model (BSD-3-Clause) converted reproducibly by
`scripts/convert-realesrgan-x2.py`. GraXpert's AI models are **not**
redistributed — Nebula uses the copies GraXpert itself installs. StarNet is
**not** bundled (its licence is non-commercial); it remains a user-supplied
hook. Full inventory: [NOTICES.md](NOTICES.md).

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

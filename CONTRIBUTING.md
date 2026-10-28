# Contributing to Nebula

Thanks for helping! Nebula is GPL-3.0; by submitting a contribution you agree
to license it under GPL-3.0 too.

## Getting started

1. Read [`CLAUDE.md`](CLAUDE.md) first — it's the contributor quick-start:
   module map, build/run/test commands, and the gotchas that cost real time.
   [`seestar-autoprocess-design.md`](seestar-autoprocess-design.md) is the
   design of record.
2. Prerequisites: an Apple Silicon Mac on macOS 14+ (the packaged app itself
   needs macOS 26+, the OS its bundled Siril is built for), full Xcode 16+
   (Swift 6; the Command Line Tools alone can't build SwiftUI macros), and
   `brew install siril dylibbundler`.
3. Build and test with an out-of-tree scratch path:

   ```bash
   scripts/swift-xcode.sh build --scratch-path /tmp/nebula-build
   scripts/swift-xcode.sh test  --scratch-path /tmp/nebula-build
   ```

## Invariants — PRs must not break these

- **Preview == export.** Every look change goes through the shared shader
  chain (`ChainRenderer.encodeChain`), never a one-off path.
- **`LookState` is 11 normalized floats** and the single source of truth; the
  slider→shader mapping lives only in `EngineParams`. There are no presets:
  targets open on `LookState.default`, and Reset returns to it.
- **Never a dead end.** Every bake stage falls back to a good-enough result
  and records the outcome in the manifest; the user always lands on an image.
- **No jargon in UI strings** (there's a test): users see Glow, Saturation,
  Vibrance, Tint, Warmth, Stars, Contrast, Background, Detail, Star Size,
  Denoise — never "GHS"/"SPCC"/"starless".
- **No Python in the shipping build**; `prototype/` is dev-only reference.
- **No redistribution of GraXpert models or StarNet** — see `NOTICES.md`.

## Pull requests

- Keep changes focused; include or update tests (`Tests/Nebula*Tests`) for
  engine/bake/core/app behaviour you touch.
- `scripts/swift-xcode.sh test` must pass; CI runs the same on macOS runners.
- For visual changes, include before/after renders (`nebula-render` makes this
  easy: `nebula-render <bakeDir> default out.png [slider=value …]`; `neutral`
  renders the truthful "before").
- Packaging changes: run `scripts/build-app.sh` and `scripts/build-dmg.sh`
  locally — both verify the bundle's dependency closure and every signature.
- Bugs and ideas: open a GitHub issue with your macOS/hardware and, for bake
  issues, the `manifest.json` + logs from the bake cache dir
  (`~/Library/Caches/Nebula/<target>/`).

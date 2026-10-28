# Seestar Auto-Processor — Technical Design

A macOS app that turns a folder of Seestar sub-frames into a finished, gorgeous deep-sky image with **one tap**, then lets anyone refine it with a handful of plain-language sliders that respond instantly. It looks like a photo app, not a telescope tool.

**Platform:** macOS 26+, Apple Silicon · **Interactive core:** native Metal · **AI steps:** in-process onnxruntime (CPU execution provider) · **Classical DSP:** Siril, bundled & headless (invisible) · **UI:** SwiftUI · **Licence:** GPL-3.0, free & open source · **Install:** one signed DMG, drag to Applications, zero external dependencies.

---

## 0. Two truths that shape everything

1. **"Incredible" is capped by capture, not software.** Stacking and gradient removal clean up what you shot; they can't add signal. Integration time, target altitude, and sky darkness set the ceiling. The sliders get you *to* the ceiling — surface that in the UI, never imply the software raises it.
2. **You beat Siril/GraXpert's UX by hiding them, not replacing them.** Their engines are excellent; their interfaces are the problem. Robustness comes from making the engines invisible and the seam bulletproof — *not* from reimplementing astrometry, which is where projects become fragile and unfinished.

---

## 1. The robustness thesis: what's native vs wrapped, and why

Three tiers. The rule: **own the surface and the real-time layer; wrap the mature science; never expose a third-party UI.**

| Layer | Implementation | Why |
|-------|----------------|-----|
| **Interactive image ops** (all sliders) | **Native Metal** — textures on GPU, one shader per op | This is where "amazing + responsive" is won. No dependency belongs here. |
| **AI steps** (gradient removal, denoise) | **onnxruntime in-process** (CPU EP) running GraXpert's ONNX models, read from the user's GraXpert install | Deletes `GraXpert.app` as a runtime dependency; keeps only the proven models. Star separation uses a user-installed StarNet if present, else a classical star mask. |
| **Classical DSP** (register, stack, reject, plate-solve, colour-calibrate) | **Siril, bundled + headless**, version-pinned inside the app | Rewriting astrometry-grade solving is where robustness goes to die. Wrapping it *is* the robust choice. |

**Reimplementing the classical DSP would make the app *less* robust, not more.** Plate-solving needs star catalogues and blind-solve search; spectrophotometric colour calibration needs catalogue photometry. These are solved problems in Siril. Wrapping a pinned, invisible binary is lower-risk than owning that code.

### What makes a wrap robust instead of "stitched together"

- **Bundled & pinned.** Siril ships *inside* the `.app`. No PATH, no user install, no "please download GraXpert." One version, tested.
- **File + typed manifest IPC, never scraped stdout.** Stages read/write FITS and a structured `manifest.json`. Nothing depends on parsing human-readable log text.
- **Typed errors with silent fallbacks.** Every bake stage can fail into a good-enough path (plate-solve fails → native white-balance; SPCC fails → background-neutralise). The non-expert **never reaches a dead end** — they always get a beautiful image.
- **Health check on launch + smoke test.** Verify the bundled engine runs on 5 subs before the user's first real job.
- **Cancellable, timeouted, off-main-thread.** The bake never blocks or freezes the UI; it can always be cancelled cleanly.
- **Deterministic & idempotent.** Same inputs + params → same output; re-running is safe and cached.

---

## 2. Architecture: Bake once, play forever

```
   IMPORT a _subs folder
        │
        ▼
┌──────────────────────────────────────────────────────────┐
│ STAGE A — BAKE  (headless, invisible, ~minutes, one time) │
│  Siril (bundled)         onnxruntime (in-process)         │
│  register → stack →      background removal → denoise →    │
│  plate-solve → colour    star separation                  │
│        └──────────────► emits 5 float layers (GPU-ready): │
│   master · corrected · denoised · starless · stars        │
└───────────────────────────────┬──────────────────────────┘
                                 │  layers uploaded to MTLTextures, resident
                                 ▼
┌──────────────────────────────────────────────────────────┐
│ STAGE B — PLAY  (native Metal, ~real-time, 120 Hz)        │
│  display-link render loop → shader chain on latest slider │
│  state → hero preview.  Same shaders, tiled, for export.  │
└───────────────────────────────┬──────────────────────────┘
                                 ▼
                 SwiftUI: hero image + 6 sliders (+ Refine)
                 menubar watch: subs land → baked → notify
```

Stage A runs the science once and hands Stage B five floating-point layers. Stage B never calls Siril or the AI again while you drag sliders — it's pure GPU. That's the entire reason it can be both faithful and instant.

---

## 3. Seestar input contract

- **Advanced Settings → "Save each frame in enhancing"** → per-target `<Target>_subs/` of 10 s FITS lights + the on-board stack.
- Retrieve via USB or the MyWorks share. **Lights only** (no darks/flats/bias). Headers carry RA/Dec, exposure, temp, filter → grouping, solve seeding, profile auto-select.
- **Alt-az ⇒ field rotation** → rotation-tolerant registration + autocrop of ragged edges.
- **Broadband (clear/LP) vs duo-band/narrowband** → different colour + default look.
- **Mosaic/framing mode** (spiral panels) → separate path, deferred.

---

## 4. Stage A — the bake (invisible)

Linear-domain; output is **not** stretched. Emits five 32-bit float layers.

| # | Step | Engine | Note |
|---|------|--------|------|
| 1 | Ingest & group | Swift/Python | headers → groups, profile guess |
| 2 | Register (+ inline best-frame select) | Siril | FWHM/roundness filtering folded in — no separate QC stage |
| 3 | Stack | Siril | `stack r_light rej w 3 3` — Winsorized clipping kills planes/satellites/hot pixels |
| 4 | Plate-solve | Siril | seeded from header RA/Dec; blind-solve fallback |
| 5 | Colour-calibrate | Siril | `spcc` → fallback `pcc` → fallback native white-balance |
| 6 | Background removal | **onnxruntime** | GraXpert bg model in-process; no sample points needed → `corrected` |
| 7 | Denoise | **onnxruntime** | kept as a **separate layer**, never baked in destructively |
| 8 | Star separation | StarNet (user-installed) / Swift | → `starless` + `stars`; classical star mask when StarNet is absent |
| 9 | Emit layers | Swift | 5 float FITS + `manifest.json`, uploaded to Metal textures |

**Pivotal choices:** cull folds into Siril's frame selection (no experimental Python API in the critical path); denoise is preserved as its own layer so strength becomes a *slider*, not a bake-time commitment; star separation is what lets nebulosity stretch hard without bloating stars.

> **Simplification for robustness:** for the automatic path you can skip plate-solving/SPCC entirely and use a native background-neutralise + star-field white-balance for colour. It's "good enough to look great" for non-experts, removes a failure mode, and you offer accurate SPCC only as an optional "Precise colour" toggle.

---

## 5. Stage B — the native Metal engine (responsiveness core)

**Residency:** on bake completion, the five layers upload to `MTLTexture`s (RGBA16F) and *stay* on the GPU. A downsampled preview texture and the full-res texture both live there.

**Render loop:** a `CVDisplayLink`/`MTKView` loop renders the latest slider state every vsync (120 Hz on ProMotion). Slider input only mutates a small uniforms struct; it never enqueues work or backs up a queue — the loop always draws *current* params, so dragging feels weightless with zero lag or stale frames.

**The chain = a sequence of shaders**, each op one compute/fragment pass over the starless texture, then a recombine with stars:

```
lerp(master, denoised, denoise)      // denoise as a blend, not a switch
→ blackPoint(background)
→ ghs(glow, contrast)                // generalised hyperbolic stretch, in a shader
→ localContrast(detail)              // unsharp on starless only
→ colour(saturation, vibrance, tint, warmth)  // background stays neutral
─ stars: ghs(starStretch) · scaled by starWeight
→ screen(starless, stars)            // 1-(1-a)(1-b): adds stars without clipping cores
```

- **GHS in-shader:** implement the published closed-form generalised hyperbolic stretch as a Metal function so the look is identical in preview and export.
- **Export:** the *same* shaders run on the full-res texture, **tiled** to stay within memory; no separate "render path" to drift out of sync. Preview truly equals export.
- **Before/after:** free — just draw the master vs the chained result split by a draggable divider, both already on the GPU.
- **Precision:** RGBA32F through the chain to a 16-bit PNG export, which needs no dither. The 8-bit live preview gets TPDF dither in the display blit only, so it shows no banding the export doesn't have.

This is why "all-Metal" is the right call *here specifically*: the interactive layer has no legitimate dependency, and owning it end-to-end is what delivers the feel.

---

## 6. UX — a photo app, not a telescope tool

**Principle: one hero image, one tap to great, depth only if wanted.**

- **Import → instant Auto.** Drop (or auto-ingest) a target; the bake runs with a progress shimmer *over a live-updating preview*, and lands on a finished, profile-tuned image. Zero decisions required. For most people, this is the whole app.
- **Six headline sliders, plain language:** **Glow** (faint-detail brightness), **Saturation**, **Vibrance**, **Tint**, **Warmth** (colour), **Stars** (presence). That's the front screen.
- **"Refine" reveals five more:** Contrast, Background, Detail, Star Size, Denoise. Same instant response.
- **No jargon, anywhere.** Never "GHS D," "SPCC," "sigma clipping," "starless." The user only sees the eleven slider names.
- **Image-first aesthetic:** full-bleed image on near-black, chrome recedes, controls float and auto-hide. The photo is the interface.
- **No presets** (dropped after the slider redesign): every target opens on one developed look (`LookState.default`), Reset returns to it, and the before/after wipe shows the truthful `LookState.neutral`.
- **Watch mode (menubar):** point it at the Seestar folder once; thereafter targets bake automatically and notify with a thumbnail. Tap → opens on the finished image, sliders ready.
- **Never a dead end:** any engine failure falls back silently to a good result. The user sees a beautiful image or a gentle "still gathering light," never an error dialog or a broken state.

### Slider → engine mapping (internal)

| User label | Internal | Acts on |
|------------|----------|---------|
| Glow | GHS D (log-domain, `expm1`) | starless |
| Contrast | GHS SP (symmetry point) | starless |
| Background | correction blend + black point (sets `skyFloor`); below 60 also fades out the finishing steps (SCNR floor, core whitening, shadow neutralisation) toward the truthful master | starless |
| Saturation | uniform chroma scale | starless |
| Vibrance | chroma-protected boost | starless |
| Tint | SCNR green balance | starless |
| Warmth | red↔blue white-balance trim | starless |
| Detail | multi-scale local contrast | starless |
| Stars | star weight | recombine |
| Star Size | flux erosion below 50 · GHS D on stars above | stars |
| Denoise | master↔denoised blend + bilateral | master |

The whole look is 11 floats → saved in the manifest, shareable, reproducible.

**The GHS is the published closed form** (ghsastro.co.uk; Siril `ght.c`),
hyperbolic branch with LP = 0, mirrored on the CPU as `NebulaCore/GHS.swift` so
the shader's curve is unit-testable. It is applied to the *above-sky* signal, so
the sky floor is invariant under Glow and Contrast by construction.

**Base stretch:** a per-channel MTF autostretch (shadow = median − 2.8·MADN,
Siril's constant) measured on the **corrected** layer — the one actually
rendered — landing the sky at 0.12. That is deliberately below Siril's 0.25,
which is a *screen* convention: pulling the sky that high compresses everything
above it, so a bright core can only ever render white. The GHS above does the
tone shaping.

---

## 7. Profiles = bake settings + a starting look

Auto-selected from filter + object type; user-overridable in one tap. Sets bake parameters and the initial 11-float slider state (see §6). Ship: **Galaxy**, **Broadband Nebula**, **Narrowband/Duo-band**, **Star Cluster**.

---

## 8. Build phases

Order de-risks the two hard, novel parts (the Metal engine and the robust bake seam) before UI polish. *This is the original plan; what shipped (onnxruntime rather than CoreML, 11 sliders, no presets, five layers) is logged in `HANDOFF.md`.*

| Phase | Deliverable | Acceptance |
|-------|-------------|-----------|
| **0 · Prove the bake** | Bundled headless Siril + subprocess GraXpert/StarNet on one target → 4 layers | Hand-stretched result beats the Seestar JPEG on the same subs |
| **1 · Metal engine** | The shader chain + display-link loop, driven by a debug slider panel on baked layers | 8 sliders re-render at 120 Hz; export == preview, tiled full-res |
| **2 · Native AI** | Move bg/denoise/starnet to in-process CoreML; drop the GraXpert/StarNet apps | Identical layers, no external AI app, licensing cleared |
| **3 · Robust bake orchestrator** | Bundled/pinned Siril, typed manifest, fallbacks, health check, cancellation | Kill/curveball tests never dead-end; always a good image |
| **4 · The app** | SwiftUI hero UI, 3+5 sliders, presets, import | Non-expert → gorgeous result, one tap, no jargon |
| **5 · Watch + polish** | Menubar auto-ingest, notifications, multi-night, mosaic | Subs land → baked & ready unattended |

---

## 8a. Licence & distribution (free, open source, 1-click)

**The app is GPL-3.0.** Going FOSS *resolves* the earlier licensing gate for Siril: it (GPLv3) and its GPL/LGPL/permissive Homebrew libraries can be bundled because the whole app inherits a compatible copyleft licence. The obligations are attribution + licence texts (shipped in the app and DMG) and the Corresponding Source (attached to every release by `scripts/fetch-sources.sh`; see NOTICES.md). **GraXpert's model weights and StarNet are never bundled or downloaded:** the weights' redistribution terms are unstated (GraXpert fetches them with private credentials) and StarNet is proprietary — the app reads a user's own GraXpert install and uses StarNet only if the user installed it.

**Ship with zero external dependencies.** The user installs *one* thing.

- **No Python in the shipping build.** Swift orchestrates the bundled Siril binary directly and runs the AI models through onnxruntime, in-process. Python stays purely a dev/prototyping convenience (Phase 0), never something the user touches. This is the single biggest robustness and simplicity win — no conda, no pip, no version drift on the user's machine.
- **Everything lives inside the `.app` bundle:** the pinned Siril binary + its dylibs (`Contents/Resources/siril`, `…/siril/libs`), the Real-ESRGAN enlargement model (`Contents/Resources/Models`), and every licence text (`Contents/Resources/Licenses`). No plate-solving star index is bundled: catalogue colour calibration is attempted and falls back to native white balance. One folder, self-contained, relocatable.
- **Distribution = a single signed, notarised DMG** on GitHub Releases. The user drags the icon to Applications and opens it. That's the whole install. A Homebrew Cask (`brew install --cask nebula`) is a one-line alternative for terminal users, pointing at the same DMG.
- **First launch:** a friendly one-screen check verifies the bundled engine runs (5-sub smoke test) and, *only if* you chose not to bundle the larger star catalogues, downloads them once with a progress screen. Prefer bundling so the app works fully offline on first run — a bigger download beats a fragile first-run network step.
- **Notarisation reality:** Gatekeeper requires an Apple Developer ID ($99/yr) to notarise, so the app opens with a normal double-click instead of a System Settings → Privacy & Security → "Open Anyway" dance (right-click → Open no longer bypasses Gatekeeper on macOS 15+). Status: builds are Developer ID signed; notarisation is the remaining step (`scripts/notarize.sh`). For a free app this small cost buys the "trivially simple" open experience; without it, users hit a scary warning. Budget for it.
- **Updates:** Sparkle (the standard open-source macOS updater) for silent in-app updates, feed hosted on GitHub Releases.

**Net user experience:** download one file → drag to Applications → open → point it at the Seestar folder once → finished images appear. No terminal, no Python, no GraXpert, no Siril install, ever.

---

## 9. Risks & mitigations

- **Bundle size.** Siril + dylibs + the enlargement model make a ~130 MB DMG (the GraXpert models, ~700 MB, are not bundled). Acceptable for the zero-dependency payoff; trim the star index to the Seestar's fixed focal length, and lazy-download only truly optional data.
- **Keeping the bundled Siril working across macOS releases** → pin and test one version per app release; the smoke test on launch catches breakage before the user does.
- **Scope creep into reimplementing DSP** → hold the line: native = interactive + AI models only; classical DSP stays wrapped. Revisit only with measured cause.
- **CoreML model conversion effort** (ONNX→CoreML, or onnxruntime CoreML EP) → *resolved in Phase 2:* coremltools can't ingest these ONNX models and the CoreML EP fails/slows on them, so onnxruntime's CPU EP runs them (bit-exact with GraXpert).
- **Overcooked look** → star separation + starless-only denoise/detail make it structurally hard; conservative defaults; Denoise/Detail dial *down*.
- **Plate-solve/SPCC fragility** → native colour fallback (§4) means colour never blocks a result.
- **Full-res export memory** → tiled shader passes; stream, don't hold everything.
- **"Incredible" expectation** → UI surfaces integration time / altitude so users attribute limits to capture, not the app.

---

## 10. Open decisions

1. **Ship SPCC at all, or native colour only?** Simpler + more robust to start native; add "Precise colour" later.
2. **StarNet vs GraXpert stellar model** for separation — pick by quality on *your* Seestar subs.
3. **Layer interchange format** GPU-side: FITS vs EXR vs raw float — pick for fast Metal upload.
4. **Bundle vs first-run-download the star index** — bundle for offline reliability unless size forces the split.

*Settled: GPL-3.0, Developer-ID DMG (not App Store — bundling GPL binaries + arm's-length process execution fits direct distribution far better than App Store sandbox rules).*

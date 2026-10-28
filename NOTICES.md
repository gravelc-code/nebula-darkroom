# Third-party notices

Nebula is licensed under **GPL-3.0** (see `LICENSE`). It bundles, or
interoperates with, the third-party components below.

**Licence texts ship with every copy:** inside the app at
`Nebula.app/Contents/Resources/Licenses/`, and in the `Licenses` folder at the
root of the DMG — Nebula's GPL-3.0 text, this file, `NOTICES-bundled.txt`
(every bundled Siril binary and library → Homebrew formula, exact version,
licence, source archive) and each component's own licence files.

## Bundled in the app

| Component | Role | Licence | Notes |
|-----------|------|---------|-------|
| **[Siril](https://siril.org)** | Classical DSP: light selection, register, stack, reject, plate-solve, colour calibration | GPL-3.0-or-later | Headless binary in `Contents/Resources/siril`, run as a separate process. One pinned version per release (recorded in `NOTICES-bundled.txt`). |
| **Siril's dependency closure** (~93 Homebrew libraries: FFmpeg, GSL, FFTW, GLib, cairo, OpenCV, CFITSIO, …) | Libraries Siril loads | Mixed: GPL-2.0/3.0, LGPL-2.1/3.0, MIT, BSD, Apache-2.0, … | Unmodified Homebrew builds in `Contents/Resources/siril/libs`; only their install names/rpaths are rewritten and they are re-signed (`scripts/build-app.sh`). Per-file formula, version and licence in `NOTICES-bundled.txt`. |
| **[onnxruntime](https://github.com/microsoft/onnxruntime)** | In-process AI inference (CPU execution provider) | MIT (+ its third-party notices) | Statically linked into the Nebula executable from the official Swift package, pinned in `Package.resolved` (1.19.2). Texts: `Licenses/onnxruntime/`. |
| **[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) x2plus** | Optional AI enlargement (in-app Enhance, 2× export) | BSD-3-Clause | Official v0.2.1 weights (`RealESRGAN_x2plus.pth`, SHA-256 `49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb`) converted reproducibly to ONNX by `scripts/convert-realesrgan-x2.py` (ONNX SHA-256 `38d4a9e1fe8afbc400660420e22e178009eb31adbba0d9b18f1d08f7ebc65261`; `build-app.sh` refuses any other file). |

## Used but never redistributed

| Component | Role | Licence | How Nebula obtains it |
|-----------|------|---------|-----------------------|
| **[GraXpert](https://graxpert.com) AI models** (background extraction, denoise) | Neural sky-gradient removal and denoising during the bake | GraXpert is GPL-3.0; the model weights' redistribution terms are not separately stated, so Nebula neither ships nor downloads them | The app guides the user to install GraXpert (free) once; GraXpert downloads its models to `~/Library/Application Support/GraXpert/…` and Nebula reads them there (also `~/Library/Application Support/Nebula/Models`). Overridable via `NEBULA_BGE_MODEL` / `NEBULA_DENOISE_MODEL`. |
| **StarNet** (optional) | Neural star ↔ nebulosity separation | Proprietary/non-commercial — incompatible with GPL redistribution, never bundled or downloaded | Used only if the user installs it: a `starnet2` CLI is auto-discovered at `/usr/local/bin`, `/opt/homebrew/bin` or `/usr/bin`, or any FITS-in/out command can be set with `NEBULA_STARNET='cmd {input} {output}'`. Without it, Nebula's own classical star mask is used. |

## Source code for the bundled binaries

Nebula is distributed as object code (the DMG). Under GPL-3.0 §6(d) and
LGPL-2.1 §6, the Corresponding Source is offered **from the same place, at no
charge**:

- **Nebula itself:** <https://github.com/gravelc-code/nebula-darkroom> — the
  `v<version>` tag of each release, and the source archives GitHub attaches to
  that release. This includes `scripts/build-app.sh`, which shows exactly how
  the bundled binaries were copied, re-linked and signed.
- **Siril and every bundled library:** each GitHub release that carries
  `Nebula.dmg` also carries `Nebula-<version>-third-party-sources.tar`, made by
  `scripts/fetch-sources.sh`: for every formula in `NOTICES-bundled.txt`, the
  exact upstream source archive (SHA-256 verified against what Homebrew built),
  every patch Homebrew applied, and the Homebrew formula used to build it.

**Written offer.** If that archive is ever missing or incomplete, then for at
least three years after we last distribute a given release, anyone may request
the complete Corresponding Source for the third-party binaries in that release
by opening an issue at
<https://github.com/gravelc-code/nebula-darkroom/issues>. We will provide it
at no charge (or, for a physical medium, for no more than the cost of
performing the distribution).

The LGPL libraries are separate shared libraries in
`Contents/Resources/siril/libs`; you may replace them with modified versions
(re-sign the app afterwards, e.g. `codesign --force --deep --sign - Nebula.app`).

## Development-only (never shipped)

| Component | Role | Licence |
|-----------|------|---------|
| Python 3 + `prototype/` scripts | Phase-0 bake prototyping and AI-parity validation | PSF / per-package |
| PyTorch (used by `scripts/convert-realesrgan-x2.py`) | One-time reproducible model conversion | BSD-style |

> **Per release** (`docs/RELEASING.md`): `build-app.sh` regenerates
> `NOTICES-bundled.txt` and the licence folder, and refuses a release build it
> can't fully attribute or whose `superres.onnx` doesn't match the SHA-256
> above. Run `scripts/fetch-sources.sh` and attach its tarball to the release;
> record the bundled Siril version in the release notes.

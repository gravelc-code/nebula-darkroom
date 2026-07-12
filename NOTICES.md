# Third-party notices

Nebula is licensed under **GPL-3.0** (see `LICENSE`). It bundles, downloads, or
interoperates with the following third-party components. Attribution and source
availability are provided here; a per-dylib licence inventory for the bundled
Siril closure is generated at DMG build time (`Contents/Resources/NOTICES-bundled.txt`).

## Bundled in the app

| Component | Role | Licence | Notes |
|-----------|------|---------|-------|
| **[Siril](https://siril.org)** | Classical DSP: light selection, register, stack, reject, plate-solve, colour calibration | GPL-3.0 | Headless binary + its Homebrew dylib closure in `Contents/Resources/siril`, bundled by `scripts/build-app.sh`. One pinned version per app release. |
| **[onnxruntime](https://github.com/microsoft/onnxruntime)** | In-process AI inference (CPU execution provider) | MIT | `onnxruntime.framework` via the official Swift package, pinned in `Package.resolved` (1.19.2). |
| **[Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) x2plus** | Optional AI enlargement (in-app Enhance, 2× export) | BSD-3-Clause | Official v0.2.1 weights (`RealESRGAN_x2plus.pth`, SHA-256 `49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb`) converted reproducibly to ONNX by `scripts/convert-realesrgan-x2.py` (ONNX SHA-256 `38d4a9e1fe8afbc400660420e22e178009eb31adbba0d9b18f1d08f7ebc65261`). |

## Used but never redistributed

| Component | Role | Licence | How Nebula obtains it |
|-----------|------|---------|-----------------------|
| **[GraXpert](https://graxpert.com) AI models** (background extraction, denoise) | Neural sky-gradient removal and denoising during the bake | GraXpert is GPL-3.0; the model weights' redistribution terms are not separately stated, so Nebula does not ship them | The app guides the user to install GraXpert (free) once; GraXpert downloads its models to `~/Library/Application Support/GraXpert/…` and Nebula reads them there. Overridable via `NEBULA_BGE_MODEL` / `NEBULA_DENOISE_MODEL`. |
| **StarNet** (optional) | Neural star ↔ nebulosity separation | Non-commercial licence — incompatible with GPL redistribution, never bundled | User-supplied external command via `NEBULA_STARNET='cmd {input} {output}'` (FITS in/out). Without it, Nebula's own classical star mask is used. |

## Development-only (never shipped)

| Component | Role | Licence |
|-----------|------|---------|
| Python 3 + `prototype/` scripts | Phase-0 bake prototyping and AI-parity validation | PSF / per-package |
| PyTorch (used by `scripts/convert-realesrgan-x2.py`) | One-time reproducible model conversion | BSD-style |

> **Per-release checklist:** record the bundled Siril version in the release
> notes; regenerate the dylib licence inventory (`scripts/build-app.sh` does
> this automatically); verify the Real-ESRGAN ONNX SHA-256 above matches the
> bundled `superres.onnx`.

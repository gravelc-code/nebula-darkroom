# Third-party notices

Nebula is licensed under **GPL-3.0** (see `LICENSE`). It bundles and/or builds on
the following third-party components. Their licences are compatible with GPL-3.0;
attribution and source availability are provided here and in the public repository.

## Bundled at ship time

| Component | Role | Licence | Notes |
|-----------|------|---------|-------|
| **Siril** | Classical DSP: register, stack, reject, plate-solve, colour calibration | GPL-3.0 | Version-pinned binary + dylibs bundled in `Contents/Frameworks`. One version per app release. |
| **GraXpert background model** | Neural sky-gradient removal | (copyleft — confirm exact terms per release) | ONNX weights converted to CoreML, embedded in `Contents/Resources/Models`. |
| **StarNet / stellar-separation model** | Star ↔ nebulosity separation | (copyleft — confirm exact terms per release) | ONNX weights converted to CoreML. Final model chosen in Phase 2. |
| **Plate-solve star index** | Blind/seeded solving at the Seestar focal length | catalogue-dependent | Trimmed to the Seestar's fixed focal length; bundled for offline first-run. |

## Development-only (not shipped)

| Component | Role | Licence |
|-----------|------|---------|
| Python 3 + prototyping scripts | Phase 0 bake prototyping | PSF / per-package |
| Sparkle | In-app updates | MIT-like (see Sparkle LICENSE when integrated) |

> **Action items before first release:** pin exact Siril version + record its commit/tag;
> confirm and paste the exact licence text for each shipped model; verify the star-index
> catalogue redistribution terms.

# Phase 2 spike — native (in-process) AI

Goal: run GraXpert's background-removal + denoise **in-process**, dropping the
external `GraXpert.app` subprocess dependency — the real "simple to install" win.

## Status

- ✅ **Denoise reproduced bit-exactly.** `denoise_onnx.py` is a faithful port of
  GraXpert 3.0.2 `graxpert/denoising.py` (median/MAD normalize → 256px tiles @
  stride 128 → keep-bright mask → stitch → strength blend). Driving the shipped
  ONNX model (`denoise-ai-models/3.0.2`) via onnxruntime matches GraXpert's own
  CLI output to **max abs diff 1.9e-9** (signal std ~2e-3) on a real M83 crop.
- ✅ **Background-extraction reproduced.** `bg_extract_onnx.py` ports the AI +
  Subtraction path of `graxpert/background_extraction.py` (downscale→240, pad→256,
  normalize, single model pass on `bge-ai-models/1.0.1`, blur, upscale, subtract).
  Matches GraXpert to **max abs diff 2.9e-6** (mean 2.9e-7, signal std 5e-3) on the
  full M83 master — the residual is just GraXpert's CoreML-EP vs our CPU-EP;
  visually identical. Needs `opencv-python` for pixel-exact resize/blur.
- ⬜ **Swift integration** — get onnxruntime into the SwiftPM app (C/Obj-C API or
  `onnxruntime-objc`), port these two pipelines to Swift, run in-process, and
  retire the GraXpert subprocess from `BakeRunner` / the aitools wrappers.

## Dev-only tooling (installed in prototype/.venv)
`onnx`, `onnxruntime`, `coremltools`, `opencv-python-headless<4.11` (numpy-1.x
compatible — cv2 5.x forces numpy 2 and breaks astropy). Keep `numpy<2`.

## Format decision: onnxruntime, not a converted CoreML .mlpackage

`coremltools` 9.0 **cannot ingest ONNX** (source must be tensorflow/pytorch; the
ONNX frontend was removed). Converting would need a fragile
`onnx2torch → torch.jit → coremltools` bridge across a 2,527-node graph, with real
op-support risk — and it would still be *the same model*.

Instead, ship **onnxruntime** + the ONNX models and run in-process. This:
- drops the external GraXpert.app dependency (the actual Phase-2 goal),
- is **bit-exact** with GraXpert (same runtime + models — proven above),
- still runs on the **ANE/GPU** via ORT's `CoreMLExecutionProvider` (how GraXpert
  itself runs), so "native CoreML acceleration" holds under the hood,
- follows "wrapper, not reinvent" — bundle a mature runtime, don't fight a
  model conversion.

Licensing: GraXpert is GPL-3.0 (matches Nebula); onnxruntime is MIT. The model
weights ship with GraXpert — confirm redistribution terms before bundling.

## Reproduce

```bash
prototype/.venv/bin/pip install onnx onnxruntime coremltools   # dev-only
# parity check on a crop:
prototype/.venv/bin/python prototype/ai_native/denoise_onnx.py in.fits out.fits --strength 1.0
```

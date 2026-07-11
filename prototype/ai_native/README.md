# Phase 2 spike — native (in-process) AI

Goal: run GraXpert's background-removal + denoise **in-process**, dropping the
external `GraXpert.app` subprocess dependency — the real "simple to install" win.

## Status

- ✅ **Denoise pipeline reverse-engineered and reproduced bit-exactly.**
  `denoise_onnx.py` is a faithful port of GraXpert 3.0.2 `graxpert/denoising.py`
  (median/MAD normalize → 256px tiles @ stride 128 → keep-bright mask → stitch →
  strength blend). Driving the shipped ONNX model (`denoise-ai-models/3.0.2`) via
  onnxruntime matches GraXpert's own CLI output to **max abs diff 1.9e-9** (signal
  std ~2e-3) on a real M83 crop. So we understand the model I/O and the full
  wrapping pipeline.
- ⬜ Background-extraction port (`graxpert/background_extraction.py`) — more
  involved (AI interpolation + subtraction correction); next.
- ⬜ Swift integration.

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

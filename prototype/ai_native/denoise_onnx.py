"""Phase 2 spike: reproduce GraXpert's denoise in-process from the ONNX model.

This is the parity check that gates the CoreML port — before converting anything,
prove we can drive GraXpert's denoise model ourselves and match GraXpert's own
output. The tiling / normalization / stitching here is a faithful port of
GraXpert 3.0.2 `graxpert/denoising.py` (GPL-3.0), so the CoreML/Swift version can
be validated against this, and this against GraXpert itself.

Usage: denoise_onnx.py <in.fits> <out.fits> [--strength S] [--model PATH]
"""
from __future__ import annotations
import argparse
import numpy as np
import onnxruntime as ort
from astropy.io import fits

WINDOW = 256
STRIDE = 128


def _read_fits(path: str):
    data = np.asarray(fits.getdata(path), dtype=np.float32)
    hdr = fits.getheader(path)
    if data.ndim == 2:                      # mono -> HxWx1
        data = data[:, :, None]
    elif data.ndim == 3:                    # FITS is (C,H,W) -> HxWxC
        data = np.moveaxis(data, 0, -1)
    return data, hdr


def _write_fits(path: str, img: np.ndarray, hdr):
    out = img
    if out.shape[-1] == 1:
        out = out[:, :, 0]
    else:
        out = np.moveaxis(out, -1, 0)       # HxWxC -> (C,H,W)
    fits.writeto(path, out.astype(np.float32), hdr, overwrite=True)


def denoise(image: np.ndarray, ai_path: str, strength: float,
            batch_size: int = 4) -> np.ndarray:
    """Port of graxpert/denoising.py::denoise (single-shot, no event bus / cache)."""
    input_image = image.copy()

    # Robust normalization from a decimated sample (every 4th pixel), per channel.
    median = np.median(image[::4, ::4, :], axis=(0, 1))
    mad = np.median(np.abs(image[::4, ::4, :] - median), axis=(0, 1))
    model_threshold = 10.0                  # 3.x models (1.0.0/1.1.0 would be 1.0)

    num_colors = image.shape[-1]
    if num_colors == 1:                     # model wants 3 channels
        image = np.repeat(image, 3, axis=-1)

    H, W, _ = image.shape
    offset = (WINDOW - STRIDE) // 2

    h, w, _ = image.shape
    ith = h // STRIDE + 1
    itw = w // STRIDE + 1
    dh = ith * STRIDE - h
    dw = itw * STRIDE - w

    # Replicate-pad to a whole number of tiles, then pad the offset border.
    image = np.concatenate((image, image[h - dh:, :, :]), axis=0)
    image = np.concatenate((image, image[:, w - dw:, :]), axis=1)
    h, w, _ = image.shape
    image = np.concatenate((image, image[h - offset:, :, :]), axis=0)
    image = np.concatenate((image[:offset, :, :], image), axis=0)
    image = np.concatenate((image, image[:, w - offset:, :]), axis=1)
    image = np.concatenate((image[:, :offset, :], image), axis=1)

    output = image.copy()
    session = ort.InferenceSession(ai_path, providers=["CPUExecutionProvider"])

    for b in range(0, ith * itw + batch_size, batch_size):
        tiles, copies, idxs = [], [], []
        for t in range(batch_size):
            index = b + t
            i, j = index % ith, index // ith
            if i >= ith or j >= itw:
                break
            x, y = STRIDE * i, STRIDE * j
            tile = image[x:x + WINDOW, y:y + WINDOW, :]
            tile = (tile - median) / mad * 0.04
            copies.append(np.copy(tile))
            tiles.append(np.clip(tile, -model_threshold, model_threshold))
            idxs.append((i, j))
        if not tiles:
            continue

        result = session.run(None, {"gen_input_image": np.array(tiles, dtype=np.float32)})[0]

        for t, out_tile in enumerate(result):
            i, j = idxs[t]
            x, y = STRIDE * i, STRIDE * j
            out_tile = np.where(copies[t] < model_threshold, out_tile, copies[t])
            out_tile = out_tile / 0.04 * mad + median
            out_tile = out_tile[offset:offset + STRIDE, offset:offset + STRIDE, :]
            output[x + offset:STRIDE * (i + 1) + offset,
                   y + offset:STRIDE * (j + 1) + offset, :] = out_tile

    output = output[offset:H + offset, offset:W + offset, :]
    if num_colors == 1:
        output = output[:, :, :1]

    # Blend by strength (keep-bright threshold is enormous -> effectively denoised).
    threshold = model_threshold / 0.04 * mad + median
    blend = np.where(input_image < threshold, output, input_image)
    blend = blend * strength + input_image * (1 - strength)
    return np.clip(blend, 0, 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--strength", type=float, default=0.5)
    ap.add_argument("--model", default=None)
    args = ap.parse_args()

    import os
    model = args.model or os.path.expanduser(
        "~/Library/Application Support/GraXpert/denoise-ai-models/3.0.2/model.onnx")

    img, hdr = _read_fits(args.input)
    # GraXpert works in [0,1]; the Seestar master is already ~linear in that range,
    # but clip defensively so normalization matches GraXpert's expectations.
    out = denoise(np.clip(img, 0, 1), model, args.strength)
    _write_fits(args.output, out, hdr)
    print(f"denoised {args.input} -> {args.output} (strength={args.strength})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""Phase 2 spike: reproduce GraXpert's AI background-extraction in-process.

Faithful port of GraXpert 3.0.2 `graxpert/background_extraction.py::extract_background`
(the `interpolation_type == "AI"`, `corr_type == "Subtraction"` path the bake uses)
so it can be validated against GraXpert itself and later ported to Swift + ORT.

Unlike denoise (tiled), bg-extraction is a single 256x256 model pass: downscale the
whole frame → predict the background → upscale → subtract.

Usage: bg_extract_onnx.py <in.fits> <out.fits> [--smoothing S] [--model PATH]
"""
from __future__ import annotations
import argparse
import os
import cv2
import numpy as np
import onnxruntime as ort
from astropy.io import fits


def _read_fits(path):
    data = np.asarray(fits.getdata(path), dtype=np.float32)
    hdr = fits.getheader(path)
    if data.ndim == 2:
        data = data[:, :, None]
    elif data.ndim == 3:
        data = np.moveaxis(data, 0, -1)     # (C,H,W) -> HxWxC
    return data, hdr


def _write_fits(path, img, hdr):
    out = img[:, :, 0] if img.shape[-1] == 1 else np.moveaxis(img, -1, 0)
    fits.writeto(path, out.astype(np.float32), hdr, overwrite=True)


def gaussian_kernel(sigma=1.0, truncate=4.0):
    k = round(sigma * truncate)
    ksize = k - 1 if k % 2 == 0 else k
    return (ksize, ksize)


def extract_background(in_imarray: np.ndarray, ai_path: str,
                       smoothing: float = 0.0) -> np.ndarray:
    """Return the background-subtracted image (corr_type='Subtraction')."""
    num_colors = in_imarray.shape[-1]
    imarray = in_imarray.astype(np.float32).copy()

    padding = 8
    shrink = cv2.resize(imarray, dsize=(256 - 2 * padding, 256 - 2 * padding),
                        interpolation=cv2.INTER_LINEAR)
    if shrink.ndim == 2:
        shrink = shrink[:, :, None]
    shrink = np.pad(shrink, ((padding, padding), (padding, padding), (0, 0)), mode="edge")

    median = [np.median(shrink[:, :, c]) for c in range(num_colors)]
    mad = [np.median(np.abs(shrink[:, :, c] - median[c])) for c in range(num_colors)]

    shrink = (shrink - median) / mad * 0.04
    shrink = np.clip(shrink, -1.0, 1.0)
    if num_colors == 1:                         # model wants 3 channels
        shrink = np.repeat(shrink, 3, axis=-1)

    session = ort.InferenceSession(ai_path, providers=["CPUExecutionProvider"])
    background = session.run(None, {"gen_input_image": np.expand_dims(shrink, 0).astype(np.float32)})[0][0]
    background = background / 0.04 * np.array(mad) + np.array(median)

    if smoothing != 0:
        sigma = smoothing * 20
        background = cv2.GaussianBlur(background, ksize=gaussian_kernel(sigma), sigmaX=sigma, sigmaY=sigma)

    if num_colors == 1:
        background = background[:, :, :1]

    background = background[padding:-padding, padding:-padding, :]

    sigma = 3.0
    background = cv2.GaussianBlur(background, ksize=gaussian_kernel(sigma), sigmaX=sigma, sigmaY=sigma)
    background = cv2.resize(background, dsize=(in_imarray.shape[1], in_imarray.shape[0]),
                            interpolation=cv2.INTER_LINEAR)
    if background.ndim == 2:
        background = background[:, :, None]

    # Correction — Subtraction (re-add the global mean to keep the level).
    mean = np.mean(background)
    imarray = imarray - background + mean
    return np.clip(imarray, 0.0, 1.0)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--smoothing", type=float, default=0.0)
    ap.add_argument("--model", default=None)
    args = ap.parse_args()

    model = args.model or os.path.expanduser(
        "~/Library/Application Support/GraXpert/bge-ai-models/1.0.1/model.onnx")
    img, hdr = _read_fits(args.input)
    out = extract_background(np.clip(img, 0, 1), model, args.smoothing)
    _write_fits(args.output, out, hdr)
    print(f"bg-extracted {args.input} -> {args.output} (smoothing={args.smoothing})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

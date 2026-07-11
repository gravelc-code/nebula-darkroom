#!/usr/bin/env python3
"""StarNet star-separation wrapper: linear FITS in -> linear starless FITS out.

StarNet++ v2 is trained on *stretched* (non-linear) images, but the Nebula bake
works in the linear domain. So we:
  1. read the linear master FITS,
  2. apply an invertible midtones (MTF) stretch to a 16-bit TIFF,
  3. run the native starnet2 binary,
  4. read the starless TIFF and invert the exact same stretch,
  5. write a linear starless FITS at the requested path.

Same stretch params (lo, hi, m) are used forward and inverse, so the round-trip
is exact except where StarNet actually removed stars.

Usage: starnet_fits.py <input.fits> <output.fits>
Env:   STARNET_BIN, STARNET_WEIGHTS, STARNET_LIBDIR (for cwd)
"""
from __future__ import annotations
import os, sys, subprocess, tempfile
import numpy as np
from astropy.io import fits
import tifffile

STARNET_BIN = os.environ["STARNET_BIN"]
STARNET_WEIGHTS = os.environ["STARNET_WEIGHTS"]
STARNET_DIR = os.path.dirname(STARNET_BIN)


def mtf(x: np.ndarray, m: float) -> np.ndarray:
    """PixInsight midtones transfer function. Inverse is mtf(x, 1-m)."""
    x = np.clip(x, 0.0, 1.0)
    num = (m - 1.0) * x
    den = (2.0 * m - 1.0) * x - m
    out = np.divide(num, den, out=np.zeros_like(x), where=np.abs(den) > 1e-12)
    return np.clip(out, 0.0, 1.0)


def to_hwc(d: np.ndarray) -> np.ndarray:
    return np.moveaxis(d, 0, -1) if d.ndim == 3 else d


def to_fits_order(d: np.ndarray, ndim: int) -> np.ndarray:
    return np.moveaxis(d, -1, 0) if ndim == 3 else d


def main() -> int:
    in_fits, out_fits = sys.argv[1], sys.argv[2]
    data = np.asarray(fits.getdata(in_fits), dtype=np.float32)
    header = fits.getheader(in_fits)
    ndim = data.ndim
    img = to_hwc(data).astype(np.float32)

    # Robust normalisation shared across channels (preserves colour balance).
    lo = float(np.percentile(img, 0.1))
    hi = float(np.percentile(img, 99.9))
    span = max(hi - lo, 1e-6)
    x01 = np.clip((img - lo) / span, 0.0, 1.0)

    # Choose m so the median maps to ~0.2 (a gentle display stretch).
    med = float(np.median(x01))
    target = 0.2
    # Solve mtf(med, m)=target for m numerically (monotonic in m over (0,1)).
    ms = np.linspace(0.01, 0.99, 4001)
    m = float(ms[np.argmin(np.abs(mtf(np.full_like(ms, med), ms) - target))])

    stretched = mtf(x01, m)
    tif16 = (np.clip(stretched, 0, 1) * 65535.0 + 0.5).astype(np.uint16)

    with tempfile.TemporaryDirectory() as td:
        in_tif = os.path.join(td, "in.tif")
        out_tif = os.path.join(td, "starless.tif")
        tifffile.imwrite(in_tif, tif16)
        subprocess.run(
            [STARNET_BIN, "-i", in_tif, "-o", out_tif,
             "-w", STARNET_WEIGHTS, "-s", "256", "-q"],
            cwd=STARNET_DIR, check=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        starless_s = tifffile.imread(out_tif).astype(np.float32) / 65535.0

    # Invert the exact same stretch back to linear.
    x01_starless = mtf(starless_s, 1.0 - m)
    linear = x01_starless * span + lo
    linear = to_fits_order(linear.astype(np.float32), ndim)
    fits.PrimaryHDU(data=linear, header=header).writeto(out_fits, overwrite=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

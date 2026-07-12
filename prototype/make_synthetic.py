#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""Generate synthetic test data for the Phase 0 prototype.

This is a stand-in so the pipeline can be exercised *before* real Seestar subs
arrive. It is NOT a substitute for the real acceptance test (a hand-stretch that
beats the Seestar JPEG) — it only proves the plumbing.

    python make_synthetic.py master   # one 3-plane master FITS (AI + manifest test)
    python make_synthetic.py subs      # a folder of dithered light frames (Siril test)
"""

from __future__ import annotations

import argparse
import os

import numpy as np
from astropy.io import fits


def _nebula(h: int, w: int, seed: int) -> np.ndarray:
    """A believable-ish 3-plane (RGB) nebula field: smooth emission + stars + noise."""
    rng = np.random.default_rng(seed)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    cy, cx = h * 0.5, w * 0.52

    # Large-scale emission glow.
    r2 = ((xx - cx) ** 2 + (yy - cy) ** 2) / (0.35 * w) ** 2
    glow = np.exp(-r2).astype(np.float32)
    planes = np.stack([glow * 0.9, glow * 0.5, glow * 1.0])  # magenta/teal-ish tint

    # Stars — small Gaussian PSFs (FWHM ~3 px) so Siril's star-finder can
    # actually detect and register on them.
    sigma = 1.3
    k = 5  # half-window
    gy, gx = np.mgrid[-k:k + 1, -k:k + 1].astype(np.float32)
    psf = np.exp(-(gx ** 2 + gy ** 2) / (2 * sigma ** 2)).astype(np.float32)
    for _ in range(300):
        sy = int(rng.integers(k, h - k))
        sx = int(rng.integers(k, w - k))
        amp = rng.random() ** 2 * 4.0 + 0.5
        planes[:, sy - k:sy + k + 1, sx - k:sx + k + 1] += psf * amp

    # Sky pedestal + read noise.
    planes += 0.05
    planes += rng.normal(0, 0.01, planes.shape).astype(np.float32)
    return np.clip(planes, 0, None).astype(np.float32)


def _header(exptime=10.0, filt="LP", ra=83.82, dec=-5.39):
    hdr = fits.Header()
    hdr["EXPTIME"] = exptime
    hdr["FILTER"] = filt
    hdr["RA"] = ra
    hdr["DEC"] = dec
    hdr["CCD-TEMP"] = -10.0
    hdr["INSTRUME"] = "Seestar S50"
    return hdr


def make_master(out: str, h=300, w=480):
    data = _nebula(h, w, seed=7)
    fits.PrimaryHDU(data=data, header=_header()).writeto(out, overwrite=True)
    print(f"wrote synthetic master: {out}  shape={data.shape}")


def make_subs(out_dir: str, n=12, h=300, w=480):
    os.makedirs(out_dir, exist_ok=True)
    base = _nebula(h, w, seed=7)
    rng = np.random.default_rng(99)
    for i in range(n):
        dy, dx = rng.integers(-6, 7), rng.integers(-6, 7)
        shifted = np.roll(np.roll(base, dy, axis=1), dx, axis=2)
        frame = shifted + rng.normal(0, 0.03, base.shape).astype(np.float32)
        frame = np.clip(frame, 0, None).astype(np.float32)
        path = os.path.join(out_dir, f"light_{i:04d}.fits")
        fits.PrimaryHDU(data=frame, header=_header()).writeto(path, overwrite=True)
    print(f"wrote {n} synthetic subs to: {out_dir}")


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("kind", choices=["master", "subs"])
    p.add_argument("--out", default=None)
    args = p.parse_args()
    if args.kind == "master":
        make_master(args.out or "synthetic/master.fits")
    else:
        make_subs(args.out or "synthetic/M42_subs")
    return 0


if __name__ == "__main__":
    os.makedirs("synthetic", exist_ok=True)
    raise SystemExit(main())

# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""AI stages (design §4 steps 6-8): background removal, denoise, star separation.

In the *shipping* app these run in-process via CoreML (Phase 2). In this Phase 0
prototype they are subprocess calls to GraXpert / StarNet when their binaries are
provided, and each degrades to a safe numerical fallback when a tool is missing
or fails — so the four layers are always produced (never a dead end).

The four emitted layers (design §4 step 9):
  master   — calibrated stack with sky gradient removed
  denoised — master run through the denoise model (kept separate for the slider)
  starless — master with stars removed
  stars    — master minus starless (the isolated star layer)
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from typing import Optional

import numpy as np

try:
    from astropy.io import fits
except ImportError as exc:  # pragma: no cover
    raise SystemExit("astropy is required: pip install -r requirements.txt") from exc

from .siril import StageOutcome


@dataclass
class Layers:
    """Paths to the four emitted float FITS layers + their pixel dimensions."""

    master: str
    denoised: str
    starless: str
    stars: str
    width: int
    height: int
    outcomes: list[StageOutcome]


# ---- FITS float I/O helpers -------------------------------------------------

def read_fits(path: str) -> tuple[np.ndarray, fits.Header]:
    with fits.open(path) as hdul:
        data = np.asarray(hdul[0].data, dtype=np.float32)
        header = hdul[0].header.copy()
    return data, header


def write_fits(path: str, data: np.ndarray, header: Optional[fits.Header] = None) -> None:
    fits.PrimaryHDU(data=data.astype(np.float32), header=header).writeto(path, overwrite=True)


def dimensions(data: np.ndarray) -> tuple[int, int]:
    """(width, height) for 2D (H,W) or 3-plane (3,H,W) arrays."""
    if data.ndim == 2:
        return data.shape[1], data.shape[0]
    if data.ndim == 3:
        return data.shape[2], data.shape[1]
    raise ValueError(f"Unexpected FITS ndim {data.ndim}")


# ---- external-tool hook -----------------------------------------------------

def _run_external(cmd_template: Optional[str], in_path: str, out_path: str,
                  timeout_s: int = 1200) -> bool:
    """Run an external tool from a template like
    ``"/path/to/tool {input} -o {output}"``. Returns True iff it produced
    `out_path`. Any failure returns False so the caller can fall back."""
    if not cmd_template:
        return False
    cmd = cmd_template.format(input=in_path, output=out_path)
    try:
        subprocess.run(cmd, shell=True, check=False, timeout=timeout_s,
                       capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        return False
    return os.path.exists(out_path)


# ---- numerical fallbacks ----------------------------------------------------

def _fallback_background_removal(data: np.ndarray) -> np.ndarray:
    """Subtract a smooth low-order background estimate (per channel).

    A crude stand-in for the neural model: estimate the pedestal from a low
    percentile so we don't crush signal, and subtract it. Good enough to prove
    the pipeline; the real model replaces this in Phase 2."""
    def _one(plane: np.ndarray) -> np.ndarray:
        pedestal = np.percentile(plane, 5.0)
        return np.clip(plane - pedestal, 0.0, None)

    if data.ndim == 2:
        return _one(data)
    return np.stack([_one(data[c]) for c in range(data.shape[0])], axis=0)


def _fallback_denoise(data: np.ndarray) -> np.ndarray:
    """A gentle 3x3 box blur as a denoise stand-in (separable, no SciPy dep)."""
    def _blur(plane: np.ndarray) -> np.ndarray:
        p = np.pad(plane, 1, mode="edge")
        acc = np.zeros_like(plane)
        for dy in (0, 1, 2):
            for dx in (0, 1, 2):
                acc += p[dy:dy + plane.shape[0], dx:dx + plane.shape[1]]
        return acc / 9.0

    if data.ndim == 2:
        return _blur(data)
    return np.stack([_blur(data[c]) for c in range(data.shape[0])], axis=0)


# ---- pipeline ---------------------------------------------------------------

def produce_layers(
    master_fits: str,
    out_dir: str,
    graxpert_cmd: Optional[str] = None,
    denoise_cmd: Optional[str] = None,
    starnet_cmd: Optional[str] = None,
) -> Layers:
    os.makedirs(out_dir, exist_ok=True)
    outcomes: list[StageOutcome] = []

    data, header = read_fits(master_fits)

    # --- step 6: background removal -> the master layer ---------------------
    bg_tmp = os.path.join(out_dir, "_bg_removed.fits")
    if _run_external(graxpert_cmd, master_fits, bg_tmp):
        master_data, _ = read_fits(bg_tmp)
        outcomes.append(StageOutcome("background-removal", True))
    else:
        master_data = _fallback_background_removal(data)
        outcomes.append(StageOutcome("background-removal", graxpert_cmd is None,
                                     "numerical-pedestal-subtraction"))
    master_out = os.path.join(out_dir, "master.fits")
    write_fits(master_out, master_data, header)

    # --- step 7: denoise (kept as its own layer) ---------------------------
    denoised_out = os.path.join(out_dir, "denoised.fits")
    den_tmp = os.path.join(out_dir, "_denoised.fits")
    if _run_external(denoise_cmd, master_out, den_tmp):
        denoised_data, _ = read_fits(den_tmp)
        outcomes.append(StageOutcome("denoise", True))
    else:
        denoised_data = _fallback_denoise(master_data)
        outcomes.append(StageOutcome("denoise", denoise_cmd is None, "box-blur-fallback"))
    write_fits(denoised_out, denoised_data, header)

    # --- step 8: star separation -> starless + stars -----------------------
    starless_out = os.path.join(out_dir, "starless.fits")
    stars_out = os.path.join(out_dir, "stars.fits")
    sn_tmp = os.path.join(out_dir, "_starless.fits")
    if _run_external(starnet_cmd, master_out, sn_tmp):
        starless_data, _ = read_fits(sn_tmp)
        outcomes.append(StageOutcome("star-separation", True))
    else:
        # No separation available: starless = master, stars = 0. Degrades to a
        # perfectly usable (if un-separated) result rather than failing.
        starless_data = master_data.copy()
        outcomes.append(StageOutcome("star-separation", starnet_cmd is None,
                                     "no-separation-starless-equals-master"))
    write_fits(starless_out, starless_data, header)

    # stars = max(master - starless, 0), per channel.
    stars_data = np.clip(master_data - starless_data, 0.0, None)
    write_fits(stars_out, stars_data, header)

    w, h = dimensions(master_data)
    return Layers(
        master=master_out,
        denoised=denoised_out,
        starless=starless_out,
        stars=stars_out,
        width=w,
        height=h,
        outcomes=outcomes,
    )

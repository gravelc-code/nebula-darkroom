# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""Read Seestar FITS headers → capture stats + a profile guess (design §3).

Header keys vary between Seestar firmware versions and capture tools, so every
lookup tries several aliases and degrades gracefully — a missing key never stops
the bake, it just leaves a field unknown (design: never a dead end).
"""

from __future__ import annotations

import glob
import os
from dataclasses import dataclass
from typing import Optional

try:
    from astropy.io import fits
except ImportError as exc:  # pragma: no cover - dependency hint
    raise SystemExit(
        "astropy is required for the Phase 0 prototype: pip install -r requirements.txt"
    ) from exc


# Profile raw values must match Swift `NebulaCore.Profile`.
PROFILE_GALAXY = "galaxy"
PROFILE_BROADBAND = "broadbandNebula"
PROFILE_NARROWBAND = "narrowbandDuoband"
PROFILE_CLUSTER = "starCluster"


@dataclass
class CaptureStats:
    """Matches Swift `NebulaCore.CaptureStats`. Optionals are omitted from JSON
    when None, exactly as Swift's encoder omits nil optionals."""

    frameCount: int
    subExposureSeconds: float
    filter: Optional[str] = None
    isBroadband: bool = True
    raDegrees: Optional[float] = None
    decDegrees: Optional[float] = None
    sensorTemperatureC: Optional[float] = None

    def to_json(self) -> dict:
        out = {
            "frameCount": self.frameCount,
            "subExposureSeconds": self.subExposureSeconds,
            "isBroadband": self.isBroadband,
        }
        if self.filter is not None:
            out["filter"] = self.filter
        if self.raDegrees is not None:
            out["raDegrees"] = self.raDegrees
        if self.decDegrees is not None:
            out["decDegrees"] = self.decDegrees
        if self.sensorTemperatureC is not None:
            out["sensorTemperatureC"] = self.sensorTemperatureC
        return out


def _first(header, *keys):
    for k in keys:
        if k in header and header[k] not in ("", None):
            return header[k]
    return None


def _to_float(value) -> Optional[float]:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def list_light_frames(subs_dir: str) -> list[str]:
    """All FITS light frames in a `<Target>_subs/` folder, sorted."""
    patterns = ("*.fits", "*.fit", "*.FITS", "*.FIT")
    files: list[str] = []
    for p in patterns:
        files.extend(glob.glob(os.path.join(subs_dir, p)))
    return sorted(set(files))


def _is_broadband(filt: Optional[str]) -> bool:
    if not filt:
        return True  # Seestar clear/IRCUT default is broadband
    f = filt.lower()
    narrowband_hints = ("duo", "narrow", "ha", "oiii", "sii", "nb")
    return not any(h in f for h in narrowband_hints)


def parse_capture(subs_dir: str) -> CaptureStats:
    """Build CaptureStats from the folder's light frames."""
    frames = list_light_frames(subs_dir)
    if not frames:
        raise SystemExit(f"No FITS light frames found in {subs_dir!r}")

    # Read the first frame's header for the per-sub metadata; count all frames.
    with fits.open(frames[0]) as hdul:
        header = hdul[0].header

    sub_exposure = _to_float(_first(header, "EXPTIME", "EXPOSURE", "EXP")) or 10.0
    filt = _first(header, "FILTER", "FILTER1")
    ra = _to_float(_first(header, "RA", "OBJCTRA", "CRVAL1"))
    dec = _to_float(_first(header, "DEC", "OBJCTDEC", "CRVAL2"))
    temp = _to_float(_first(header, "CCD-TEMP", "CCDTEMP", "TEMP"))

    return CaptureStats(
        frameCount=len(frames),
        subExposureSeconds=sub_exposure,
        filter=str(filt) if filt is not None else None,
        isBroadband=_is_broadband(str(filt) if filt else None),
        raDegrees=ra,
        decDegrees=dec,
        sensorTemperatureC=temp,
    )


def guess_profile(stats: CaptureStats, object_type: Optional[str] = None) -> str:
    """Mirror of Swift `Profile.guess`. Broadband nebula is the safe default."""
    o = (object_type or "").lower()
    f = (stats.filter or "").lower()
    if "galaxy" in o:
        return PROFILE_GALAXY
    if "cluster" in o:
        return PROFILE_CLUSTER
    if any(h in f for h in ("duo", "narrow", "ha", "oiii")):
        return PROFILE_NARROWBAND
    return PROFILE_BROADBAND


def target_name_from_dir(subs_dir: str) -> str:
    """`/path/M42_subs` -> "M42". A friendlier name comes later from a catalogue."""
    base = os.path.basename(os.path.normpath(subs_dir))
    for suffix in ("_subs", "-subs", "_sub"):
        if base.endswith(suffix):
            return base[: -len(suffix)]
    return base

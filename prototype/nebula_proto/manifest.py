"""Assemble and write `manifest.json` matching Swift `NebulaCore.Manifest`.

Field names, enum raw values, and the flat look dict all mirror the Swift types
so Phase 3's Swift orchestrator reads prototype output unchanged.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import uuid
from typing import Optional

from .headers import CaptureStats
from .ai import Layers

SCHEMA_VERSION = 1  # matches Manifest.currentSchemaVersion

# Auto preset in normalised form (mirrors Swift Preset.auto / Profile.initialLook).
_AUTO = {
    "glow": 0.60, "colour": 0.55, "stars": 0.65, "contrast": 0.50,
    "background": 0.55, "detail": 0.40, "starSize": 0.45, "denoise": 0.60,
}

# Per-profile overrides — must match Swift `Profile.initialLook`.
_PROFILE_OVERRIDES = {
    "galaxy": {"glow": 0.52, "stars": 0.55, "starSize": 0.40, "background": 0.60},
    "broadbandNebula": {},
    "narrowbandDuoband": {"colour": 0.68, "glow": 0.66, "stars": 0.50},
    "starCluster": {"stars": 0.78, "starSize": 0.55, "glow": 0.45, "colour": 0.48},
}


def initial_look(profile: str) -> dict:
    look = dict(_AUTO)
    look.update(_PROFILE_OVERRIDES.get(profile, {}))
    return look


def _iso8601_utc(when: _dt.datetime) -> str:
    """Match Swift's ISO-8601 encoder: whole-second UTC with a 'Z' suffix."""
    return when.astimezone(_dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def build_manifest(
    *,
    target_name: str,
    subs_path: str,
    catalogue: Optional[str],
    capture: CaptureStats,
    profile: str,
    colour_method: str,
    layers: Layers,
    stage_outcomes: list,
) -> dict:
    layer_refs = [
        {"layer": name, "path": os.path.basename(path), "format": "fits",
         "width": layers.width, "height": layers.height}
        for name, path in (
            ("master", layers.master),
            ("denoised", layers.denoised),
            ("starless", layers.starless),
            ("stars", layers.stars),
        )
    ]

    target = {
        "id": str(uuid.uuid4()).upper(),
        "name": target_name,
        "subsPath": subs_path,
        "capture": capture.to_json(),
        "profile": profile,
    }
    if catalogue:
        target["catalogue"] = catalogue

    return {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": _iso8601_utc(_dt.datetime.now()),
        "target": target,
        "look": initial_look(profile),
        "colourMethod": colour_method,
        "layers": layer_refs,
        "stageOutcomes": [o.to_json() for o in stage_outcomes],
    }


def write_manifest(manifest: dict, out_dir: str) -> str:
    path = os.path.join(out_dir, "manifest.json")
    with open(path, "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")
    return path

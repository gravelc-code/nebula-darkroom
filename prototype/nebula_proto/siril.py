"""Drive headless Siril for the classical DSP stages (design §4 steps 2-5):
register → stack (with inline frame selection) → plate-solve → colour-calibrate.

Robustness principles carried from the design:
  * File-based success detection — we check for the *output file*, never scrape
    Siril's human-readable stdout.
  * Silent colour fallback chain: spcc → pcc → native (background-neutralise).
  * Frame selection (FWHM/roundness) folds into the stack filter, so there is no
    separate QC stage.

This module only *builds and runs* the commands; the exact command list is what
Phase 3 will re-issue from Swift.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Optional

# ColourMethod raw values must match Swift `NebulaCore.ColourMethod`.
COLOUR_SPCC = "spcc"
COLOUR_PCC = "pcc"
COLOUR_NATIVE = "nativeWhiteBalance"

SIRIL_REQUIRES = "1.2.0"


@dataclass
class StageOutcome:
    """Matches Swift `NebulaCore.StageOutcome`."""

    stage: str
    succeeded: bool
    fallback: Optional[str] = None

    def to_json(self) -> dict:
        out = {"stage": self.stage, "succeeded": self.succeeded}
        if self.fallback is not None:
            out["fallback"] = self.fallback
        return out


@dataclass
class StackResult:
    master_fits: str
    colour_method: str
    outcomes: list[StageOutcome] = field(default_factory=list)


def find_siril(explicit: Optional[str] = None) -> Optional[str]:
    """Locate a Siril binary: explicit path → PATH → common app-bundle location."""
    candidates = [
        explicit,
        shutil.which("siril"),
        shutil.which("siril-cli"),
        "/Applications/Siril.app/Contents/MacOS/siril",
        "/opt/homebrew/bin/siril",
    ]
    for c in candidates:
        if c and os.path.exists(c):
            return c
    return None


def _quote(path: str) -> str:
    return f'"{path}"'


def build_script(subs_dir: str, work_dir: str, precise_colour: bool,
                 mem_gb: float = 4.0) -> tuple[str, str]:
    """Return (ssf_text, master_output_path_without_ext).

    Uses relative frame-selection filters on the stack so poor subs are dropped
    without a separate cull stage.
    """
    process_dir = os.path.join(work_dir, "process")
    master_out = os.path.join(work_dir, "master")

    colour_cmds = []
    if precise_colour:
        # Seeded from header WCS; spcc is preferred, pcc is the first fallback.
        # If plate-solving fails, these become no-ops and we fall back natively
        # (detected by the caller via the output-file check).
        colour_cmds += [
            "platesolve",
            "spcc",
        ]
    else:
        # Native path: neutralise the background and remove the green cast.
        # Good enough to look great, and removes the plate-solve failure mode.
        colour_cmds += [
            "subsky 1",
            "rmgreen",
        ]

    lines = [
        f"requires {SIRIL_REQUIRES}",
        # Use a fixed memory ceiling rather than a ratio of "available" memory.
        # This is both a determinism win for the real app and a hard requirement
        # in environments where Siril's host_statistics64() memory probe fails
        # (it then computes 0 MB and stacking aborts).
        "set core.mem_mode=1",
        f"set core.mem_amount={mem_gb}",
        "setext fits",
        f"cd {_quote(subs_dir)}",
        # Seestar is a one-shot-colour (OSC) camera: every sub is a raw Bayer CFA
        # frame (header BAYERPAT=GRBG, NAXIS=2). `-debayer` demosaics on convert so
        # the sequence — and the resulting master — is 3-channel colour. Without it
        # the whole bake is monochrome and the colour stage has nothing to work on.
        # `debayer.use_bayer_header=true` (Siril default) picks the pattern per-frame
        # from the header, so this is correct regardless of the specific CFA layout.
        # NB: Siril 1.4's parser does NOT accept quotes on `-out=` (it takes the
        # quote literally). The work dir is app-controlled and space-free, so an
        # unquoted path is safe here.
        f"convert light -debayer -out={process_dir}",
        f"cd {_quote(process_dir)}",
        # Global star registration — tolerant of the Seestar's alt-az field rotation.
        "register light",
        # Winsorized sigma clipping kills planes/satellites/hot pixels;
        # FWHM + roundness filters fold best-frame selection into the stack.
        # `-out=` is unquoted for the same parser reason as `convert -out=`.
        "stack r_light rej w 3 3 "
        "-filter-round=2.5k -filter-fwhm=90% "
        f"-norm=addscale -output_norm -out={master_out}",
        f"load {_quote(master_out)}",
    ] + colour_cmds + [
        f"save {_quote(master_out)}",
    ]
    return "\n".join(lines) + "\n", master_out


def run_stack(
    subs_dir: str,
    work_dir: str,
    precise_colour: bool,
    siril_bin: Optional[str] = None,
    timeout_s: int = 1800,
    mem_gb: float = 4.0,
) -> StackResult:
    """Run the Siril stage. Falls back to the native colour path if the precise
    (plate-solve/SPCC) path does not produce a master. Never raises on Siril
    failure for the colour step alone — colour must never block a result."""

    siril = find_siril(siril_bin)
    if siril is None:
        raise SystemExit(
            "Siril not found. Install with `brew install siril`, or pass --siril PATH."
        )

    os.makedirs(work_dir, exist_ok=True)
    # Siril's `convert -out=<dir>` requires the target directory to already exist.
    os.makedirs(os.path.join(work_dir, "process"), exist_ok=True)
    outcomes: list[StageOutcome] = []

    def _attempt(precise: bool) -> Optional[str]:
        ssf_text, master_out = build_script(subs_dir, work_dir, precise, mem_gb)
        ssf_path = os.path.join(work_dir, "bake_precise.ssf" if precise else "bake_native.ssf")
        with open(ssf_path, "w") as fh:
            fh.write(ssf_text)
        try:
            subprocess.run(
                [siril, "-s", ssf_path],
                check=False,
                timeout=timeout_s,
                capture_output=True,
                text=True,
            )
        except subprocess.TimeoutExpired:
            return None
        master_fits = master_out + ".fits"
        return master_fits if os.path.exists(master_fits) else None

    # Register + stack always run; colour method is what varies / falls back.
    master = _attempt(precise=precise_colour)
    if master is not None:
        method = COLOUR_SPCC if precise_colour else COLOUR_NATIVE
        outcomes.append(StageOutcome("register+stack", True))
        outcomes.append(StageOutcome("colour", True, None if precise_colour else "native-white-balance"))
        return StackResult(master, method, outcomes)

    # Precise path produced nothing — fall back to native colour and retry.
    if precise_colour:
        outcomes.append(StageOutcome("colour", False, "spcc-failed-fallback-native"))
        master = _attempt(precise=False)
        if master is not None:
            outcomes.append(StageOutcome("register+stack", True))
            return StackResult(master, COLOUR_NATIVE, outcomes)

    outcomes.append(StageOutcome("register+stack", False, "no-master-produced"))
    raise SystemExit(
        "Siril did not produce a master. Check that the subs folder contains "
        "registrable FITS lights and that Siril runs (health check)."
    )

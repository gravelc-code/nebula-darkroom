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
import tempfile
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
        # quote literally) AND splits the value on spaces — so `-out=` cannot
        # express a path containing a space. `run_stack` therefore points these
        # at a guaranteed space-free scratch dir (real targets like "M 83" put a
        # space in the app's cache path). See the scratch handling below.
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


def _stage_fits_lights(subs_dir: str, work_dir: str) -> str:
    """Symlink just the FITS light frames from `subs_dir` into a clean, space-free
    dir under `work_dir` (sequential names), and return that dir. Falls back to
    `subs_dir` if it holds no FITS (nothing to filter out)."""
    fits = sorted(
        n for n in os.listdir(subs_dir)
        if n.lower().endswith((".fit", ".fits"))
    )
    if not fits:
        return subs_dir
    lights_dir = os.path.join(work_dir, "lights")
    os.makedirs(lights_dir, exist_ok=True)
    for i, name in enumerate(fits):
        ext = os.path.splitext(name)[1].lower()
        link = os.path.join(lights_dir, f"light_{i:05d}{ext}")
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(os.path.join(subs_dir, name), link)
    return lights_dir


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

    # Siril's `-out=` can express neither quotes nor spaces, but the app's cache
    # path routinely contains a space (target names like "M 83", "NGC 3372").
    # Run Siril's `-out=` writes in a guaranteed space-free scratch dir, then
    # relocate the master into work_dir (Python file ops handle spaces fine, and
    # so do the downstream AI binaries invoked with argv arrays).
    siril_work = work_dir if " " not in work_dir else tempfile.mkdtemp(prefix="nebula-siril-")
    # Siril's `convert -out=<dir>` requires the target directory to already exist.
    os.makedirs(os.path.join(siril_work, "process"), exist_ok=True)

    # A Seestar `<Target>_sub` folder interleaves the real FITS lights with the
    # on-board preview JPEGs and tiny `_thn.jpg` thumbnails. `convert light` would
    # ingest ALL of them, so the sequence mixes 1080x1920 lights with 148x264
    # thumbnails and registration/stacking silently produces no master. Stage
    # symlinks to just the FITS lights (renamed to clean, space-free sequential
    # names) in a scratch dir and convert that instead of the raw folder.
    lights_dir = _stage_fits_lights(subs_dir, siril_work)

    outcomes: list[StageOutcome] = []

    def _attempt(precise: bool) -> Optional[str]:
        ssf_text, master_out = build_script(lights_dir, siril_work, precise, mem_gb)
        # The .ssf itself is passed to Siril as an argv element, so it may live in
        # the (possibly spaced) work_dir — only the in-script `-out=` values must
        # be space-free.
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
        produced = master_out + ".fits"
        if not os.path.exists(produced):
            return None
        # Hand the master back inside work_dir so downstream stages and the
        # manifest reference a stable path (no-op when siril_work == work_dir).
        final_master = os.path.join(work_dir, "master.fits")
        if os.path.abspath(produced) != os.path.abspath(final_master):
            shutil.copyfile(produced, final_master)
        return final_master

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

#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
"""Nebula Phase 0 bake prototype (dev-only — never shipped).

Turns one Seestar `<Target>_subs/` folder into the four float layers
(master · denoised · starless · stars) + a `manifest.json` that matches the
Swift `NebulaCore.Manifest` schema.

Usage:
    python bake.py <subs_dir> --out <out_dir> [options]
    python bake.py --health-check            # verify Siril runs

Options:
    --out DIR            Output directory (default: ./out/<target>)
    --precise-colour     Use plate-solve + SPCC (default: native colour)
    --siril PATH         Path to the Siril binary
    --graxpert 'CMD'     Command template for background removal, e.g.
                         "graxpert-cli background-extraction {input} -o {output}"
    --denoise 'CMD'      Command template for denoise
    --starnet 'CMD'      Command template for star separation
    --catalogue NAME     Catalogue designation (e.g. "M 42")

Every AI step falls back to a numerical stand-in when its tool is absent, so the
prototype runs end-to-end even before GraXpert/StarNet are wired up — proving the
Siril seam and the manifest first.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

from nebula_proto import ai, headers, manifest as manifest_mod, siril


def health_check(siril_bin: str | None) -> int:
    """Design §1/§3: verify the engine runs before the first real job."""
    found = siril.find_siril(siril_bin)
    if not found:
        print("✗ Siril not found. Install with `brew install siril`.", file=sys.stderr)
        return 1
    try:
        out = subprocess.run([found, "-v"], capture_output=True, text=True, timeout=30)
    except Exception as exc:  # noqa: BLE001
        print(f"✗ Siril found at {found} but failed to run: {exc}", file=sys.stderr)
        return 1
    version = (out.stdout or out.stderr).strip().splitlines()[0] if (out.stdout or out.stderr) else "?"
    print(f"✓ Siril OK: {found}\n  {version}")
    return 0


def run(args: argparse.Namespace) -> int:
    subs_dir = os.path.abspath(args.subs_dir)
    if not os.path.isdir(subs_dir):
        print(f"✗ Not a directory: {subs_dir}", file=sys.stderr)
        return 1

    target_name = headers.target_name_from_dir(subs_dir)
    out_dir = os.path.abspath(args.out or os.path.join("out", target_name))
    work_dir = os.path.join(out_dir, "_work")
    os.makedirs(out_dir, exist_ok=True)

    print(f"● Target: {target_name}")
    print(f"● Subs:   {subs_dir}")
    print(f"● Out:    {out_dir}")

    # 1. Ingest & group — parse headers, guess profile.
    capture = headers.parse_capture(subs_dir)
    profile = headers.guess_profile(capture)
    print(f"● Capture: {capture.frameCount} × {capture.subExposureSeconds:g}s "
          f"· filter={capture.filter or '—'} · profile={profile}")

    # 2-5. Siril: register → stack → (plate-solve) → colour.
    if args.from_master:
        # Skip the Siril stage and re-bake the AI layers from an existing master.
        # Handy for iterating on the AI steps and for testing without Siril.
        from nebula_proto.siril import StackResult, StageOutcome, COLOUR_NATIVE
        stack = StackResult(os.path.abspath(args.from_master), COLOUR_NATIVE,
                            [StageOutcome("register+stack", True, "reused-existing-master")])
        print(f"  master: {stack.master_fits}  (reused, colour: {stack.colour_method})")
    else:
        print("● Siril: register → stack → colour ...")
        stack = siril.run_stack(
            subs_dir=subs_dir,
            work_dir=work_dir,
            precise_colour=args.precise_colour,
            siril_bin=args.siril,
        )
        print(f"  master: {stack.master_fits}  (colour: {stack.colour_method})")

    # 6-8. AI: background removal → denoise → star separation.
    print("● AI: background removal → denoise → star separation ...")
    layers = ai.produce_layers(
        master_fits=stack.master_fits,
        out_dir=out_dir,
        graxpert_cmd=args.graxpert,
        denoise_cmd=args.denoise,
        starnet_cmd=args.starnet,
    )
    for o in layers.outcomes:
        flag = "✓" if o.succeeded else "→"
        print(f"  {flag} {o.stage}{'' if not o.fallback else f' (fallback: {o.fallback})'}")

    # 9. Emit manifest.
    m = manifest_mod.build_manifest(
        target_name=target_name,
        subs_path=subs_dir,
        catalogue=args.catalogue,
        capture=capture,
        profile=profile,
        colour_method=stack.colour_method,
        layers=layers,
        stage_outcomes=stack.outcomes + layers.outcomes,
    )
    manifest_path = manifest_mod.write_manifest(m, out_dir)
    print(f"● Manifest: {manifest_path}")
    print("✓ Bake complete. Hand-stretch the layers and compare to the Seestar JPEG.")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description="Nebula Phase 0 bake prototype")
    p.add_argument("subs_dir", nargs="?", help="Path to a <Target>_subs/ folder")
    p.add_argument("--out")
    p.add_argument("--precise-colour", action="store_true")
    p.add_argument("--siril")
    p.add_argument("--graxpert")
    p.add_argument("--denoise")
    p.add_argument("--starnet")
    p.add_argument("--catalogue")
    p.add_argument("--from-master", help="Skip Siril; re-bake AI layers from this master FITS")
    p.add_argument("--health-check", action="store_true")
    args = p.parse_args()

    if args.health_check:
        return health_check(args.siril)
    if not args.subs_dir:
        p.error("subs_dir is required (or use --health-check)")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())

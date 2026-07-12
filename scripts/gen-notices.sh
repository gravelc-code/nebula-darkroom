#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Generate a licence inventory for the bundled Siril dylib closure.
# Usage: gen-notices.sh <libs-dir> <out-file>
# Maps each bundled dylib back to its Homebrew formula (via the path it was
# copied from under /opt/homebrew) and records the formula's declared licence
# from `brew info --json=v2`. Referenced by NOTICES.md; run by build-app.sh.
set -euo pipefail

LIBS="${1:?usage: gen-notices.sh <libs-dir> <out-file>}"
OUT="${2:?usage: gen-notices.sh <libs-dir> <out-file>}"

/usr/bin/python3 - "$LIBS" "$OUT" <<'PY'
import datetime, glob, json, os, subprocess, sys

libs_dir, out_path = sys.argv[1], sys.argv[2]

def formula_for(basename):
    """The Homebrew formula a dylib was copied from, via its install path."""
    for root in ("/opt/homebrew/opt", "/opt/homebrew/Cellar"):
        hits = glob.glob(os.path.join(root, "*", "lib", basename)) \
             + glob.glob(os.path.join(root, "*", "*", "lib", basename))
        if hits:
            return hits[0].split("/")[4]
    return "unknown"

pairs = sorted((os.path.basename(p), formula_for(os.path.basename(p)))
               for p in glob.glob(os.path.join(libs_dir, "*.dylib")))
formulae = sorted({f for _, f in pairs if f != "unknown"})

lic = {}
if formulae:
    info = subprocess.run(["brew", "info", "--json=v2", *formulae],
                          capture_output=True, text=True)
    for f in json.loads(info.stdout or "{}").get("formulae", []):
        licence = f.get("license") or "unknown"
        lic[f["name"]] = licence
        for a in f.get("aliases", []):
            lic.setdefault(a, licence)

with open(out_path, "w") as out:
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out.write("Third-party dynamic libraries bundled with Nebula (Siril dependency closure).\n")
    out.write(f"Generated {now} by scripts/gen-notices.sh from Homebrew metadata.\n")
    out.write("Sources for these unmodified binaries: https://formulae.brew.sh"
              " and each project's homepage.\n\n")
    out.write("%-44s %-24s %s\n" % ("dylib", "formula", "licence"))
    out.write("%-44s %-24s %s\n" % ("-----", "-------", "-------"))
    for base, formula in pairs:
        out.write("%-44s %-24s %s\n" % (base, formula, lic.get(formula, "unknown")))

print(f"  · wrote {os.path.basename(out_path)} ({len(pairs)} libs)")
PY

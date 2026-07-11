#!/bin/bash
# Nebula real-AI bake entry point — the one durable command the app shells out to.
#
#   nebula-bake.sh <subs_dir_or_master> --out <out_dir> [extra bake.py args...]
#
# Wires the repo's env-configured AI wrappers (GraXpert bg + denoise, StarNet
# separation) into prototype/bake.py. Each AI step falls back to a numerical
# stand-in if its tool is absent (bake.py handles that), so this always runs
# end-to-end — with real AI when the tools are configured, stand-ins otherwise.
#
# Tool locations (set what you have; unset => that step falls back):
#   GRAXPERT_BIN      GraXpert executable (…/GraXpert.app/Contents/MacOS/GraXpert)
#   STARNET_BIN       starnet2 executable
#   STARNET_WEIGHTS   StarNet2_weights.pt
# Optional: SIRIL_BIN, PYTHON (defaults to the prototype venv or python3).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AITOOLS="$HERE/aitools"

# Pick a Python that has astropy/tifffile (the prototype venv, if present).
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
    if [ -x "$HERE/.venv/bin/python" ]; then PY="$HERE/.venv/bin/python"; else PY="python3"; fi
fi

args=("$@")

# Only pass an AI command template when its tool is actually configured, so the
# absent-tool fallback in bake.py kicks in cleanly instead of erroring.
# Templates are .format()'d then run via shell=True, so quote the placeholders —
# bake output paths (e.g. out/"M 83") can contain spaces.
if [ -n "${GRAXPERT_BIN:-}" ]; then
    args+=(--graxpert "'$AITOOLS/gx_bg.sh' '{input}' '{output}'")
    args+=(--denoise  "'$AITOOLS/gx_denoise.sh' '{input}' '{output}'")
fi
if [ -n "${STARNET_BIN:-}" ] && [ -n "${STARNET_WEIGHTS:-}" ]; then
    args+=(--starnet "'$PY' '$AITOOLS/starnet_fits.py' '{input}' '{output}'")
fi
if [ -n "${SIRIL_BIN:-}" ]; then args+=(--siril "$SIRIL_BIN"); fi

exec "$PY" "$HERE/bake.py" "${args[@]}"

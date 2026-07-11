#!/bin/bash
# GraXpert background-extraction wrapper: linear FITS in -> bg-removed FITS out.
# Tool location is env-configured (durable): set GRAXPERT_BIN to the GraXpert
# executable, e.g. /Applications/GraXpert.app/Contents/MacOS/GraXpert.
# Called by the bake as:  gx_bg.sh <input.fits> <output.fits>
set -e
IN="$1"; OUT="$2"; BASE="${OUT%.fits}"
BIN="${GRAXPERT_BIN:?set GRAXPERT_BIN to the GraXpert executable}"
"$BIN" -cli -cmd background-extraction "$IN" -output "$BASE" -gpu true -smoothing 0.0 >/dev/null 2>&1
# GraXpert appends .fits to -output; normalise back to the requested path.
[ -f "$BASE.fits" ] && [ "$BASE.fits" != "$OUT" ] && mv -f "$BASE.fits" "$OUT"
exit 0

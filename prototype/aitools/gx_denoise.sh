#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# GraXpert denoising wrapper: linear FITS in -> denoised FITS out.
# Set GRAXPERT_BIN to the GraXpert executable (see gx_bg.sh).
# Called by the bake as:  gx_denoise.sh <input.fits> <output.fits>
set -e
IN="$1"; OUT="$2"; BASE="${OUT%.fits}"
BIN="${GRAXPERT_BIN:?set GRAXPERT_BIN to the GraXpert executable}"
"$BIN" -cli -cmd denoising "$IN" -output "$BASE" -gpu true >/dev/null 2>&1
[ -f "$BASE.fits" ] && [ "$BASE.fits" != "$OUT" ] && mv -f "$BASE.fits" "$OUT"
exit 0

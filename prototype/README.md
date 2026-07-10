# Phase 0 — bake prototype (dev-only, never shipped)

Turns one Seestar `<Target>_subs/` folder into the four float layers
(`master · denoised · starless · stars`) + a `manifest.json` that matches the
Swift `NebulaCore.Manifest` schema.

This proves the **bake seam** (design §4) before any of it is re-implemented in
Swift (Phase 3) or moved in-process to CoreML (Phase 2). The shipping app has
**no** Python dependency.

## Setup

```bash
brew install siril                 # classical DSP engine
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python bake.py --health-check
```

## Run

```bash
# On real Seestar subs:
.venv/bin/python bake.py /path/to/M42_subs --out out/M42 --catalogue "M 42"

# Wire up the real AI tools when available (otherwise safe numerical fallbacks run):
.venv/bin/python bake.py /path/to/M42_subs \
    --graxpert "graxpert-cli background-extraction {input} -o {output}" \
    --starnet  "starnet++ {input} {output}" \
    --precise-colour                       # plate-solve + SPCC (else native colour)

# Iterate on the AI steps without re-stacking:
.venv/bin/python bake.py /path/to/M42_subs --from-master out/M42/master.fits --out out/M42
```

Every AI step degrades to a numerical stand-in when its tool is missing, and the
colour step silently falls back (spcc → native), so the bake **always produces
four layers + a manifest** — never a dead end (design §4).

## Testing without real data

```bash
.venv/bin/python make_synthetic.py subs --out synthetic/M42_subs   # dithered lights w/ Gaussian stars
.venv/bin/python bake.py synthetic/M42_subs --out out/M42          # full Siril bake
```

Synthetic data only proves the **plumbing**. The real acceptance test (design §8,
Phase 0) is a hand-stretch of the layers from *real* subs that beats the Seestar
on-board JPEG.

## Siril quirks discovered here (carry into the Phase 3 Swift orchestrator)

These were found the hard way against bundled Siril **1.4.4** and must be
reproduced when Swift re-issues the commands:

1. **Fixed memory ceiling is mandatory.** Siril computes "available memory" via
   `host_statistics64()`, which can fail (sandbox / some environments) → it then
   uses `0 MB` and **stacking silently aborts**. Always set:
   `set core.mem_mode=1` + `set core.mem_amount=<GB>`.
2. **`-out=` does not accept quotes.** `cd`/`load`/`save` accept a quoted path,
   but `convert -out="…"` and `stack … -out="…"` take the quote *literally*
   (you get a file named `"`). Keep the work dir space-free and pass `-out=`
   unquoted.
3. **`convert -out=<dir>` needs the directory to pre-exist** — create it first.
4. **Stale star-detection cache** (`process/cache/*.lst`) survives re-runs; wipe
   the work dir when the input subs change.

## Files

| File | Role |
|------|------|
| `bake.py` | Orchestrator + CLI + `--health-check` |
| `nebula_proto/headers.py` | FITS headers → `CaptureStats` + profile guess |
| `nebula_proto/siril.py` | SSF script generation + headless runner + colour fallback |
| `nebula_proto/ai.py` | GraXpert/StarNet/denoise subprocess hooks + numerical fallbacks |
| `nebula_proto/manifest.py` | Emits `manifest.json` matching `NebulaCore.Manifest` |
| `make_synthetic.py` | Synthetic subs / master for plumbing tests |

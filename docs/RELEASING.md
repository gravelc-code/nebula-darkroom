# Releasing Nebula

The DMG is built **locally**: it bundles Siril and its Homebrew dylib closure
from the release Mac, which hosted CI runners can't provide. CI (GitHub
Actions) covers build + tests; this checklist covers shipping.

## Prerequisites (release machine)

- Apple Silicon Mac, full Xcode 16+. Homebrew bottles target the host macOS,
  so the app will require the release Mac's macOS (`build-app.sh` derives
  `LSMinimumSystemVersion` from the bundle — currently **26.0**).
- `brew install siril dylibbundler`, then `brew update && brew upgrade` so the
  bundled libraries (and their source archives) are current.
- `~/Library/Application Support/Nebula/Models/superres.onnx` (reproducible
  conversion: `scripts/convert-realesrgan-x2.py`). A release build refuses any
  file whose SHA-256 differs from the one in `NOTICES.md`.
- A **Developer ID Application** certificate in the login keychain, and a
  notarytool keychain profile, created once, interactively:
  ```bash
  xcrun notarytool store-credentials nebula-notary \
    --apple-id <your-apple-id-email> --team-id <TEAMID>
  ```
- Environment for the session:
  ```bash
  export NEBULA_SIGN_ID="Developer ID Application: <Name> (<TEAMID>)"
  export NEBULA_VERSION=x.y.z
  # NEBULA_TEAM_ID defaults to the (TEAMID) in NEBULA_SIGN_ID;
  # NEBULA_NOTARY_PROFILE defaults to nebula-notary.
  ```

## Checklist

1. **Sanity**
   ```bash
   scripts/swift-xcode.sh test --scratch-path /tmp/nebula-build   # all green
   ```
2. **Build + sign the app**
   ```bash
   scripts/build-app.sh
   ```
   With `NEBULA_SIGN_ID` set this is a release build: missing Siril or
   dylibbundler, a dylibbundler failure, a missing/mismatched model, or any
   bundled binary the licence inventory can't attribute is a hard error. Every
   build asserts the dependency closure is complete and verifies **each**
   Mach-O's signature (Siril's tree under `Resources/` is invisible to
   `codesign --deep`) via `scripts/verify-bundle.sh`; release builds also
   require hardened runtime, a secure timestamp, Developer ID and one Team ID
   on all of them. It ends with a summary — check it.
3. **Notarise the app** — `scripts/notarize.sh app` (validates the keychain
   profile, preflights the bundle, submits, prints the full notary log on any
   rejection, staples).
4. **DMG** — `scripts/build-dmg.sh`, then `scripts/notarize.sh dmg`.
   `build-dmg.sh` reuses the stapled app only if it is Developer ID signed by
   your team and newer than every source file; otherwise it stops and says
   why (`NEBULA_REBUILD_APP=1` / `NEBULA_REUSE_APP=1` override). The DMG holds
   the app, an Applications link and a `Licenses` folder.
5. **Third-party sources** (GPL-3.0 §6 — required for every release)
   ```bash
   scripts/fetch-sources.sh
   # → build/Nebula-$NEBULA_VERSION-third-party-sources.tar
   ```
   Exact upstream archives (SHA-256 verified), Homebrew patches and formulae
   for Siril and every bundled library, attributed from the built app itself.
   Expect a few hundred MB (GCC's source alone is ~100 MB). If an upstream
   host is down, the script names the file and hash to drop in by hand.
6. **Smoke test on a fresh account/Mac** (no Homebrew, no GraXpert):
   - mount the DMG (the `Licenses` folder is visible), drag to Applications,
     **double-click** — it must open with no Gatekeeper prompt
   - develop a real `…_sub` folder end-to-end: the GraXpert guidance sheet
     appears, "Develop Without AI" completes to an image
   - install GraXpert, open it once, re-develop: full-quality bake, no prompt
   - export a PNG; confirm it matches the preview
7. **Tag & release** — attach **both** files, and keep the sources tarball
   attached for as long as the DMG is offered (NOTICES.md's written offer runs
   three years beyond that):
   ```bash
   git tag v$NEBULA_VERSION && git push --tags
   gh release create v$NEBULA_VERSION build/Nebula.dmg \
     build/Nebula-$NEBULA_VERSION-third-party-sources.tar \
     --title "Nebula $NEBULA_VERSION" --notes-file <(cat <<'NOTES'
   <highlights>

   **Install:** download `Nebula.dmg`, drag Nebula to Applications, open it.
   Requires macOS <LSMinimumSystemVersion>+ on Apple Silicon.
   Bundled Siril <version from the build summary>. Source code for the bundled
   third-party components is attached (see NOTICES.md in the DMG).
   NOTES
   )
   ```

## Contributor / unsigned builds

Leave `NEBULA_SIGN_ID` unset: `build-app.sh` ad-hoc signs, and degradations
are warnings listed in its summary (`NEBULA_STRICT=1` rehearses the release
checks without a certificate). An un-notarised app is blocked on first launch
on another Mac: open it once, then **System Settings → Privacy & Security →
Open Anyway**. (Right-click → Open no longer bypasses Gatekeeper on macOS 15+.)

| Variable | Used by | Meaning |
|----------|---------|---------|
| `NEBULA_SIGN_ID` | build-app, build-dmg | Developer ID identity; set = release build |
| `NEBULA_TEAM_ID` | build-app, build-dmg, notarize | Team ID (default: parsed from `NEBULA_SIGN_ID`) |
| `NEBULA_NOTARY_PROFILE` | notarize | notarytool keychain profile (default `nebula-notary`) |
| `NEBULA_VERSION` | build-app | `CFBundleShortVersionString` (default `0.1`) |
| `NEBULA_SUPERRES_MODEL` | build-app | path to `superres.onnx` |
| `NEBULA_STRICT=1` | build-app | release-strength checks without signing |
| `NEBULA_REBUILD_APP=1` / `NEBULA_REUSE_APP=1` | build-dmg | force a rebuild / package a stale app |
| `SCRATCH` | build-app | SwiftPM scratch path (default `/tmp/nebula-build`) |

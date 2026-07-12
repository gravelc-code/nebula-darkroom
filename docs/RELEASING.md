# Releasing Nebula

The DMG is built **locally** — it bundles Siril and its dylib closure from a
trusted Homebrew install, which hosted CI runners can't provide. CI (GitHub
Actions) covers build + tests; this checklist covers shipping.

## Prerequisites (release machine)

- Apple Silicon Mac, full Xcode 16+
- `brew install siril dylibbundler`
- `~/Library/Application Support/Nebula/Models/superres.onnx` present
  (reproducible conversion: `scripts/convert-realesrgan-x2.py`; SHA-256 in
  `NOTICES.md`)

## Checklist

1. **Version & sanity**
   ```bash
   scripts/swift-xcode.sh test --scratch-path /tmp/nebula-build   # all green
   export NEBULA_VERSION=x.y.z
   ```
2. **Build**
   ```bash
   scripts/build-app.sh    # → build/Nebula.app (+ NOTICES-bundled.txt inside)
   scripts/build-dmg.sh    # → build/Nebula.dmg (~100 MB)
   ```
3. **Smoke test on a fresh account/machine** (no Homebrew, no GraXpert):
   - mount the DMG, drag to Applications, **right-click → Open**
   - develop a real `…_sub` folder end-to-end: the GraXpert guidance sheet
     appears, "Develop Without AI" completes to an image
   - install GraXpert, open it once, re-develop: full-quality bake, no prompt
   - export a PNG; confirm it matches the preview
4. **Tag & release**
   ```bash
   git tag v$NEBULA_VERSION && git push --tags
   gh release create v$NEBULA_VERSION build/Nebula.dmg \
     --title "Nebula $NEBULA_VERSION" --notes-file <(cat <<'NOTES'
   <highlights>

   **Install:** download `Nebula.dmg`, drag to Applications, then
   **right-click → Open** the first time (the app is not yet notarised).
   Bundled Siril version: <siril --version>.
   NOTES
   )
   ```
5. **Record in the release notes:** bundled Siril version, and anything the
   per-release checklist at the bottom of `NOTICES.md` calls out.

## Not yet automated

- **Notarisation** needs an Apple Developer ID:
  `codesign --options runtime` + `xcrun notarytool submit` + `stapler staple`.
  Until then the right-click→Open instruction must stay in every release note.

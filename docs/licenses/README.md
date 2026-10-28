# Vendored licence texts

Copied into `Nebula.app/Contents/Resources/Licenses/` (and the DMG) by
`scripts/build-app.sh`. All other licence texts there are collected from the
installed Homebrew kegs by `scripts/gen-notices.sh`.

| File | Upstream |
|------|----------|
| `onnxruntime/LICENSE`, `onnxruntime/ThirdPartyNotices.txt` | microsoft/onnxruntime @ `v1.19.2`, the version pinned in `Package.swift` (refresh both on a bump) |
| `Real-ESRGAN/LICENSE` | xinntao/Real-ESRGAN @ `v0.2.1`, the release the bundled weights come from |
| `homebrew/cfitsio/License.txt` | HEASARC/cfitsio @ `cfitsio-4.7.0` (the Homebrew keg installs no licence file) |

`homebrew/<formula>/` is only a fallback for kegs that ship no licence file;
`gen-notices.sh --strict` (release builds) fails if a formula has neither.

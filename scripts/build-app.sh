#!/bin/bash
# Assemble a self-contained Nebula.app from the SwiftPM build: the release
# executable + the onnxruntime framework + the Real-ESRGAN model + Info.plist,
# ad-hoc signed so it runs locally. GraXpert's AI models are deliberately NOT
# bundled (unconfirmed redistribution terms) — the app guides users to install
# GraXpert once instead. (Notarised DMG still needs an Apple Developer ID.)
#
# Siril and its dylib closure are bundled below when the Homebrew development
# copy is available.
set -euo pipefail

# `xcode-select` may point at the standalone Command Line Tools even when full
# Xcode is installed. CLT lacks SwiftUI macro plugins and XCTest, so SwiftPM
# emits misleading source errors. Select full Xcode for this process only.
if [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ]; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1; then
  echo "error: full Xcode is required (SwiftUI macros are not included in Command Line Tools)" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/nebula-build}"
APP="$HERE/build/Nebula.app"

echo "▸ release build"
swift build -c release --product NebulaApp --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/NebulaApp"
FWDIR="$SCRATCH/out/Products/Release"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Models"
cp "$BIN" "$APP/Contents/MacOS/Nebula"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nebula</string>
  <key>CFBundleDisplayName</key><string>Nebula</string>
  <key>CFBundleIdentifier</key><string>com.nebula.app</string>
  <key>CFBundleExecutable</key><string>Nebula</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST

# onnxruntime framework + an rpath so the executable finds it inside the bundle.
if [ -d "$FWDIR/onnxruntime.framework" ]; then
  cp -R "$FWDIR/onnxruntime.framework" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Nebula" 2>/dev/null || true
  echo "  · bundled onnxruntime.framework"
fi

# GraXpert's bge/denoise models are NOT bundled: their redistribution terms are
# unconfirmed, so the app guides the user to install GraXpert (free, GPL) once
# and reads its model cache. Only Real-ESRGAN (BSD-3, reproducibly converted by
# scripts/convert-realesrgan-x2.py) ships in the bundle.
NM="$HOME/Library/Application Support/Nebula/Models"
SR="${NEBULA_SUPERRES_MODEL:-$NM/superres.onnx}"
[ -f "$SR" ] && cp "$SR" "$APP/Contents/Resources/Models/superres.onnx" && echo "  · bundled AI super-resolution model"

# Bundle Siril (register/stack) + its dylib closure -> a self-contained app that
# needs no `brew install siril`. dylibbundler gets ~93 libs; a short loop then
# resolves the versioned-name stragglers (libde265/openblas/tbb) it misses.
SIRIL_BIN="$(command -v siril || true)"
if [ -n "$SIRIL_BIN" ] && command -v dylibbundler >/dev/null 2>&1; then
  echo "▸ bundling Siril"
  SDIR="$APP/Contents/Resources/siril"
  mkdir -p "$SDIR/libs"
  cp "$(readlink -f "$SIRIL_BIN" 2>/dev/null || greadlink -f "$SIRIL_BIN" 2>/dev/null || echo "$SIRIL_BIN")" "$SDIR/siril"
  dylibbundler -cd -of -b -x "$SDIR/siril" -d "$SDIR/libs/" -p "@executable_path/libs/" >/dev/null 2>&1 || true
  # Complete the dependency closure statically: dylibbundler misses libs that are
  # only referenced by *other* bundled libs (libde265 via libheif, openblas, tbb).
  # Repeatedly scan every bundled lib + the binary for remaining /opt/homebrew
  # deps, copy+rewrite them, until nothing changes.
  # Catches every dep whose basename is missing from libs/ — including ones
  # dylibbundler already rewrote to @executable_path/libs/… but never copied.
  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    for lib in "$SDIR/siril" "$SDIR/libs"/*.dylib; do
      [ -f "$lib" ] || continue
      for ref in $(otool -L "$lib" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -E '\.dylib$'); do
        case "$ref" in /usr/lib/*|/System/*) continue;; esac
        base="$(basename "$ref")"
        if [ ! -f "$SDIR/libs/$base" ]; then
          src="$(find /opt/homebrew/opt /opt/homebrew/Cellar -name "$base" 2>/dev/null | head -1)"
          [ -z "$src" ] && continue
          cp -Lf "$src" "$SDIR/libs/$base"; chmod +w "$SDIR/libs/$base"
          install_name_tool -id "@executable_path/libs/$base" "$SDIR/libs/$base" 2>/dev/null || true
          changed=1
        fi
        case "$ref" in @executable_path/libs/*) ;;
          *) install_name_tool -change "$ref" "@executable_path/libs/$base" "$lib" 2>/dev/null || true;; esac
      done
    done
  done
  # dyld rejects a Mach-O with a duplicate LC_RPATH — collapse to exactly one.
  for lib in "$SDIR/siril" "$SDIR/libs"/*.dylib; do
    [ -f "$lib" ] || continue
    while install_name_tool -delete_rpath '@executable_path/libs/' "$lib" 2>/dev/null; do :; done
    install_name_tool -add_rpath '@executable_path/libs/' "$lib" 2>/dev/null || true
  done
  codesign --force --sign - "$SDIR/siril" "$SDIR/libs"/*.dylib >/dev/null 2>&1 || true
  echo "  · bundled Siril + $(ls "$SDIR/libs" | wc -l | tr -d ' ') dylibs"
else
  echo "  Siril: not bundled (need siril + dylibbundler) — discovered from Homebrew at runtime."
fi

# Dropbox/File Provider attaches resource-fork-like metadata inside a freshly
# assembled bundle. Strip it before signing and once more afterwards in case it
# races the signer; the latter does not alter signed file contents.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
xattr -cr "$APP" 2>/dev/null || true
echo "✓ built $APP"

#!/bin/bash
# Assemble a self-contained Nebula.app from the SwiftPM build: the release
# executable + the onnxruntime framework + the bundled ONNX models + Info.plist,
# ad-hoc signed so it runs locally. This is the Phase-5 shipping foundation
# (notarised DMG still needs an Apple Developer ID).
#
# Not yet bundled: Siril. It's discovered from Homebrew at runtime; bundling its
# ~38-dylib GTK dependency tree is a separate packaging task.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/nebula-build}"
APP="$HERE/build/Nebula.app"
GX="$HOME/Library/Application Support/GraXpert"

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

# Bundled ONNX models -> self-contained AI (no external GraXpert.app).
DN="$(ls -t "$GX"/denoise-ai-models/*/model.onnx 2>/dev/null | head -1 || true)"
BG="$(ls -t "$GX"/bge-ai-models/*/model.onnx 2>/dev/null | head -1 || true)"
[ -n "$DN" ] && cp "$DN" "$APP/Contents/Resources/Models/denoise.onnx" && echo "  · bundled denoise model"
[ -n "$BG" ] && cp "$BG" "$APP/Contents/Resources/Models/bge.onnx" && echo "  · bundled bge model"

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

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ built $APP"

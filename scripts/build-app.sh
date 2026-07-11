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

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ built $APP"
echo "  Siril: discovered from Homebrew at runtime (bundling is a separate task)."

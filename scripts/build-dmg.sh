#!/bin/bash
# Package Nebula.app into a drag-to-Applications DMG. Builds the app first via
# build-app.sh. The DMG is NOT notarised (needs an Apple Developer ID) — on
# another Mac, first launch is right-click → Open to get past Gatekeeper.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/Nebula.app"
DMG="$HERE/build/Nebula.dmg"

bash "$HERE/scripts/build-app.sh"

echo "▸ packaging DMG"
STAGE="$(mktemp -d)"
COPYFILE_DISABLE=1 cp -R "$APP" "$STAGE/Nebula.app"
xattr -cr "$STAGE/Nebula.app" 2>/dev/null || true
codesign --verify --deep --strict "$STAGE/Nebula.app"
ln -s /Applications "$STAGE/Applications"       # drag-install target
rm -f "$DMG"
hdiutil create -volname "Nebula" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ $DMG ($(du -h "$DMG" | awk '{print $1}'))"
echo "  Not notarised — first launch on another Mac: right-click → Open."

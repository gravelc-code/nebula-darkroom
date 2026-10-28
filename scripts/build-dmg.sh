#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Package Nebula.app into a drag-to-Applications DMG: the app, an Applications
# link, and a Licenses folder (GPL-3.0 text, NOTICES.md with where to get the
# source, and every bundled component's licence).
#
# Release (NEBULA_SIGN_ID set): run build-app.sh and notarize.sh app BEFORE
# this (so the stapled ticket ships inside the DMG), and notarize.sh dmg
# after. The existing build/Nebula.app is reused — rebuilding would discard
# its staple — but only if it is Developer ID signed by the right team and
# newer than every source file. Otherwise:
#   · not Developer ID / wrong team  → rebuilt (there is no staple to lose)
#   · older than the sources         → refused; rebuild + re-notarise it, or
#       NEBULA_REBUILD_APP=1  rebuild now (the app inside won't be stapled)
#       NEBULA_REUSE_APP=1    package the stale app anyway
# Ad-hoc (no NEBULA_SIGN_ID): the app is (re)built when missing or stale.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/Nebula.app"
DMG="$HERE/build/Nebula.dmg"
SIGN_ID="${NEBULA_SIGN_ID:-}"
TEAM_ID="${NEBULA_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -n "$SIGN_ID" ]; then
  TEAM_ID="$(sed -nE 's/.*\(([A-Z0-9]{10})\)[[:space:]]*$/\1/p' <<< "$SIGN_ID")"
fi
die() { echo "error: $*" >&2; exit 1; }

# The newest input that ends up in the app (code, package pins, bundled
# licence texts, the packaging scripts themselves).
newest_input() {
  find "$HERE/Sources" "$HERE/Package.swift" "$HERE/Package.resolved" "$HERE/LICENSE" \
       "$HERE/NOTICES.md" "$HERE/docs/licenses" "$HERE/scripts/build-app.sh" \
       "$HERE/scripts/gen-notices.sh" -type f -print0 2>/dev/null \
    | xargs -0 stat -f '%m %N' | sort -n | tail -1
}

rebuild=""
if [ ! -d "$APP" ]; then
  rebuild="no app built yet"
elif [ "${NEBULA_REBUILD_APP:-0}" = 1 ]; then
  rebuild="NEBULA_REBUILD_APP=1"
else
  sealed="$(stat -f %m "$APP/Contents/_CodeSignature/CodeResources" 2>/dev/null || echo 0)"
  newest="$(newest_input)"; newest="${newest:-0 none}"
  stale=""
  [ "${newest%% *}" -gt "$sealed" ] && stale="${newest#* }"
  sig="$(codesign -dvv "$APP" 2>&1 || true)"
  authority="$(awk -F= '/^Authority=/ {print $2; exit}' <<< "$sig")"
  team="$(awk -F= '/^TeamIdentifier=/ {print $2}' <<< "$sig")"
  if [ -n "$SIGN_ID" ]; then
    if [[ "$authority" != "Developer ID Application:"* ]]; then
      rebuild="existing app is not Developer ID signed (${authority:-ad-hoc})"
    elif [ -n "$TEAM_ID" ] && [ "$team" != "$TEAM_ID" ]; then
      rebuild="existing app is signed by team $team, not $TEAM_ID"
    elif [ -n "$stale" ] && [ "${NEBULA_REUSE_APP:-0}" != 1 ]; then
      die "build/Nebula.app is older than ${stale#"$HERE"/}.
       It may be notarised and stapled, so it is not rebuilt silently. Either
         NEBULA_SIGN_ID=… scripts/build-app.sh && scripts/notarize.sh app   (then re-run this), or
         NEBULA_REBUILD_APP=1  rebuild now (the app in the DMG won't carry a staple), or
         NEBULA_REUSE_APP=1    package the stale app anyway."
    fi
  elif [ -n "$stale" ] && [ "${NEBULA_REUSE_APP:-0}" != 1 ]; then
    rebuild="app is older than ${stale#"$HERE"/}"
  fi
fi
if [ -n "$rebuild" ]; then
  echo "▸ building the app ($rebuild)"
  bash "$HERE/scripts/build-app.sh"
fi

VB=()
if [ -n "$SIGN_ID" ]; then
  VB=(--release); [ -n "$TEAM_ID" ] && VB+=(--team "$TEAM_ID")
  xcrun stapler validate -q "$APP" 2>/dev/null \
    || echo "  ! app is not notarised+stapled — run scripts/notarize.sh app first so it opens offline once copied out of the DMG" >&2
fi
[ -d "$APP/Contents/Resources/Licenses" ] || die "app has no Contents/Resources/Licenses — rebuild it with this build-app.sh"

echo "▸ packaging DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
COPYFILE_DISABLE=1 cp -R "$APP" "$STAGE/Nebula.app"
xattr -cr "$STAGE/Nebula.app" 2>/dev/null || true
# Verify the copy that ships: closure + every Mach-O's signature (incl. Siril's
# under Resources, which `codesign --deep` never checks).
bash "$HERE/scripts/verify-bundle.sh" "${VB[@]+"${VB[@]}"}" "$STAGE/Nebula.app"
# Licence texts + where to get the source, visible before anyone installs.
COPYFILE_DISABLE=1 cp -R "$APP/Contents/Resources/Licenses" "$STAGE/Licenses"
ln -s /Applications "$STAGE/Applications"       # drag-install target
rm -f "$DMG"
hdiutil create -volname "Nebula" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | awk '{print $1}')"
if [ -n "$SIGN_ID" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  codesign --verify --strict "$DMG"
  echo "✓ $DMG ($SIZE, signed)"
  echo "  Notarise it with: scripts/notarize.sh dmg"
else
  echo "✓ $DMG ($SIZE, ad-hoc app — not notarised)"
  echo "  First launch on another Mac: open Nebula once (macOS blocks it), then"
  echo "  System Settings → Privacy & Security → Open Anyway. (Right-click → Open"
  echo "  no longer bypasses Gatekeeper on macOS 15 and later.)"
fi

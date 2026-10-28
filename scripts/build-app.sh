#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Assemble a self-contained Nebula.app from the SwiftPM build: the release
# executable (onnxruntime is linked in), Siril + its Homebrew dylib closure, the
# Real-ESRGAN model, every licence text, and Info.plist.
# GraXpert's AI models and StarNet are deliberately NEVER bundled — the app
# guides users to install GraXpert once instead (see NOTICES.md).
#
# Signing: set NEBULA_SIGN_ID to a "Developer ID Application: … (TEAMID)"
# identity for a notarisable release build (hardened runtime + secure
# timestamp on every Mach-O, signed inside-out). Unset, the bundle is ad-hoc
# signed so contributors without a certificate can still build and run it.
#
# Release builds (NEBULA_SIGN_ID set, or NEBULA_STRICT=1 to rehearse without a
# certificate) turn every degradation into a hard error: missing siril or
# dylibbundler, a dylibbundler failure, a missing/mismatched super-resolution
# model, or a licence inventory that can't attribute every bundled binary.
# Every build — release or not — fails if any bundled Mach-O still links
# outside the bundle or carries an invalid signature (scripts/verify-bundle.sh).
set -euo pipefail

SIGN_ID="${NEBULA_SIGN_ID:-}"
STRICT=0
if [ -n "$SIGN_ID" ] || [ "${NEBULA_STRICT:-0}" = 1 ]; then STRICT=1; fi
WARNINGS=()
# A degradation: fatal for a release build, a loud warning otherwise.
problem() {
  if [ "$STRICT" = 1 ]; then echo "error: $* (release builds must be complete)" >&2; exit 1; fi
  WARNINGS+=("$*"); echo "  ! $*" >&2
}
die() { echo "error: $*" >&2; exit 1; }

# Sign one Mach-O/bundle. Distribution signing must be applied per item,
# inside-out — `codesign --deep` is deprecated for this and does not reliably
# put the hardened runtime on nested executables under Resources/.
sign() {
  local out
  if [ -n "$SIGN_ID" ]; then
    out="$(codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$@" 2>&1)" \
      || { echo "$out" >&2; die "codesign failed"; }
  else
    out="$(codesign --force --sign - "$@" 2>&1)" || { echo "$out" >&2; die "codesign failed"; }
  fi
}
rpaths() { otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}'; }

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
xcrun --find xcodebuild >/dev/null 2>&1 \
  || die "full Xcode is required (SwiftUI macros are not included in Command Line Tools)"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-/tmp/nebula-build}"
APP="$HERE/build/Nebula.app"
RES="$APP/Contents/Resources"
LIC="$RES/Licenses"
VERSION="${NEBULA_VERSION:-0.1}"   # release version (see docs/RELEASING.md)
TEAM_ID="${NEBULA_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -n "$SIGN_ID" ]; then
  TEAM_ID="$(sed -nE 's/.*\(([A-Z0-9]{10})\)[[:space:]]*$/\1/p' <<< "$SIGN_ID")"
fi

# ── Preflight: fail a release build in seconds, not after a release compile ──
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
SIRIL_BIN="$(command -v siril || true)"
HAVE_SIRIL=0
if [ -n "$SIRIL_BIN" ] && [ -n "$BREW_PREFIX" ] && command -v dylibbundler >/dev/null 2>&1; then
  HAVE_SIRIL=1
else
  problem "Siril not bundled: need Homebrew siril + dylibbundler (brew install siril dylibbundler) — the app will look for a Homebrew Siril at runtime"
fi
NM="$HOME/Library/Application Support/Nebula/Models"
SR="${NEBULA_SUPERRES_MODEL:-$NM/superres.onnx}"
SR_EXPECTED="$(grep -oE 'ONNX SHA-256 `[0-9a-f]{64}`' "$HERE/NOTICES.md" | grep -oE '[0-9a-f]{64}' || true)"
HAVE_SR=0
if [ ! -f "$SR" ]; then
  problem "AI enlargement model not bundled: $SR not found (convert it with scripts/convert-realesrgan-x2.py)"
elif [ -z "$SR_EXPECTED" ]; then
  problem "NOTICES.md records no 'ONNX SHA-256' for the enlargement model — bundled unverified"
  HAVE_SR=1
elif [ "$(shasum -a 256 "$SR" | awk '{print $1}')" != "$SR_EXPECTED" ]; then
  problem "AI enlargement model not bundled: $SR does not match the SHA-256 recorded in NOTICES.md"
else
  HAVE_SR=1
fi

echo "▸ release build"
swift build -c release --product NebulaApp --scratch-path "$SCRATCH"
BIN="$SCRATCH/release/NebulaApp"
FWDIR="$SCRATCH/out/Products/Release"

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES/Models" "$LIC"
MAIN="$APP/Contents/MacOS/Nebula"
cp "$BIN" "$MAIN"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nebula</string>
  <key>CFBundleDisplayName</key><string>Nebula</string>
  <key>CFBundleIdentifier</key><string>com.nebula.app</string>
  <key>CFBundleExecutable</key><string>Nebula</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
</dict></plist>
PLIST

# onnxruntime: the SwiftPM binary target ships a *static* xcframework, so it is
# linked into the executable and the framework must not be copied (it would be
# ~78 MB of unloadable archive). Bundle it only if a future package makes it a
# dynamic dependency.
if otool -L "$MAIN" | grep -q 'onnxruntime.framework'; then
  [ -d "$FWDIR/onnxruntime.framework" ] || die "executable links onnxruntime.framework but $FWDIR has none"
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "$FWDIR/onnxruntime.framework" "$APP/Contents/Frameworks/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MAIN"
  ORT="dynamic (Contents/Frameworks)"
else
  ORT="statically linked into the executable"
fi
echo "  · onnxruntime: $ORT"

# The toolchain bakes absolute LC_RPATHs into the executable (e.g. the Swift
# back-deploy dir inside /Applications/Xcode-beta.app). Nothing in the bundle
# resolves through them — the Swift runtime is in the OS (/usr/lib/swift) — and
# a user's machine has no such path, so strip every absolute non-OS rpath.
# verify-bundle.sh below proves every @rpath dependency still resolves.
while IFS= read -r r; do
  case "$r" in
    /usr/lib/*|/System/*|@*|"") ;;
    /*) install_name_tool -delete_rpath "$r" "$MAIN"; echo "  · stripped build-machine rpath $r";;
  esac
done <<< "$(rpaths "$MAIN")"

# GraXpert's bge/denoise models are NOT bundled (see NOTICES.md). Only
# Real-ESRGAN (BSD-3, reproducibly converted by scripts/convert-realesrgan-x2.py,
# SHA-256 checked against NOTICES.md above) ships in the bundle.
if [ "$HAVE_SR" = 1 ]; then
  cp "$SR" "$RES/Models/superres.onnx"
  echo "  · bundled AI super-resolution model${SR_EXPECTED:+ (SHA-256 matches NOTICES.md)}"
fi

# ── Siril + its dylib closure → no `brew install siril` on the user's Mac ───
SIRIL_VER="not bundled" NLIBS=0
if [ "$HAVE_SIRIL" = 1 ]; then
  echo "▸ bundling Siril"
  SDIR="$RES/siril"
  mkdir -p "$SDIR/libs"
  SIRIL_REAL="$(readlink -f "$SIRIL_BIN")"
  SIRIL_VER="$(basename "$(dirname "$(dirname "$SIRIL_REAL")")")"   # Cellar/siril/<ver>/bin/siril
  cp "$SIRIL_REAL" "$SDIR/siril"
  BLOG="$HERE/build/dylibbundler.log"
  if ! dylibbundler -cd -of -b -x "$SDIR/siril" -d "$SDIR/libs/" -p "@executable_path/libs/" \
       -s "$BREW_PREFIX/lib" </dev/null >"$BLOG" 2>&1; then
    tail -5 "$BLOG" >&2
    problem "dylibbundler failed (log: $BLOG)"
  fi
  # Complete the dependency closure: dylibbundler misses libs that are only
  # referenced by *other* bundled libs (libde265 via libheif, openblas, tbb).
  # Repeatedly scan the binary + every bundled lib for deps whose basename is
  # missing from libs/ (including refs dylibbundler already rewrote to
  # @executable_path/libs/… but never copied), copy each from its *current*
  # Homebrew keg (opt/<formula>, never a stale Cellar version), and rewrite the
  # reference, until nothing changes.
  keg_lib() {
    local d hit
    for d in "$BREW_PREFIX"/opt/*/lib; do
      hit="$(find -L "$d" -name "$1" -type f 2>/dev/null | head -1)"
      [ -n "$hit" ] && { echo "$hit"; return 0; }
    done
    return 1
  }
  UNRESOLVED=()
  changed=1
  while [ "$changed" = 1 ]; do
    changed=0
    for lib in "$SDIR/siril" "$SDIR/libs"/*.dylib; do
      [ -f "$lib" ] || continue
      for ref in $(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -E '\.dylib$'); do
        case "$ref" in /usr/lib/*|/System/*) continue;; esac
        base="$(basename "$ref")"
        if [ ! -f "$SDIR/libs/$base" ]; then
          if ! src="$(keg_lib "$base")"; then
            case " ${UNRESOLVED[*]-} " in *" $base "*) ;; *) UNRESOLVED+=("$base");; esac
            continue
          fi
          cp -Lf "$src" "$SDIR/libs/$base"; chmod u+w "$SDIR/libs/$base"
          install_name_tool -id "@executable_path/libs/$base" "$SDIR/libs/$base" 2>/dev/null
          changed=1
        fi
        case "$ref" in @executable_path/libs/*) ;;
          *) install_name_tool -change "$ref" "@executable_path/libs/$base" "$lib" 2>/dev/null;; esac
      done
    done
  done
  # A missing library is a broken Siril whatever the build type.
  [ "${#UNRESOLVED[@]}" = 0 ] \
    || die "Siril dependency closure incomplete — no Homebrew keg provides: ${UNRESOLVED[*]}"
  # dyld rejects a Mach-O with a duplicate LC_RPATH — collapse to exactly one
  # @executable_path/libs/, and drop any absolute rpath back into Homebrew so
  # nothing can resolve outside the app on a Mac that happens to have it.
  for lib in "$SDIR/siril" "$SDIR/libs"/*.dylib; do
    while IFS= read -r r; do
      case "$r" in
        /usr/lib/*|/System/*|@*|"") ;;
        /*) while install_name_tool -delete_rpath "$r" "$lib" 2>/dev/null; do :; done;;
      esac
    done <<< "$(rpaths "$lib" | sort -u)"
    while install_name_tool -delete_rpath '@executable_path/libs/' "$lib" 2>/dev/null; do :; done
    install_name_tool -add_rpath '@executable_path/libs/' "$lib" 2>/dev/null
  done
  sign "$SDIR/libs"/*.dylib
  sign "$SDIR/siril"
  NLIBS="$(find "$SDIR/libs" -name '*.dylib' | wc -l | tr -d ' ')"
  echo "  · bundled Siril $SIRIL_VER + $NLIBS dylibs"
fi

# ── Licence texts (GPL-3.0 §4/§6, MIT, BSD-3, every bundled dylib's) ────────
echo "▸ licences"
cp "$HERE/LICENSE" "$LIC/LICENSE.txt"
cp "$HERE/NOTICES.md" "$LIC/NOTICES.md"
mkdir -p "$LIC/onnxruntime"
cp "$HERE/docs/licenses/onnxruntime/LICENSE" "$HERE/docs/licenses/onnxruntime/ThirdPartyNotices.txt" "$LIC/onnxruntime/"
if [ "$HAVE_SR" = 1 ]; then
  mkdir -p "$LIC/Real-ESRGAN"; cp "$HERE/docs/licenses/Real-ESRGAN/LICENSE" "$LIC/Real-ESRGAN/"
fi
if [ "$HAVE_SIRIL" = 1 ]; then
  # Formula + exact version + licence + source URL/SHA-256 for every bundled
  # binary, and each formula's licence texts. --strict exits non-zero (after
  # writing everything) if anything can't be attributed.
  bash "$HERE/scripts/gen-notices.sh" --strict --licenses "$LIC/homebrew" \
    --fallback-licenses "$HERE/docs/licenses/homebrew" "$SDIR" "$LIC/NOTICES-bundled.txt" \
    || problem "licence inventory incomplete (see the gen-notices lines above)"
fi
cat > "$LIC/README.txt" <<'TXT'
Nebula is free software under the GNU General Public License v3.0 (LICENSE.txt).

  LICENSE.txt           Nebula's licence (GPL-3.0)
  NOTICES.md            third-party components, and where to get the source code
  NOTICES-bundled.txt   every bundled Siril binary/library → formula, version, licence, source
  onnxruntime/          onnxruntime (MIT) + its third-party notices (linked into Nebula)
  Real-ESRGAN/          licence of the bundled AI enlargement model (BSD-3-Clause)
  homebrew/<formula>/   licence texts of Siril and each bundled library
TXT
echo "  · $(find "$LIC" -type f | wc -l | tr -d ' ') licence/notice files in Contents/Resources/Licenses"

# Only claim the macOS the bundle can actually run on. Homebrew bottles are
# built for the build Mac's OS, so the bundled Siril closure usually needs a
# newer macOS than the Swift code does; dyld refuses to load it below that.
# Take the highest deployment target (LC_BUILD_VERSION minos) of any Mach-O.
MIN_OS="$(find "$APP/Contents" -type f -exec vtool -show-build {} \; 2>/dev/null \
  | awk '$1 == "minos" { print $2 }' | sort -V | tail -1)"
MIN_OS="${MIN_OS:-14.0}"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_OS" "$APP/Contents/Info.plist"
echo "  · minimum macOS $MIN_OS (highest deployment target in the bundle)"

# Dropbox/File Provider attaches resource-fork-like metadata inside a freshly
# assembled bundle. Strip it before signing and once more afterwards in case it
# races the signer; the latter does not alter signed file contents.
xattr -cr "$APP" 2>/dev/null || true
# Inside-out: any framework first, then the app bundle (which signs the main
# executable and seals every resource, including the already-signed Siril tree).
if [ -d "$APP/Contents/Frameworks/onnxruntime.framework" ]; then
  sign "$APP/Contents/Frameworks/onnxruntime.framework"
fi
sign "$APP"
xattr -cr "$APP" 2>/dev/null || true

echo "▸ verifying"
VB=()
if [ -n "$SIGN_ID" ]; then
  VB=(--release); [ -n "$TEAM_ID" ] && VB+=(--team "$TEAM_ID")
fi
bash "$HERE/scripts/verify-bundle.sh" "${VB[@]+"${VB[@]}"}" "$APP"

echo
if [ -n "$SIGN_ID" ]; then SIGNED="Developer ID ($SIGN_ID), hardened runtime, timestamped — not yet notarised"
else SIGNED="ad-hoc (set NEBULA_SIGN_ID for a notarisable build)"; fi
echo "✓ built $APP"
echo "    version      $VERSION · minimum macOS $MIN_OS · $(du -sh "$APP" | awk '{print $1}')"
echo "    Siril        $SIRIL_VER · $NLIBS dylibs"
echo "    onnxruntime  $ORT"
echo "    enlargement  $([ "$HAVE_SR" = 1 ] && echo "Real-ESRGAN x2 bundled" || echo "NOT bundled")"
echo "    signed       $SIGNED"
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo "  ${#WARNINGS[@]} warning(s) — fatal in a release build:"
  for w in "${WARNINGS[@]}"; do echo "    ! $w"; done
fi

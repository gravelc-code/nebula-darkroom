#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Verify a built Nebula.app: dependency closure + every Mach-O's signature.
#
#   scripts/verify-bundle.sh [--release] [--team TEAMID] <Nebula.app>
#
# Why per file: Siril and its ~94 dylibs live under Contents/Resources (the
# app locates it at Resources/siril/siril), where `codesign --verify --deep`
# treats them as sealed *data* — it checks their bytes, never their own
# signatures. The notary service does check them, so we do too, one by one.
#
# Always (exit 1 on any failure):
#   · closure: every load command of every Mach-O resolves inside the bundle or
#     to the OS (/usr/lib, /System); no LC_RPATH points outside the bundle
#     (e.g. /opt/homebrew or a toolchain inside Xcode.app)
#   · every Mach-O has a valid signature (`codesign --verify --strict`), and
#     the app passes `codesign --verify --deep --strict`
# With --release (a Developer ID build), every Mach-O additionally needs:
#   · the hardened runtime flag      · a secure timestamp
#   · a "Developer ID Application" authority
#   · the same Team ID (--team, else the app's own)
set -euo pipefail

RELEASE=0 TEAM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --release) RELEASE=1; shift;;
    --team) TEAM="${2:?--team needs a Team ID}"; shift 2;;
    -h|--help) sed -n '4,21p' "$0"; exit 0;;
    -*) echo "verify-bundle: unknown option $1" >&2; exit 2;;
    *) break;;
  esac
done
APP="${1:?usage: verify-bundle.sh [--release] [--team TEAMID] <Nebula.app>}"
APP="$(cd "$APP" && pwd)"
MAIN_DIR="$APP/Contents/MacOS"
SIRIL_DIR="$APP/Contents/Resources/siril"

fails=0
fail() { echo "  ✗ $*" >&2; fails=$((fails + 1)); }

# Every Mach-O image (executables + dylibs; static archives are not loadable).
MACHOS=()
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in
    *"ar archive"*) fail "${f#"$APP"/}: static archive in the bundle (dead weight; never loadable)";;
    Mach-O*) MACHOS+=("$f");;
  esac
done < <(find "$APP/Contents" -type f -print0)
[ "${#MACHOS[@]}" -gt 0 ] || { echo "verify-bundle: no Mach-O files in $APP" >&2; exit 1; }

rpaths() { otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" {getline; getline; print $2}'; }

# ── 1. dependency closure ──────────────────────────────────────────────────
for f in "${MACHOS[@]}"; do
  rel="${f#"$APP"/}"
  # @executable_path is the main executable of the process that loads f:
  # Siril's tree runs as its own process from Resources/siril.
  case "$f" in "$SIRIL_DIR"/*) exe_dir="$SIRIL_DIR";; *) exe_dir="$MAIN_DIR";; esac
  loader_dir="$(dirname "$f")"
  own_id="$(otool -D "$f" | sed -n 2p)"
  rp="$(rpaths "$f")"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    case "$r" in
      /usr/lib/*|/System/*|@executable_path*|@loader_path*) ;;
      *) fail "$rel: LC_RPATH outside the bundle: $r";;
    esac
  done <<< "$rp"
  while IFS= read -r dep; do
    [ -n "$dep" ] && [ "$dep" != "$own_id" ] || continue
    case "$dep" in
      /usr/lib/*|/System/*) ;;   # the OS (dyld shared cache)
      @executable_path/*) [ -e "$exe_dir/${dep#@executable_path/}" ] || fail "$rel: missing $dep";;
      @loader_path/*) [ -e "$loader_dir/${dep#@loader_path/}" ] || fail "$rel: missing $dep";;
      @rpath/*)
        ok=0 leaf="${dep#@rpath/}"
        while IFS= read -r r; do
          case "$r" in
            /usr/lib/swift*) case "$leaf" in libswift*) ok=1;; esac;;
            @executable_path*) [ -e "$exe_dir${r#@executable_path}/$leaf" ] && ok=1;;
            @loader_path*) [ -e "$loader_dir${r#@loader_path}/$leaf" ] && ok=1;;
          esac
        done <<< "$rp"
        [ "$ok" = 1 ] || fail "$rel: $dep does not resolve inside the bundle";;
      *) fail "$rel: links outside the bundle: $dep";;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done
[ "$fails" = 0 ] && echo "  · closure complete: ${#MACHOS[@]} Mach-O files, every dependency inside the bundle or the OS"

# ── 2. signatures, one Mach-O at a time ───────────────────────────────────
if [ "$RELEASE" = 1 ] && [ -z "$TEAM" ]; then
  TEAM="$(codesign -dvv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
  case "$TEAM" in ""|"not set") fail "app has no Team ID (not Developer ID signed)"; TEAM="";; esac
fi
sig_fails=$fails
for f in "${MACHOS[@]}"; do
  rel="${f#"$APP"/}"
  if ! out="$(codesign --verify --strict "$f" 2>&1)"; then
    fail "$rel: invalid signature: $out"; continue
  fi
  [ "$RELEASE" = 1 ] || continue
  info="$(codesign -dvv "$f" 2>&1)"
  grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\([^)]*runtime' <<< "$info" || fail "$rel: no hardened runtime"
  grep -q '^Timestamp=' <<< "$info" || fail "$rel: no secure timestamp"
  grep -q '^Authority=Developer ID Application:' <<< "$info" || fail "$rel: not signed with a Developer ID Application certificate"
  t="$(awk -F= '/^TeamIdentifier=/ {print $2}' <<< "$info")"
  [ -z "$TEAM" ] || [ "$t" = "$TEAM" ] || fail "$rel: Team ID $t ≠ $TEAM"
done
if ! out="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
  fail "app bundle seal: $out"
fi
if [ "$fails" = "$sig_fails" ]; then
  if [ "$RELEASE" = 1 ]; then
    echo "  · signatures: ${#MACHOS[@]}/${#MACHOS[@]} valid · hardened runtime · timestamped · Developer ID (team $TEAM)"
  else
    echo "  · signatures: ${#MACHOS[@]}/${#MACHOS[@]} valid (+ app seal)"
  fi
fi

if [ "$fails" -gt 0 ]; then
  echo "✗ verify-bundle: $fails problem(s) in $APP" >&2
  exit 1
fi

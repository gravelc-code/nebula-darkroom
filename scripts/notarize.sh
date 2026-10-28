#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Notarise the built app or DMG and staple the ticket.
#
#   scripts/notarize.sh app    # zip build/Nebula.app, submit, wait, staple the app
#   scripts/notarize.sh dmg    # submit build/Nebula.dmg, wait, staple, Gatekeeper-verify
#
# Both artefacts are stapled so the app keeps working offline after being
# copied out of the DMG. Full release order (docs/RELEASING.md):
#   NEBULA_SIGN_ID=… scripts/build-app.sh → notarize.sh app → build-dmg.sh → notarize.sh dmg
#
# Team ID: NEBULA_TEAM_ID, else parsed from NEBULA_SIGN_ID
# ("Developer ID Application: Name (TEAMID)"). It is checked against the
# artefact's signature before anything is uploaded.
#
# Credentials come from a notarytool keychain profile (NEBULA_NOTARY_PROFILE,
# default "nebula-notary"). Create it once — interactively, so the app-specific
# password never lands in shell history or scripts:
#   xcrun notarytool store-credentials nebula-notary \
#     --apple-id <your-apple-id-email> --team-id <your-team-id>
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${NEBULA_NOTARY_PROFILE:-nebula-notary}"
WHAT="${1:-}"
case "$WHAT" in app|dmg) ;; *) echo "usage: notarize.sh app|dmg" >&2; exit 2;; esac

TEAM_ID="${NEBULA_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ -n "${NEBULA_SIGN_ID:-}" ]; then
  TEAM_ID="$(sed -nE 's/.*\(([A-Z0-9]{10})\)[[:space:]]*$/\1/p' <<< "$NEBULA_SIGN_ID")"
fi
if [ -z "$TEAM_ID" ]; then
  echo "error: no Team ID. Set NEBULA_TEAM_ID to your 10-character Apple Developer Team ID" >&2
  echo "       (or NEBULA_SIGN_ID=\"Developer ID Application: Your Name (TEAMID)\")." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Validate *this* profile, not just "some notarytool item exists": a read-only
# query of past submissions fails fast on a missing/expired profile.
if ! xcrun notarytool history --keychain-profile "$PROFILE" --output-format json \
     >/dev/null 2>"$WORK/history.err"; then
  echo "error: notarytool keychain profile \"$PROFILE\" is missing or not usable:" >&2
  sed 's/^/  /' "$WORK/history.err" >&2
  echo "Create it once (interactive — the app-specific password stays out of shell history):" >&2
  echo "  xcrun notarytool store-credentials \"$PROFILE\" --apple-id <your-apple-id-email> --team-id $TEAM_ID" >&2
  exit 1
fi

team_of() { codesign -dvv "$1" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}'; }

submit() {  # submit <file> — waits; on anything but Accepted prints the full reason + log
  local file="$1" rc=0 status id
  echo "▸ submitting $(basename "$file") for notarisation (usually a few minutes)…"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json \
    >"$WORK/submit.json" 2>"$WORK/submit.err" || rc=$?
  status="$(plutil -extract status raw -o - "$WORK/submit.json" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$WORK/submit.json" 2>/dev/null || true)"
  [ -z "$id" ] || echo "  submission $id: ${status:-unknown}"
  if [ "$rc" = 0 ] && [ "$status" = "Accepted" ]; then return 0; fi
  echo "✗ notarisation failed (notarytool exit $rc, status ${status:-none})" >&2
  if [ -s "$WORK/submit.json" ]; then echo "--- notarytool response:" >&2; cat "$WORK/submit.json" >&2; echo >&2; fi
  if [ -s "$WORK/submit.err" ]; then echo "--- notarytool stderr:" >&2; cat "$WORK/submit.err" >&2; fi
  if [ -n "$id" ]; then
    echo "--- notary log for $id (lists each rejected file and why):" >&2
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 \
      || echo "  (log not available yet — retry: xcrun notarytool log $id --keychain-profile $PROFILE)" >&2
  fi
  exit 1
}

case "$WHAT" in
  app)
    APP="$HERE/build/Nebula.app"
    [ -d "$APP" ] || { echo "error: $APP not built — run NEBULA_SIGN_ID=… scripts/build-app.sh" >&2; exit 1; }
    # Preflight locally what the notary service would reject remotely:
    # every Mach-O (incl. Siril's under Resources) Developer ID + hardened
    # runtime + timestamp + this team, and a complete dependency closure.
    echo "▸ preflight"
    bash "$HERE/scripts/verify-bundle.sh" --release --team "$TEAM_ID" "$APP"
    ZIP="$WORK/Nebula.zip"
    # ditto preserves the bundle structure + signatures the notary service checks.
    ditto -c -k --keepParent "$APP" "$ZIP"
    submit "$ZIP"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    echo "▸ Gatekeeper assessment:"
    spctl --assess --type execute -vv "$APP"
    echo "✓ $APP notarised and stapled — now run scripts/build-dmg.sh, then notarize.sh dmg"
    ;;
  dmg)
    DMG="$HERE/build/Nebula.dmg"
    [ -f "$DMG" ] || { echo "error: $DMG not built — run scripts/build-dmg.sh" >&2; exit 1; }
    codesign --verify --strict "$DMG" \
      || { echo "error: $DMG is not validly signed — rebuild it with NEBULA_SIGN_ID set" >&2; exit 1; }
    t="$(team_of "$DMG")"
    [ "$t" = "$TEAM_ID" ] || { echo "error: $DMG is signed by team '${t:-none}', expected $TEAM_ID" >&2; exit 1; }
    submit "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "▸ Gatekeeper assessment:"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
    echo "✓ $DMG notarised, stapled, and accepted by Gatekeeper"
    ;;
esac

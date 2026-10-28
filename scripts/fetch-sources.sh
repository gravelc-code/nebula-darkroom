#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Collect the Corresponding Source for every third-party binary bundled in
# Nebula.app (Siril + its Homebrew dylib closure), for attaching to the GitHub
# release next to the DMG (GPL-3.0 §6(d) / LGPL-2.1 §6: equivalent access to
# the source from the same place). See NOTICES.md and docs/RELEASING.md.
#
#   scripts/fetch-sources.sh [--app build/Nebula.app] [--out build/sources]
#                            [--only formula[,formula…]] [--no-tar]
#
# For each formula the bundle was built from (attributed by gen-notices.sh via
# LC_UUID, so the *installed* version — not whatever the tap says today):
#   <out>/<formula>-<version>/
#       <upstream source archive>   from the keg's SBOM, SHA-256 verified
#                                   (git-sourced formulae: `git archive` of the
#                                   pinned revision)
#       patches/                    every Homebrew patch, SHA-256 verified
#       <formula>.rb                the Homebrew build recipe as installed
#                                   (build/install scripts + inline patches)
#       licence files
# plus SHA256SUMS, the inventory, and a single uncompressed tarball
#   build/Nebula-<version>-third-party-sources.tar   ← attach to the release
#
# Re-runs are incremental: files already present with the right hash are kept.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/Nebula.app" OUT="$HERE/build/sources" ONLY="" TAR=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:?}"; shift 2;;
    --out) OUT="${2:?}"; shift 2;;
    --only) ONLY="${2:?}"; shift 2;;
    --no-tar) TAR=0; shift;;
    -h|--help) sed -n '4,26p' "$0"; exit 0;;
    *) echo "fetch-sources: unknown argument $1" >&2; exit 2;;
  esac
done
SIRIL_DIR="$APP/Contents/Resources/siril"
[ -d "$SIRIL_DIR" ] || { echo "error: no bundled Siril in $APP — run scripts/build-app.sh first" >&2; exit 1; }
for tool in brew curl git shasum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found" >&2; exit 1; }
done
export HOMEBREW_NO_AUTO_UPDATE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

echo "▸ attributing bundled binaries to Homebrew kegs"
bash "$HERE/scripts/gen-notices.sh" --json "$WORK/inventory.json" \
  --fallback-licenses "$HERE/docs/licenses/homebrew" \
  "$SIRIL_DIR" "$WORK/NOTICES-bundled.txt" 2>/dev/null || true   # problems are re-checked below

# Emit one job per formula; refuse anything not UUID-verified —
# fetching the *current* keg's source for an older binary would be wrong.
/usr/bin/python3 -I - "$WORK/inventory.json" "$ONLY" > "$WORK/jobs" <<'PY'
import json, sys
inv = json.load(open(sys.argv[1]))
only = {x for x in sys.argv[2].split(",") if x}
bad = [b for b in inv["binaries"] if b["match"] != "uuid" and (not only or b["formula"] in only)]
if bad:
    for b in bad:
        print(f"error: {b['file']} is not UUID-matched to an installed keg ({b['formula']} "
              f"{b['version']}) — rebuild the app from the current Homebrew kegs first",
              file=sys.stderr)
    sys.exit(1)
names = {f["name"] for f in inv["formulae"]}
if only - names:
    sys.exit(f"error: not in the bundle: {', '.join(sorted(only - names))}")
for f in inv["formulae"]:
    if only and f["name"] not in only:
        continue
    s = f["source"] or {}
    patches = " ".join(f"{p['url']}|{p['sha256'] or ''}" for p in f["patches"])
    print("\x1f".join([f["name"], f["version"], s.get("url") or "", s.get("sha256") or "",
                     s.get("revision") or "", f["formula_file"] or "",
                     "|".join(f["licence_files"]), patches, " ".join(s.get("mirrors") or [])]))
PY

verify() {  # verify <file> <sha256>
  [ "$(shasum -a 256 "$1" | awk '{print $1}')" = "$2" ]
}
download() {  # download <dest> <sha256> <url> [mirror…] — first URL whose bytes match wins
  local dest="$1" sha="$2" url; shift 2
  if [ -f "$dest" ] && { [ -z "$sha" ] || verify "$dest" "$sha"; }; then
    echo "    = $(basename "$dest")"; return 0
  fi
  for url in "$@"; do
    if curl -fsSL --retry 3 -o "$dest.part" "$url" 2>"$WORK/curl.err" \
       && { [ -z "$sha" ] || verify "$dest.part" "$sha"; }; then
      mv "$dest.part" "$dest"; echo "    ↓ $(basename "$dest")${sha:+ (sha256 ok)}"
      [ -n "$sha" ] || echo "    ! no SHA-256 recorded for $url — kept unverified" >&2
      return 0
    fi
    echo "    ! $url: $(head -1 "$WORK/curl.err" 2>/dev/null || echo 'SHA-256 mismatch')" >&2
    rm -f "$dest.part"
  done
  # A dead upstream host must not block a release: any copy with the recorded
  # hash is the same source, so a manual drop-in is accepted on re-run.
  echo "error: could not fetch $(basename "$dest"). Download it by any means into" >&2
  echo "       $dest  (SHA-256 ${sha:-unrecorded}) and re-run." >&2
  exit 1
}

n=0
# \x1f separator: IFS whitespace (tab) would merge empty fields.
while IFS=$'\x1f' read -r name version url sha rev rb licences patches mirrors; do
  n=$((n + 1))
  dir="$OUT/$name-$version"
  echo "  · $name $version"
  mkdir -p "$dir"
  if [ -n "$sha" ]; then
    read -r -a murls <<< "$mirrors"
    download "$dir/$(basename "${url%%\?*}")" "$sha" "$url" "${murls[@]+"${murls[@]}"}"
  elif [ -n "$rev" ]; then
    # git-sourced formula: the commit hash is the source's identity.
    arc="$dir/$name-$version-${rev:0:12}.tar.gz"
    if [ ! -f "$arc" ]; then
      g="$WORK/git-$name"; rm -rf "$g"; git init -q "$g"
      git -C "$g" fetch -q --depth 1 "$url" "$rev" 2>/dev/null \
        || git -C "$g" fetch -q "$url"   # servers that refuse fetch-by-SHA
      git -C "$g" archive --format=tar.gz --prefix="$name-$version/" -o "$arc.part" "$rev"
      mv "$arc.part" "$arc"; echo "    ↓ $(basename "$arc") (git $rev)"
    else
      echo "    = $(basename "$arc")"
    fi
  else
    echo "error: $name $version has no recorded source archive — fetch it manually into $dir" >&2
    exit 1
  fi
  if [ -n "$patches" ]; then
    mkdir -p "$dir/patches"; i=0
    read -r -a parr <<< "$patches"     # no globbing of '?' in URLs
    for p in "${parr[@]}"; do
      i=$((i + 1))
      purl="${p%%|*}"
      download "$dir/patches/$(printf %02d "$i")-$(basename "${purl%%\?*}")" "${p##*|}" "$purl"
    done
  fi
  if [ -n "$rb" ] && [ -f "$rb" ]; then
    cp -f "$rb" "$dir/$name.rb"
    # Resources declared before `test do` are build inputs the SBOM omits.
    if awk '/^[[:space:]]*test do/{exit} /^[[:space:]]*resource "/{found=1} END{exit !found}' "$rb"; then
      echo "    ! $name.rb declares build resources — fetch them with: brew fetch -s --retry $name" >&2
    fi
  fi
  IFS='|' read -r -a lics <<< "$licences"
  for l in "${lics[@]+"${lics[@]}"}"; do
    if [ -n "$l" ]; then cp -f "$l" "$dir/"; fi
  done
done < "$WORK/jobs"

cp "$WORK/NOTICES-bundled.txt" "$WORK/inventory.json" "$OUT/"
cat > "$OUT/README.txt" <<'TXT'
Corresponding Source for the third-party binaries bundled in Nebula.app
(Contents/Resources/siril): Siril and its Homebrew dependency closure.

Each <formula>-<version>/ directory holds the unmodified upstream source
archive the shipped binary was built from, every patch Homebrew applied
(patches/), and the Homebrew formula (<formula>.rb) — the build and install
recipe, including any inline patches after its __END__ marker. Rebuild a
component with Homebrew from that formula, or follow the formula's install
steps by hand. NOTICES-bundled.txt maps every bundled binary to its formula,
version and licence; SHA256SUMS covers every file here.

Nebula's own source is the matching tag of its public repository (see NOTICES.md).
TXT
( cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name '*.part' | LC_ALL=C sort \
    | sed 's|^\./||' | tr '\n' '\0' | xargs -0 shasum -a 256 > SHA256SUMS )
echo "✓ sources for $n formulae in $OUT ($(du -sh "$OUT" | awk '{print $1}'))"

if [ "$TAR" = 1 ] && [ -z "$ONLY" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo dev)"
  TARBALL="$(dirname "$OUT")/Nebula-$VERSION-third-party-sources.tar"
  tar -cf "$TARBALL" -C "$(dirname "$OUT")" "$(basename "$OUT")"
  echo "✓ $TARBALL ($(du -h "$TARBALL" | awk '{print $1}')) — attach it to the GitHub release"
fi

#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Nebula contributors
# Licence + source inventory for the bundled Siril tree (binary + dylib closure).
#
#   gen-notices.sh [--strict] [--json FILE] [--licenses DIR] [--fallback-licenses DIR]
#                  <bundle-dir> <out.txt>
#
# <bundle-dir> is searched recursively for Mach-O files (e.g. Resources/siril:
# the `siril` binary + libs/*.dylib). Each one is attributed to the Homebrew
# keg it was copied from by matching basename AND LC_UUID (install_name_tool
# and re-signing never change the UUID), so the formula *and exact installed
# version* are proven, not guessed — aliases (pzstd → zstd) and nested lib dirs
# (gcc's lib/gcc/current) resolve correctly. Per-formula licence and the exact
# source archive + patches (URL + SHA-256) come from the keg's own
# sbom.spdx.json, i.e. what was actually installed, independent of tap state.
#
#   <out.txt>        human-readable table (binary · formula · version · licence)
#   --json FILE      machine-readable inventory, consumed by fetch-sources.sh
#   --licenses DIR   copy each formula's licence files to DIR/<formula>/
#   --fallback-licenses DIR
#                    DIR/<formula>/* is used for a keg that installs no licence
#                    file (cfitsio) — see docs/licenses/README.md
#   --strict         exit 1 unless every binary is UUID-verified and every
#                    formula has a source URL + SHA-256 and a licence text
#                    (build-app.sh uses this for release builds)
set -euo pipefail

STRICT=0 JSON="" LICDIR="" FALLBACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift;;
    --json) JSON="${2:?--json needs a file}"; shift 2;;
    --licenses) LICDIR="${2:?--licenses needs a dir}"; shift 2;;
    --fallback-licenses) FALLBACK="${2:?--fallback-licenses needs a dir}"; shift 2;;
    -h|--help) sed -n '4,25p' "$0"; exit 0;;
    -*) echo "gen-notices: unknown option $1" >&2; exit 2;;
    *) break;;
  esac
done
BUNDLE="${1:?usage: gen-notices.sh [--strict] [--json FILE] [--licenses DIR] <bundle-dir> <out.txt>}"
OUT="${2:?usage: gen-notices.sh [--strict] [--json FILE] [--licenses DIR] <bundle-dir> <out.txt>}"
command -v brew >/dev/null 2>&1 || { echo "gen-notices: Homebrew (brew) not found" >&2; exit 1; }
BREW_PREFIX="$(brew --prefix)"
BREW_CELLAR="$(brew --cellar)"
BREW_VERSION="$(brew --version 2>/dev/null | head -1)"

/usr/bin/python3 -I - "$BUNDLE" "$OUT" "$JSON" "$LICDIR" "$STRICT" \
  "$BREW_PREFIX" "$BREW_CELLAR" "$BREW_VERSION" "$FALLBACK" <<'PY'
import datetime, glob, json, os, re, shutil, struct, subprocess, sys

bundle, out_path, json_path, lic_dir, strict, prefix, cellar, brew_ver, fallback = sys.argv[1:10]
strict = strict == "1"

# ── Mach-O identity ────────────────────────────────────────────────────────
MAGIC_THIN = {0xfeedfacf: "<", 0xcffaedfe: ">", 0xfeedface: "<", 0xcefaedfe: ">"}
def uuids(path):
    """Set of LC_UUIDs in a thin or fat Mach-O (empty if not Mach-O)."""
    try:
        with open(path, "rb") as f:
            data = f.read(1 << 16)
            head = data[:8]
            if len(head) < 8:
                return set()
            (magic_be,) = struct.unpack(">I", head[:4])
            if magic_be in (0xcafebabe, 0xcafebabf):  # fat (32/64-bit arch table)
                n = struct.unpack(">I", head[4:8])[0]
                size = 20 if magic_be == 0xcafebabe else 32
                out = set()
                for i in range(min(n, 16)):
                    ent = data[8 + i * size: 8 + (i + 1) * size]
                    off = struct.unpack(">I", ent[8:12])[0] if size == 20 else struct.unpack(">Q", ent[8:16])[0]
                    out |= _thin_uuids(f, off)
                return out
            return _thin_uuids(f, 0)
    except OSError:
        return set()

def _thin_uuids(f, off):
    f.seek(off)
    hdr = f.read(32)
    if len(hdr) < 28:
        return set()
    (m,) = struct.unpack("<I", hdr[:4])
    if m not in MAGIC_THIN:
        return set()
    e = MAGIC_THIN[m]
    is64 = m in (0xfeedfacf, 0xcffaedfe)
    ncmds, sizeofcmds = struct.unpack(e + "II", hdr[16:24])
    f.seek(off + (32 if is64 else 28))
    cmds = f.read(sizeofcmds)
    p, out = 0, set()
    for _ in range(ncmds):
        if p + 8 > len(cmds):
            break
        cmd, size = struct.unpack(e + "II", cmds[p:p + 8])
        if cmd == 0x1b and size >= 24:  # LC_UUID
            out.add(cmds[p + 8:p + 24].hex())
        if size < 8:
            break
        p += size
    return out

def is_macho(path):
    try:
        with open(path, "rb") as f:
            m, n = struct.unpack(">II", f.read(8))
        if m in (0xcafebabe, 0xcafebabf):
            return n < 20  # a fat arch count, not a Java class version
        return m in (0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe)
    except (OSError, struct.error):
        return False

# ── What's bundled ─────────────────────────────────────────────────────────
bundled = []
for root, _, files in os.walk(bundle):
    for name in files:
        p = os.path.join(root, name)
        if not os.path.islink(p) and is_macho(p):
            bundled.append(p)
bundled.sort(key=lambda p: (os.path.basename(p) != "siril", os.path.basename(p).lower()))
if not bundled:
    sys.exit(f"gen-notices: no Mach-O files under {bundle}")
wanted = {os.path.basename(p) for p in bundled}

# ── Index the installed kegs: Cellar/<formula>/<version>/{lib/**,bin/*} ────
current = {os.path.realpath(p) for p in glob.glob(os.path.join(prefix, "opt", "*"))}
cands = {}  # basename → [(keg, path)]
for keg in glob.glob(os.path.join(cellar, "*", "*")):
    if not os.path.isdir(keg):
        continue
    for sub in ("lib", "bin"):
        d = os.path.join(keg, sub)
        for root, dirs, files in os.walk(d):
            # skip huge irrelevant trees (python site-packages, perl, etc.)
            dirs[:] = [x for x in dirs if not x.startswith(("python", "perl", "node_modules"))]
            for name in files:
                if name in wanted:
                    cands.setdefault(name, []).append((keg, os.path.join(root, name)))

def keg_of(keg):
    rel = os.path.relpath(keg, cellar).split(os.sep)
    return rel[0], rel[1]  # formula, pkg version (incl. _revision)

rows, problems = [], []
for p in bundled:
    base, have = os.path.basename(p), uuids(p)
    hits = cands.get(base, [])
    exact = [(k, c) for k, c in hits if have and (uuids(os.path.realpath(c)) & have)]
    pick, how = None, "none"
    if exact:
        pick = next((k for k, _ in exact if k in current), exact[0][0]); how = "uuid"
    elif hits:
        pick = next((k for k, _ in hits if k in current), hits[0][0]); how = "name"
    rel = os.path.relpath(p, bundle)
    if pick:
        f, v = keg_of(pick)
        rows.append({"file": rel, "formula": f, "version": v, "keg": pick, "match": how})
        if how != "uuid":
            problems.append(f"{rel}: not UUID-verified (matched by name to {f} {v}; keg upgraded since the build?)")
    else:
        rows.append({"file": rel, "formula": "unknown", "version": "?", "keg": None, "match": how})
        problems.append(f"{rel}: no Homebrew keg ships this file")

# ── Per-formula metadata from each keg's own SBOM ──────────────────────────
# Licence files at the keg root: the classic names, plus REUSE-style SPDX-named
# texts (glib ships only "LGPL-2.1-or-later.txt").
LIC_RE = re.compile(r"^(LICEN[CS]E|COPYING|COPYRIGHT|NOTICE|UNLICENSE|PATENTS)"
                    r"|^(A?GPL|LGPL|GPL|MIT|BSD|Apache|MPL|ISC|Zlib|BSL|CC0|Unicode|OFL)"
                    r"[-.\w]*\.(txt|md)$", re.I)

def mirrors(rb_path, url):
    """`mirror` URLs listed with the formula's stable url (same SHA-256)."""
    try:
        text = open(rb_path).read()
    except (OSError, TypeError):
        return []
    m = re.search(r'url\s+"' + re.escape(url) + r'"[^\n]*\n((?:[ \t]*(?:mirror|sha256|version)\s+"[^"]*"[^\n]*\n)*)', text)
    return re.findall(r'mirror\s+"([^"]+)"', m.group(1)) if m else []

def git_pin(rb_path, url):
    """For a git-sourced formula (no tarball SHA), the tag/revision its stable
    `url` pins — the commit hash is the source's cryptographic identity."""
    try:
        text = open(rb_path).read()
    except (OSError, TypeError):
        return {}
    m = re.search(r'url\s+"' + re.escape(url) + r'"(?P<args>(?:\s*,\s*\w+:\s*"[^"]*")*)', text)
    if not m:
        return {}
    args = dict(re.findall(r'(\w+):\s*"([^"]*)"', m.group("args")))
    return {k: args[k] for k in ("tag", "revision") if k in args}
formulae = {}
for r in rows:
    if not r["keg"] or r["keg"] in formulae:
        continue
    keg = r["keg"]; name, ver = keg_of(keg)
    info = {"name": name, "version": ver, "keg": keg, "licence": None,
            "source": None, "patches": [], "formula_file": None, "licence_files": []}
    rb = os.path.join(keg, ".brew", name + ".rb")
    info["formula_file"] = rb if os.path.isfile(rb) else None
    sbom = os.path.join(keg, "sbom.spdx.json")
    if os.path.isfile(sbom):
        with open(sbom) as fh:
            doc = json.load(fh)
        for pkg in doc.get("packages", []):
            sid = pkg.get("SPDXID", "")
            sha = next((c["checksumValue"] for c in pkg.get("checksums", [])
                        if c.get("algorithm") == "SHA256"), None)
            loc = pkg.get("downloadLocation")
            if sid.startswith("SPDXRef-Archive-"):
                lic = pkg.get("licenseConcluded")
                if not lic or lic == "NOASSERTION":
                    lic = pkg.get("licenseDeclared")
                info["licence"] = None if lic in (None, "NOASSERTION") else lic
                info["source"] = {"url": loc, "sha256": sha or None,
                                  "mirrors": mirrors(info["formula_file"], loc)}
                if not sha and loc:
                    info["source"].update(git_pin(info["formula_file"], loc))
            elif sid.startswith("SPDXRef-Patch-"):
                info["patches"].append({"url": loc, "sha256": sha})
    files = [os.path.join(keg, x) for x in sorted(os.listdir(keg))
             if LIC_RE.match(x) and os.path.isfile(os.path.join(keg, x))]
    if not files:  # some formulae install licences under share/doc/<name>
        for d in (os.path.join(keg, "share", "doc", name), os.path.join(keg, "share", name)):
            if os.path.isdir(d):
                files += [os.path.join(d, x) for x in sorted(os.listdir(d))
                          if LIC_RE.match(x) and os.path.isfile(os.path.join(d, x))]
    if not files and fallback and os.path.isdir(os.path.join(fallback, name)):
        d = os.path.join(fallback, name)  # vendored: the keg installs none
        files = [os.path.join(d, x) for x in sorted(os.listdir(d)) if os.path.isfile(os.path.join(d, x))]
    info["licence_files"] = files
    formulae[keg] = info

missing_lic = [i["name"] for i in formulae.values() if not i["licence"]]
if missing_lic:  # SBOM silent → fall back to the formula's declared licence
    try:
        res = subprocess.run(["brew", "info", "--json=v2", *missing_lic],
                             capture_output=True, text=True, timeout=120)
        for f in json.loads(res.stdout or "{}").get("formulae", []):
            for i in formulae.values():
                if i["name"] == f.get("name") and not i["licence"]:
                    i["licence"] = f.get("license")
    except (subprocess.SubprocessError, ValueError):
        pass

for i in formulae.values():
    n = f"{i['name']} {i['version']}"
    if not i["licence"]:
        problems.append(f"{n}: no declared licence")
    src = i["source"] or {}
    if not str(src.get("url") or "").startswith(("http", "git")) \
            or not (src.get("sha256") or src.get("revision")):
        problems.append(f"{n}: no source URL + SHA-256/git revision recorded (fetch its source manually)")
    if not i["licence_files"]:
        problems.append(f"{n}: keg ships no licence file")

# ── Licence texts ──────────────────────────────────────────────────────────
if lic_dir:
    for i in formulae.values():
        dest = os.path.join(lic_dir, i["name"])
        os.makedirs(dest, exist_ok=True)
        for src in i["licence_files"]:
            shutil.copyfile(src, os.path.join(dest, os.path.basename(src)))

# ── Outputs ────────────────────────────────────────────────────────────────
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
byname = {i["name"]: i for i in formulae.values()}
w = max([len(r["file"]) for r in rows] + [6]) + 2
with open(out_path, "w") as out:
    out.write("Third-party binaries bundled with Nebula: Siril and its Homebrew dependency closure\n")
    out.write(f"(Contents/Resources/siril). Generated {now} by scripts/gen-notices.sh from the\n")
    out.write(f"installed Homebrew kegs ({brew_ver}). Each binary was matched to its keg by\n")
    out.write("LC_UUID, so formula and version are exact. Version is Homebrew's package version;\n")
    out.write("a \"_N\" suffix is the Homebrew formula revision (same upstream source, rebuilt).\n")
    out.write("Licence texts: Licenses/homebrew/<formula>/. Corresponding source: see NOTICES.md,\n")
    out.write("\"Source code for the bundled binaries\".\n\n")
    out.write(f"{'binary':<{w}}{'formula':<22}{'version':<16}licence\n")
    out.write(f"{'------':<{w}}{'-------':<22}{'-------':<16}-------\n")
    for r in rows:
        lic = byname.get(r["formula"], {}).get("licence") or "unknown"
        mark = {"uuid": "", "name": "  [unverified]"}.get(r["match"], "  [not found]")
        out.write(f"{r['file']:<{w}}{r['formula']:<22}{r['version']:<16}{lic}{mark}\n")
    out.write("\nSource archives (exact upstream source + Homebrew patches for each version above):\n\n")
    for i in sorted(formulae.values(), key=lambda i: i["name"]):
        src = i["source"] or {}
        out.write(f"{i['name']} {i['version']}\n  source  {src.get('url') or 'unknown'}\n")
        if src.get("sha256") or not src.get("revision"):
            out.write(f"  sha256  {src.get('sha256') or 'unknown'}\n")
        else:
            tag = f" (tag {src['tag']})" if src.get("tag") else ""
            out.write(f"  git     revision {src['revision']}{tag}\n")
        for pt in i["patches"]:
            out.write(f"  patch   {pt['url']}  (sha256 {pt['sha256']})\n")
if json_path:
    inv = {"generated": now, "homebrew": brew_ver, "homebrew_prefix": prefix,
           "binaries": [{k: r[k] for k in ("file", "formula", "version", "match")} for r in rows],
           "formulae": sorted(formulae.values(), key=lambda i: i["name"]),
           "problems": problems}
    with open(json_path, "w") as fh:
        json.dump(inv, fh, indent=1)

gpl = sum(1 for i in formulae.values() if re.search(r"GPL", i["licence"] or ""))
print(f"  · licence inventory: {len(rows)} binaries from {len(formulae)} formulae "
      f"({gpl} GPL/LGPL), {sum(r['match'] == 'uuid' for r in rows)} UUID-verified")
for msg in problems:
    print(f"  {'✗' if strict else '!'} {msg}", file=sys.stderr)
if strict and problems:
    sys.exit(f"gen-notices: {len(problems)} problem(s) — a release bundle needs every binary attributed")
PY

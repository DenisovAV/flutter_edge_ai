#!/usr/bin/env bash
# verify_tarball_manifest.sh — release gate that catches DROPPED native files.
#
# THE BUG THIS PREVENTS (native-v0.13.1, 1.0.0): rebuilding native for a new
# LiteRT-LM version silently shipped WITHOUT the manually-built NPU add-on
# stacks — android lost 11 Qualcomm/QNN libs, windows lost 12 Intel OpenVino/
# TBB files. `PreferredBackend.npu` broke on both. Nothing caught it: the
# release skill's "dylibs changed?" step diffs a GITIGNORED prebuilt/ dir, and
# the FFI gate only exercises GPU/CPU, never NPU. So the only safety net is
# comparing the NEW tarball's file-list against the LAST PUBLISHED tag.
#
# What it does: for every litertlm-<plat>.tar.gz you are about to publish, it
# downloads the same archive from the previous tag and DIFFS the file lists.
# Any file present in the old tag but MISSING in the new one is a hard FAIL
# (exit 1) — unless explicitly allow-listed via INTENTIONAL_DROPS.
#
# Usage:
#   ./verify_tarball_manifest.sh <DIST_DIR> <PREV_TAG>
#   ./verify_tarball_manifest.sh "$DIST" native-v0.13.1
#
# Intentional removals (e.g. you really meant to drop a lib) go in
# INTENTIONAL_DROPS below, one "plat:filename" per line, with a comment saying
# why. An empty/default list means "nothing may disappear".

set -euo pipefail

DIST_DIR="${1:?usage: verify_tarball_manifest.sh <DIST_DIR> <PREV_TAG>}"
PREV_TAG="${2:?usage: verify_tarball_manifest.sh <DIST_DIR> <PREV_TAG>}"
REPO="${FLUTTER_GEMMA_REPO:-DenisovAV/flutter_edge_ai}"

# Allow-list of files that are INTENTIONALLY removed in this release.
# Format: "<platform>:<basename>" (e.g. "android_arm64:libQnnHtp.so").
# Keep this EMPTY unless you are deliberately dropping a file — every entry
# needs a comment explaining why, so the gate stays meaningful.
INTENTIONAL_DROPS=(
  # native-v0.17.0: #437 stages release TBB only. native-v0.16.0 was packed
  # before it landed and still carried the parallel debug set.
  "windows_x86_64:tbb12_debug.dll"
  "windows_x86_64:tbbbind_2_5_debug.dll"
  "windows_x86_64:tbbmalloc_debug.dll"
  "windows_x86_64:tbbmalloc_proxy_debug.dll"
  # native-v0.18.0: all three list libwebgpu_dawn.so in NEEDED, and Dawn was
  # never in the Android bundle, so none of them could load (~18 MB per APK).
  # Android GPU is OpenCL only, as in Google's own Android SDKs.
  "android_arm64:libLiteRtGpuAccelerator.so"
  "android_arm64:libLiteRtWebGpuAccelerator.so"
  "android_arm64:libLiteRtTopKWebGpuSampler.so"
  # native-v0.18.0: the QNN runtime left the bundle. Qualcomm licenses it for
  # redistribution only inside an application, so an app opts in with
  # `qualcomm_npu: true` and its build hook fetches com.qualcomm.qti:qnn-runtime
  # from Maven. The dispatch stays — it is LiteRT's, built from source.
  "android_arm64:libQnnHtp.so"
  "android_arm64:libQnnSystem.so"
  "android_arm64:libQnnHtpV73Stub.so"
  "android_arm64:libQnnHtpV75Stub.so"
  "android_arm64:libQnnHtpV79Stub.so"
  "android_arm64:libQnnHtpV81Stub.so"
  "android_arm64:libQnnHtpV73Skel.so"
  "android_arm64:libQnnHtpV75Skel.so"
  "android_arm64:libQnnHtpV79Skel.so"
  "android_arm64:libQnnHtpV81Skel.so"
  # native-v0.18.0: upstream's Metal accelerator ships renamed to
  # libLiteRtLmMetalAccelerator.dylib. flutter_litert embeds a
  # LiteRtMetalAccelerator.framework for its own LiteRT, an app bundle holds
  # one framework per name, and ours silently replaced theirs.
  "ios_arm64:libLiteRtMetalAccelerator.dylib"
  "ios_sim_arm64:libLiteRtMetalAccelerator.dylib"
  "macos_arm64:libLiteRtMetalAccelerator.dylib"
)

_is_intentional() {
  local key="$1"
  for d in "${INTENTIONAL_DROPS[@]:-}"; do
    [[ "$d" == "$key" ]] && return 0
  done
  return 1
}

PREV_DL="$(mktemp -d)"
# ONE trap for every temp dir. bash REPLACES an EXIT trap rather than adding to
# it, so the later `trap ... EXIT` for the alignment scan used to silently
# disinherit this one — every successful run left the previous tag's archives
# behind, ~250 MB a time, forever.
align_tmp=""
trap 'rm -rf "$PREV_DL" ${align_tmp:+"$align_tmp"}' EXIT

echo "==> Verifying new tarballs in $DIST_DIR against previous tag $PREV_TAG"
echo "    repo: $REPO"
echo

# Enumerate the previous tag's assets ONCE, up front. Failing to read this list
# is a failure to LEARN what shipped last time — it is NOT evidence that a file
# is absent, so it must never be reported as a skip. Hard-fail instead.
if ! prev_assets="$(gh release view "$PREV_TAG" --repo "$REPO" \
      --json assets --jq '.assets[].name' 2>&1)"; then
  echo "❌ Cannot read the asset list of $PREV_TAG from $REPO." >&2
  echo "   gh said: $prev_assets" >&2
  echo "   This gate compares against that tag, so it cannot run at all." >&2
  echo "   Fix access (gh auth status) or the tag name, then re-run." >&2
  echo "   Do NOT publish on the strength of a check that did not execute." >&2
  exit 2
fi

_prev_has() {
  printf '%s\n' "$prev_assets" | grep -qxF "$1"
}

# One shot used to be enough until a 98 MB windows_x86_64 timed out and failed
# the whole gate on native-v0.17.1. Retry, then let the caller fail closed — a
# platform we could not diff must never read as a pass.
_download_prev() {
  local name="$1" attempt
  for attempt in 1 2 3; do
    if gh release download "$PREV_TAG" --repo "$REPO" --pattern "$name" \
          --dir "$PREV_DL" --clobber >/dev/null 2>&1; then
      return 0
    fi
    sleep $((attempt * 5))
  done
  return 1
}

# The diff below is only as good as the archive it compares against, and a zero
# exit from `gh` says nothing about WHICH bytes arrived — `--clobber` only means
# "overwrite". Hand this script the NEW archive under the OLD name and the list
# diff compares a file with itself, prints "no files dropped", and green-lights
# a release that dropped everything. So verify against the tag's own sums.
PREV_SUMS="checksums_litertlm.txt"
if ! _prev_has "$PREV_SUMS"; then
  echo "❌ $PREV_TAG publishes no $PREV_SUMS, so nothing downloaded from it" >&2
  echo "   can be verified, and an unverified archive cannot prove anything" >&2
  echo "   about a dropped native library. Re-release the tag with sums." >&2
  exit 2
fi
if ! _download_prev "$PREV_SUMS"; then
  echo "❌ Cannot download $PREV_SUMS from $PREV_TAG after three attempts." >&2
  echo "   Do NOT publish on the strength of a check that did not execute." >&2
  exit 2
fi

fail=0
checked=0
skipped=0

for new in "$DIST_DIR"/litertlm-*.tar.gz; do
  [[ -e "$new" ]] || { echo "No litertlm-*.tar.gz found in $DIST_DIR" >&2; exit 2; }
  base="$(basename "$new")"                 # litertlm-android_arm64.tar.gz
  plat="${base#litertlm-}"; plat="${plat%.tar.gz}"

  # Two different outcomes used to collapse into one skip here. Keep them apart:
  # "the previous tag has no such asset" is a legitimate skip (new platform),
  # while "the asset is listed but would not download" means we cannot compare —
  # a hard failure, not a pass.
  if ! _prev_has "$base"; then
    echo "  [skip] $plat — '$base' is not an asset of $PREV_TAG (new platform)"
    skipped=$((skipped + 1))
    continue
  fi

  if ! _download_prev "$base"; then
    echo "  [FAIL] $plat — '$base' IS an asset of $PREV_TAG but would not download."
    echo "         Cannot diff it, so this run proves nothing about $plat."
    fail=1
    continue
  fi

  want_sum="$(awk -v f="$base" '$2 == f { print $1 }' "$PREV_DL/$PREV_SUMS")"
  got_sum="$(shasum -a 256 "$PREV_DL/$base" | awk '{ print $1 }')"
  if [[ -z "$want_sum" || "$want_sum" != "$got_sum" ]]; then
    echo "  [FAIL] $plat — what we downloaded is not what $PREV_TAG published."
    if [[ -z "$want_sum" ]]; then
      echo "         $PREV_SUMS of $PREV_TAG has no line for '$base'."
    else
      echo "         expected $want_sum"
      echo "         got      $got_sum"
    fi
    echo "         Diffing against it would prove nothing about $plat."
    fail=1
    continue
  fi

  checked=$((checked + 1))
  # Normalise a leading `./` (the `tar -C dir .` layout) and drop directory
  # entries and blanks — they aren't files. Without the normalisation a
  # `./`-prefixed archive diffs wholesale against a non-`./` one.
  #
  # Compare FULL PATHS, not basenames. `xargs -n1 basename` used to flatten the
  # tree, so `./libQnnHtp.so` -> `./nested/libQnnHtp.so` read as "no files
  # dropped" plus a reassuring "new files (ok): nested" — while the hook's flat
  # extraction would no longer find it. A relocation is a drop.
  _list() {
    tar -tzf "$1" \
      | sed 's|^\./||' \
      | grep -vE '/$' \
      | grep -vE '^\.?$' \
      | sort -u
  }
  old_list="$(_list "$PREV_DL/$base")"
  new_list="$(_list "$new")"

  # Files in OLD but not in NEW = dropped.
  dropped="$(comm -23 <(printf '%s\n' "$old_list") <(printf '%s\n' "$new_list"))"
  added="$(comm -13 <(printf '%s\n' "$old_list") <(printf '%s\n' "$new_list"))"

  if [[ -n "$added" ]]; then
    echo "  [info] $plat — new files (ok): $(echo "$added" | tr '\n' ' ')"
  fi

  if [[ -z "$dropped" ]]; then
    echo "  [ok]   $plat — no files dropped"
    continue
  fi

  # Some files dropped — fail unless every one is allow-listed.
  local_fail=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if _is_intentional "$plat:$f"; then
      echo "  [allow] $plat — intentionally dropped: $f"
    else
      echo "  [FAIL] $plat — MISSING from new tarball: $f"
      local_fail=1
    fi
  done <<< "$dropped"

  [[ $local_fail -eq 1 ]] && fail=1
done

# The loop above walks the NEW tarballs, so a platform that vanished entirely
# is invisible to it: pack only windows when the previous tag had windows and
# android, and it reports "1 platform(s) compared" and exits 0. That is the same
# defect the gate exists to catch, one level up — "android was never rebuilt"
# instead of "a file inside android went missing". Walk the other direction too.
missing_plat=0
while IFS= read -r asset; do
  [[ "$asset" == litertlm-*.tar.gz ]] || continue
  if [[ ! -e "$DIST_DIR/$asset" ]]; then
    plat="${asset#litertlm-}"; plat="${plat%.tar.gz}"
    echo "  [FAIL] $plat — '$asset' is in $PREV_TAG but was not packed at all."
    echo "         The platform was not rebuilt, or packing skipped it."
    missing_plat=1
  fi
done <<< "$prev_assets"
[[ $missing_plat -eq 1 ]] && fail=1

# What must, and must not, be inside each NEW tarball — whatever the previous
# tag held. The drop check above only sees files that disappeared, so a file
# that should have gone but was left behind in prebuilt/ passes it silently;
# and INTENTIONAL_DROPS lets an old name vanish without proving its replacement
# arrived. For these files that is a licence or a correctness problem.
FORBIDDEN=(
  # Qualcomm licenses the QNN runtime for redistribution inside an application
  # only; since native-v0.18.0 apps fetch it through `qualcomm_npu`.
  "android_arm64:libQnn*"
  # Need libwebgpu_dawn.so, which no Android bundle carries (native-v0.18.0).
  "android_arm64:libLiteRtGpuAccelerator.so"
  "android_arm64:libLiteRtWebGpuAccelerator.so"
  "android_arm64:libLiteRtTopKWebGpuSampler.so"
  # Upstream's name, which flutter_litert's framework also uses (native-v0.18.0).
  "ios_arm64:libLiteRtMetalAccelerator.dylib"
  "ios_sim_arm64:libLiteRtMetalAccelerator.dylib"
  "macos_arm64:libLiteRtMetalAccelerator.dylib"
)
REQUIRED=(
  "android_arm64:libLiteRtDispatch_Qualcomm.so"
  "ios_arm64:libLiteRtLmMetalAccelerator.dylib"
  "ios_sim_arm64:libLiteRtLmMetalAccelerator.dylib"
  "macos_arm64:libLiteRtLmMetalAccelerator.dylib"
)
echo
echo "==> Checking files that must, and must not, ship"
content_fail=0
for new in "$DIST_DIR"/litertlm-*.tar.gz; do
  [[ -e "$new" ]] || continue
  base="$(basename "$new")"; plat="${base#litertlm-}"; plat="${plat%.tar.gz}"
  files="$(tar -tzf "$new" | sed 's|^\./||' | grep -vE '/$' | grep -vE '^\.?$' | sort -u)"
  for rule in "${FORBIDDEN[@]}"; do
    [[ "${rule%%:*}" == "$plat" ]] || continue
    pat="${rule#*:}"
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # $pat unquoted on purpose: it is a glob.
      if [[ "$(basename "$f")" == $pat ]]; then
        echo "  [FAIL] $plat — must not ship: $f"
        content_fail=1
      fi
    done <<< "$files"
  done
  for rule in "${REQUIRED[@]}"; do
    [[ "${rule%%:*}" == "$plat" ]] || continue
    if ! printf '%s\n' "$files" | grep -qxF "${rule#*:}"; then
      echo "  [FAIL] $plat — required file missing: ${rule#*:}"
      content_fail=1
    fi
  done
done
if [[ $content_fail -eq 1 ]]; then
  fail=1
else
  echo "  [ok]   no forbidden file shipped, every required file present"
fi

# Page alignment. The manifest check above answers "is every file still here";
# it cannot see that a file arrived misaligned. Google Play rejects an APK in
# which any .so has a PT_LOAD p_align below 16 KB, and the Qualcomm Skel blobs
# ship from the QAIRT SDK at 0x1000 — so this slipped through every build,
# every test and the manifest gate, and surfaced as a store rejection in a
# consumer's app (#529). Look inside the archives, not just at their listings.
echo
echo "==> Checking 16 KB page alignment inside each tarball"
align_tmp="$(mktemp -d)"   # cleaned by the single EXIT trap above
align_fail=0
for new in "$DIST_DIR"/litertlm-*.tar.gz; do
  [[ -e "$new" ]] || continue
  name="$(basename "$new")"
  dest="$align_tmp/${name%.tar.gz}"
  mkdir -p "$dest"
  tar -xzf "$new" -C "$dest"
  enforce=0
  case "$name" in litertlm-android_*) enforce=1 ;; esac
  if ! python3 - "$dest" "$name" "$enforce" <<'PYALIGN'
import glob, os, struct, sys

ALIGN = 0x4000
root, name, enforce = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
bad, checked = [], 0
for path in sorted(glob.glob(os.path.join(root, "**", "*.so"), recursive=True)
                   + glob.glob(os.path.join(root, "**", "*.dylib"), recursive=True)):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF":
        continue                      # Mach-O / PE are not page-gated by Play
    if data[4] == 2:
        phoff = struct.unpack_from("<Q", data, 0x20)[0]
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
        o_al, word = 0x30, "<Q"
    else:
        phoff = struct.unpack_from("<I", data, 0x1C)[0]
        phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
        o_al, word = 0x1C, "<I"
    aligns = [struct.unpack_from(word, data, phoff + i * phentsize + o_al)[0]
              for i in range(phnum)
              if struct.unpack_from("<I", data, phoff + i * phentsize)[0] == 1]
    if not aligns:
        continue
    checked += 1
    if min(aligns) < ALIGN:
        bad.append((os.path.basename(path), hex(min(aligns))))
if bad and enforce:
    print(f"  [FAIL] {name} — {len(bad)} of {checked} ELF object(s) below 16 KB:")
    for n, a in bad:
        print(f"         {n}  p_align={a}")
    sys.exit(1)
if bad:
    # Not Android, so Play never sees it: an x86_64 linker defaults p_align to
    # the 4 KB page it targets, and that is correct there. Printed, not failed.
    print(f"  [info] {name} — {len(bad)} of {checked} ELF object(s) below 16 KB "
          f"(not an APK payload, so not gated)")
elif checked == 0 and enforce:
    # The one bundle this gate exists for, with nothing in it to gate. That is a
    # broken archive or a wrong path, never a pass — "inspected nothing" and
    # "found nothing wrong" must not share an exit code.
    print(f"  [FAIL] {name} — no ELF objects found at all; the archive or the "
          f"path is wrong, so nothing was verified")
    sys.exit(1)
elif checked == 0:
    print(f"  [info] {name} — no ELF objects (Mach-O or PE bundle), nothing to check")
else:
    print(f"  [ok]   {name} — {checked} ELF object(s), all 16 KB-aligned")
PYALIGN
  then
    align_fail=1
  fi
done
if [[ $align_fail -eq 1 ]]; then
  echo
  echo "❌ ALIGNMENT CHECK FAILED — Google Play will reject any app shipping this."
  echo "   Relink the offending library with -Wl,-z,max-page-size=16384. (The"
  echo "   Qualcomm Skels no longer ship here: the hook raises their p_align.)"
  exit 1
fi

# The alignment scan above extracted every tarball into $align_tmp; check the
# Android one's imports there, on the bytes that will actually ship.
echo
echo "==> Checking every Android import is reachable through its own NEEDED"
for d in "$align_tmp"/litertlm-android_*; do
  [[ -d "$d" ]] || continue
  if ! python3 "$(dirname "$0")/check_android_needed.py" "$d"; then
    echo
    echo "❌ NEEDED CHECK FAILED — a library imports a symbol its NEEDED chain"
    echo "   cannot reach. A WEAK one binds to NULL and crashes on first call (#545)."
    exit 1
  fi
done

echo
echo "==> Checking the Windows C++ runtime against what the docs promise"
# The docs tell Windows end-users what they must install. That sentence is a
# claim about the bundle's import tables, and it drifted for a year: the pages
# asked for "Visual C++ Redistributable 2019 or newer" while `LiteRtLm.dll` also
# needed `vcruntime140_threads.dll`, which VS 2022 17.8 introduced and the 2019
# redistributable does not carry. Nothing failed until a Microsoft Store
# certification VM refused the app (#456).
#
# Since litertlm 1.7.1 the runtime is linked statically and the promise is
# "nothing to install". This checks that promise against the bytes, here rather
# than in a separate tool, because here is where the bundle changes: an Intel
# OpenVINO bump is exactly how a ninth CRT-importing DLL — or `_threads` coming
# back — would arrive, and the page saying "nothing to install" would go on
# saying it.
win_dir=""
for d in "$align_tmp"/litertlm-windows_*; do
  [[ -d "$d" ]] && win_dir="$d"
done
if [[ -z "$win_dir" ]]; then
  # Reachable only for a release that ships no Windows tarball at all. A
  # release that DROPPED one has already failed the manifest stage above, which
  # is where "was an asset of the previous tag but was not packed" is caught.
  echo "  [skip] this release ships no Windows tarball"
else
  # `dirname $0` does not resolve a symlink, and this script is short enough to
  # be symlinked somewhere convenient. Resolve before walking up.
  self="$0"
  while [[ -L "$self" ]]; do
    link="$(readlink "$self")"
    case "$link" in /*) self="$link" ;; *) self="$(dirname "$self")/$link" ;; esac
  done
  REPO_ROOT="$(cd "$(dirname "$self")/../../../.." && pwd)"
  # `if ! cmd` rather than `cmd; if [[ $? -ne 0 ]]`: under `set -e` the second
  # form never reaches the test — bash exits at the failing command and the
  # explanatory banner is dead code. Measured on bash 3.2.
  if ! WIN_DIR="$win_dir" REPO_ROOT="$REPO_ROOT" python3 - <<'PYWIN'
import glob, io, os, re, struct, sys

win, root = os.environ["WIN_DIR"], os.environ["REPO_ROOT"]

def pe_imports(path):
    """DLL names from the PE import directory.

    Every malformed shape raises. A parser that returns an empty list for input
    it did not understand reports "imports no C++ runtime", which is the answer
    this whole check exists to distrust. Directory index 1 — index 0 is the
    export table, and a first version read that and returned plausible nonsense.
    """
    d = open(path, "rb").read()
    if d[:2] != b"MZ":
        raise ValueError("not a PE file (no MZ)")
    if len(d) < 0x40:
        raise ValueError("truncated DOS header")
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if pe + 24 > len(d) or d[pe:pe + 4] != b"PE\0\0":
        raise ValueError("no PE signature")
    nsec, = struct.unpack_from("<H", d, pe + 6)
    sizeopt, = struct.unpack_from("<H", d, pe + 20)
    opt = pe + 24
    magic, = struct.unpack_from("<H", d, opt)
    if magic not in (0x10B, 0x20B):
        raise ValueError("unknown optional-header magic 0x%x" % magic)
    ddbase = opt + (112 if magic == 0x20B else 96)
    nrva, = struct.unpack_from("<I", d, ddbase - 4)
    if nrva < 2:
        raise ValueError("no import data directory")
    imp_rva, imp_size = struct.unpack_from("<II", d, ddbase + 8)
    if not imp_rva:
        return []
    secs = []
    for i in range(nsec):
        h = opt + sizeopt + i * 40
        if h + 40 > len(d):
            raise ValueError("truncated section table")
        vs, va, rs, ra = struct.unpack_from("<IIII", d, h + 8)
        secs.append((va, vs, rs, ra))
    def off(rva):
        # Bounded by SizeOfRawData, not by max(VirtualSize, SizeOfRawData): the
        # virtual tail of a section is zero-filled and has no bytes in the file,
        # so mapping it would read whatever follows and call it a name.
        for va, vs, rs, ra in secs:
            if va <= rva < va + vs:
                delta = rva - va
                if delta >= rs:
                    raise ValueError("RVA 0x%x is in a section's virtual tail" % rva)
                fo = ra + delta
                if fo >= len(d):
                    raise ValueError("RVA 0x%x maps past end of file" % rva)
                return fo
        raise ValueError("RVA 0x%x is in no section" % rva)
    out, o, limit = [], off(imp_rva), None
    if imp_size:
        limit = o + imp_size
    while True:
        if limit is not None and o + 20 > limit:
            break
        if o + 20 > len(d):
            raise ValueError("import descriptor runs past end of file")
        ent = d[o:o + 20]
        if ent == b"\0" * 20:
            break
        nr, = struct.unpack_from("<I", ent, 12)
        if nr:
            no = off(nr)
            z = d.find(b"\0", no)
            if z < 0:
                raise ValueError("unterminated import name")
            out.append(d[no:z].decode("ascii", "replace"))
        o += 20
    return out

CRT = re.compile(r"^(msvcp|vcruntime|concrt)\d", re.I)
# What a Flutter Windows app resolves anyway. NOT what the redistributable
# installs — the redist also carries vcruntime140_threads.dll, and needing that
# one is exactly #456.
ALLOWED = {"msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"}

# Recursive: "*.dll" would describe the flat bundle we ship today and quietly
# stop describing it the day anything lands in a subdirectory.
dlls = sorted(glob.glob(os.path.join(win, "**", "*.dll"), recursive=True))
if not dlls:
    sys.exit("  [FAIL] the Windows tarball contains no DLLs — nothing was checked")

crt, dispatch_importers, fail = {}, [], False
for path in dlls:
    name = os.path.relpath(path, win)
    try:
        imp = pe_imports(path)
    except Exception as e:
        print(f"  [FAIL] {name}: {e}")
        fail = True
        continue
    got = sorted({i for i in imp if CRT.match(i)}, key=str.lower)
    if got:
        crt[name] = got
    if any(i.lower() == "litertdispatch.dll" for i in imp):
        dispatch_importers.append(name)

clean = len(dlls) - len(crt)
print(f"    {len(dlls)} DLL(s): {clean} import no C++ runtime, {len(crt)} do")

# 1. The library we build must carry its own runtime. Windows filenames are
#    case-insensitive, so match that way.
litertlm = [n for n in crt if os.path.basename(n).lower() == "litertlm.dll"]
if litertlm:
    print(f"  [FAIL] {litertlm[0]} imports {', '.join(crt[litertlm[0]])} —"
          " static_link_msvcrt did not apply")
    fail = True
if not any(os.path.basename(p).lower() == "litertlm.dll" for p in dlls):
    print("  [FAIL] no LiteRtLm.dll in the Windows tarball — the assertion about"
          " it cannot have been checked")
    fail = True

# 2. Nothing may need a runtime a Flutter app does not already resolve. Stated
#    as a property: naming vcruntime140_threads.dll would catch only the one
#    spelling that has already bitten us.
for name, got in sorted(crt.items()):
    bad = [g for g in got if g.lower() not in ALLOWED]
    if bad:
        print(f"  [FAIL] {name} needs {', '.join(bad)}, which an end-user would"
              " have to install")
        fail = True

# 3. The NPU stack is reachable only through PreferredBackend.npu. A static
#    import from an always-loaded DLL would make that false, and the docs say it.
if dispatch_importers:
    print("  [FAIL] these statically import LiteRtDispatch.dll, so its OpenVINO"
          f" runtime loads unconditionally: {', '.join(dispatch_importers)}")
    fail = True

# 4. Every page that states the split must state the measured one, and each of
#    them must still state it — one page keeping the sentence would otherwise
#    cover for three that dropped it.
DOCS = ["website/content/docs/desktop.md",
        "packages/flutter_edge_ai/DESKTOP_SUPPORT.md",
        "packages/flutter_edge_ai/README.md",
        "packages/flutter_edge_ai/skills/flutter-edge-ai-inference/references/platform-setup.md"]
COUNT = re.compile(r"(\d+) of (?:the bundle's |its )?(\d+) DLLs")
# Every mention of a redistributable must be a denial or a description of the
# past. Checking for instruction verbs instead would miss "Download the …" and
# any phrasing nobody thought of; this way an approving mention has to opt in.
# Deliberately narrow. "before" and "was" were in a first draft and would have
# waved through "Download the Visual C++ Redistributable before launching."
DENIAL = re.compile(r"\bno\b|\bnot\b|\bnothing\b|\bnever\b|\blacks\b|\babsent\b|"
                    r"\bused to\b|\bup to\b|\bpreviously\b|\b1\.7\.0\b", re.I)
for rel in DOCS:
    p = os.path.join(root, rel)
    if not os.path.exists(p):
        print(f"  [FAIL] {rel} is gone — this check names the pages it guards")
        fail = True
        continue
    text = io.open(p, encoding="utf-8").read()
    hits = list(COUNT.finditer(text))
    if not hits:
        print(f"  [FAIL] {rel} no longer states the DLL split; this check would"
              " pass vacuously for it")
        fail = True
    for m in hits:
        if (int(m.group(1)), int(m.group(2))) != (clean, len(dlls)):
            line = text[:m.start()].count("\n") + 1
            print(f'  [FAIL] {rel}:{line} says "{m.group(0)}";'
                  f" measured {clean} of {len(dlls)}")
            fail = True
    for sentence in re.split(r"(?<=[.!?])\s+|\n\n", text):
        if not re.search(r"redistributable", sentence, re.I):
            continue
        if DENIAL.search(sentence):
            continue
        line = text[:text.index(sentence)].count("\n") + 1
        one = " ".join(sentence.split())[:80]
        print(f'  [FAIL] {rel}:{line} mentions a redistributable without denying'
              f' it is needed: "{one}"')
        fail = True

if fail:
    sys.exit(1)
print(f"    docs agree: {clean} of {len(dlls)}, nothing to install")
PYWIN
  then
    echo
    echo "❌ WINDOWS RUNTIME CHECK FAILED — the bundle and the docs disagree, or"
    echo "   a DLL now needs a runtime the end-user would have to install."
    echo "   Fix whichever is wrong before publishing; #456 is what happens when"
    echo "   the page keeps promising something the bytes stopped doing."
    exit 1
  fi
fi

echo
if [[ $checked -eq 0 ]]; then
  echo "❌ MANIFEST CHECK DID NOT RUN — zero platforms compared."
  echo "   $skipped tarball(s) had no counterpart in $PREV_TAG."
  echo "   A check that compared nothing is not a check that passed; if every"
  echo "   platform really is new, you are comparing against the wrong tag."
  exit 1
fi

if [[ $fail -eq 1 ]]; then
  echo "❌ MANIFEST CHECK FAILED — files disappeared vs $PREV_TAG."
  echo "   If a removal is intentional, add it to INTENTIONAL_DROPS with a reason."
  echo "   Otherwise a build step (e.g. build_qualcomm_dispatch.sh / Intel NPU"
  echo "   staging) did not run — rebuild before publishing."
  exit 1
fi

echo "✅ MANIFEST CHECK PASSED — $checked platform(s) compared against $PREV_TAG, no unexplained file drops."
if [[ $skipped -gt 0 ]]; then
  echo "   ($skipped tarball(s) skipped as new platforms.)"
fi

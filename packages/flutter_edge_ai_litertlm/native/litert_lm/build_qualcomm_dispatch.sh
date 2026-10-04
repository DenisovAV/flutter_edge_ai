#!/bin/bash
# Build libLiteRtDispatch_Qualcomm.so for Android arm64 from LiteRT source.
#
# Requires the Qualcomm QNN dispatch bridge between LiteRT-LM and the on-device
# QNN/HTP runtime. This lib is NOT shipped in official LiteRT releases as of
# LiteRT v2.1.5 — we build it from source.
#
# Prerequisites:
#   - Bazel (via bazelisk): brew install bazelisk
#   - Android NDK at ~/Library/Android/sdk/ndk/<version>/
#   - Internet access (Bazel auto-downloads QAIRT SDK ~500MB on first run)
#     OR set LITERT_QAIRT_SDK=/path/to/qairt/2.44.0.260225 to use local copy
#
# Usage:
#   ./build_qualcomm_dispatch.sh
#   LITERTLM_REF=<sha> ./build_qualcomm_dispatch.sh          # match a specific engine build
#   LITERT_QAIRT_SDK=/path/to/qairt/2.44.0.260225 ./build_qualcomm_dispatch.sh
#
# Env:
#   LITERTLM_REF      LiteRT-LM commit to derive LITERT_REF from (default below).
#   LITERT_REF        Override the derived LiteRT ref. Rarely correct — the two
#                     must come from one tree or the dispatch SIGSEGVs.
#   LITERT_QAIRT_SDK  Local QAIRT SDK, skips the ~500 MB download.
#   ANDROID_NDK_HOME  NDK r29+ (auto-detected from ~/Library/Android/sdk/ndk).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/android_arm64"
LITERT_DIR="/tmp/LiteRT"

# The dispatch library must be built from the SAME LiteRT tree as the engine it
# calls into. Hardcoding a ref here is how it silently drifted: this file sat at
# 5c5b9ce6 (LiteRT-LM ffed38ad, native-v0.12.0) while the engine moved on, and a
# stale dispatch does not fail politely — on v0.16.0 it SIGSEGVs inside
# LiteRtDestroyOptions the moment engine_create tears an options object down.
#
# So derive it instead: read LITERT_REF out of the WORKSPACE of the LiteRT-LM
# revision we are building. Pass LITERTLM_REF to match a specific engine build.
#
# Do NOT go back to a literal, and do NOT use LiteRT v2.1.1 or earlier — the
# LiteRtDispatchApi struct has breaking ABI changes after it.
LITERTLM_REF="${LITERTLM_REF:-e9fd8c53ff968071774206163027dd84bedfe925}"   # v0.17.0
LITERT_REF="${LITERT_REF:-}"
if [ -z "$LITERT_REF" ]; then
  echo "Resolving LITERT_REF from LiteRT-LM $LITERTLM_REF WORKSPACE..."
  # Fetch and parse as separate steps. Combined, `set -e` aborts on a curl
  # failure (a bad LITERTLM_REF 404s — the single most likely operator error)
  # at the assignment, so the diagnostic below could never print. `sed …;q`
  # rather than `| head -1` also avoids a SIGPIPE that `pipefail` reports as 141.
  if ! _workspace="$(curl -fsSL \
      "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$LITERTLM_REF/WORKSPACE")"; then
    echo "ERROR: could not fetch WORKSPACE for LiteRT-LM $LITERTLM_REF" >&2
    echo "       (bad ref? network? the ref must be a commit/tag that exists)" >&2
    exit 1
  fi
  LITERT_REF="$(printf '%s\n' "$_workspace" \
    | sed -n 's/^LITERT_REF *= *"\([0-9a-f]*\)".*/\1/p;/^LITERT_REF/q')"
  if [ -z "$LITERT_REF" ]; then
    echo "ERROR: WORKSPACE for $LITERTLM_REF has no LITERT_REF line" >&2
    exit 1
  fi
  echo "  -> $LITERT_REF"
fi

# Resolve Android NDK
if [ -z "${ANDROID_NDK_HOME:-}" ]; then
  if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
    ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/$(ls -1 "$HOME/Library/Android/sdk/ndk" | sort -V | tail -1)"
    export ANDROID_NDK_HOME
    echo "Auto-detected ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
  else
    echo "ERROR: ANDROID_NDK_HOME not set and ~/Library/Android/sdk/ndk not found"
    exit 1
  fi
fi

if [ -z "${ANDROID_HOME:-}" ]; then
  export ANDROID_HOME="$(dirname "$(dirname "$ANDROID_NDK_HOME")")"
  echo "Auto-detected ANDROID_HOME=$ANDROID_HOME"
fi

echo "=== Building libLiteRtDispatch_Qualcomm.so for Android arm64 ==="
echo "LiteRT ref:         $LITERT_REF"
echo "ANDROID_NDK_HOME:   $ANDROID_NDK_HOME"
echo "ANDROID_HOME:       $ANDROID_HOME"
if [ -n "${LITERT_QAIRT_SDK:-}" ]; then
  echo "LITERT_QAIRT_SDK:   $LITERT_QAIRT_SDK (local)"
else
  echo "LITERT_QAIRT_SDK:   (Bazel will auto-download QAIRT 2.44.0.260225 ~500MB)"
fi

# 1. Clone or update LiteRT
if [ -d "$LITERT_DIR/.git" ]; then
  echo ""
  echo "Updating $LITERT_DIR..."
  git -C "$LITERT_DIR" fetch origin
else
  echo ""
  echo "Cloning LiteRT..."
  git clone https://github.com/google-ai-edge/LiteRT "$LITERT_DIR"
fi

echo "Checking out $LITERT_REF..."
git -C "$LITERT_DIR" checkout -f "$LITERT_REF"
echo "Building from: $(git -C "$LITERT_DIR" log --oneline -1)"

cd "$LITERT_DIR"

# 2. Build dispatch lib.
#
# The NDK path goes in via --repo_env, NOT --action_env. At this pin LiteRT
# resolves the toolchain through rules_android_ndk and gates it on a repository
# rule: check_android_ndk_env() reads ctx.getenv("ANDROID_NDK_HOME") and, when
# it comes back empty, registers @android_ndk_env//:all — a repo with an EMPTY
# BUILD file. Zero toolchains, cc resolution finds nothing, Bazel falls back to
# the legacy crosstool, and you get `clang: error: unknown argument:
# '-gcc-toolchain'` — which reads as "NDK too new" and is not.
#
# --action_env populates action environments, which repo rules never read. The
# old .litert_configure.bazelrc written here (ANDROID_NDK_API_LEVEL and
# friends) was the pre-rules_android_ndk mechanism and is dead weight now:
# api_level is declared in LiteRT's own WORKSPACE call.
#
# LITERT_QAIRT_SDK rides the same rule: it is read by a repository rule, so
# exporting it does nothing. Without this line the script printed "(local)" and
# then downloaded the 500 MB SDK anyway.
QAIRT_ENV=()
if [ -n "${LITERT_QAIRT_SDK:-}" ]; then
  QAIRT_ENV+=(--repo_env=LITERT_QAIRT_SDK="$LITERT_QAIRT_SDK")
fi
echo ""
echo "=== Running Bazel build ==="
bazelisk build \
  --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
  --repo_env=ANDROID_HOME="$ANDROID_HOME" \
  --repo_env=HERMETIC_PYTHON_VERSION=3.12 \
  "${QAIRT_ENV[@]+"${QAIRT_ENV[@]}"}" \
  --config=android_arm64 \
  --compilation_mode=opt \
  --strip=always \
  --linkopt=-Wl,-z,max-page-size=16384 \
  //litert/vendors/qualcomm/dispatch:dispatch_api_so

# 3. Stage the whole set, promote only when every piece is in hand.
#
# The dispatch and the QNN runtime are one matched pair. Writing the dispatch
# straight into $PREBUILT_DIR and refreshing QNN afterwards means any abort in
# between leaves exactly the mismatched pair this script exists to prevent —
# new dispatch, old runtime — and the next `tar czf` ships it. Nothing in the
# bundle records which half is stale, so the failure is unrecoverable by
# inspection; it shows up only on device.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

OUTPUT="bazel-bin/litert/vendors/qualcomm/dispatch/libLiteRtDispatch_Qualcomm.so"
if [ ! -f "$OUTPUT" ]; then
  echo "ERROR: expected output not found at $OUTPUT"
  echo "Bazel bin contents:"
  find bazel-bin/litert/vendors/qualcomm/dispatch/ -name "*.so" 2>/dev/null || true
  exit 1
fi
cp "$OUTPUT" "$STAGE/libLiteRtDispatch_Qualcomm.so"

# 4. Refresh the QNN runtime from the SAME QAIRT the dispatch was built against.
#
# These are not compiled from source — they come out of the QAIRT SDK — which
# makes "keep the old ones" look safe. It is not: the dispatch negotiates an
# API version with them. Ours drifted to
#   qnn_manager.cc:349 Qnn System library version 1.8.0 is mismatched.
#                      The minimum supported version is 1.11.0.
#   dispatch_api.cc:139 Failed to set up QNN manager
#   dispatch_delegate.cc:131 No usable Dispatch runtime found
# and engine_create then fails on backend=npu in ~60ms with nothing but an
# opaque null, which the Dart layer reports as "model may be invalid".
#
# Do NOT try to catch this by version string: QNN has two independent
# numberings, and libQnnSystem.so — the file that actually broke — carries no
# version string at all. Compare sizes against the SDK instead.
if ! OUTPUT_BASE="$(bazelisk info output_base)"; then
  echo "ERROR: 'bazelisk info output_base' failed (see its stderr above)" >&2
  exit 1
fi
if [ -z "$OUTPUT_BASE" ]; then
  echo "ERROR: 'bazelisk info output_base' returned nothing" >&2
  exit 1
fi
QAIRT_DIR="$OUTPUT_BASE/external/qairt"
if [ ! -d "$QAIRT_DIR/lib/aarch64-android" ]; then
  echo "ERROR: QAIRT SDK not found at $QAIRT_DIR" >&2
  echo "       The QNN runtime cannot be refreshed. Shipping a runtime older" >&2
  echo "       than the dispatch fails only on real hardware, at engine_create." >&2
  exit 1
fi
echo ""
echo "=== Staging QNN runtime from $QAIRT_DIR ==="
for f in libQnnSystem.so libQnnHtp.so \
         libQnnHtpV73Stub.so libQnnHtpV75Stub.so \
         libQnnHtpV79Stub.so libQnnHtpV81Stub.so; do
  src="$QAIRT_DIR/lib/aarch64-android/$f"
  [ -f "$src" ] || { echo "ERROR: missing in SDK: $src" >&2; exit 1; }
  cp -f "$src" "$STAGE/$f"
  printf "  %-26s %s bytes\n" "$f" "$(wc -c < "$STAGE/$f" | tr -d ' ')"
done
# Skel libs live per-Hexagon-version, outside lib/aarch64-android. V79 is the
# HTP of SM8750 (Snapdragon 8 Elite) and is absent from /vendor/dsp/cdsp/ even
# on Qualcomm reference firmware, so bundling it is required, not a workaround.
for v in 73 75 79 81; do
  src="$QAIRT_DIR/lib/hexagon-v$v/unsigned/libQnnHtpV${v}Skel.so"
  [ -f "$src" ] || { echo "ERROR: missing in SDK: $src" >&2; exit 1; }
  cp -f "$src" "$STAGE/libQnnHtpV${v}Skel.so"
  printf "  %-26s %s bytes\n" "libQnnHtpV${v}Skel.so" "$(wc -c < "$STAGE/libQnnHtpV${v}Skel.so" | tr -d ' ')"
done

# 5. Raise p_align to 16 KB where Qualcomm shipped 4 KB.
#
# Google Play rejects an APK in which any .so has a PT_LOAD p_align below
# 16 KB ("Your app does not support 16 KB memory page sizes"). The Skel blobs
# arrive from the QAIRT SDK at 0x1000, and since androidExtraLibs puts them in
# every consumer APK, that rejection reaches every app shipping this package —
# not only the ones that use the NPU. The blobs are Hexagon DSP images parsed
# by the DSP's own loader through FastRPC and never mapped by the kernel, so
# the bump is metadata and nothing else moves.
#
# It is sound exactly when every PT_LOAD keeps p_vaddr == p_offset (mod 16K):
# the loader derives the mapping from that congruence, and a blob that breaks
# it would stop loading rather than fail the check. So refuse loudly there —
# a future SDK must not be able to turn this into an unloadable binary quietly.
echo ""
echo "=== Checking 16 KB page alignment ==="
python3 - "$STAGE" <<'PYALIGN'
import glob, os, struct, sys

ALIGN = 0x4000
raised, checked = [], 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.so"))):
    data = bytearray(open(path, "rb").read())
    if data[:4] != b"\x7fELF":
        sys.exit(f"ERROR: not an ELF: {path}")
    if data[4] == 2:  # ELF64
        phoff = struct.unpack_from("<Q", data, 0x20)[0]
        phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
        o_off, o_va, o_al, word = 0x08, 0x10, 0x30, "<Q"
    else:             # ELF32 — the Hexagon Skel blobs
        phoff = struct.unpack_from("<I", data, 0x1C)[0]
        phentsize, phnum = struct.unpack_from("<HH", data, 0x2A)
        o_off, o_va, o_al, word = 0x04, 0x08, 0x1C, "<I"
    loads = []
    for i in range(phnum):
        o = phoff + i * phentsize
        if struct.unpack_from("<I", data, o)[0] != 1:  # PT_LOAD
            continue
        loads.append((o,
                      struct.unpack_from(word, data, o + o_off)[0],
                      struct.unpack_from(word, data, o + o_va)[0],
                      struct.unpack_from(word, data, o + o_al)[0]))
    if not loads:
        sys.exit(f"ERROR: no PT_LOAD segment in {os.path.basename(path)}")
    checked += 1
    if all(al >= ALIGN for _, _, _, al in loads):
        continue
    broken = [(hex(off), hex(va)) for _, off, va, _ in loads if (va - off) % ALIGN]
    if broken:
        sys.exit(
            f"ERROR: {os.path.basename(path)} cannot be 16 KB-aligned in place: "
            f"p_vaddr and p_offset are not congruent mod 16K for {broken}. "
            f"Take an aligned build from the SDK instead of patching."
        )
    for o, _, _, al in loads:
        if al < ALIGN:
            struct.pack_into(word, data, o + o_al, ALIGN)
    open(path, "wb").write(data)
    raised.append(os.path.basename(path))
print(f"  {checked} .so checked, {len(raised)} raised to 16 KB"
      + (": " + ", ".join(raised) if raised else ""))
PYALIGN

# 6. Verify the staged dispatch before it can reach the bundle. This is the one
# symbol the library exists to export; without it the NPU path is dead.
if ! nm -D "$STAGE/libLiteRtDispatch_Qualcomm.so" 2>/dev/null \
     | grep -q 'LiteRtDispatchGetApi'; then
  echo "ERROR: staged dispatch does not export LiteRtDispatchGetApi" >&2
  exit 1
fi

# 7. Promote. All 11 files are present and the dispatch is sane, so the bundle
# moves from one consistent state to another.
staged=$(find "$STAGE" -maxdepth 1 -type f -name '*.so' | wc -l | tr -d ' ')
if [ "$staged" -ne 11 ]; then
  echo "ERROR: staged $staged files, expected 11 (dispatch + 10 QNN)" >&2
  exit 1
fi
mkdir -p "$PREBUILT_DIR"
for f in "$STAGE"/*.so; do
  cp -f "$f" "$PREBUILT_DIR/$(basename "$f")"
  chmod +w "$PREBUILT_DIR/$(basename "$f")"
done

echo ""
echo "=== Done ==="
echo "  libLiteRtDispatch_Qualcomm.so + 10 QNN runtime libs → $PREBUILT_DIR/"
ls -lh "$PREBUILT_DIR/libLiteRtDispatch_Qualcomm.so"

#!/bin/bash
# Build libLiteRtDispatch_Qualcomm.so for Android arm64 or Linux arm64 from
# LiteRT source (TARGET=android_arm64, the default, or TARGET=linux_arm64).
#
# Requires the Qualcomm QNN dispatch bridge between LiteRT-LM and the on-device
# QNN/HTP runtime. This lib is NOT shipped in official LiteRT releases as of
# LiteRT v2.1.5 — we build it from source.
#
# Prerequisites:
#   - Bazel (via bazelisk): brew install bazelisk
#   - Android NDK at ~/Library/Android/sdk/ndk/<version>/
#   - Internet access (Bazel auto-downloads QAIRT SDK ~500MB on first run)
#     OR set LITERT_QAIRT_SDK=/path/to/qairt/<version> to use local copy.
#     The version is whatever LiteRT's third_party/qairt/workspace.bzl pins at
#     the derived LITERT_REF (2.50.0.260828 at the v0.18.0 pin) — a local SDK
#     must be that same version.
#
# Linux arm64 (TARGET=linux_arm64) builds natively on an arm64 Linux host — CI
# runs it on ubuntu-22.04-arm, whose glibc sets the floor — with clang >= 15
# (abseil needs std::source_location; Ubuntu 22.04's clang 14 fails). Google
# publishes no Linux dispatch at all. It also builds our libcdsprpc.so shim
# (see "Linux shim" below).
#
# Usage:
#   ./build_qualcomm_dispatch.sh
#   TARGET=linux_arm64 CC=clang-17 CXX=clang++-17 ./build_qualcomm_dispatch.sh
#   LITERTLM_REF=<sha> ./build_qualcomm_dispatch.sh          # match a specific engine build
#   LITERT_QAIRT_SDK=/path/to/qairt/<version> ./build_qualcomm_dispatch.sh
#
# Env:
#   TARGET            android_arm64 (default) or linux_arm64.
#   CC, CXX           Linux only: clang >= 15 (default clang / clang++).
#   LITERTLM_REF      LiteRT-LM commit to derive LITERT_REF from (default below).
#   LITERT_REF        Override the derived LiteRT ref. Rarely correct — the two
#                     must come from one tree or the dispatch SIGSEGVs.
#   LITERT_QAIRT_SDK  Local QAIRT SDK, skips the ~500 MB download.
#   ANDROID_NDK_HOME  NDK r29+ (auto-detected from ~/Library/Android/sdk/ndk).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="${TARGET:-android_arm64}"
case "$TARGET" in
  android_arm64) QAIRT_HOST_LIB=aarch64-android ;;
  # The OpenEmbedded set: the Ubuntu one (aarch64-ubuntu-gcc9.4) stops at V68,
  # and the hook takes the runtime from this one (lib/src/hook/qairt_linux.dart).
  linux_arm64) QAIRT_HOST_LIB=aarch64-oe-linux-gcc11.2 ;;
  *) echo "ERROR: TARGET must be android_arm64 or linux_arm64, got '$TARGET'" >&2; exit 1 ;;
esac
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/$TARGET"
LITERT_DIR="/tmp/LiteRT"

if [ "$TARGET" = linux_arm64 ]; then
  if [ "$(uname -s)" != Linux ] || [ "$(uname -m)" != aarch64 ]; then
    echo "ERROR: TARGET=linux_arm64 builds on an arm64 Linux host (this is $(uname -sm))" >&2
    exit 1
  fi
  CC="${CC:-clang}"
  CXX="${CXX:-clang++}"
  CLANG_MAJOR="$("$CC" --version 2>/dev/null | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1 || true)"
  if [ -z "$CLANG_MAJOR" ] || [ "$CLANG_MAJOR" -lt 15 ]; then
    echo "ERROR: $CC is not clang >= 15 (got '${CLANG_MAJOR:-none}'); abseil needs std::source_location" >&2
    exit 1
  fi
fi

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
LITERTLM_REF="${LITERTLM_REF:-b2f686e2ed4718fb84ec398a61dd59ca0f0aff27}"   # v0.18.0
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
if [ "$TARGET" = android_arm64 ] && [ -z "${ANDROID_NDK_HOME:-}" ]; then
  if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
    ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/$(ls -1 "$HOME/Library/Android/sdk/ndk" | sort -V | tail -1)"
    export ANDROID_NDK_HOME
    echo "Auto-detected ANDROID_NDK_HOME=$ANDROID_NDK_HOME"
  else
    echo "ERROR: ANDROID_NDK_HOME not set and ~/Library/Android/sdk/ndk not found"
    exit 1
  fi
fi

if [ "$TARGET" = android_arm64 ] && [ -z "${ANDROID_HOME:-}" ]; then
  export ANDROID_HOME="$(dirname "$(dirname "$ANDROID_NDK_HOME")")"
  echo "Auto-detected ANDROID_HOME=$ANDROID_HOME"
fi

echo "=== Building libLiteRtDispatch_Qualcomm.so for $TARGET ==="
echo "LiteRT ref:         $LITERT_REF"
if [ "$TARGET" = android_arm64 ]; then
  echo "ANDROID_NDK_HOME:   $ANDROID_NDK_HOME"
  echo "ANDROID_HOME:       $ANDROID_HOME"
else
  echo "CC / CXX:           $CC / $CXX (clang $CLANG_MAJOR)"
fi
if [ -n "${LITERT_QAIRT_SDK:-}" ]; then
  echo "LITERT_QAIRT_SDK:   $LITERT_QAIRT_SDK (local)"
else
  echo "LITERT_QAIRT_SDK:   (Bazel will auto-download the QAIRT LiteRT pins in third_party/qairt/workspace.bzl, ~500MB)"
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

# Linux: drop the dispatch's `-Wl,-lc++abi` linkopt. It is there for the
# Android NDK's libc++; on Linux libstdc++ carries the C++ ABI and lld fails
# on the missing libc++abi. Edited in this throwaway checkout only (the
# `checkout -f` above restores it on the next run), so Android keeps it.
if [ "$TARGET" = linux_arm64 ]; then
  DISPATCH_BUILD=litert/vendors/qualcomm/dispatch/BUILD
  if grep -q -- '-Wl,-lc++abi' "$DISPATCH_BUILD"; then
    sed -i -e '/-Wl,-lc++abi/d' "$DISPATCH_BUILD"
    echo "Linux: removed -Wl,-lc++abi from $DISPATCH_BUILD"
  else
    echo "Linux: $DISPATCH_BUILD has no -Wl,-lc++abi (upstream dropped it?)"
  fi
fi

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
if [ "$TARGET" = android_arm64 ]; then
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
else
  bazelisk build \
    --repo_env=CC="$CC" --repo_env=CXX="$CXX" \
    --action_env=CC="$CC" --action_env=CXX="$CXX" \
    --repo_env=HERMETIC_PYTHON_VERSION=3.12 \
    "${QAIRT_ENV[@]+"${QAIRT_ENV[@]}"}" \
    --config=linux_arm64 \
    --compilation_mode=opt \
    --strip=always \
    //litert/vendors/qualcomm/dispatch:dispatch_api_so
fi

# 3. Stage the dispatch; promote it only once every check below has passed, so
# an abort never leaves an unchecked dispatch in $PREBUILT_DIR for the next
# `tar czf` to ship.
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

# 4. The dispatch and the QNN runtime are one matched pair: the dispatch
# negotiates an API version with the runtime it finds. A stale runtime does not
# fail politely — ours once drifted to
#   qnn_manager.cc:349 Qnn System library version 1.8.0 is mismatched.
#                      The minimum supported version is 1.11.0.
#   dispatch_api.cc:139 Failed to set up QNN manager
#   dispatch_delegate.cc:131 No usable Dispatch runtime found
# and engine_create then failed on backend=npu in ~60ms with nothing but an
# opaque null, which the Dart layer reports as "model may be invalid".
#
# The runtime half now comes from Maven through the hook (see below), so the
# pair is held together by release number: the QAIRT SDK's own sdk.yaml here
# against the hook's pin. Not by a version string inside the libraries — QNN
# has two independent numberings, and libQnnSystem.so, the file that broke,
# carries none.
if ! OUTPUT_BASE="$(bazelisk info output_base)"; then
  echo "ERROR: 'bazelisk info output_base' failed (see its stderr above)" >&2
  exit 1
fi
if [ -z "$OUTPUT_BASE" ]; then
  echo "ERROR: 'bazelisk info output_base' returned nothing" >&2
  exit 1
fi
QAIRT_DIR="$OUTPUT_BASE/external/qairt"
if [ ! -d "$QAIRT_DIR/lib/$QAIRT_HOST_LIB" ]; then
  echo "ERROR: QAIRT SDK not found at $QAIRT_DIR" >&2
  echo "       Its version cannot be checked against the hook's qnn-runtime pin." >&2
  echo "       A mismatched pair fails only on real hardware, at engine_create." >&2
  exit 1
fi
echo ""
echo "=== Checking QAIRT $QAIRT_DIR against the hook ==="
# The SDK's own sdk.yaml, not a literal here: a hardcoded version in this
# script claimed 2.44 for two releases after LiteRT had moved to 2.47 and 2.50.
# `|| true`: a missing sdk.yaml must reach the error below, not abort here
# under pipefail with nothing said.
QAIRT_VERSION="$(sed -n 's/^version: *//p' "$QAIRT_DIR/sdk.yaml" 2>/dev/null | head -1 || true)"
echo "QAIRT version: $QAIRT_VERSION"
# Since native-v0.18.0 the QNN runtime is not staged here: Qualcomm's licence
# allows it only inside an application, so the build hook of an app that sets
# `qualcomm_npu: true` fetches com.qualcomm.qti:qnn-runtime from Maven Central
# (lib/src/hook/qnn_runtime.dart pins version and sha256). What stays this
# script's job is keeping the two halves matched: the dispatch built here must
# negotiate with that pinned runtime, so refuse to build against any other
# QAIRT release.
HOOK_QNN="$(sed -n "s/^const qnnRuntimeVersion = '\\(.*\\)';/\\1/p" \
  "$SCRIPT_DIR/../../lib/src/hook/qnn_runtime.dart")"
if [ -z "$QAIRT_VERSION" ] || [ -z "$HOOK_QNN" ]; then
  echo "ERROR: could not read the QAIRT version ('$QAIRT_VERSION') or the hook's" >&2
  echo "       qnnRuntimeVersion ('$HOOK_QNN') — cannot prove the pair matches" >&2
  exit 1
fi
if [ "$QAIRT_VERSION" != "$HOOK_QNN" ]; then
  echo "ERROR: LiteRT builds the dispatch against QAIRT $QAIRT_VERSION, but the hook" >&2
  echo "       fetches qnn-runtime $HOOK_QNN. Bump qnnRuntimeVersion and" >&2
  echo "       qnnRuntimeSha256 in lib/src/hook/qnn_runtime.dart to the matching" >&2
  echo "       com.qualcomm.qti:qnn-runtime release first." >&2
  exit 1
fi
echo "  matches the hook's qnn-runtime $HOOK_QNN"

# 5. Check 16 KB page alignment. Google Play rejects an APK in which any .so
# has a PT_LOAD p_align below 16 KB. The dispatch is linked with
# max-page-size=16384 above, so this is a check, not a patch: a failure means
# the link flag stopped reaching the linker. (The 4 KB Hexagon Skels that used
# to be raised here are raised by the hook now — prepareQnnLibrary in
# lib/src/hook/qnn_runtime.dart.)
if [ "$TARGET" = android_arm64 ]; then
echo ""
echo "=== Checking 16 KB page alignment ==="
python3 - "$STAGE" <<'PYALIGN'
import glob, os, struct, sys

ALIGN = 0x4000
checked = 0
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.so"))):
    data = open(path, "rb").read()
    if data[:4] != b"\x7fELF" or data[4] != 2:
        sys.exit(f"ERROR: not an ELF64: {path}")
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    aligns = [struct.unpack_from("<Q", data, phoff + i * phentsize + 0x30)[0]
              for i in range(phnum)
              if struct.unpack_from("<I", data, phoff + i * phentsize)[0] == 1]
    if not aligns:
        sys.exit(f"ERROR: no PT_LOAD segment in {os.path.basename(path)}")
    if min(aligns) < ALIGN:
        sys.exit(f"ERROR: {os.path.basename(path)} has PT_LOAD p_align "
                 f"{hex(min(aligns))} < 16 KB")
    checked += 1
print(f"  {checked} .so checked, all PT_LOAD at >= 16 KB")
PYALIGN
fi

# 6. Verify the staged dispatch before it can reach the bundle. This is the one
# symbol the library exists to export; without it the NPU path is dead.
if ! nm -D "$STAGE/libLiteRtDispatch_Qualcomm.so" 2>/dev/null \
     | grep -q 'LiteRtDispatchGetApi'; then
  echo "ERROR: staged dispatch does not export LiteRtDispatchGetApi" >&2
  exit 1
fi

# Linux shim. Qualcomm's Linux Stubs (libQnnHtpV*Stub.so) carry
# `NEEDED libcdsprpc.so` and `RPATH $ORIGIN`, but Ubuntu's qcom-fastrpc1
# installs only libcdsprpc.so.1 — the bare name is a -dev symlink an end user
# does not have. So we ship a libcdsprpc.so of our own, with nothing in it but
# `NEEDED libcdsprpc.so.1`: next to the Stubs, $ORIGIN finds it, and it brings
# in the system FastRPC library whose symbols the Stubs then resolve. Linked
# against a stand-in libcdsprpc.so.1 built here (only its SONAME matters), so
# the build host needs no FastRPC.
if [ "$TARGET" = linux_arm64 ]; then
  SHIM_TMP="$(mktemp -d)"
  "$CC" -shared -fPIC -nostdlib -o "$SHIM_TMP/libcdsprpc.so.1" \
    -Wl,-soname,libcdsprpc.so.1 -x c /dev/null
  "$CC" -shared -fPIC -nostdlib -o "$STAGE/libcdsprpc.so" \
    -Wl,-soname,libcdsprpc.so -Wl,--no-as-needed "$SHIM_TMP/libcdsprpc.so.1" \
    -x c /dev/null
  rm -rf "$SHIM_TMP"
  SHIM_DYN="$(readelf -d "$STAGE/libcdsprpc.so")"
  if ! printf '%s\n' "$SHIM_DYN" | grep -q 'NEEDED.*\[libcdsprpc\.so\.1\]' ||
     ! printf '%s\n' "$SHIM_DYN" | grep -q 'SONAME.*\[libcdsprpc\.so\]'; then
    echo "ERROR: the libcdsprpc.so shim lacks NEEDED libcdsprpc.so.1 or SONAME libcdsprpc.so:" >&2
    printf '%s\n' "$SHIM_DYN" >&2
    exit 1
  fi
  echo ""
  echo "=== Linux dispatch: NEEDED and glibc floor ==="
  readelf -d "$STAGE/libLiteRtDispatch_Qualcomm.so" | grep NEEDED
  # `|| true`: no versioned import at all must reach the print, not pipefail.
  echo "  max GLIBC: $(objdump -T "$STAGE/libLiteRtDispatch_Qualcomm.so" \
    | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 || true)"
fi

# 7. Promote what this target's bundle carries: the dispatch, and on Linux the
# shim. Never the QNN runtime — the app's build hook fetches that.
want_staged=1
[ "$TARGET" = linux_arm64 ] && want_staged=2
staged=$(find "$STAGE" -maxdepth 1 -type f -name '*.so' | wc -l | tr -d ' ')
if [ "$staged" -ne "$want_staged" ]; then
  echo "ERROR: staged $staged files, expected $want_staged" >&2
  exit 1
fi
mkdir -p "$PREBUILT_DIR"
# QNN runtime libraries an older version of this script promoted must not stay
# behind: Step 4 of the release packs the whole directory, so a leftover would
# ship Qualcomm's runtime standalone again (verify_tarball_manifest.sh fails on
# them too, but the order these scripts run in should not matter).
for f in libQnnHtp.so libQnnSystem.so \
         libQnnHtpV73Stub.so libQnnHtpV75Stub.so libQnnHtpV79Stub.so libQnnHtpV81Stub.so \
         libQnnHtpV73Skel.so libQnnHtpV75Skel.so libQnnHtpV79Skel.so libQnnHtpV81Skel.so; do
  rm -f "$PREBUILT_DIR/$f"
done
for f in "$STAGE"/*.so; do
  cp -f "$f" "$PREBUILT_DIR/$(basename "$f")"
  chmod +w "$PREBUILT_DIR/$(basename "$f")"
done

echo ""
echo "=== Done ==="
echo "  $(cd "$STAGE" && ls *.so | tr '\n' ' ')→ $PREBUILT_DIR/ (QNN runtime: from Qualcomm via the app's hook)"
ls -lh "$PREBUILT_DIR/libLiteRtDispatch_Qualcomm.so"
[ "$TARGET" = linux_arm64 ] && ls -lh "$PREBUILT_DIR/libcdsprpc.so"
exit 0

#!/bin/bash
# Build libLiteRtLm.so for Android arm64 from LiteRT-LM source.
#
# Cross-compile from macOS host using Android NDK + Bazel.
#
# Prerequisites:
#   - Bazel (via bazelisk): brew install bazelisk
#   - Android NDK at ~/Library/Android/sdk/ndk/<version>/
#     (typically installed by Android Studio)
#   - Git LFS: brew install git-lfs
#
# Usage:
#   ./build_android.sh [ref]
#   ./build_android.sh b2f686e2       # v0.18.0 (the default)
#   ./build_android.sh v0.11.0        # WARNING: v0.11.0 prebuilt accelerators
#                                     # are ABI-incompatible with libLiteRtLm
#                                     # rebuilt from v0.11.0 source. Use 032334d
#                                     # (post-6571c42 which re-syncs accelerator
#                                     # binaries with WORKSPACE LITERT_REF).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/android_arm64"
LITERT_LM_DIR="/tmp/LiteRT-LM"
DEFAULT_REF="b2f686e2ed4718fb84ec398a61dd59ca0f0aff27"   # v0.18.0
VERSION="${1:-}"

# Resolve Android NDK — prefer ANDROID_NDK_HOME env, else newest under
# Android Studio default location.
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

# bazel rules_android needs ANDROID_HOME too — synthesize from NDK parent.
if [ -z "${ANDROID_HOME:-}" ]; then
  export ANDROID_HOME="$(dirname "$(dirname "$ANDROID_NDK_HOME")")"
  echo "Auto-detected ANDROID_HOME=$ANDROID_HOME"
fi

echo "=== Building libLiteRtLm.so for Android arm64 ==="
echo "ANDROID_NDK_HOME: $ANDROID_NDK_HOME"
echo "ANDROID_HOME: $ANDROID_HOME"

# 1. Clone or update LiteRT-LM
if [ -d "$LITERT_LM_DIR" ]; then
  echo "Updating $LITERT_LM_DIR..."
  cd "$LITERT_LM_DIR"
  # --force so a tag that moved upstream doesn't abort the fetch.
  git fetch --tags --force origin
else
  echo "Cloning LiteRT-LM..."
  git clone https://github.com/google-ai-edge/LiteRT-LM "$LITERT_LM_DIR"
  cd "$LITERT_LM_DIR"
fi

# 2. Checkout version (-f to discard any patch leftovers)
TARGET_REF="${VERSION:-$DEFAULT_REF}"
echo "Checking out $TARGET_REF..."
git checkout -f "$TARGET_REF"
echo "Building from: $(git log --oneline -1)"

# 3. Ensure cc_binary(linkshared=True) target exists in c/BUILD
if ! grep -q '"libLiteRtLm.dylib"' c/BUILD; then
  cat >> c/BUILD << 'BUILDEOF'

cc_binary(
    name = "libLiteRtLm.dylib",
    linkshared = True,
    linkopts = select({
        "@platforms//os:android": ["-Wl,-soname,libLiteRtLm.so"],
        "//conditions:default": [],
    }),
    visibility = ["//visibility:public"],
    deps = [":engine"],
)
BUILDEOF
fi

# 3b. Apply C API patch.
bash "$SCRIPT_DIR/patch_c_api.sh" "$LITERT_LM_DIR"

# 4. Pull LFS files
echo "Pulling LFS files..."
# The companion prebuilts come from a LATER upstream commit than the source.
# Upstream changed Constraint on 2026-08-21 (a8a8c445, a41b7c5c): ComputeMask
# took the vtable slot ComputeBitmap had, and the prebuilt provider at the
# v0.17.0 and v0.17.1 tags still implements the old one — so a tool call
# segfaults in CompositeLogitMask::Apply. Upstream refreshed the prebuilts on
# main in 4453b286, and that provider carries the LogitMask types. Upstream's
# own release lane never hits this: its wheel compiles the provider in.
PREBUILT_REF="${PREBUILT_REF:-b2f686e2ed4718fb84ec398a61dd59ca0f0aff27}"
echo "Taking prebuilt companions from $PREBUILT_REF"
git lfs pull --include="prebuilt/android_arm64/*"
# One file, from a different commit than the source: fetch it straight from the
# LFS media endpoint. `git restore --source=<ref>` does the same job, but then
# the ref lives in two places — the restore and this build's assumptions — and a
# stale one is invisible. A URL carries the ref where you can read it.
curl -fsSL -o "prebuilt/android_arm64/libGemmaModelConstraintProvider.so" \
  "https://media.githubusercontent.com/media/google-ai-edge/LiteRT-LM/$PREBUILT_REF/prebuilt/android_arm64/libGemmaModelConstraintProvider.so"
# Fail here, not an hour later at the end of the build: a wrong PREBUILT_REF
# looks exactly like a correct one until something reads the binary.
CONSTRAINT_H=runtime/components/constrained_decoding/constraint.h
[ -f "$CONSTRAINT_H" ] || {
  echo "ERROR: $CONSTRAINT_H is missing, so the provider ABI cannot be checked. A guard that cannot read its input must not pass." >&2
  exit 1
}
# Two-sided on purpose. A provider OLDER than the runtime segfaults in
# CompositeLogitMask::Apply; a provider NEWER than the runtime does the same
# thing from the other side, and that is reachable whenever this script is
# pointed at a ref from before upstream's 2026-08-21 Constraint change while
# PREBUILT_REF still names a post-change commit.
if grep -q 'ComputeMask' "$CONSTRAINT_H"; then want=1; else want=0; fi
PROVIDER="prebuilt/android_arm64/libGemmaModelConstraintProvider.so"
[ -s "$PROVIDER" ] || { echo "ERROR: $PROVIDER is missing or empty — a guard that cannot read its input must not pass." >&2; exit 1; }
# grep reads the binary directly: `strings … | grep -q` exits at the first
# match, SIGPIPEs strings, and under `set -o pipefail` the pipeline status is
# 141 — so the guard reported "no LogitMask" for every provider that has it.
if grep -q 'LogitMask' "$PROVIDER"; then have=1; else have=0; fi
[ "$want" = "$have" ] || {
  echo "ERROR: provider/runtime Constraint ABI mismatch (source wants ComputeMask=$want, provider has LogitMask=$have) — every tool call would segfault. Point PREBUILT_REF at a commit whose prebuilts match this source." >&2
  exit 1
}
echo "provider ABI: source and provider agree (ComputeMask=$want)"

# 5. Build for Android arm64
echo ""
echo "=== Building for Android arm64 ==="
# Note: Android deliberately does NOT use --define=litert_runtime_link_mode=dynamic.
# On Linux/Windows that define keeps the LiteRt C API out of libLiteRtLm so it
# resolves against a separate libLiteRt we ship alongside and preload via
# RTLD_GLOBAL from Dart. On Android, upstream's prebuilt accelerator libs are
# already linked against a fully self-contained libLiteRtLm.so, so we build the
# same way and ship no libLiteRt.so at all.
#
# (This note used to name `litert_link_capi_so=true`. That define no longer
# exists upstream — the deviation described here is still correct, only the
# flag's name changed.)
#
# 16KB page size support (Android 15+ on Pixel 8 and beyond, mandatory for
# Google Play uploads since Nov 2025 — see #253). max-page-size=16384 makes
# the linker pad PT_LOAD segments to 16KB boundaries; the binary is still
# loadable on 4KB-page kernels, just ~12KB larger per segment.
bazelisk build \
  -c opt \
  --strip=always \
  --config=android_arm64 \
  --linkopt=-Wl,-z,max-page-size=16384 \
  '//c:libLiteRtLm.dylib'

# 6. Copy + rename .dylib → .so (bazel target name is hardcoded to .dylib).
mkdir -p "$PREBUILT_DIR"
cp bazel-bin/c/libLiteRtLm.dylib "$PREBUILT_DIR/libLiteRtLm.so"
chmod +w "$PREBUILT_DIR/libLiteRtLm.so"
echo "  libLiteRtLm.so → $PREBUILT_DIR/"

# 7. Build StreamProxy for Android (cross-compile via NDK toolchain).
NDK_TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64"
if [ ! -d "$NDK_TOOLCHAIN" ]; then
  # Apple silicon hosts: NDK r26+ has darwin-x86_64 with x86_64 binaries
  # that run via Rosetta. r28+ may have native arm64 — try that first.
  NDK_TOOLCHAIN_ARM64="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-arm64"
  if [ -d "$NDK_TOOLCHAIN_ARM64" ]; then
    NDK_TOOLCHAIN="$NDK_TOOLCHAIN_ARM64"
  fi
fi
NDK_CLANG="$NDK_TOOLCHAIN/bin/aarch64-linux-android24-clang"
if [ ! -x "$NDK_CLANG" ]; then
  echo "ERROR: NDK clang not found at $NDK_CLANG"
  echo "Available toolchain bins:"
  ls "$NDK_TOOLCHAIN/bin/" 2>/dev/null | head -20
  exit 2
fi

echo ""
echo "=== Building StreamProxy with $NDK_CLANG ==="
# 16KB page-size flag for Google Play parity with libLiteRtLm.so build above.
# NDK r25+ defaults to this anyway, but make it explicit so older NDKs work.
"$NDK_CLANG" -shared -fPIC \
  -Wl,-z,max-page-size=16384 \
  -o "$PREBUILT_DIR/libStreamProxy.so" \
  "$SCRIPT_DIR/stream_proxy.c"
echo "  libStreamProxy.so → $PREBUILT_DIR/"

# 8. Copy companion libs from upstream prebuilt (we don't rebuild these
#    — they're Google's GPU accelerator + sampler binaries).
#
#    Android GPU is OpenCL only. upstream's prebuilt/android_arm64/ also carries
#    libLiteRtGpuAccelerator.so, libLiteRtWebGpuAccelerator.so and
#    libLiteRtTopKWebGpuSampler.so, and all three list libwebgpu_dawn.so in
#    NEEDED. We never shipped Dawn on Android, so from native-v0.14.0 (when Dawn
#    was split out) through v0.17.x those three sat in every APK (~18 MB) and
#    could not be dlopen'ed; gpu_registry silently moved on to the OpenCL
#    accelerator. Google's own Android SDKs ship no Dawn either: the
#    litertlm-android AAR is a single liblitertlm_jni.so with ML Drift OpenCL
#    linked in, and litert-gpu ships only libLiteRtClGlAccelerator.so. Adding
#    Dawn instead would put a different accelerator first in gpu_registry's
#    order on every Android device — a path nobody ships.
echo ""
echo "=== Copying companion libs from upstream prebuilt ==="
for lib in libGemmaModelConstraintProvider.so \
           libLiteRtOpenClAccelerator.so \
           libLiteRtTopKOpenClSampler.so; do
  if [ -f "prebuilt/android_arm64/$lib" ]; then
    cp "prebuilt/android_arm64/$lib" "$PREBUILT_DIR/$lib"
    echo "  $lib"
  else
    echo "ERROR: prebuilt/android_arm64/$lib not found in upstream" >&2
    exit 1
  fi
done
# PREBUILT_DIR outlives builds: drop copies a ≤0.17 build left there, or they
# get packed into the tarball again.
for lib in libLiteRtGpuAccelerator.so \
           libLiteRtWebGpuAccelerator.so \
           libLiteRtTopKWebGpuSampler.so; do
  if [ -f "$PREBUILT_DIR/$lib" ]; then
    rm -f "$PREBUILT_DIR/$lib"
    echo "  removed stale $lib (needs Dawn, not shipped on Android)"
  fi
done

# Qualcomm NPU: only OUR dispatch ships in this bundle (built from the LiteRT
# pin by build_qualcomm_dispatch.sh, Apache 2.0). Qualcomm's QNN runtime is
# not ours to redistribute standalone: since native-v0.18.0 an app that sets
# `qualcomm_npu: true` gets it from Qualcomm's Maven artifact through the
# build hook. PREBUILT_DIR outlives builds, so delete QNN copies an older run
# staged here — otherwise they get packed into the release again.
if [ -f "$PREBUILT_DIR/libLiteRtDispatch_Qualcomm.so" ]; then
  echo "  libLiteRtDispatch_Qualcomm.so (Qualcomm NPU dispatch)"
else
  echo "  WARN: libLiteRtDispatch_Qualcomm.so not staged yet — run build_qualcomm_dispatch.sh"
fi
for lib in libQnnHtp.so libQnnSystem.so \
           libQnnHtpV73Stub.so libQnnHtpV73Skel.so \
           libQnnHtpV75Stub.so libQnnHtpV75Skel.so \
           libQnnHtpV79Stub.so libQnnHtpV79Skel.so \
           libQnnHtpV81Stub.so libQnnHtpV81Skel.so; do
  if [ -f "$PREBUILT_DIR/$lib" ]; then
    rm -f "$PREBUILT_DIR/$lib"
    echo "  removed stale $lib (QNN comes from Qualcomm's Maven artifact)"
  fi
done

# 8b. Patch sampler libs with DT_NEEDED libLiteRtLm.so. Bionic per-library
#     linker namespaces (Nougat+) only resolve UND symbols against the
#     caller's DT_NEEDED chain, NOT against arbitrary libs already loaded
#     in the process. Upstream samplers reference LiteRtCreateEnvironment
#     as UND but ship with NEEDED list containing only libm/libdl/liblog/
#     libc — so dlopen fails at runtime and the engine silently falls back
#     to CPU sampling (~3× decode slowdown). Adding libLiteRtLm.so to
#     NEEDED on each sampler binary lets bionic resolve LiteRtCreateEnvironment
#     against our libLiteRtLm.so (which exports it). See:
#       - DenisovAV/flutter_edge_ai#270
#       - google-ai-edge/LiteRT-LM#2211
if ! command -v patchelf >/dev/null 2>&1; then
  echo "ERROR: patchelf not installed — the DT_NEEDED fixes below cannot run," >&2
  echo "       and a bundle without them crashes on device (#270, #545)." >&2
  echo "       Install with: brew install patchelf" >&2
  exit 1
else
  echo ""
  echo "=== Patching sampler DT_NEEDED (#270) ==="
  for lib in libLiteRtTopKOpenClSampler.so; do
    if [ -f "$PREBUILT_DIR/$lib" ]; then
      # Idempotent: only add if not already present.
      if ! patchelf --print-needed "$PREBUILT_DIR/$lib" | grep -q '^libLiteRtLm\.so$'; then
        patchelf --add-needed libLiteRtLm.so "$PREBUILT_DIR/$lib"
        echo "  $lib: added libLiteRtLm.so to NEEDED"
      else
        echo "  $lib: libLiteRtLm.so already in NEEDED, skipping"
      fi
    fi
  done
fi

# 8c. Patch GPU accelerator libs with DT_NEEDED libandroid.so. At the pinned
#     PREBUILT_REF, upstream's libLiteRtOpenClAccelerator.so and
#     libLiteRtGpuAccelerator.so reference AHardwareBuffer_allocate/_release
#     as WEAK UND but list neither libandroid.so nor libnativewindow.so in
#     NEEDED, so under BIND_NOW both bind to NULL (same bionic rule as 8b:
#     a symbol only resolves through the library's own DT_NEEDED chain).
#     Adreno evidently doesn't take that path (the GPU backend works there).
#     On Mali, weights preparation on GPU is disabled and buffers go through
#     AHardwareBuffer, so engine_create jumps to address 0 (SIGSEGV) while
#     delegating the decode subgraph.
#     Upstream fixed this by linking accelerators with -landroid under
#     --no-as-needed (litert_accelerator_library in LiteRT); newer LiteRT-LM
#     prebuilts already carry libandroid.so, so this becomes a no-op once
#     PREBUILT_REF moves past that change. libandroid.so pulls in
#     libnativewindow.so. Verified on Galaxy A34 (Mali-G68 MC4).
#     The v0.18.0 prebuilts already list libandroid.so, so this prints
#     "already in NEEDED"; kept as a guard against a regression upstream.
#     patchelf is guaranteed here: step 8b exits without it.
echo ""
echo "=== Patching GPU accelerator DT_NEEDED (Mali AHardwareBuffer) ==="
for lib in libLiteRtOpenClAccelerator.so; do
  if [ -f "$PREBUILT_DIR/$lib" ]; then
    # Idempotent: only add if not already present.
    if ! patchelf --print-needed "$PREBUILT_DIR/$lib" | grep -q '^libandroid\.so$'; then
      patchelf --add-needed libandroid.so "$PREBUILT_DIR/$lib"
      echo "  $lib: added libandroid.so to NEEDED"
    else
      echo "  $lib: libandroid.so already in NEEDED, skipping"
    fi
  fi
done

# 8d. Every import must be reachable through the library's own NEEDED (#545).
#     8b and 8c fix the cases we know about; this catches the next one.
echo ""
echo "=== DT_NEEDED closure ==="
python3 "$SCRIPT_DIR/check_android_needed.py" "$PREBUILT_DIR" || exit 1

# 9. Verify
echo ""
echo "=== Verification ==="
ls -lh "$PREBUILT_DIR/" | head -20
echo ""
echo "Symbols (libLiteRtLm.so):"
nm -D "$PREBUILT_DIR/libLiteRtLm.so" 2>/dev/null | grep -i "litert_lm_engine_create\|SetPendingSamplerParams" | head -5

echo ""
echo "=== Done ==="
echo "Version: $(cd $LITERT_LM_DIR && git log --oneline -1)"

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
#   ./build_android.sh 7a03724c       # v0.19.1 (the default)
#   ./build_android.sh v0.11.0        # WARNING: v0.11.0 prebuilt accelerators
#                                     # are ABI-incompatible with libLiteRtLm
#                                     # rebuilt from v0.11.0 source. Use 032334d
#                                     # (post-6571c42 which re-syncs accelerator
#                                     # binaries with WORKSPACE LITERT_REF).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/android_arm64"
LITERT_LM_DIR="${LITERT_LM_DIR:-/tmp/LiteRT-LM}"
DEFAULT_REF="7a03724cece417f1724c923b3d527b4319730841"   # v0.19.1
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
# Only the C APIs leave the library: litert_lm_* for the Dart client and
# LiteRt* for the companions that resolve the runtime through NEEDED (the TopK
# sampler, #270; the NPU dispatches). Everything else stays local. From
# v0.19.0 libLiteRtLm NEEDs libEGL/libGLES (the static OpenCL accelerator),
# whose vendor stack loads the system libprotobuf-cpp-lite in the same dlopen;
# with our ~3900 protobuf symbols exported, its constructors bound to ours and
# SIGSEGVed (Galaxy S25 Ultra, 2026-11-01). Upstream's own //c:litert-lm does
# the same with c/litert_lm_c_api_linux.lds.
cat > c/flutter_edge_ai_android_exports.lds << 'LDSEOF'
{
  global:
    litert_lm_*;
    LiteRt*;
  local:
    *;
};
LDSEOF
if ! grep -q '"libLiteRtLm.dylib"' c/BUILD; then
  cat >> c/BUILD << 'BUILDEOF'

cc_binary(
    name = "libLiteRtLm.dylib",
    additional_linker_inputs = [":flutter_edge_ai_android_exports.lds"],
    linkshared = True,
    linkopts = select({
        "@platforms//os:android": [
            "-Wl,-soname,libLiteRtLm.so",
            "-Wl,--version-script=$(location :flutter_edge_ai_android_exports.lds)",
        ],
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
PREBUILT_REF="${PREBUILT_REF:-7a03724cece417f1724c923b3d527b4319730841}"
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
  '//c:libLiteRtLm.dylib' \
  '@litert//litert/vendors/google_tensor/dispatch:dispatch_api_so'

# LiteRT-LM v0.19.0 stopped shipping prebuilt TopK GPU samplers (43b79e8); the
# OpenCL one is built from source with ML Drift (47d7ba6). Older refs have no
# such target and keep the prebuilt.
if grep -q 'name = "top_k_opencl_sampler_so"' runtime/components/BUILD; then
  bazelisk build \
    -c opt \
    --strip=always \
    --config=android_arm64 \
    --linkopt=-Wl,-z,max-page-size=16384 \
    '//runtime/components:top_k_opencl_sampler_so'
fi

# 6. Copy + rename .dylib → .so (bazel target name is hardcoded to .dylib).
mkdir -p "$PREBUILT_DIR"
cp bazel-bin/c/libLiteRtLm.dylib "$PREBUILT_DIR/libLiteRtLm.so"
chmod +w "$PREBUILT_DIR/libLiteRtLm.so"
echo "  libLiteRtLm.so → $PREBUILT_DIR/"

# Google Tensor NPU dispatch bridge. The target's sources and BUILD file in the
# pinned LiteRT tree carry Apache-2.0 headers. It is built from the exact LiteRT
# commit resolved by this LiteRT-LM ref, then late-binds libedgetpu_litert.so
# from the Pixel system image at runtime. Neither the proprietary system runtime
# nor the separately licensed Google Tensor compiler/SDK is built or bundled.
GOOGLE_TENSOR_DISPATCH="$(find -L bazel-bin -type f \
  -path '*/litert/vendors/google_tensor/dispatch/libLiteRtDispatch_GoogleTensor.so' \
  -print -quit)"
if [ -z "$GOOGLE_TENSOR_DISPATCH" ] || [ ! -f "$GOOGLE_TENSOR_DISPATCH" ]; then
  echo "ERROR: Google Tensor dispatch output not found" >&2
  find -L bazel-bin -path '*google_tensor*' -name '*.so' -print >&2 || true
  exit 1
fi
cp "$GOOGLE_TENSOR_DISPATCH" "$PREBUILT_DIR/libLiteRtDispatch_GoogleTensor.so"
chmod +w "$PREBUILT_DIR/libLiteRtDispatch_GoogleTensor.so"
echo "  libLiteRtDispatch_GoogleTensor.so → $PREBUILT_DIR/"

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

# 7b. The MediaTek dispatch adapter (LiteRT-LM v0.19.0 on): our
#     libLiteRtDispatch_MediaTek.so gives Google's legacy MediaTek dispatch
#     the versioned dispatch ABI LiteRT now requires
#     (mediatek_dispatch_compat.c). It does not ship: the MediaTek NPU is
#     refused in core 2.6.0 (design decision K, 2026-11-03), and the release
#     gate forbids the name in the Android archive. BUILD_MEDIATEK_ADAPTER=1
#     builds it, with its host test, into $PREBUILT_DIR/../mediatek_adapter,
#     outside the archive. The host test is part of CI either way.
if [ "${BUILD_MEDIATEK_ADAPTER:-0}" = 1 ]; then
  echo ""
  echo "=== MediaTek dispatch adapter (not shipped) ==="
  LITERT_DIR="${LITERT_DIR:-}" "$SCRIPT_DIR/run_mediatek_dispatch_compat_test.sh"
  ADAPTER_DIR="$PREBUILT_DIR/../mediatek_adapter"
  mkdir -p "$ADAPTER_DIR"
  "$NDK_CLANG" -std=c11 -O2 -shared -fPIC -fvisibility=hidden \
    -Wall -Wextra -Werror \
    -Wl,-z,max-page-size=16384 \
    -Wl,-soname,libLiteRtDispatch_MediaTek.so \
    -o "$ADAPTER_DIR/libLiteRtDispatch_MediaTek.so" \
    "$SCRIPT_DIR/mediatek_dispatch_compat.c"
  echo "  libLiteRtDispatch_MediaTek.so → $ADAPTER_DIR/"
fi

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
# From native-v0.19.0-a only the constraint provider: libLiteRtLm.so links the
# OpenCL accelerator and sampler in (patch_c_api.sh section 19), and Adreno 830
# and Mali-G715 run the GPU without upstream's separate
# libLiteRtOpenClAccelerator.so and libLiteRtTopKOpenClSampler.so with the
# same results (DDP, 2026-11-04), so those two are no longer shipped.
for lib in libGemmaModelConstraintProvider.so; do
  if [ -f "prebuilt/android_arm64/$lib" ]; then
    cp "prebuilt/android_arm64/$lib" "$PREBUILT_DIR/$lib"
    echo "  $lib"
  elif [ -f "bazel-bin/runtime/components/$lib" ]; then
    cp "bazel-bin/runtime/components/$lib" "$PREBUILT_DIR/$lib"
    chmod +w "$PREBUILT_DIR/$lib"
    echo "  $lib (built from source)"
  else
    echo "ERROR: prebuilt/android_arm64/$lib not found in upstream" >&2
    exit 1
  fi
done
# PREBUILT_DIR outlives builds: drop copies an older build left there, or they
# get packed into the tarball again.
for lib in libLiteRtGpuAccelerator.so \
           libLiteRtOpenClAccelerator.so \
           libLiteRtTopKOpenClSampler.so \
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

# 8b/8c (until native-v0.18.0-h): patchelf added libLiteRtLm.so to the OpenCL
#     sampler's NEEDED (#270) and libandroid.so to the OpenCL accelerator's
#     (the Mali crash, #545). Both libraries left the bundle in
#     native-v0.19.0-a (the accelerator and sampler are linked into
#     libLiteRtLm.so, section 19), so nothing is patched here any more; 8d
#     still checks every import of what ships.
# 8d. Every import must be reachable through the library's own NEEDED (#545).
#     It caught #270 and #545 before 8b/8c fixed them; it catches the next one.
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

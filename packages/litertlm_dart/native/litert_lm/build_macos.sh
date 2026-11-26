#!/bin/bash
# Build libLiteRtLm.dylib for macOS arm64 from LiteRT-LM source.
#
# Prerequisites:
#   - Bazel (via bazelisk): brew install bazelisk
#   - Xcode command line tools
#   - Git LFS: brew install git-lfs
#
# Usage:
#   ./build_macos.sh [ref]
#   ./build_macos.sh 95df4c2a       # v0.20.0 (the default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/macos_arm64"
LITERT_LM_DIR="${LITERT_LM_DIR:-/tmp/LiteRT-LM}"
DEFAULT_REF="95df4c2a932b4917ace66fcfef6c154e8d2a6699"   # v0.20.0
VERSION="${1:-}"

# Since v0.18.0 the WORKSPACE registers the Android NDK toolchain whenever
# ANDROID_NDK_HOME is set, even for an Apple build — and a value pointing at an
# NDK that is no longer installed fails analysis ("can't readdir(), not a
# directory"). This build needs no NDK.
unset ANDROID_NDK_HOME

echo "=== Building libLiteRtLm.dylib for macOS arm64 ==="

# 1. Clone or update LiteRT-LM
if [ -d "$LITERT_LM_DIR" ]; then
  echo "Updating $LITERT_LM_DIR..."
  cd "$LITERT_LM_DIR"
  # --force so a tag that moved upstream (e.g. v0.11.0 itself was retagged
  # while we waited for accelerator fixes) doesn't abort the fetch.
  git fetch --tags --force origin
else
  echo "Cloning LiteRT-LM..."
  git clone https://github.com/google-ai-edge/LiteRT-LM "$LITERT_LM_DIR"
  cd "$LITERT_LM_DIR"
fi

# 2. Checkout version
TARGET_REF="${VERSION:-$DEFAULT_REF}"
echo "Checking out $TARGET_REF..."
git checkout -f "$TARGET_REF"

echo "Building from: $(git log --oneline -1)"

# 3. Ensure cc_binary(linkshared=True) target exists in c/BUILD
if ! grep -q '"libLiteRtLm.dylib"' c/BUILD; then
  echo "Adding shared library target to c/BUILD..."
  cat >> c/BUILD << 'BUILDEOF'

cc_binary(
    name = "libLiteRtLm.dylib",
    linkshared = True,
    visibility = ["//visibility:public"],
    deps = [":engine"],
)
BUILDEOF
fi

# 3b. Apply C API patch (adds set_max_num_images, set_litert_dispatch_lib_dir,
# 6-arg conversation_config_create, etc). git checkout above resets the
# source tree, so we re-apply on every build. Use SCRIPT_DIR captured
# at top of file (we are now in $LITERT_LM_DIR after cd above).
bash "$SCRIPT_DIR/patch_c_api.sh" "$LITERT_LM_DIR"

# 4. No prebuilt companion. Up to native-v0.19.1 this pulled Google's prebuilt
# libGemmaModelConstraintProvider (FST tool-call constraints) from upstream's
# LFS prebuilt/ and checked its Constraint ABI against the source. From
# native-v0.20.0 the tool-call constraints are built with LLGuidance from
# source (patch_c_api.sh section 29), so libLiteRtLm links no provider and none
# ships; the check after the build refuses a libLiteRtLm that still names one.
# The LFS pull stays for upstream's other prebuilt (Dawn), which a target of
# the tree may name; the provider it also pulls is linked by nothing.
echo "Pulling LFS files..."
git lfs pull --include="prebuilt/macos_arm64/*"
grep -q 'enable_fst_constraints=false' .bazelrc || {
  echo "ERROR: .bazelrc does not turn FST constraints off (patch_c_api.sh section 29); the build would link Google's prebuilt constraint provider." >&2
  exit 1
}

# 5. Build
echo "Building with Bazel..."
# From LiteRT-LM v0.19.0 the GPU accelerator and the TopK samplers are linked
# into libLiteRtLm on Apple. macOS defaults to ML Drift WebGPU, which makes
# libLiteRtLm NEED libwebgpu_dawn.dylib; Metal keeps it to Metal, the backend
# we ship on macOS. Older trees have no such flag.
GPU_FLAG=()
if grep -q 'name = "gpu_accelerator"' runtime/executor/BUILD 2>/dev/null; then
  GPU_FLAG=(--//runtime/executor:gpu_accelerator="${MACOS_GPU_ACCELERATOR:-metal}")
fi
bazelisk build -c opt --strip=always --config=macos_arm64 "${GPU_FLAG[@]}" '//c:libLiteRtLm.dylib'

# 6. Copy to prebuilt
BUILT_LIB="bazel-bin/c/libLiteRtLm.dylib"
if [ ! -f "$BUILT_LIB" ]; then
  echo "ERROR: Build output not found: $BUILT_LIB"
  exit 1
fi

mkdir -p "$PREBUILT_DIR"

# Fix install_name and add rpath for framework bundle layout
cp "$BUILT_LIB" "$PREBUILT_DIR/libLiteRtLm.dylib"
chmod +w "$PREBUILT_DIR/libLiteRtLm.dylib"
install_name_tool -id @rpath/libLiteRtLm.dylib "$PREBUILT_DIR/libLiteRtLm.dylib"
install_name_tool -add_rpath '@loader_path/../../..' "$PREBUILT_DIR/libLiteRtLm.dylib" 2>/dev/null || true

# No companion library ships. Up to native-v0.19.1 Google's prebuilt Gemma
# constraint provider and Metal accelerator were copied here. From
# native-v0.20.0 the tool-call constraints come from LLGuidance (patch_c_api.sh
# section 29) and libLiteRtLm links the Metal accelerator in
# (runtime/executor:default_static_gpu_accelerator, set by
# LiteRtStaticLinkedAcceleratorGpuDef when the library loads), which LiteRT's
# gpu_registry registers before it dlopens anything (0.20 migration decision
# D1). Stale copies are removed.
rm -f "$PREBUILT_DIR/libLiteRtMetalAccelerator.dylib" "$PREBUILT_DIR/libLiteRtLmMetalAccelerator.dylib" \
  "$PREBUILT_DIR/libGemmaModelConstraintProvider.dylib"

# 7. Build stream proxy
echo "Building stream proxy..."
# -mmacosx-version-min is not optional: without it clang stamps LC_BUILD_VERSION
# with the *build host's* OS, so the bundle's minimum silently tracks whichever
# Mac produced it (native-v0.14.0 shipped minos 26.0 this way). Pin it to 11.0 to
# match libLiteRtLm.dylib, which sets the bundle's real floor. build_ios.sh does
# the equivalent in step 8b via `vtool -set-build-version`; macOS had no such step.
clang -shared -o "$PREBUILT_DIR/libStreamProxy.dylib" \
  -arch arm64 \
  -mmacosx-version-min=11.0 \
  -install_name @rpath/libStreamProxy.dylib \
  -Wl,-headerpad_max_install_names \
  "$SCRIPT_DIR/stream_proxy.c"

# 8. Verify
echo ""
echo "=== Verification ==="
# The GPU accelerator is linked into libLiteRtLm: loading the library must set
# LiteRtStaticLinkedAcceleratorGpuDef, which gpu_registry registers before it
# tries any library. A build that lost it would dlopen a framework no bundle
# carries and run the GPU on the CPU with no error, so this loads the library
# for real and reads the pointer.
# A check that reads a library with `strings … || true` passes on a file
# that is missing or empty; refuse those first.
require_library() {
  if [ ! -s "$1" ]; then
    echo "ERROR: $1 is missing or empty" >&2
    exit 1
  fi
}
check_static_gpu_accelerator() {
  local dir="$1" probe
  require_library "$dir/libLiteRtLm.dylib"
  probe="$(mktemp -d)/static_gpu_probe"
  cat > "$probe.c" << 'CEOF'
#include <dlfcn.h>
#include <stdio.h>
int main(int argc, char** argv) {
  void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 2; }
  void** def = (void**)dlsym(lib, "LiteRtStaticLinkedAcceleratorGpuDef");
  if (!def) { fprintf(stderr, "LiteRtStaticLinkedAcceleratorGpuDef is not exported\n"); return 3; }
  if (!*def) { fprintf(stderr, "LiteRtStaticLinkedAcceleratorGpuDef is null after load\n"); return 4; }
  return 0;
}
CEOF
  clang -arch arm64 -o "$probe" "$probe.c"
  if DYLD_LIBRARY_PATH="$dir" "$probe" "$dir/libLiteRtLm.dylib"; then
    echo "  GPU: Metal accelerator statically linked (LiteRtStaticLinkedAcceleratorGpuDef set)"
  else
    echo "ERROR: libLiteRtLm has no statically linked GPU accelerator" >&2
    exit 1
  fi
}
# Every framework libLiteRtLm dlopens by path must be in the bundle. From
# native-v0.20.0 LiteRT's gpu_registry dlopens nothing on Apple
# (patches/litert_gpu_registry_apple.patch), so none should be named at all.
check_dlopened_frameworks() {
  local dir="$1" fw missing=0
  require_library "$dir/libLiteRtLm.dylib"
  for fw in $(strings "$dir/libLiteRtLm.dylib" \
                | grep -oE '@executable_path/(\.\./)?Frameworks/[A-Za-z0-9_]+\.framework/' \
                | sed -E 's|.*Frameworks/([A-Za-z0-9_]+)\.framework/|\1|' | sort -u); do
    if [ -f "$dir/lib$fw.dylib" ]; then
      echo "  dlopen target $fw.framework: lib$fw.dylib present"
    else
      echo "ERROR: libLiteRtLm dlopens $fw.framework but $dir/lib$fw.dylib is missing" >&2
      missing=1
    fi
  done
  # No GPU accelerator library may be named: one that resolved (or, after a
  # failed dlopen, the default lookup) in an app with flutter_litert binds that
  # runtime's accelerator and crashes (patches/litert_gpu_registry_apple.patch). No `grep -q`: under pipefail its
  # early exit SIGPIPEs strings and reads as "not found".
  local foreign
  foreign="$(strings "$dir/libLiteRtLm.dylib" \
    | grep -E 'libLiteRt[A-Za-z]*Accelerator|LiteRt(Lm)?MetalAccelerator' || true)"
  if [ -n "$foreign" ]; then
    echo "ERROR: libLiteRtLm still names another GPU accelerator: $foreign" >&2
    missing=1
  fi
  [ "$missing" -eq 0 ] || exit 1
}
# No constraint provider, linked or named: the tool-call constraints are
# LLGuidance's (patch_c_api.sh section 29). No `grep -q` (pipefail, see above).
check_no_constraint_provider() {
  local dir="$1" named
  require_library "$dir/libLiteRtLm.dylib"
  named="$( { otool -L "$dir/libLiteRtLm.dylib"; strings "$dir/libLiteRtLm.dylib"; } \
    | grep -E 'GemmaModelConstraintProvider' || true)"
  if [ -n "$named" ]; then
    echo "ERROR: libLiteRtLm still links or names the Gemma constraint provider: $named" >&2
    exit 1
  fi
  echo "  constraints: no Gemma constraint provider linked or named (LLGuidance)"
}
check_static_gpu_accelerator "$PREBUILT_DIR"
check_dlopened_frameworks "$PREBUILT_DIR"
check_no_constraint_provider "$PREBUILT_DIR"
echo "Symbols:"
nm -gU "$PREBUILT_DIR/libLiteRtLm.dylib" | grep "litert_lm_engine_create" | head -2
echo ""
echo "Files:"
ls -lh "$PREBUILT_DIR/"
echo ""
echo "=== Done ==="
echo "Version: $(git describe --tags --always)"

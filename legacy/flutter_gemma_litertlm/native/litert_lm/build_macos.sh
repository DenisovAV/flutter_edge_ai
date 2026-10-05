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
#   ./build_macos.sh e9fd8c53       # v0.17.0 (the default)
#   ./build_macos.sh v0.11.0        # WARNING: v0.11.0 prebuilt accelerators
#                                   # are ABI-incompatible with libLiteRtLm
#                                   # rebuilt from v0.11.0 source — crashes
#                                   # in libLiteRtMetalAccelerator on engine
#                                   # init/teardown. Use 032334d (post-6571c42
#                                   # on main, which re-syncs accelerator
#                                   # binaries with WORKSPACE LITERT_REF).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PREBUILT_DIR="$SCRIPT_DIR/prebuilt/macos_arm64"
LITERT_LM_DIR="/tmp/LiteRT-LM"
DEFAULT_REF="e9fd8c53ff968071774206163027dd84bedfe925"   # v0.17.0
VERSION="${1:-}"

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

# 4. Pull LFS files (prebuilt companion libs)
echo "Pulling LFS files..."
# The companion prebuilts come from a LATER upstream commit than the source.
# Upstream changed Constraint on 2026-08-21 (a8a8c445, a41b7c5c): ComputeMask
# took the vtable slot ComputeBitmap had, and the prebuilt provider at the
# v0.17.0 and v0.17.1 tags still implements the old one — so a tool call
# segfaults in CompositeLogitMask::Apply. Upstream refreshed the prebuilts on
# main in 4453b286, and that provider carries the LogitMask types. Upstream's
# own release lane never hits this: its wheel compiles the provider in.
PREBUILT_REF="${PREBUILT_REF:-4453b286c549d216584866ed49b6fed6d11fa3a7}"
echo "Taking prebuilt companions from $PREBUILT_REF"
git lfs pull --include="prebuilt/macos_arm64/*"
# One file, from a different commit than the source: fetch it straight from the
# LFS media endpoint. `git restore --source=<ref>` does the same job, but then
# the ref lives in two places — the restore and this build's assumptions — and a
# stale one is invisible. A URL carries the ref where you can read it.
curl -fsSL -o "prebuilt/macos_arm64/libGemmaModelConstraintProvider.dylib" \
  "https://media.githubusercontent.com/media/google-ai-edge/LiteRT-LM/$PREBUILT_REF/prebuilt/macos_arm64/libGemmaModelConstraintProvider.dylib"
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
PROVIDER="prebuilt/macos_arm64/libGemmaModelConstraintProvider.dylib"
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

# 5. Build
echo "Building with Bazel..."
bazelisk build -c opt --strip=always --config=macos_arm64 '//c:libLiteRtLm.dylib'

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

# Copy companion libs from prebuilt
for lib in libGemmaModelConstraintProvider.dylib libLiteRtMetalAccelerator.dylib; do
  if [ -f "prebuilt/macos_arm64/$lib" ]; then
    cp "prebuilt/macos_arm64/$lib" "$PREBUILT_DIR/$lib"
    echo "Copied $lib"
  fi
done

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
echo "Symbols:"
nm -gU "$PREBUILT_DIR/libLiteRtLm.dylib" | grep "litert_lm_engine_create" | head -2
echo ""
echo "Files:"
ls -lh "$PREBUILT_DIR/"
echo ""
echo "=== Done ==="
echo "Version: $(git describe --tags --always)"

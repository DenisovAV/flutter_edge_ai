#!/bin/bash
# Build libLiteRtLm.dylib for iOS device (arm64) and simulator (arm64).
#
# Prerequisites:
#   - Bazel (via bazelisk): brew install bazelisk
#   - Xcode with iOS SDK
#   - Git LFS: brew install git-lfs
#
# Usage:
#   ./build_ios.sh [ref]
#   ./build_ios.sh e9fd8c53       # v0.17.0 (the default)
#   ./build_ios.sh v0.11.0        # WARNING: v0.11.0 prebuilt accelerators
#                                 # are ABI-incompatible with libLiteRtLm
#                                 # rebuilt from v0.11.0 source — crashes
#                                 # in libLiteRtMetalAccelerator on engine
#                                 # init/teardown. Use 032334d (post-6571c42
#                                 # which re-syncs accelerator binaries with
#                                 # WORKSPACE LITERT_REF).
#   ./build_ios.sh v0.10.2        # WARNING: predates Metal accelerator,
#                                 # produces libLiteRtLm.dylib that crashes
#                                 # iPhone GPU with EXC_BAD_ACCESS in
#                                 # litert_lm_engine_create.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LITERT_LM_DIR="${LITERT_LM_DIR:-/tmp/LiteRT-LM}"
VERSION="${1:-}"

echo "=== Building libLiteRtLm.dylib for iOS ==="

# 1. Clone or update LiteRT-LM
if [ -d "$LITERT_LM_DIR/.git" ]; then
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
# v0.17.0. Build from a release tag: its source and its prebuilt accelerator
# dylibs come from one tree, which is the invariant that matters — mixing
# them is what crashed in libLiteRtMetalAccelerator (see the build-native
# skill). v0.11.0 itself is broken — see the WARNING above.
DEFAULT_REF="e9fd8c53ff968071774206163027dd84bedfe925"
TARGET_REF="${VERSION:-$DEFAULT_REF}"
echo "Checking out $TARGET_REF..."
git checkout -f "$TARGET_REF"
echo "Building from: $(git log --oneline -1)"

# 3. Ensure shared library target exists
if ! grep -q '"libLiteRtLm.dylib"' c/BUILD; then
  echo "Adding shared library target to c/BUILD..."
  cat >> c/BUILD << 'BUILDEOF'

cc_binary(
    name = "libLiteRtLm.dylib",
    linkshared = True,
    linkopts = select({
        "@platforms//os:macos": ["-Wl,-exported_symbol,_LiteRt*", "-Wl,-exported_symbol,_litert_lm_*"],
        "@platforms//os:ios": ["-Wl,-exported_symbol,_LiteRt*", "-Wl,-exported_symbol,_litert_lm_*", "-Wl,-x"],
        "@platforms//os:linux": ["-Wl,--export-dynamic-symbol=LiteRt*", "-Wl,--export-dynamic-symbol=litert_lm_*"],
        "//conditions:default": [],
    }),
    visibility = ["//visibility:public"],
    deps = [":engine"],
)
BUILDEOF
fi

# 3b. Apply C API patch (adds set_max_num_images, set_litert_dispatch_lib_dir, etc).
# git checkout above resets the source tree, so we re-apply on every build.
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
PREBUILT_REF="${PREBUILT_REF:-4453b286c549d216584866ed49b6fed6d11fa3a7}"
echo "Taking prebuilt companions from $PREBUILT_REF"
git lfs pull --include="prebuilt/ios_arm64/*,prebuilt/ios_sim_arm64/*"
# One file, from a different commit than the source: fetch it straight from the
# LFS media endpoint. `git restore --source=<ref>` does the same job, but then
# the ref lives in two places — the restore and this build's assumptions — and a
# stale one is invisible. A URL carries the ref where you can read it.
curl -fsSL -o "prebuilt/ios_arm64/libGemmaModelConstraintProvider.dylib" \
  "https://media.githubusercontent.com/media/google-ai-edge/LiteRT-LM/$PREBUILT_REF/prebuilt/ios_arm64/libGemmaModelConstraintProvider.dylib"
# One file, from a different commit than the source: fetch it straight from the
# LFS media endpoint. `git restore --source=<ref>` does the same job, but then
# the ref lives in two places — the restore and this build's assumptions — and a
# stale one is invisible. A URL carries the ref where you can read it.
curl -fsSL -o "prebuilt/ios_sim_arm64/libGemmaModelConstraintProvider.dylib" \
  "https://media.githubusercontent.com/media/google-ai-edge/LiteRT-LM/$PREBUILT_REF/prebuilt/ios_sim_arm64/libGemmaModelConstraintProvider.dylib"
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
PROVIDER="prebuilt/ios_arm64/libGemmaModelConstraintProvider.dylib"
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
PROVIDER="prebuilt/ios_sim_arm64/libGemmaModelConstraintProvider.dylib"
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

verify_flutter_ios_strip() {
  local dylib="$1"
  local probe
  local output

  probe="$(mktemp)"
  cp "$dylib" "$probe"
  if ! output="$(xcrun strip -x -S "$probe" 2>&1)"; then
    rm -f "$probe"
    echo "ERROR: $dylib is not compatible with Flutter iOS Native Assets release stripping."
    echo "Flutter runs: xcrun strip -x -S <dylib>"
    printf '%s\n' "$output"
    return 1
  fi
  rm -f "$probe"
}

# 5. Build for iOS device (arm64)
echo ""
echo "=== Building for iOS device (arm64) ==="
bazelisk build -c opt --strip=always --config=ios_arm64 '//c:libLiteRtLm.dylib'
DEVICE_DIR="$SCRIPT_DIR/prebuilt/ios_arm64"
mkdir -p "$DEVICE_DIR"
cp bazel-bin/c/libLiteRtLm.dylib "$DEVICE_DIR/"
chmod +w "$DEVICE_DIR/libLiteRtLm.dylib"
install_name_tool -id @rpath/libLiteRtLm.dylib "$DEVICE_DIR/libLiteRtLm.dylib"
install_name_tool -add_rpath '@loader_path/../../..' "$DEVICE_DIR/libLiteRtLm.dylib" 2>/dev/null || true

# 6. Build for iOS simulator (arm64)
echo ""
echo "=== Building for iOS simulator (arm64) ==="
bazelisk build --config=ios_sim_arm64 '//c:libLiteRtLm.dylib'
SIM_DIR="$SCRIPT_DIR/prebuilt/ios_sim_arm64"
mkdir -p "$SIM_DIR"
cp bazel-bin/c/libLiteRtLm.dylib "$SIM_DIR/"
chmod +w "$SIM_DIR/libLiteRtLm.dylib"
install_name_tool -id @rpath/libLiteRtLm.dylib "$SIM_DIR/libLiteRtLm.dylib"
install_name_tool -add_rpath '@loader_path/../../..' "$SIM_DIR/libLiteRtLm.dylib" 2>/dev/null || true

# 7. Build StreamProxy for both targets
echo ""
echo "=== Building StreamProxy ==="
clang -shared -o "$DEVICE_DIR/libStreamProxy.dylib" \
  -arch arm64 -target arm64-apple-ios15.0 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -install_name @rpath/libStreamProxy.dylib \
  -Wl,-headerpad_max_install_names \
  "$SCRIPT_DIR/stream_proxy.c"
echo "StreamProxy (device): OK"

clang -shared -o "$SIM_DIR/libStreamProxy.dylib" \
  -arch arm64 -target arm64-apple-ios15.0-simulator \
  -isysroot "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
  -install_name @rpath/libStreamProxy.dylib \
  -Wl,-headerpad_max_install_names \
  "$SCRIPT_DIR/stream_proxy.c"
echo "StreamProxy (simulator): OK"

# 8. Copy companion libs
echo ""
echo "=== Copying companion libs ==="
# libLiteRtMetalAccelerator.dylib was added upstream in commit 5e0d86b ("Update
# dependencies of litert_lm") — must be on a tag/commit that includes it. The
# v0.10.2 tag predates that commit. The other two upstream iOS prebuilts are not
# copied, for reasons of our own: libLiteRt.dylib is not needed, because
# libLiteRtLm.dylib carries the LiteRt C API itself (it exports the LiteRt*
# symbols and loads no libLiteRt.dylib — checked with otool -L at v0.17.0); and
# libLiteRtTopKMetalSampler.dylib is unreachable while sampler_factory.cc keeps
# its basename dlopen (patch_c_api.sh, 10a). Upstream #2072 — those two shipped
# as x86_64 binaries — was closed in May 2026 and is no longer a reason.
for lib in libGemmaModelConstraintProvider.dylib libLiteRtMetalAccelerator.dylib; do
  [ -f "prebuilt/ios_arm64/$lib" ] && cp "prebuilt/ios_arm64/$lib" "$DEVICE_DIR/$lib" && echo "  $lib → device"
  [ -f "prebuilt/ios_sim_arm64/$lib" ] && cp "prebuilt/ios_sim_arm64/$lib" "$SIM_DIR/$lib" && echo "  $lib → simulator"
done

# 8b. Normalize iOS minos of all 4 companion dylibs to 13.0 — this matches
# the MinimumOSVersion that Flutter Native Assets hardcodes into the
# generated framework wrapper Info.plist (flutter/flutter#148501). Without
# this, App Store Connect rejects the archive with ITMS-90208 ("framework
# does not support the minimum OS Version specified in the Info.plist")
# whenever a dylib's binary minos differs from the wrapper plist's 13.0.
#
# The declared floor is flutter_gemma's podspec `s.platform = :ios, '15.0'`
# (#441; 16.0 only for flutter_gemma_mediapipe) — that's the real contract.
# The minos here is just metadata to satisfy validator equality between binary
# and wrapper plist; the actual minimum is enforced by whichever dependency
# manager the app uses — SwiftPM against the Runner target on the default path,
# CocoaPods against the Podfile platform when the app has one.
# See #245, #286.
echo ""
echo "=== Patch iOS companion dylibs minos → 13.0 ==="
# Normalize an Apple slice's minimum-OS metadata to 13.0.
#
# Flutter hardcodes `MinimumOSVersion 13.0` into the Native-Assets framework
# wrapper it generates, and App Store Connect compares each framework's BINARY
# against ITS OWN wrapper plist — so any other value is ITMS-90208, whatever the
# app's own deployment target is. This rewrites metadata only: the real floor is
# enforced by the podspec, not by this number. See #245, #286.
#
# `-output` is the SAME path as the input, deliberately. vtool re-signs its
# output ad-hoc and derives the signature Identifier from the -output BASENAME,
# so the `-output "$lib.new"` + `mv` shape bakes ".new" into the shipped
# binary's identifier — which every simulator dylib up to native-v0.16.0
# carried. Same path in and out, no temp name, no wrong identifier.
#
# Reads BOTH fields back afterwards. vtool accepts a wrong platform silently, so
# a device slice stamped MACOS still reports minos 13.0 and passes a minos-only
# check — then fails at dlopen with "built for a different platform", far from
# here.
normalize_apple_minos() {
  local lib="$1" platform="$2" want
  # Derived, never passed in: a caller that supplies both can get them out of
  # step, and "expected" would then be whatever the mistake was.
  case "$platform" in
    ios)    want=IOS ;;
    iossim) want=IOSSIMULATOR ;;
    *) echo "ERROR: unsupported platform '$platform'" >&2; exit 1 ;;
  esac
  vtool -set-build-version "$platform" 13.0 18.5 -replace -output "$lib" "$lib"
  local info; info="$(vtool -show-build-version "$lib")"
  local got_plat got_min
  got_plat="$(awk '/platform/ {print $2; exit}' <<<"$info")"
  got_min="$(awk '/minos/ {print $2; exit}' <<<"$info")"
  [ "$got_plat" = "$want" ] && [ "$got_min" = "13.0" ] || {
    echo "ERROR: $(basename "$lib") is platform='$got_plat' minos='$got_min', want $want 13.0" >&2
    exit 1
  }
  echo "    minos -> 13.0 ($want)"
}

for arch_dir_pair in "ios:$DEVICE_DIR" "iossim:$SIM_DIR"; do
  platform="${arch_dir_pair%%:*}"
  dir="${arch_dir_pair##*:}"
  for libname in libGemmaModelConstraintProvider libLiteRtLm libLiteRtMetalAccelerator libStreamProxy; do
    d="$dir/${libname}.dylib"
    if [ -f "$d" ]; then
      normalize_apple_minos "$d" "$platform"
      chmod +w "$d"
      echo "  $d: minos $(vtool -show-build "$d" | grep minos | awk '{print $2}'), sdk $(vtool -show-build "$d" | grep sdk | awk '{print $2}')"
    fi
  done
done

# 9. Verify
echo ""
echo "=== Verification ==="
echo "Device (ios_arm64):"
ls -lh "$DEVICE_DIR/"
nm -gU "$DEVICE_DIR/libLiteRtLm.dylib" | grep "litert_lm_engine_create" | head -1
for dylib in "$DEVICE_DIR"/*.dylib; do
  verify_flutter_ios_strip "$dylib"
done
echo ""
echo "Simulator (ios_sim_arm64):"
ls -lh "$SIM_DIR/"
nm -gU "$SIM_DIR/libLiteRtLm.dylib" | grep "litert_lm_engine_create" | head -1
for dylib in "$SIM_DIR"/*.dylib; do
  verify_flutter_ios_strip "$dylib"
done
echo ""
echo "=== Done ==="

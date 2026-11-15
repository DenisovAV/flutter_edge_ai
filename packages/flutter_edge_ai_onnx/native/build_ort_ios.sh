#!/usr/bin/env bash
# Builds the iOS ONNX Runtime that OnnxEmbeddingBackend loads, and packs it
# the way hook/build.dart fetches it: onnxruntime-ios-<ver>-a.zip with
#   ios-arm64/libonnxruntime.dylib            (device)
#   ios-arm64-simulator/libonnxruntime.dylib  (Apple-Silicon simulator)
#
# Why: Microsoft publishes ONNX Runtime for iOS only as a static library
# (the `onnxruntime-c` pod archive), and Native Assets bundles dynamic
# libraries only. ORT-GenAI's iOS framework links its own ORT but exports
# only `Oga*` since 0.18.0 (microsoft/onnxruntime-genai#2673), so the
# embedding arm needs an ORT of its own, as on every other host.
#
# This links Microsoft's static library, unchanged, into one dylib per slice:
# - `-all_load`: every object of the archive, as the pod would link it;
# - `-exported_symbols_list`: only the C entry points (`_Ort*`:
#   `OrtGetApiBase` and the execution-provider appenders); every C++ symbol
#   stays private, so the copy inside onnxruntime-genai.framework and this
#   one cannot interpose on each other;
# - install name `@rpath/onnxruntime.framework/onnxruntime`, the framework
#   Native Assets wraps `libonnxruntime.dylib` in;
# - `vtool` sets minos 13.0: Flutter's generated framework Info.plist says
#   MinimumOSVersion 13.0 and App Store validation requires the two to match
#   (ITMS-90208). Microsoft compiles the objects for iOS 15.1, the real floor.
#
# Needs Xcode (clang, lipo, vtool, nm), curl, unzip, zip, shasum.
#
#   packages/flutter_edge_ai_onnx/native/build_ort_ios.sh [WORKDIR]
#
# Prints the zip's SHA-256: that is the pin in hook/build.dart.
set -euo pipefail

ORT_VERSION=${ORT_VERSION:-1.30.0}
# Newest `onnxruntime-c` pod archive Microsoft publishes (1.30.1, 1.31.0 and
# 1.32.0 have none). Pinned by content.
ORT_POD_URL=https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ORT_VERSION}.zip
ORT_POD_SHA256=${ORT_POD_SHA256:-e6f1670c14406fd9f082bb400ab197a9b0a9646058ca6366e440642e2b54a2ea}
REVISION=${REVISION:-a}
ZIP=onnxruntime-ios-${ORT_VERSION}-${REVISION}.zip
OBJ_MIN_IOS=15.1

WORK=${1:-$PWD/ort-ios-build}
mkdir -p "$WORK" && cd "$WORK"

# Verified on every run, so a stale or hand-placed archive is never linked.
[ -f pod.zip ] || curl -sfL -o pod.zip "$ORT_POD_URL"
echo "$ORT_POD_SHA256  pod.zip" | shasum -a 256 -c -
rm -rf pod && mkdir pod && (cd pod && unzip -q ../pod.zip)
XC=pod/onnxruntime.xcframework

printf '_Ort*\n' > exports.lst
rm -rf out && mkdir -p out/ios-arm64 out/ios-arm64-simulator

link() { # sdk slice-dir out-dir vtool-platform target-triple
  local sdk=$1 slice=$2 out=$3 plat=$4 triple=$5
  local lib="$XC/$slice/onnxruntime.framework/onnxruntime"
  local thin="$WORK/$out.a"
  lipo "$lib" -thin arm64 -output "$thin" 2>/dev/null || cp "$lib" "$thin"
  xcrun --sdk "$sdk" clang++ -target "$triple" -dynamiclib \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -Wl,-all_load "$thin" \
    -Wl,-exported_symbols_list,exports.lst \
    -Wl,-dead_strip \
    -install_name @rpath/onnxruntime.framework/onnxruntime \
    -framework Foundation -framework CoreML -framework Network -framework UIKit \
    -o "out/$out/libonnxruntime.dylib"
  vtool -set-build-version "$plat" 13.0 "$(xcrun --sdk "$sdk" --show-sdk-version)" \
    -replace -output "out/$out/libonnxruntime.dylib" "out/$out/libonnxruntime.dylib"
  rm -f "$thin"
}
link iphoneos ios-arm64 ios-arm64 ios "arm64-apple-ios$OBJ_MIN_IOS"
link iphonesimulator ios-arm64_x86_64-simulator ios-arm64-simulator iossim \
  "arm64-apple-ios$OBJ_MIN_IOS-simulator"

# The properties the hook and the loader depend on.
for d in out/ios-arm64 out/ios-arm64-simulator; do
  f=$d/libonnxruntime.dylib
  lipo -info "$f" | grep -q 'arm64$' || { echo "$f is not arm64 only" >&2; exit 1; }
  nm -gU "$f" | grep -q ' _OrtGetApiBase$' || { echo "$f does not export OrtGetApiBase" >&2; exit 1; }
  if nm -gU "$f" | awk '{print $3}' | grep -qv '^_Ort'; then
    echo "$f exports more than _Ort*" >&2; exit 1; fi
  vtool -show-build "$f" | grep -q 'minos 13.0' || { echo "$f minos is not 13.0" >&2; exit 1; }
  otool -D "$f" | grep -q '@rpath/onnxruntime.framework/onnxruntime' || {
    echo "$f has the wrong install name" >&2; exit 1; }
done

rm -f "$ZIP"
(cd out && TZ=UTC touch -t 202601010000 ios-arm64/libonnxruntime.dylib \
  ios-arm64-simulator/libonnxruntime.dylib && \
  zip -qX "../$ZIP" ios-arm64/libonnxruntime.dylib ios-arm64-simulator/libonnxruntime.dylib)
shasum -a 256 "$ZIP"

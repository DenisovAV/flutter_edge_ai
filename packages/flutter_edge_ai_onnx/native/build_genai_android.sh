#!/usr/bin/env bash
# Builds ORT-GenAI v0.17.0 for Android arm64 WITHOUT telemetry, and packs it the
# way hook/build.dart fetches it: onnxruntime-genai-android-0.17.0-a.zip with
# jni/arm64-v8a/libonnxruntime-genai.so.
#
# Why not Microsoft's AAR: its 0.17.0 libonnxruntime-genai.so lists libmat.so
# (the 1DS telemetry SDK) in DT_NEEDED, and libmat.so is 4 KB-aligned, which
# Google Play rejects (API 35+) and a 16 KB-page device cannot load. With
# ENABLE_TELEMETRY=OFF the library needs only liblog/libm/libdl/libc.
#
# Needs: git, Python 3.10+ with `requests` (build.py), cmake with ctest,
# ninja or make, unzip, zip, curl, sha256sum, readelf (on macOS the
# NDK's llvm-readelf, linked or aliased as readelf on PATH), and an Android
# NDK >= r28 (16 KB-aligned by default). No Rust: guidance is not built.
# The output is not byte-reproducible across machines: the NDK version, the
# build directory (in __FILE__ strings) and the zip entry times change it.
#
#   NDK=$HOME/Android/Sdk/ndk/28.2.13676358 \
#   ANDROID_HOME=$HOME/Android/Sdk \
#   packages/flutter_edge_ai_onnx/native/build_genai_android.sh [WORKDIR]
#
# Prints the zip's SHA-256: that is the pin in hook/build.dart.
#
#   build_genai_android.sh --check LIB
#
# runs only the three checks below on an existing library. Measured on the
# 0.17.0 files: our library passes; Microsoft's AAR `libonnxruntime-genai.so`
# fails the first two (it is 16 KB-aligned), and the third check alone fails
# its 4 KB-aligned `libmat.so`; a copy of ours with "OneCollector" appended
# fails the second. The old `strings | grep -q` form missed Microsoft's
# library (pipe status 141).
#
# TODO(next rebuild): build with --android_api=24, the package's minSdk (this
# build used 27), and keep the build directory out of the library's debug
# strings (__FILE__).
set -euo pipefail

# The three properties the hook and the review depend on. Each tool's output
# is read whole before it is searched: under pipefail, `tool | grep -q` fails
# with SIGPIPE (141) when grep stops at its first match, and the `if` then
# reads a found string as "not found".
check_lib() {
  local lib=$1 out
  out=$(readelf -dW "$lib")
  if grep -q 'NEEDED.*libmat' <<<"$out"; then
    echo "$lib still needs libmat.so" >&2; return 1; fi
  if grep -aqi 'OneCollector' "$lib"; then
    echo "the 1DS endpoint is still in $lib" >&2; return 1; fi
  out=$(readelf -lW "$lib" | awk '/LOAD/ {print $NF}')
  if grep -qv '^0x4000$' <<<"$out"; then
    echo "a PT_LOAD segment of $lib is not 16 KB-aligned" >&2; return 1; fi
}

if [ "${1:-}" = --check ]; then
  check_lib "${2:?--check LIB}" && echo "$2: ok"; exit
fi

GENAI_TAG=v0.17.0
GENAI_COMMIT=1d67be30e5b1ed0c264f6f41c598f85157e8288b
ORT_AAR_URL=https://repo1.maven.org/maven2/com/microsoft/onnxruntime/onnxruntime-android/1.27.0/onnxruntime-android-1.27.0.aar
ORT_AAR_SHA256=077dec5e2d821234c7dc0aba584bec8f999854b546c754cab93a90741c56fbeb

WORK=${1:-$PWD/genai-android-build}
: "${NDK:?set NDK to an Android NDK >= r28}"
: "${ANDROID_HOME:?set ANDROID_HOME to the Android SDK}"
mkdir -p "$WORK" && cd "$WORK"

[ -d src ] || git clone -q --depth 1 --branch "$GENAI_TAG" \
  https://github.com/microsoft/onnxruntime-genai.git src
[ "$(git -C src rev-parse HEAD)" = "$GENAI_COMMIT" ] || {
  echo "onnxruntime-genai $GENAI_TAG is not $GENAI_COMMIT" >&2; exit 1; }

# ORT 1.27.0 headers + library: the pin the package ships on every host.
if [ ! -f ort/jni/arm64-v8a/libonnxruntime.so ]; then
  mkdir -p ort && curl -sfL -o ort/ort.aar "$ORT_AAR_URL"
  echo "$ORT_AAR_SHA256  ort/ort.aar" | sha256sum -c -
  (cd ort && unzip -qo ort.aar 'headers/*' 'jni/arm64-v8a/*')
fi

(cd src && python3 build.py --android --android_api=27 \
  --android_home="$ANDROID_HOME" --android_ndk_path="$NDK" \
  --android_abi=arm64-v8a --config=Release --parallel \
  --skip_wheel --skip_examples --ort_home="$WORK/ort" \
  --cmake_extra_defines ENABLE_TELEMETRY=OFF --update --build)

LIB=src/build/Android/Release/libonnxruntime-genai.so

check_lib "$LIB"

rm -rf stage && mkdir -p stage/jni/arm64-v8a
cp "$LIB" stage/jni/arm64-v8a/
rm -f onnxruntime-genai-android-0.17.0-a.zip
(cd stage && zip -qXr ../onnxruntime-genai-android-0.17.0-a.zip jni)
sha256sum onnxruntime-genai-android-0.17.0-a.zip

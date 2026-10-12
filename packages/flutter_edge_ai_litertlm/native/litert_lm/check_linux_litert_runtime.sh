#!/usr/bin/env bash
# Gate for a Linux LiteRT-LM bundle (linux_x86_64 / linux_arm64): the
# libLiteRt.so beside libLiteRtLm.so must be the runtime built from the pinned
# LiteRT by the same toolchain, never Google's prebuilt.
#
# Why: with litert_runtime_link_mode=dynamic, libLiteRtLm.so (clang + libstdc++)
# reaches into libLiteRt.so through LiteRT's C++ wrappers, and not all of them
# are ABI-neutral. litert::Options::SetExternalWeightScopedFile plants a
# std::unordered_map<std::string, ...> inside the runtime-owned LiteRtOptionsT.
# Google's prebuilt libLiteRt.so is google3 libc++ (std::__u): it reads that map
# with another layout, misses the "tflite_weights" group, opens a file of that
# name in the CWD instead (ENOENT) and EmbeddingGemma 2 engine_create fails with
# an empty message. LLM bundles carry no TFLiteWeights section, so nothing else
# notices. Apple and Android link LiteRT statically: one STL, no split.
#
# usage: check_linux_litert_runtime.sh <bundle-dir> <litert_runtime_c_api_so_symbols.txt>
#          <litert_bindings.dart> [google-prebuilt-libLiteRt.so]
#
# The symbols file is LiteRT's own expected export list at the pinned LiteRT
# (upstream's litert_runtime_c_api_so_symbol_test reads the same file). The
# Google prebuilt is optional and only reported, never required.
set -euo pipefail

usage="usage: $0 <bundle-dir> <symbols.txt> <litert_bindings.dart> [google-libLiteRt.so]"
DIR="${1:?$usage}"
EXPECTED="${2:?$usage}"
BINDINGS="${3:?$usage}"
GOOGLE_RT="${4:-}"

LM="$DIR/libLiteRtLm.so"
RT="$DIR/libLiteRt.so"
PROV="$DIR/libGemmaModelConstraintProvider.so"
for f in "$LM" "$RT" "$PROV" "$EXPECTED" "$BINDINGS"; do
  [ -s "$f" ] || { echo "::error::$f is missing or empty"; exit 1; }
done

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0
err() { echo "::error::$*"; fail=1; }
defined() { nm -D --defined-only "$1" | awk '{print $NF}' | sed 's/@.*//' | LC_ALL=C sort -u; }

# 1. One C++ standard library on both sides of the C API. Counts are printed
#    next to the verdict so "absent" and "never read" cannot look alike.
for f in "$LM" "$RT"; do
  n="$(basename "$f")"
  stdcxx="$(readelf -d "$f" | grep -c 'NEEDED.*\[libstdc++\.so\.6\]' || true)"
  cxx11="$(LC_ALL=C grep -ac '__cxx11' "$f" || true)"
  libcxx="$(LC_ALL=C grep -acE 'St3__[u1]' "$f" || true)"
  echo "$n: NEEDED libstdc++.so.6=$stdcxx, __cxx11 lines=$cxx11, libc++ (St3__u/St3__1) lines=$libcxx"
  if [ "$stdcxx" != 1 ] || [ "$cxx11" -eq 0 ] || [ "$libcxx" != 0 ]; then
    err "$n is not a libstdc++ build - libLiteRtLm.so and libLiteRt.so must share one C++ library"
  fi
done

# 2. Every LiteRt* import of libLiteRtLm.so is defined by libLiteRt.so (the
#    LiteRtLm* provider entry points come from the constraint provider).
defined "$RT" > "$T/rt_def"
defined "$PROV" > "$T/prov_def"
nm -D --undefined-only "$LM" | awk '{print $NF}' | sed 's/@.*//' \
  | { grep -E '^k?LiteRt' || true; } | LC_ALL=C sort -u > "$T/lm_imp"
LC_ALL=C comm -23 "$T/lm_imp" "$T/prov_def" > "$T/lm_need"
LC_ALL=C comm -23 "$T/lm_need" "$T/rt_def" > "$T/lm_missing"
echo "libLiteRtLm.so: $(wc -l < "$T/lm_need") LiteRt* imports from libLiteRt.so, $(wc -l < "$T/lm_missing") unresolved"
if [ ! -s "$T/lm_need" ]; then
  err "libLiteRtLm.so imports no LiteRt* symbol - not a litert_runtime_link_mode=dynamic build, or nm read nothing"
fi
if [ -s "$T/lm_missing" ]; then
  err "libLiteRt.so does not define what libLiteRtLm.so imports:"
  sed 's/^/  /' "$T/lm_missing"
fi

# 3. libLiteRt.so exports exactly LiteRT's expected list at the pin - the same
#    comparison as upstream's litert_runtime_c_api_so_symbol_test. Catches a
#    runtime that built but linked header-only C API targets.
nm -D "$RT" | grep -E ' (T LiteRt|D kLiteRtRuntimeBuiltin)' | awk '{print $3}' \
  | sed 's/@@VERS_1.0//' | LC_ALL=C sort > "$T/rt_exports"
grep -v '^#' "$EXPECTED" | grep -v '^$' | LC_ALL=C sort > "$T/rt_expected"
echo "libLiteRt.so: $(wc -l < "$T/rt_exports") LiteRt* exports, pin expects $(wc -l < "$T/rt_expected")"
if ! diff -u "$T/rt_expected" "$T/rt_exports" > "$T/rt_diff"; then
  err "libLiteRt.so exports differ from the pin's litert_runtime_c_api_so_symbols.txt:"
  cat "$T/rt_diff"
fi

# 4. Every LiteRt* function the Dart bindings look up (embeddings, speech) is
#    exported by libLiteRt.so - Linux opens that file by name for them.
tr -s ' \n' '  ' < "$BINDINGS" | { grep -oE ">\( ?'[A-Za-z0-9_]+'" || true; } \
  | sed -E "s/^>\( ?'//; s/'$//" > "$T/dart_all"
calls="$(tr -s ' \n' '  ' < "$BINDINGS" | { grep -oE 'lookupFunction<' || true; } | wc -l)"
LC_ALL=C sort -u "$T/dart_all" > "$T/dart"
LC_ALL=C comm -23 "$T/dart" "$T/rt_def" > "$T/dart_missing"
echo "Dart bindings: $(wc -l < "$T/dart_all") of $calls lookupFunction names read, $(wc -l < "$T/dart_missing") not exported"
if [ "$calls" -eq 0 ] || [ "$(wc -l < "$T/dart_all")" -ne "$calls" ]; then
  err "could not read every lookupFunction name from $BINDINGS - fix the extraction, do not skip it"
fi
if [ -s "$T/dart_missing" ]; then
  err "libLiteRt.so does not export what the Dart bindings look up:"
  sed 's/^/  /' "$T/dart_missing"
fi

# 5. libLiteRt.so needs nothing the bundle or a base system does not provide,
#    and does not raise the glibc / libstdc++ floor libLiteRtLm.so already sets.
for n in $(readelf -d "$RT" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
  case "$n" in
    libc.so.6|libm.so.6|libdl.so.2|libpthread.so.0|librt.so.1|libstdc++.so.6|libgcc_s.so.1|ld-linux-*) ;;
    *) [ -e "$DIR/$n" ] || err "libLiteRt.so NEEDs $n - neither in the bundle nor a base system library" ;;
  esac
done
maxver() { objdump -T "$1" | { grep -oE "\b$2_[0-9][0-9.]*" || true; } | sed "s/^$2_//" | sort -V | tail -1; }
for tag in GLIBC GLIBCXX; do
  rt="$(maxver "$RT" "$tag")"
  lm="$(maxver "$LM" "$tag")"
  echo "$tag floor: libLiteRt.so ${rt:-none}, libLiteRtLm.so ${lm:-none}"
  if [ -n "$rt" ] && [ "$(printf '%s\n%s\n' "$rt" "${lm:-0}" | sort -V | tail -1)" != "${lm:-0}" ]; then
    err "libLiteRt.so needs ${tag}_$rt, above libLiteRtLm.so's ${tag}_${lm:-none}"
  fi
done

# Report only: how the export surface moved against Google's prebuilt.
if [ -n "$GOOGLE_RT" ] && [ -s "$GOOGLE_RT" ]; then
  defined "$GOOGLE_RT" | grep -E '^k?LiteRt' > "$T/g_def" || true
  grep -E '^k?LiteRt' "$T/rt_def" > "$T/o_def" || true
  echo "vs Google's prebuilt libLiteRt.so: only Google exports $(LC_ALL=C comm -23 "$T/g_def" "$T/o_def" | wc -l), only ours $(LC_ALL=C comm -13 "$T/g_def" "$T/o_def" | wc -l)"
  LC_ALL=C comm -23 "$T/g_def" "$T/o_def" | sed 's/^/  only Google: /'
fi

if [ "$fail" != 0 ]; then
  echo "Linux LiteRT runtime gate FAILED for $DIR"
  exit 1
fi
echo "Linux LiteRT runtime gate: OK for $DIR"

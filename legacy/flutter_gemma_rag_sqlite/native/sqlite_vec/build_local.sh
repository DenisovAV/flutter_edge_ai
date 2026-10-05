#!/usr/bin/env bash
# Build the sqlite-vec (vec0) loadable extension tarballs for every platform the
# native SqliteVectorStore supports, normalized to the layout hook/build.dart
# expects. (It used to mirror the qdrant package's build_local.sh; that package
# dropped its native/ entirely in 2.0.0 for the official qdrant_edge SDK.)
#
# WHY this exists instead of fetching asg017's prebuilts directly: the upstream
# asg017 android loadable ships with 4 KB ELF LOAD-segment alignment, which
# Android 15 (16 KB pages) and Google Play targetSdk 35+ reject at dlopen. We
# REBUILD android from the sqlite-vec amalgamation with
# `-Wl,-z,max-page-size=16384` (the same fix qdrant applies, #319). The other
# platforms have no alignment constraint, so we just repackage asg017's upstream
# loadable under our naming.
#
# Inputs : SQLITE_VEC_VERSION env (default "0.1.9"); ANDROID_NDK_HOME for android.
# Outputs: dist/sqlite-vec-<platform>.tar.gz  (each a flat tar of one vec0 lib)
#          dist/checksums_sqlite_vec.txt
#
# Usage:
#   ./native/sqlite_vec/build_local.sh            # all available targets
#   ./native/sqlite_vec/build_local.sh android    # just the 16 KB android rebuild
#
# RELEASING (hook/build.dart fetches from a tag; it does NOT read dist/):
#   1. Build every target. A partial run publishes a partial release, and the
#      missing platform fails at the consumer's `pub get`, not here.
#      2. Set `_bundleVersion` in hook/build.dart to SQLITE_VEC_VERSION. Our
#      android rebuild and the Apple re-stamps do NOT change that number —
#      it names the upstream these bytes were built from. Append a letter
#      (`0.1.9-a`, like native-v0.12.0-a) only when RE-releasing: the bytes
#      for a version already published have changed, and that tag cannot be
#      reused. The marker file is keyed on this string, so a consumer who
#      already has the old bytes keeps them until it moves.
#   3. Copy the seven sums from dist/checksums_sqlite_vec.txt into the
#      `_checksums` map in hook/build.dart.
#   4. Create the tag and upload all seven archives PLUS a
#      checksums_sqlite_vec.txt carrying the same sums:
#        gh release create native-sqlite-vec-v<X> --repo DenisovAV/flutter_gemma \
#          dist/sqlite-vec-*.tar.gz dist/checksums_sqlite_vec.txt
#   5. NEVER re-upload assets on an existing tag. tar is not reproducible, so
#      the published SHA256 cannot be recovered, and every consumer already
#      pinned to that tag starts failing the integrity check (#316).
#
# Targets (keys match hook/build.dart prebuilt dir names):
#   android_arm64   → REBUILT from amalgamation, 16 KB aligned → libvec0.so
#   macos_arm64     → repackage asg017 macos-aarch64           → libvec0.dylib
#   ios_arm64       → repackage asg017 ios-aarch64             → libvec0.dylib
#   ios_sim_arm64   → repackage asg017 iossimulator-aarch64    → libvec0.dylib
#   linux_x86_64    → repackage asg017 linux-x86_64            → libvec0.so
#   linux_arm64     → repackage asg017 linux-aarch64           → libvec0.so
#   windows_x86_64  → repackage asg017 windows-x86_64          → vec0.dll
set -euo pipefail

SQLITE_VEC_VERSION="${SQLITE_VEC_VERSION:-0.1.9}"
# sqlite version whose amalgamation headers we compile the extension against.
# Matches the sqlite3.dart wasm build's pin (sqlite-autoconf-3530200).
SQLITE_VERSION="${SQLITE_VERSION:-3530200}"
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"  # minSdk 24, matches flutter_gemma

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"            # vendored sqlite-vec amalgamation
DIST_DIR="$SCRIPT_DIR/dist"
WORK="$(mktemp -d)"
mkdir -p "$DIST_DIR"

UPSTREAM="https://github.com/asg017/sqlite-vec/releases/download/v$SQLITE_VEC_VERSION"

# Pack one library file into a flat tarball named for the platform.
pack() {
  local dirName="$1" libFile="$2"
  (cd "$(dirname "$libFile")" && tar -czf "$DIST_DIR/sqlite-vec-$dirName.tar.gz" "$(basename "$libFile")")
  echo "    → dist/sqlite-vec-$dirName.tar.gz"
  install_prebuilt "$dirName" "$libFile"
}

# Put the artifact where the hook's LOCAL path reads it.
#
# What ships is dist/*.tar.gz, uploaded to a native-sqlite-vec-v* release; the
# hook fetches from there. prebuilt/ is the maintainer override, checked ahead
# of the download cache so this script's output can be built against before it
# is released. Both come from the same normalized bytes: pack() and
# install_prebuilt() are fed the same file, after normalize_if_apple.
install_prebuilt() {
  local dirName="$1" libFile="$2"
  local dest="$SCRIPT_DIR/prebuilt/$dirName"
  mkdir -p "$dest"
  cp "$libFile" "$dest/$(basename "$libFile")"
  echo "    → prebuilt/$dirName/$(basename "$libFile")  (local override; dist/*.tar.gz is what ships)"
}

# Download + extract asg017's upstream loadable for one platform, rename the bare
# vec0.<ext> to our libvec0.<ext> convention, and pack it.
repackage() {
  local dirName="$1" suffix="$2" upstreamName="$3" bundledName="$4"
  local archive="$WORK/up-$dirName.tar.gz"
  echo "==> $dirName (repackage asg017 $suffix)"
  curl -fsSL "$UPSTREAM/sqlite-vec-$SQLITE_VEC_VERSION-loadable-$suffix.tar.gz" -o "$archive"
  local ext="$WORK/$dirName"; mkdir -p "$ext"
  tar -xzf "$archive" -C "$ext"
  [ -f "$ext/$upstreamName" ] || { echo "ERROR: $upstreamName missing in upstream tarball" >&2; exit 1; }
  mv "$ext/$upstreamName" "$ext/$bundledName"
  normalize_if_apple "$dirName" "$ext/$bundledName"
  pack "$dirName" "$ext/$bundledName"
}

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
# binary's identifier — which is what every simulator dylib in this repo carried
# — the identifier every simulator dylib in native-v0.16.0 still carries, since
# a released tarball cannot be re-uploaded; corrected from the next native
# release onward. Same path in and out, no temp name, no wrong identifier.
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

# Which of this package's targets are Apple, and what platform each declares.
normalize_if_apple() {
  local dirName="$1" lib="$2"
  case "$dirName" in
    ios_arm64)     normalize_apple_minos "$lib" ios ;;
    ios_sim_arm64) normalize_apple_minos "$lib" iossim ;;
    # macOS is deliberately excluded. Flutter's macOS Native-Assets path never
    # writes a MinimumOSVersion into the generated framework Info.plist, so
    # there is no wrapper value for App Store Connect to diff against — the
    # ITMS-90208 mechanism this guards does not exist there.
    *) return 0 ;;
  esac
}

# Rebuild android arm64 from the amalgamation with 16 KB LOAD-segment alignment.
build_android_arm64() {
  echo "==> android_arm64 (rebuild from amalgamation, 16 KB aligned)"
  [ -n "${ANDROID_NDK_HOME:-}" ] || { echo "ERROR: ANDROID_NDK_HOME unset (need NDK r26+)" >&2; exit 1; }
  local cc
  cc="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android${ANDROID_API_LEVEL}-clang 2>/dev/null | head -1)"
  [ -x "$cc" ] || cc="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/aarch64-linux-android*-clang 2>/dev/null | sort -V | tail -1)"
  [ -x "$cc" ] || { echo "ERROR: android clang not found in NDK" >&2; exit 1; }

  # Fetch the matching sqlite amalgamation headers (sqlite3.h + sqlite3ext.h)
  # the extension compiles against. Loadable extensions resolve sqlite symbols
  # at runtime via sqlite3_api_routines, so no link against sqlite is needed.
  # sqlite.org buckets amalgamations by release year; try recent years until one
  # resolves rather than hard-coding the path.
  local zip="$WORK/sqlite-amalg.zip" got=""
  for yr in 2026 2025 2024; do
    if curl -fsSL "https://sqlite.org/$yr/sqlite-amalgamation-$SQLITE_VERSION.zip" -o "$zip" 2>/dev/null; then
      got="$yr"; break
    fi
  done
  [ -n "$got" ] || { echo "ERROR: could not fetch sqlite-amalgamation-$SQLITE_VERSION" >&2; exit 1; }
  echo "    fetched sqlite headers (sqlite.org/$got)"
  unzip -oq "$WORK/sqlite-amalg.zip" -d "$WORK"
  local hdr; hdr="$(dirname "$(find "$WORK" -name sqlite3ext.h | head -1)")"

  # Loadable-extension mode: SQLITE_CORE must be UNDEFINED (not =0). The
  # amalgamation gates `SQLITE_EXTENSION_INIT1` on `#ifndef SQLITE_CORE`, which
  # tests *defined-ness*, so `-DSQLITE_CORE=0` would wrongly disable it and emit
  # ~40 undefined `sqlite3_*` symbols that Android's strict linker can't resolve
  # at dlopen ("cannot locate symbol sqlite3_free"). Leaving it undefined routes
  # every sqlite call through the `sqlite3_api` pointer (zero undefined symbols).
  local out="$WORK/android_arm64"; mkdir -p "$out"
  "$cc" -O3 -fPIC -shared \
    -I "$SRC_DIR" -I "$hdr" \
    -Wl,-z,max-page-size=16384 \
    -Wl,--build-id=sha1 \
    -o "$out/libvec0.so" "$SRC_DIR/sqlite-vec.c"

  # Guard: a loadable extension must have NO undefined sqlite3_* symbols, or
  # Android dlopen fails resolving them. Catch a SQLITE_CORE regression here.
  local nm
  nm="$(ls "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin/llvm-nm 2>/dev/null | head -1)"
  if [ -x "$nm" ]; then
    local undef
    undef="$("$nm" -D "$out/libvec0.so" 2>/dev/null | grep ' U ' | grep -ci sqlite || true)"
    [ "$undef" = "0" ] || { echo "ERROR: android libvec0.so has $undef undefined sqlite3_* symbols (loadable mode broke)" >&2; exit 1; }
  fi

  # Verify the 16 KB alignment actually landed before packing.
  python3 - "$out/libvec0.so" <<'PY'
import struct, sys
d = open(sys.argv[1], 'rb').read()
phoff = struct.unpack('<Q', d[0x20:0x28])[0]
phes  = struct.unpack('<H', d[0x36:0x38])[0]
phn   = struct.unpack('<H', d[0x38:0x3a])[0]
aligns = [struct.unpack('<Q', d[phoff+i*phes+48:phoff+i*phes+56])[0]
          for i in range(phn)
          if struct.unpack('<I', d[phoff+i*phes:phoff+i*phes+4])[0] == 1]
assert aligns and max(aligns) >= 16384, f'android .so not 16KB-aligned: {[hex(a) for a in aligns]}'
print(f'    16 KB alignment OK ({[hex(a) for a in aligns]})')
PY
  pack "android_arm64" "$out/libvec0.so"
}

build_target() {
  case "$1" in
    android|android_arm64) build_android_arm64 ;;
    macos|macos_arm64)     repackage macos_arm64    macos-aarch64        vec0.dylib libvec0.dylib ;;
    ios|ios_arm64)         repackage ios_arm64      ios-aarch64          vec0.dylib libvec0.dylib ;;
    ios_sim|ios_sim_arm64) repackage ios_sim_arm64  iossimulator-aarch64 vec0.dylib libvec0.dylib ;;
    linux|linux_x86_64)    repackage linux_x86_64   linux-x86_64         vec0.so    libvec0.so ;;
    linux_arm64)           repackage linux_arm64    linux-aarch64        vec0.so    libvec0.so ;;
    windows|windows_x86_64) repackage windows_x86_64 windows-x86_64      vec0.dll   vec0.dll ;;
    all)
      build_android_arm64
      repackage macos_arm64    macos-aarch64        vec0.dylib libvec0.dylib
      repackage ios_arm64      ios-aarch64          vec0.dylib libvec0.dylib
      repackage ios_sim_arm64  iossimulator-aarch64 vec0.dylib libvec0.dylib
      repackage linux_x86_64   linux-x86_64         vec0.so    libvec0.so
      repackage linux_arm64    linux-aarch64        vec0.so    libvec0.so
      repackage windows_x86_64 windows-x86_64       vec0.dll   vec0.dll
      ;;
    *) echo "Unknown target: $1 (valid: all|android|macos|ios|ios_sim|linux|linux_arm64|windows)" >&2; exit 1 ;;
  esac
}

build_target "${1:-all}"

# Checksums for the GitHub Release page + to paste into hook/build.dart.
# Name it exactly what step 4 uploads and what hook/build.dart's doc refers to.
# It used to be written as ...._local.txt, so the documented `gh release create`
# named a file nothing produced and failed as written.
(cd "$DIST_DIR" && shasum -a 256 sqlite-vec-*.tar.gz | tee checksums_sqlite_vec.txt)
echo "==> done. tarballs in $DIST_DIR"
rm -rf "$WORK"

#!/usr/bin/env bash
# build.sh: builds libany_shim for one target into <out>/<target>/.
#
#   build.sh <target> [<out_dir>]
#
# Targets and what they produce:
#   macos_arm64      libany_shim.dylib   c-shared, macOS 13.0+ (Go 1.27's floor)          (macOS host)
#   ios_arm64        libany_shim.dylib   c-archive linked into a dylib,  (macOS host)
#   ios_sim_arm64    libany_shim.dylib   minos 13.0 (see below)          (macOS host)
#   android_arm64    libany_shim.so      c-shared, API 24, 16 KB pages   (NDK r29)
#   linux_x86_64     libany_shim.so      c-shared                        (Linux x64 host)
#   linux_arm64      libany_shim.so      c-shared                        (Linux arm64 host)
#   windows_x86_64   any_shim.dll        c-shared                        (Windows host, MinGW-w64 gcc)
#
# Linux and Windows build natively on their own hosts (CI: any-native.yml);
# cgo has no cross C toolchain on a Mac without one installed.
#
# Reproducibility: Go is pinned by go.mod's toolchain line and checked here
# (GOTOOLCHAIN=local: a different local Go is an error, not a download);
# modules by go.sum (GOFLAGS=-mod=readonly); paths by -trimpath; build ids
# are emptied (-buildid=). Every binary is stripped (-s -w). Two builds of
# one commit are byte-identical (checked on macOS, iOS and Android).
#
# Apple header room: `dart run`/`dart test` and Flutter rewrite the dylib's
# install name to an absolute path when they bundle it, and install_name_tool
# fails when the new load command does not fit in the header ("larger updated
# load commands do not fit"; measured: a plain Go c-shared link has too
# little). Both Apple links pass -headerpad_max_install_names, and
# check_exports.py refuses a Mach-O with less than 4 KB of room.
#
# iOS minos: Flutter wraps each Native Assets dylib in a framework whose
# Info.plist says MinimumOSVersion 13.0, and App Store Connect rejects a
# binary that declares anything else (ITMS-90208). So the iOS slices are
# compiled and linked for 13.0. The apps this package targets need iOS 15
# anyway (flutter_edge_ai's own floor). The arm64 simulator did not exist
# before iOS 14, so ld raises that slice to 14.0; it is re-stamped to 13.0
# with vtool afterwards, as flutter_edge_ai_sqlite does for its slices
# (metadata only; vtool writes in place so the ad-hoc signature keeps the
# file's own name as its identifier).
#
# Environment:
#   ANDROID_NDK_HOME   NDK r29 (default: ~/Library/Android/sdk/ndk/29.0.14206865)
#   GOCACHE, GOMODCACHE are honoured; nothing else is downloaded.
set -euo pipefail

target="${1:?usage: build.sh <target> [<out_dir>]}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out_root="${2:-$here/prebuilt}"
mkdir -p "$out_root"
out_root="$(cd "$out_root" && pwd)"   # the go builds below run in $here
out="$out_root/$target"

want_go="$(sed -n 's/^toolchain //p' "$here/go.mod")"
have_go="$(GOTOOLCHAIN=local go env GOVERSION)"
if [[ "$have_go" != "$want_go" ]]; then
  echo "build.sh: go.mod pins $want_go, this machine has $have_go" >&2
  exit 1
fi

export GOTOOLCHAIN=local
export GOFLAGS="-mod=readonly"
export CGO_ENABLED=1
ldflags="-s -w -buildid="
# nographviz: any-sync's objecttree links graphviz (a wasm build plus the
# wazero runtime) for debug rendering on desktop Linux/macOS; the tag drops
# it (it is already off on Android and iOS).
gobuild=(go build -trimpath -buildvcs=false -tags nographviz)

mkdir -p "$out"
rm -f "$out"/*

case "$target" in
  macos_arm64)
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
    export GOOS=darwin GOARCH=arm64
    export CC="$(xcrun --sdk macosx -f clang) -arch arm64 -isysroot $sdk -mmacosx-version-min=13.0"
    export CGO_CFLAGS="-mmacosx-version-min=13.0" CGO_LDFLAGS="-mmacosx-version-min=13.0"
    (cd "$here" && "${gobuild[@]}" -buildmode=c-shared \
      -ldflags="$ldflags -extldflags=-Wl,-install_name,@rpath/libany_shim.dylib,-headerpad_max_install_names" \
      -o "$out/libany_shim.dylib" .)
    rm -f "$out/libany_shim.h"
    ;;

  ios_arm64|ios_sim_arm64)
    if [[ "$target" == ios_arm64 ]]; then
      sdkname=iphoneos; triple=arm64-apple-ios13.0
    else
      sdkname=iphonesimulator; triple=arm64-apple-ios13.0-simulator
    fi
    sdk="$(xcrun --sdk "$sdkname" --show-sdk-path)"
    clang="$(xcrun --sdk "$sdkname" -f clang)"
    export GOOS=ios GOARCH=arm64
    export CC="$clang -target $triple -isysroot $sdk"
    export CGO_CFLAGS="-target $triple" CGO_LDFLAGS="-target $triple"
    work="$(mktemp -d "${TMPDIR:-/tmp}/any_shim_ios.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    (cd "$here" && "${gobuild[@]}" -buildmode=c-archive -ldflags="$ldflags" -o "$work/libany_shim.a" .)
    # Export only the C API: the archive's other globals stay local, and
    # -dead_strip drops what they alone reached.
    python3 - "$here/include/any_shim.h" > "$work/exports.txt" <<'PY'
import re, sys
for n in re.findall(r'(?m)^(?:any_shim_status|uint32_t|void) (any_shim_[a-z0-9_]+)\(', open(sys.argv[1]).read()):
    print("_" + n)
PY
    "$clang" -target "$triple" -isysroot "$sdk" -dynamiclib \
      -Wl,-force_load,"$work/libany_shim.a" \
      -Wl,-exported_symbols_list,"$work/exports.txt" \
      -Wl,-dead_strip -Wl,-install_name,@rpath/libany_shim.dylib \
      -Wl,-headerpad_max_install_names \
      -framework CoreFoundation -framework Security -lresolv \
      -o "$out/libany_shim.dylib"
    xcrun strip -x "$out/libany_shim.dylib"
    if [[ "$target" == ios_sim_arm64 ]]; then
      xcrun vtool -set-build-version iossim 13.0 "$(xcrun --sdk iphonesimulator --show-sdk-version)" \
        -replace -output "$out/libany_shim.dylib" "$out/libany_shim.dylib"
    fi
    ;;

  android_arm64)
    ndk="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/29.0.14206865}"
    case "$(uname -s)" in
      Darwin) host=darwin-x86_64 ;;
      Linux) host=linux-x86_64 ;;
      *) echo "build.sh: no NDK host for $(uname -s)" >&2; exit 1 ;;
    esac
    if ! grep -q 'Pkg.Revision = 29\.' "$ndk/source.properties"; then
      echo "build.sh: $ndk is not NDK r29" >&2
      exit 1
    fi
    export GOOS=android GOARCH=arm64
    export CC="$ndk/toolchains/llvm/prebuilt/$host/bin/aarch64-linux-android24-clang"
    (cd "$here" && "${gobuild[@]}" -buildmode=c-shared \
      -ldflags="$ldflags -extldflags=-Wl,-z,max-page-size=16384,-soname,libany_shim.so" \
      -o "$out/libany_shim.so" .)
    rm -f "$out/libany_shim.h"
    ;;

  linux_x86_64|linux_arm64)
    want_arch=x86_64; [[ "$target" == linux_arm64 ]] && want_arch=aarch64
    if [[ "$(uname -s)" != Linux || "$(uname -m)" != "$want_arch" ]]; then
      echo "build.sh: $target builds on a Linux $want_arch host" >&2
      exit 1
    fi
    export GOOS=linux
    (cd "$here" && "${gobuild[@]}" -buildmode=c-shared \
      -ldflags="$ldflags -extldflags=-Wl,-soname,libany_shim.so" \
      -o "$out/libany_shim.so" .)
    rm -f "$out/libany_shim.h"
    ;;

  windows_x86_64)
    case "$(uname -s)" in
      MINGW*|MSYS*|CYGWIN*) ;;
      *) echo "build.sh: windows_x86_64 builds on a Windows host" >&2; exit 1 ;;
    esac
    export GOOS=windows GOARCH=amd64
    (cd "$here" && "${gobuild[@]}" -buildmode=c-shared -ldflags="$ldflags" -o "$out/any_shim.dll" .)
    rm -f "$out/any_shim.h"
    ;;

  *)
    echo "build.sh: unknown target $target" >&2
    exit 1
    ;;
esac

py=python3; command -v python3 > /dev/null || py=python   # Windows runners
"$py" "$here/check_exports.py" "$out/"*any_shim.* "$target"
ls -l "$out"

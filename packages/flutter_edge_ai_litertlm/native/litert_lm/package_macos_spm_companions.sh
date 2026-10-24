#!/bin/bash
#
# Package the two macOS companion libraries of a native release as the
# xcframework zips that macos/flutter_edge_ai_litertlm/Package.swift fetches as
# Swift Package Manager binary targets (#689).
#
# Input is the release's own litertlm-macos_arm64.tar.gz, already published and
# pinned by hook/build.dart, so the zips carry exactly the bytes users already
# run, wrapped as versioned frameworks: the install name becomes
# @rpath/<X>.framework/Versions/A/<X> (Google's headers have room for it) and
# the binary is signed ad hoc. Xcode signs the embedded copy with the app's own
# identity.
#
# The output is deterministic: running it twice on the same tarball gives the
# same zip bytes, so a checksum can be regenerated and compared at any time.
#
# Usage:
#   package_macos_spm_companions.sh <litertlm-macos_arm64.tar.gz> <out_dir>
#
# Writes <out_dir>/GemmaModelConstraintProvider.xcframework.zip,
# <out_dir>/LiteRtLmMetalAccelerator.xcframework.zip and
# <out_dir>/checksums_spm_macos.txt (`swift package compute-checksum` of each,
# the value Package.swift pins).

set -euo pipefail

TARBALL="${1:?usage: $0 <litertlm-macos_arm64.tar.gz> <out_dir>}"
OUT="${2:?usage: $0 <litertlm-macos_arm64.tar.gz> <out_dir>}"
COMPANIONS="GemmaModelConstraintProvider LiteRtLmMetalAccelerator"

mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

tar -xzf "${TARBALL}" -C "${WORK}"

# The bundle version in each framework's Info.plist: the native release the
# bytes come from, read from the hook so the two cannot disagree.
HOOK="$(cd "$(dirname "$0")/../.." && pwd)/hook/build.dart"
NATIVE_VERSION="$(sed -n "s/^  version: '\([^']*\)',$/\1/p" "${HOOK}" | head -1)"
[ -n "${NATIVE_VERSION}" ] || { echo "could not read the native version from ${HOOK}" >&2; exit 1; }

: > "${OUT}/checksums_spm_macos.txt"
for base in ${COMPANIONS}; do
  src="${WORK}/lib${base}.dylib"
  [ -f "${src}" ] || { echo "${TARBALL} has no lib${base}.dylib" >&2; exit 1; }

  fw="${WORK}/fw/${base}.framework"
  mkdir -p "${fw}/Versions/A/Resources"
  cp "${src}" "${fw}/Versions/A/${base}"
  install_name_tool -id "@rpath/${base}.framework/Versions/A/${base}" \
    "${fw}/Versions/A/${base}" 2>/dev/null
  (cd "${fw}" && ln -s A Versions/Current && ln -s "Versions/Current/${base}" "${base}" \
    && ln -s Versions/Current/Resources Resources)
  # LSMinimumSystemVersion is the binary's own minimum (Google builds these for
  # macOS 14), which is also what Package.swift declares.
  minos="$(vtool -show-build "${fw}/Versions/A/${base}" | awk '/minos/{print $2; exit}')"
  cat > "${fw}/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${base}</string>
  <key>CFBundleIdentifier</key><string>dev.flutteredge.litertlm.${base}</string>
  <key>CFBundleName</key><string>${base}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${NATIVE_VERSION%%-*}</string>
  <key>CFBundleVersion</key><string>${NATIVE_VERSION}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>${minos}</string>
</dict>
</plist>
EOF
  codesign --force --sign - "${fw}"

  xcf="${WORK}/xcf/${base}.xcframework"
  mkdir -p "${WORK}/xcf"
  xcodebuild -create-xcframework -framework "${fw}" -output "${xcf}" >/dev/null

  # Fixed timestamps and order, no extra attributes: the zip's bytes depend on
  # the content only.
  find "${xcf}" -exec touch -h -t 200001010000 {} +
  zip_out="${OUT}/${base}.xcframework.zip"
  rm -f "${zip_out}"
  (cd "${WORK}/xcf" && find "${base}.xcframework" | LC_ALL=C sort \
    | TZ=UTC zip -q -X -y -D "${zip_out}" -@)

  sum="$(swift package compute-checksum "${zip_out}")"
  echo "${sum}  ${base}.xcframework.zip" >> "${OUT}/checksums_spm_macos.txt"
  echo "${base}.xcframework.zip ${sum}"
done

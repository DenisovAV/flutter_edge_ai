#!/bin/sh
#
# Stage the upstream Apple companion dylibs into a built macOS .app.
#
# hook/build.dart deliberately skips these from Native Assets on macOS (#247):
# the three dylibs Google ships (libGemmaModelConstraintProvider.dylib,
# libLiteRtMetalAccelerator.dylib, libLiteRtTopKMetalSampler.dylib) were linked
# without -Wl,-headerpad_max_install_names, so Native Assets' JIT path aborts
# rewriting their install_name to a long absolute path. Nothing else stages
# them, so this script does — and patches LiteRtLm's own reference to match.
#
# Called from the app's macos/Podfile `post_install` build phase. Kept as a
# standalone script so the logic has ONE home (it used to be copy-pasted into
# every example Podfile and the README) and so it can be tested without an
# Xcode build.
#
# Usage:
#   stage_macos_companions.sh <frameworks_dir> [source_dir]
#
#   frameworks_dir  the app's Contents/Frameworks
#   source_dir      where the lib*.dylib companions live; when omitted, the
#                   Native Assets cache is used, then an in-repo prebuilt/.

set -e

FRAMEWORKS="$1"
SOURCE_DIR="$2"

if [ -z "${FRAMEWORKS}" ]; then
  echo "[flutter_gemma] usage: $0 <frameworks_dir> [source_dir]" >&2
  exit 2
fi

# Not an error: the phase can run before the app bundle exists.
if [ ! -d "${FRAMEWORKS}" ]; then
  exit 0
fi

COMPANIONS="GemmaModelConstraintProvider LiteRtMetalAccelerator LiteRtTopKMetalSampler"

# Sweep any leftover lib*.dylib symlinks from older flutter_gemma versions.
for base in ${COMPANIONS}; do
  rm -f "${FRAMEWORKS}/lib${base}.dylib"
done

# Resolve the dylib source directory in this order:
# 1. Native Assets cache — where hook/build.dart fetches them on
#    `flutter pub get`. This is the ONLY source an installed app ever sees:
#    prebuilt/ is .gitignored and excluded from the pub package.
# 2. This repo's own prebuilt/, for working on the plugin itself with a
#    freshly built bundle and a cold cache. It never exists for an app
#    installed from pub.dev, but it DOES exist in a source checkout where a
#    maintainer ran native/litert_lm/build_macos.sh.
if [ -n "${SOURCE_DIR}" ]; then
  PLUGIN_PREBUILT="${SOURCE_DIR}"
else
  for candidate in \
      "${HOME}/Library/Caches/flutter_gemma/native/macos_arm64" \
      "${SRCROOT}/../../../flutter_gemma_litertlm/native/litert_lm/prebuilt/macos_arm64"; do
    if [ -f "${candidate}/libGemmaModelConstraintProvider.dylib" ]; then
      PLUGIN_PREBUILT="${candidate}"
      break
    fi
  done
fi

if [ -z "${PLUGIN_PREBUILT:-}" ] || [ ! -d "${PLUGIN_PREBUILT}" ]; then
  echo "[flutter_gemma] ERROR: Could not find macOS companion dylibs in either of:"
  echo "  - \$HOME/Library/Caches/flutter_gemma/native/macos_arm64/"
  echo "  - \$SRCROOT/../../../flutter_gemma_litertlm/native/litert_lm/prebuilt/macos_arm64/"
  echo "  Run 'flutter clean && flutter pub get' to repopulate the Native Assets cache."
  exit 1
fi

echo "[flutter_gemma] Using companion dylibs from: ${PLUGIN_PREBUILT}"

# Wrap each upstream dylib into a .framework bundle inside the app's
# Contents/Frameworks/ so dlopen("@executable_path/../Frameworks/<X>.framework/<X>")
# (the path our patched gpu_registry.cc uses) resolves at runtime.
for base in ${COMPANIONS}; do
  src="${PLUGIN_PREBUILT}/lib${base}.dylib"
  if [ ! -f "${src}" ]; then
    # Not every companion ships on every platform (the macOS bundle carries no
    # TopK Metal sampler), so this is a note, not a failure. The one that MUST
    # be present is whichever LiteRtLm names in its load commands, and the
    # post-condition at the end fails the build if that one is missing.
    echo "[flutter_gemma] note: ${src} not found — ${base}.framework not staged"
    continue
  fi
  fw_dir="${FRAMEWORKS}/${base}.framework"
  mkdir -p "${fw_dir}/Versions/A/Resources"
  cp "${src}" "${fw_dir}/Versions/A/${base}"
  # Set install_name to the @rpath the patched LiteRtLm dlopens.
  install_name_tool -id "@rpath/${base}.framework/Versions/A/${base}" \
    "${fw_dir}/Versions/A/${base}" 2>/dev/null || true
  # Symlinks Apple expects in a versioned framework bundle.
  (cd "${fw_dir}" && ln -sfh A Versions/Current && ln -sfh "Versions/Current/${base}" "${base}" && ln -sfh "Versions/Current/Resources" Resources)
  # Minimal Info.plist so the framework is well-formed.
  cat > "${fw_dir}/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${base}</string>
  <key>CFBundleIdentifier</key><string>dev.flutterberlin.flutter_gemma.${base}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
</dict>
</plist>
EOF
  # Re-sign the framework binary: install_name_tool above invalidated its code
  # signature, and unlike LiteRtLm these hand-copied companion frameworks are
  # not re-signed by Xcode — an unsigned/modified page trips CODESIGNING
  # "Invalid Page" at dlopen. Ad-hoc sign like LiteRtLm. Deliberately NOT
  # silenced: a failed re-sign is a bundle that dies at launch, and `set -e`
  # turning it into a build error is the whole point of this script.
  codesign --force --sign - "${fw_dir}/Versions/A/${base}"
  echo "[flutter_gemma] copied ${base}.framework"
done

# Point LiteRtLm's LC_LOAD_DYLIB entries at the frameworks staged above.
#
# Read the CURRENT value out of the binary instead of assuming the upstream
# `@rpath/lib<X>.dylib` shape. In some macOS builds the dependency has already
# been relocated — `@executable_path/../Frameworks/lib<X>.dylib` — before this
# runs, and `install_name_tool -change` on a string that is no longer present
# silently succeeds while changing nothing. The companion framework then sits
# in the bundle unreferenced and the app dies at launch on the plain dylib name
# that no file answers to (#457).
LITERTLM="${FRAMEWORKS}/LiteRtLm.framework/Versions/A/LiteRtLm"
if [ -f "${LITERTLM}" ]; then
  for base in ${COMPANIONS}; do
    [ -d "${FRAMEWORKS}/${base}.framework" ] || continue
    for old in $(otool -L "${LITERTLM}" | awk '{print $1}' \
                   | grep "/lib${base}\.dylib\$" || true); do
      install_name_tool -change \
        "${old}" \
        "@rpath/${base}.framework/Versions/A/${base}" \
        "${LITERTLM}"
      echo "[flutter_gemma] repointed ${old} -> ${base}.framework"
    done
  done

  # Fail the build rather than ship a bundle that cannot launch: any remaining
  # plain-dylib reference to a companion is the #457 signature.
  stale=$(otool -L "${LITERTLM}" | awk '{print $1}' \
            | grep -E "/lib(GemmaModelConstraintProvider|LiteRtMetalAccelerator|LiteRtTopKMetalSampler)\.dylib\$" \
            || true)
  if [ -n "${stale}" ]; then
    echo "[flutter_gemma] ERROR: LiteRtLm still loads companion dylibs that are" >&2
    echo "  not staged in the app bundle — it would fail dlopen at launch:" >&2
    echo "${stale}" | sed 's/^/    /' >&2
    exit 1
  fi

  # install_name_tool above invalidated LiteRtLm's signature; re-sign it, and
  # let a failure fail the build for the same reason as the companions above.
  codesign --force --sign - "${LITERTLM}"
fi

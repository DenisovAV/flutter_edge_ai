#!/usr/bin/env bash
# check_litertlm_runtime_imports.sh — how far flutter_edge_ai_litertlm's
# lib/src still is from a Flutter-free runtime layer. REPORT ONLY: it always
# exits 0 and is not wired into CI.
#
# For every .dart file under packages/flutter_edge_ai_litertlm/lib/src it
# lists the import/export directives that tie the file to Flutter or to core:
#   flutter  — package:flutter/ (the SDK: foundation, services, …)
#   plugin   — package:path_provider/ (a Flutter plugin)
#   core     — package:flutter_edge_ai/ (core, which itself imports Flutter)
# and prints per-area counts. The runtime side is lib/src/{ffi,bundle,runtime,
# hook}; everything else is counted as the rest (adapter, web, catalog, …).
# The later goal (Phase 0 exit criterion) is no flutter/plugin/core directive
# in the runtime side.
#
# Usage: tool/check_litertlm_runtime_imports.sh [path to the package's lib/src]
#        (defaults to this checkout's), -q for the counts alone.
#
# Directive detection: a line starting (after indentation) with `import` or
# `export` whose URI sits on that line — what `dart format` writes.

set -u

quiet=0
if [[ "${1:-}" == "-q" ]]; then
  quiet=1
  shift
fi
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$root/packages/flutter_edge_ai_litertlm/lib/src}"
if [[ ! -d "$src" ]]; then
  echo "no such directory: $src" >&2
  exit 0
fi

kind_of() {
  case "$1" in
    *"'package:flutter/"*) echo flutter ;;
    *"'package:path_provider/"*) echo plugin ;;
    *"'package:flutter_edge_ai/"*) echo core ;;
    *) echo "" ;;
  esac
}

area_of() {
  case "$1" in
    ffi/* | bundle/* | runtime/* | hook/*) echo runtime ;;
    *) echo rest ;;
  esac
}

# Per-area counters (bash 3.2, macOS's /bin/bash, has no associative
# arrays): <counter>_runtime and <counter>_rest.
for area in runtime rest; do
  for counter in any flutter plugin core; do
    eval "${counter}_${area}=0"
  done
done
total_files=0

while IFS= read -r file; do
  rel="${file#"$src"/}"
  area="$(area_of "$rel")"
  total_files=$((total_files + 1))
  has_flutter=0 has_plugin=0 has_core=0
  lines=()
  while IFS= read -r line; do
    kind="$(kind_of "$line")"
    [[ -z "$kind" ]] && continue
    case "$kind" in
      flutter) has_flutter=1 ;;
      plugin) has_plugin=1 ;;
      core) has_core=1 ;;
    esac
    lines+=("    $kind: $(echo "$line" | sed -E 's/^[[:space:]]+//')")
  done < <(grep -E "^[[:space:]]*(import|export)[[:space:]]+'package:(flutter|path_provider|flutter_edge_ai)/" "$file" | tr -d '\r')
  if ((${#lines[@]} > 0)); then
    eval "any_${area}=\$((any_${area} + 1))"
    eval "flutter_${area}=\$((flutter_${area} + has_flutter))"
    eval "plugin_${area}=\$((plugin_${area} + has_plugin))"
    eval "core_${area}=\$((core_${area} + has_core))"
    if ((quiet == 0)); then
      echo "[$area] $rel"
      printf '%s\n' "${lines[@]}"
    fi
  fi
done < <(find "$src" -name '*.dart' -type f | LC_ALL=C sort)

((quiet == 0)) && echo
echo "Files under $src: $total_files"
for area in runtime rest; do
  eval "any=\$any_${area} flutter=\$flutter_${area}"
  eval "plugin=\$plugin_${area} core=\$core_${area}"
  echo "$area: $any file(s) import Flutter, a Flutter plugin or core" \
    "(flutter $flutter, path_provider $plugin, flutter_edge_ai $core)"
done
exit 0

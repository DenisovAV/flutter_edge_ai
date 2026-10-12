#!/usr/bin/env bash
# check_core_surface.sh — keep every package on flutter_edge_ai's public surface.
#
# Core publishes five libraries: flutter_edge_ai.dart (apps), engine.dart
# (engine SPI, re-exports the app library), engine_io.dart (dart:io/ffi
# helpers), engine_web.dart (dart:js_interop helpers) and genai.dart. Everything
# else lives under lib/src and is private. The analyzer enforces part of that
# (`implementation_imports: error` in every analysis_options.yaml), but its lint
# only looks at files inside lib/, and it cannot tell a reviewed exception from
# a careless one. This script closes both gaps.
#
# It scans every .dart file under packages/ and fails on:
#   (a) an import/export of `package:flutter_edge_ai/<x>` where <x> is neither
#       one of the five public libraries nor under src/ (an old deep path);
#   (b) an import/export of another workspace package's `src/` that is not
#       directly preceded by the annotated ignore
#         // ignore: implementation_imports — <reason>
#       That inline comment is the single allowlist: there is no second list to
#       keep in sync, and the reason sits next to the import it excuses;
#   (c) any such `src/` import or export in code a package SHIPS, annotated or
#       not: packages/<pkg>/{lib,hook,bin}/ and packages/<pkg>/example/lib/
#       (example/lib is in the pub archive; .pubignore drops only test/,
#       example/integration_test/ and example/build/). No exceptions.
#
# Directive detection: a line that starts (after indentation) with `import` or
# `export` followed by anything but an identifier character — so `import'x'`,
# `import/*c*/'x'` and a URI on the next line are all seen — up to the first
# line containing `;`. CRLF line endings are accepted.
#
# It prints every annotated import with its reason, so the allowlist can be
# reviewed in one place.
#
# Scope: every .dart file under packages/; every ```dart fence of the website's
# docs and codelab texts (website/content/**/*.md, website/codelabs/**/*.md),
# which users copy into their apps; and every .dart file of the codelab apps
# (codelabs/**), which users start their own apps from. Fences and codelab
# apps are held to the shipped-code rules: (a) for a deep path, and
#   (d) any import or export of a workspace package's src/ — no annotation
#       excuses it in a doc or a codelab.
# A violation in a fence is reported at the line of the .md file.
#
# Usage: tool/check_core_surface.sh
#        CHECK_CORE_SURFACE_ROOT=<dir> tool/check_core_surface.sh   (scan <dir>
#        instead of the repository — for the script's own self-test,
#        packages/flutter_edge_ai/test/tool/check_core_surface_test.dart)
# Exit:  0 clean · 1 a violation, or nothing was scanned.

set -uo pipefail

cd "${CHECK_CORE_SURFACE_ROOT:-$(dirname "${BASH_SOURCE[0]}")/..}"

# Owning package of every pubspec under packages/, deepest directory first so
# an example app wins over the package that contains it.
owners_file="$(mktemp)"
files_file="$(mktemp)"
fence_dir="$(mktemp -d)"
trap 'rm -f "$owners_file" "$files_file"; rm -rf "$fence_dir"' EXIT

find packages -name pubspec.yaml \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' \
  -not -path '*/ephemeral/*' -not -path '*/Pods/*' -not -path '*/.symlinks/*' |
  while read -r pubspec; do
    name="$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9_]*\).*/\1/p' "$pubspec" | head -1)"
    [[ -n "$name" ]] && printf '%s\t%s\n' "$(dirname "$pubspec")" "$name"
  done | awk -F'\t' '{ print length($1) "\t" $0 }' | sort -rn | cut -f2- \
  >"$owners_file"

find packages -name '*.dart' \
  -not -path '*/.dart_tool/*' -not -path '*/build/*' \
  -not -path '*/ephemeral/*' -not -path '*/Pods/*' -not -path '*/.symlinks/*' \
  -not -path '*/node_modules/*' | sort >"$files_file"

scanned="$(wc -l <"$files_file" | tr -d ' ')"
if [[ "$scanned" -eq 0 ]]; then
  echo "::error::check_core_surface: found no .dart files under packages/ — a"
  echo "::error::check that examined nothing is not a pass."
  exit 1
fi

# The codelab apps, with the exclusions packages/ has (build output, generated
# platform code, CocoaPods). They are not workspace members: each resolves the
# published packages, as a user's app does.
codelab_files=0
if [[ -d codelabs ]]; then
  codelab_list="$(find codelabs -name '*.dart' \
    -not -path '*/.dart_tool/*' -not -path '*/build/*' \
    -not -path '*/ephemeral/*' -not -path '*/Pods/*' -not -path '*/.symlinks/*' \
    -not -path '*/node_modules/*' | sort)"
  if [[ -n "$codelab_list" ]]; then
    printf '%s\n' "$codelab_list" >>"$files_file"
    codelab_files="$(printf '%s\n' "$codelab_list" | wc -l | tr -d ' ')"
  fi
fi

# Each ```dart fence of a website doc or codelab text becomes one file,
# <fence_dir>/<path of the .md>@<line of its opening fence>.dart, so the awk
# below checks it like any other file and maps its lines back to the .md.
# Fences may be indented (inside a list); any other language is not Dart.
fence_sources=()
for dir in website/content website/codelabs; do
  if [[ -d "$dir" ]]; then fence_sources+=("$dir"); fi
done
if [[ "${#fence_sources[@]}" -gt 0 ]]; then
  find "${fence_sources[@]}" -name '*.md' -not -path '*/build/*' | sort |
    while read -r md; do
      mkdir -p "$fence_dir/$(dirname "$md")"
      awk -v out="$fence_dir/$md" '
        !in_fence && /^[ \t]*```dart[ \t]*$/ {
          in_fence = 1; file = out "@" FNR ".dart"; printf "" > file; next
        }
        in_fence && /^[ \t]*```/ { in_fence = 0; close(file); next }
        in_fence { print > file }
      ' "$md"
    done
fi
find "$fence_dir" -name '*.dart' | sort >>"$files_file"
fences="$(find "$fence_dir" -name '*.dart' | wc -l | tr -d ' ')"
codelab_fences=0
if [[ -d "$fence_dir/website/codelabs" ]]; then
  codelab_fences="$(find "$fence_dir/website/codelabs" -name '*.dart' | wc -l | tr -d ' ')"
fi

# Workspace packages whose src/ is private to them: every pubspec directly
# under packages/ (examples are apps, nobody imports them).
workspace_pkgs="$(awk -F'\t' '$1 ~ /^packages\/[^\/]+$/ { print $2 }' "$owners_file" | tr '\n' ' ')"

awk -v owners_file="$owners_file" -v workspace_pkgs="$workspace_pkgs" \
  -v fence_root="$fence_dir/" -v fences="$fences" \
  -v codelab_fences="$codelab_fences" -v codelab_files="$codelab_files" '
BEGIN {
  n = 0
  while ((getline line < owners_file) > 0) {
    split(line, parts, "\t")
    n++; owner_dir[n] = parts[1]; owner_name[n] = parts[2]
  }
  owners = n
  split(workspace_pkgs, wp, " ")
  for (i in wp) if (wp[i] != "") workspace[wp[i]] = 1
  public["flutter_edge_ai.dart"] = 1
  public["engine.dart"] = 1
  public["engine_io.dart"] = 1
  public["engine_web.dart"] = 1
  public["genai.dart"] = 1
  violations = 0; annotated = 0; files = 0
  # The annotation: the comment line directly above the directive.
  ann_re = "^[ \t]*// ignore: implementation_imports — [^ \t].*$"
  # A quoted package: URI, single or double quotes (\047 is the single quote).
  uri_re = "[\"\047]package:[^\"\047]+[\"\047]"
}

function owner_of(path,    i) {
  for (i = 1; i <= owners; i++) {
    if (index(path, owner_dir[i] "/") == 1) return owner_name[i]
  }
  return ""
}

function shipped(path) {
  # lib/, hook/ and bin/ of a package, and lib/ of an example app (pub archive).
  return path ~ /^packages\/[^\/]+\/(lib|hook|bin)\// ||
    path ~ /^packages\/[^\/]+\/example\/lib\//
}

function in_fence(path) {
  return index(path, fence_root) == 1
}

function in_codelab(path) {
  return index(path, "codelabs/") == 1
}

# A fence file reports as <the .md>:<its line>; the file name carries both.
function violation(msg,    rel, at, md, first) {
  if (in_fence(FILENAME)) {
    rel = substr(FILENAME, length(fence_root) + 1)
    at = match(rel, /@[0-9]+\.dart$/)
    md = substr(rel, 1, at - 1)
    first = substr(rel, at + 1, RLENGTH - 6) + 0
    printf "  FAIL  %s:%d  %s\n", md, first + start_line, msg
  } else {
    printf "  FAIL  %s:%d  %s\n", FILENAME, start_line, msg
  }
  violations++
}

# Checks one quoted URI found inside a directive.
function check_uri(uri,    rest, pkg, slash) {
  if (uri !~ /^package:/) return
  rest = substr(uri, 9)
  slash = index(rest, "/")
  if (slash == 0) return
  pkg = substr(rest, 1, slash - 1)
  rest = substr(rest, slash + 1)

  if (pkg == "flutter_edge_ai" && rest !~ /^src\// && !(rest in public)) {
    violation("(a) " uri " is not a public library — use flutter_edge_ai.dart, engine.dart, engine_io.dart, engine_web.dart or genai.dart")
    return
  }
  if (!(pkg in workspace) || rest !~ /^src\//) return
  if (pkg == file_owner) return

  if (in_fence(FILENAME)) {
    violation("(d) " uri " — a website code fence must not import a package'"'"'s src/")
    return
  }
  if (in_codelab(FILENAME)) {
    violation("(d) " uri " — a codelab app must not import a package'"'"'s src/")
    return
  }
  if (shipped(FILENAME)) {
    violation("(c) " uri " — shipped code (lib/, hook/, bin/, example/lib/) must not import another package'"'"'s src/")
    return
  }
  if (prev_line ~ ann_re) {
    reason = prev_line
    sub(/^[ \t]*\/\/ ignore: implementation_imports — /, "", reason)
    allow[++annotated] = sprintf("  %s:%d  %s\n        — %s", FILENAME, start_line, uri, reason)
  } else {
    violation("(b) " uri " needs `// ignore: implementation_imports — <reason>` on the line above")
  }
}

FNR == 1 {
  files++
  file_owner = owner_of(FILENAME)
  in_directive = 0
  before = ""
}

{
  line = $0
  sub(/\r$/, "", line)   # CRLF files
  # `import`/`export` not followed by an identifier character: catches a
  # space, a quote or a comment right after the keyword, and a bare keyword
  # whose URI is on the next line, but not `importFoo`. (No quote characters in
  # this program: it sits inside a single-quoted shell string.)
  if (!in_directive && line ~ /^[ \t]*(import|export)([^A-Za-z0-9_$]|$)/) {
    in_directive = 1
    start_line = FNR
    prev_line = before
  }
  if (in_directive) {
    rest = line
    while (match(rest, uri_re)) {
      # check_uri may call match() itself (violation() does for a fence), so
      # keep this match before it moves RSTART/RLENGTH.
      uri_start = RSTART; uri_length = RLENGTH
      check_uri(substr(rest, uri_start + 1, uri_length - 2))
      rest = substr(rest, uri_start + uri_length)
    }
    # The directive ends on the first line holding its `;`, whatever follows
    # it (a trailing `// ...` or `/* ... */`).
    if (index(line, ";") > 0) in_directive = 0
  }
  before = line
}

END {
  print "==> Annotated cross-package src/ imports (the allowlist): " annotated
  for (i = 1; i <= annotated; i++) print allow[i]
  print ""
  if (violations > 0) {
    printf "==> check_core_surface: %d violation(s) in %d files scanned (%d of them website fences, %d in codelab texts; %d codelab sources).\n", violations, files, fences, codelab_fences, codelab_files
    exit 1
  }
  printf "==> check_core_surface: OK — %d files scanned (%d of them website fences, %d in codelab texts; %d codelab sources), %d annotated src/ imports, 0 violations.\n", files, fences, codelab_fences, codelab_files, annotated
}
' $(cat "$files_file")

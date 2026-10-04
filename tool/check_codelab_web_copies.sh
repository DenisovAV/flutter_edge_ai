#!/usr/bin/env bash
# Warns, and does not fail, when a codelab's copy of a package's web bundle is
# missing or differs from this repo's packages/<pkg>/web/. Fails only when the
# check itself cannot run: a package web/ dir, every consuming app, or a copy it
# cannot read.
#
# Why a warning and not a gate: the codelab step apps depend on the PUBLISHED
# packages, and tool/check_codelabs.sh (via tool/check_codelab_web_storage.py)
# compares their copies with the version each app resolves from pub.dev.
# Between the PR that changes a bundle and the publish, the copies must still
# match the OLD, published one — syncing early would turn that check red,
# correctly. The moment to sync is after the publish (release skill, Step 10b).
# This makes the consequence visible on the PR that causes it, and on every PR
# after it until the post-publish sync lands, instead of as a red Codelabs run
# after the release (#562).
#
# It walks the PACKAGE's files, not the codelab copies: a file the bundle adds or
# renames has no copy yet, and only this direction reports it missing.
set -euo pipefail
cd "$(dirname "$0")/.."

# "<package web dir>|<file whose presence marks a codelab app as a consumer>"
BUNDLES=(
  "packages/flutter_edge_ai_litertlm/web|litert_embeddings.js"
  "packages/flutter_edge_ai/web|cache_api.js"
)

shopt -s nullglob
report=()
checked=0
for bundle in "${BUNDLES[@]}"; do
  src="${bundle%%|*}"
  key="${bundle##*|}"
  if [ ! -d "$src" ]; then
    echo "::error::$src is missing — the codelab copy check cannot run"
    exit 1
  fi
  files=("$src"/*.js)
  apps=(codelabs/*/*/web/"$key")
  if [ "${#files[@]}" -eq 0 ] || [ "${#apps[@]}" -eq 0 ]; then
    echo "::error::nothing to compare for $src (${#files[@]} package files, ${#apps[@]} codelab apps with web/$key) — the check cannot run"
    exit 1
  fi
  for marker in "${apps[@]}"; do
    web="$(dirname "$marker")"
    for f in "${files[@]}"; do
      name="$(basename "$f")"
      copy="$web/$name"
      checked=$((checked + 1))
      if [ ! -f "$copy" ]; then
        report+=("missing  $copy  (the package ships $f)")
        continue
      fi
      rc=0
      cmp -s "$copy" "$f" || rc=$?
      case $rc in
        0) ;;
        1) report+=("differs  $copy  (from $f)") ;;
        *)
          echo "::error::cannot compare $copy with $f (cmp exit $rc)"
          exit 1
          ;;
      esac
    done
  done
done

echo "codelab web copies checked: $checked, missing or differing: ${#report[@]}"
if [ "${#report[@]}" -gt 0 ]; then
  printf '  %s\n' "${report[@]}"
  # One annotation, not one per copy: GitHub shows at most 10 per step, and a
  # full bundle rebuild touches 36. The list goes to the step summary instead.
  echo "::warning::${#report[@]} codelab web copies are missing or differ from this repo's packages/*/web — sync them from the published package after the release (release skill, Step 10b)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "### Codelab web copies to sync after the next publish"
      echo
      # shellcheck disable=SC2016 # backticks are markdown, not expansion
      printf -- '- `%s`\n' "${report[@]}"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi

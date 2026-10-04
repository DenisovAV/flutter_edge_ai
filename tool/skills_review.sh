#!/usr/bin/env bash
#
# Which shipped skills does this release's diff put in doubt, and why.
#
# `check_skills.dart` answers "does this still compile" — renames, deletions
# and signature changes. It stays green when a symbol survives but changes MEANING, which is
# the failure that actually bit us: getActiveStt(language:) went from a
# load-time property of the recognizer to a per-transcription one, with no
# rename anywhere.
#
# Only reading catches that. This script decides WHAT to read: for each skill it
# lists the API symbols that skill names AND that this diff touched. A skill
# with hits is one you must open; a skill with none you can skip with a clear
# conscience.
#
# Usage, from the repo root:
#   bash tool/skills_review.sh <ref>        # e.g. v1.8.0, or origin/main
#   bash tool/skills_review.sh v1.8.0 HEAD
#
# Exit 0 always — this routes attention, it does not pass or fail.

set -uo pipefail

SKILLS_DIR=packages/flutter_edge_ai/skills
FROM=${1:-}
TO=${2:-HEAD}

if [ -z "$FROM" ]; then
  echo "usage: bash tool/skills_review.sh <since-ref> [until-ref]" >&2
  echo "  e.g. bash tool/skills_review.sh v1.8.0" >&2
  exit 2
fi

if [ ! -d "$SKILLS_DIR" ]; then
  echo "no skills directory at $SKILLS_DIR — run from the repo root" >&2
  exit 2
fi

# A ref this checkout cannot resolve — a typo, or a tag never fetched into a
# fresh clone or worktree — used to read as "nothing changed": `git diff` wrote
# to stderr, the diff file stayed empty, and the script printed the all-clear
# and exited 0. That green-lights skipping every skill, which is the one answer
# this script must never give by accident.
for r in "$FROM" "$TO"; do
  if ! git rev-parse --verify -q "$r^{commit}" >/dev/null; then
    echo "unknown ref: $r" >&2
    echo "  fetch it first, or pass one this checkout has (git tag, git branch -a)" >&2
    exit 2
  fi
done

# Added/removed source lines only. A symbol that merely sits near a change is
# not evidence; a symbol on a +/- line is.
DIFF=$(mktemp)
trap 'rm -f "$DIFF"' EXIT
git diff "$FROM" "$TO" -- 'packages/*/lib/**' \
  | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' > "$DIFF"

if [ ! -s "$DIFF" ]; then
  echo "no source changes in packages/*/lib between $FROM and $TO"
  echo "→ no skill needs re-reading on account of code"
  exit 0
fi

echo "Skills to re-read for $FROM..$TO"
echo

NOISE='String StateError ArgumentError UnsupportedError Exception name text description response spec chat must limit parameters type value'

flagged=0
for f in "$SKILLS_DIR"/*/SKILL.md; do
  skill=$(basename "$(dirname "$f")")
  code=$(awk '/^```dart/{c=1;next} /^```/{c=0} c' "$f")

  syms=$(
    {
      grep -oE '`[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*`' "$f" \
        | tr -d '`' | grep -E '^[A-Z]|[a-z][A-Z]'
      printf '%s' "$code" | grep -oE '(^|[ (,])[a-z][A-Za-z0-9_]*:' | tr -d ' (,:'
      printf '%s' "$code" | grep -oE '\b[A-Z][A-Za-z0-9_]*\.[a-z][A-Za-z0-9_]*'
    } | sort -u
  )

  hits=""
  for sym in $syms; do
    [ -z "$sym" ] && continue
    # Words with no routing power: dart:core types and identifiers so generic
    # that they appear in almost any diff. Leaving them in flagged 5 skills of 8
    # for an STT-only release, which is the same as flagging none.
    case " $NOISE " in *" $sym "*) continue ;; esac
    leaf="${sym##*.}"
    if grep -q "\b${leaf}\b" "$DIFF"; then
      hits="${hits}${hits:+ }${sym}"
    fi
  done

  if [ -n "$hits" ]; then
    flagged=$((flagged + 1))
    echo "  ${skill}"
    for h in $hits; do echo "      touched: ${h}"; done
    echo
  fi
done

if [ "$flagged" -eq 0 ]; then
  echo "  none — the diff touches no symbol any skill names"
  echo
fi

echo "${flagged} of $(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ') skill(s) flagged."
echo
echo "A hit means the skill DESCRIBES something this release changed. Open it and"
echo "check the prose still matches the behaviour — the symbol existing is not"
echo "the same as the skill being right."

#!/usr/bin/env bash
# test_all.sh — run every workspace package's tests, from the package's own dir.
#
# WHY THIS EXISTS
#
# `flutter test` at the repo root tests nothing: the workspace root has no
# test/ directory. Pointing it at a package (`flutter test packages/<pkg>`)
# runs from the WRONG working directory — several suites read fixtures through
# paths relative to the package root (flutter_edge_ai_agent's
# test/fixtures/skills/*.SKILL.md), and 20 of them fail on a missing file.
#
# Until 2026-08-18 CI ran only packages/flutter_gemma, leaving 97 of the repo's
# 169 test files unexercised — all 46 in speech, all 14 in agent — while those
# packages publish to pub.dev independently, each under its own version.
#
# Packages are DISCOVERED, never listed. A hardcoded list is how a new
# satellite ends up shipping untested: it simply never appears in the run.
# Every workspace package is reported as either tested or having no test/
# directory, and a run that discovers nothing fails rather than reporting
# success — a check that examined nothing is not a check that passed.
#
# Usage:
#   tool/test_all.sh              # all packages
#   tool/test_all.sh --coverage   # plus lcov for flutter_edge_ai (what CI does)
#
# Exit: 0 all green · 1 any package failed, or nothing was discovered.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

WANT_COVERAGE=0
[[ "${1:-}" == "--coverage" ]] && WANT_COVERAGE=1

# SqliteVectorStore resolves its vec0 loadable through Native Assets — on macOS
# that is `vec0.framework/vec0`, which exists only inside a built app, never
# under `flutter test` on the host. The store already honours $VEC0_DYLIB as an
# override (see `_resolveVec0Path`) and a maintainer usually has a local
# prebuilt, so point at it when one is there.
#
# The SUITES no longer need this: they call useHostNativeLibraries() (see
# rag_sqlite/test/vec0_locator.dart), which hands the store its path through the
# same programmatic override qdrant always had, from the same shared locator in
# core. A plain `flutter test` in that package now works with no environment at
# all. The export stays because the opt-in benchmark still reads it, and
# dropping it would silently turn that off.
#
# History worth keeping: those store tests used to SKIP, gated on $VEC0_DYLIB
# being set — which it never was — so a suite that had never once executed
# looked exactly like a suite that passed.
if [[ -z "${VEC0_DYLIB:-}" ]]; then
  _vec0_base="packages/flutter_edge_ai_sqlite/native/sqlite_vec/prebuilt"
  case "$(uname -s)" in
    Darwin) _vec0_rel="$_vec0_base/macos_arm64/libvec0.dylib" ;;
    # Both linux_x86_64 and linux_arm64 ship, so ask uname -m rather than
    # assuming: on an arm64 host the x86_64 file exists and would be exported,
    # handing every suite an incompatible ELF.
    Linux)
      case "$(uname -m)" in
        aarch64|arm64) _vec0_rel="$_vec0_base/linux_arm64/libvec0.so" ;;
        *)             _vec0_rel="$_vec0_base/linux_x86_64/libvec0.so" ;;
      esac
      ;;
    *)      _vec0_rel="" ;;
  esac
  if [[ -n "$_vec0_rel" && -f "$_vec0_rel" ]]; then
    export VEC0_DYLIB="$PWD/$_vec0_rel"   # absolute: suites run from their own dir
    echo "==> VEC0_DYLIB=$VEC0_DYLIB"
  else
    # NOT a skip announcement: since the loadables moved to a release,
    # useHostNativeLibraries() finds them in the download cache the hook
    # populates, so the suites run without this export.
    echo "==> no LOCAL prebuilt vec0 for $(uname -s); the suites will use the download cache"
  fi
fi

# NOTE: the cross-backend parity suite needs no wiring here. qdrant-edge's
# library is DOWNLOADED by a Native Assets hook and `flutter test` runs hooks,
# so it is already on disk by the time the suite opens a store. Since
# flutter_edge_ai_qdrant 1.4.0 that hook belongs to the official `qdrant_edge`
# SDK — the package carries no hook/ and no native/ of its own, and there is no
# locator file to point at. An earlier draft exported $QDRANT_DYLIB from a cargo
# target directory and told CI to build Rust; that was solving a problem the
# hook had already solved.

# NOTE, so nobody re-adds it: an earlier revision of this script excluded
# flutter_edge_ai_speech's `qwen3-artifacts` tag whenever the HuggingFace model
# snapshot was absent, on the assumption that those suites would otherwise fail
# in CI. That assumption was never tested and is false — the suites check for
# the snapshot themselves and call markTestSkipped. Measured with
# QWEN3_MODEL_DIR=/definitely/not/here: exit 0, 52 passed, 14 skipped, 0 failed.
#
# The exclusion therefore fixed no failure, replaced 14 itemised skips with
# invisible non-runs, and silenced 9 suites that execute perfectly well without
# artifacts. Removed. Let the suites decide; they already know how.

fail=0 tested=0 untested=0 total=0
summary=""

for dir in packages/*/; do
  pkg="$(basename "$dir")"
  [[ -f "${dir}pubspec.yaml" ]] || continue
  total=$((total + 1))

  # `-print -quit` rather than piping to `grep -q`: under `pipefail`, once
  # find's output exceeds the pipe buffer grep exits first, find dies on
  # SIGPIPE, and the poisoned pipeline reports "no tests" for a package that
  # has them. Reproducible at ~1.3 MB of find output; today's largest package
  # is 46 files, so it is latent — and it grows with the repo.
  if [[ -z "$(find "${dir}test" -name '*_test.dart' -print -quit 2>/dev/null)" ]]; then
    summary="${summary}  --  ${pkg}: no test/ directory"$'\n'
    untested=$((untested + 1))
    continue
  fi

  # Coverage only for core; that is what Codecov consumes.
  # No --reporter: on GitHub Actions the default is already the `github`
  # reporter, and naming any other one downgrades it.
  #
  # Spelled as two branches rather than an args array on purpose: macOS still
  # ships bash 3.2, where `set -u` plus an EMPTY array expansion is an
  # "unbound variable" error. CI runs bash 5 and would never have shown it —
  # this script is meant to be run locally too.
  echo "::group::flutter test — $pkg"
  if [[ $WANT_COVERAGE -eq 1 && "$pkg" == "flutter_edge_ai" ]]; then
    (cd "$dir" && flutter test --coverage)
  else
    (cd "$dir" && flutter test)
  fi
  rc=$?
  echo "::endgroup::"

  if [[ $rc -eq 0 ]]; then
    summary="${summary}  ok  ${pkg}"$'\n'
  else
    summary="${summary}  FAILED  ${pkg}"$'\n'
    fail=1
  fi
  tested=$((tested + 1))
done

echo
echo "==> Test coverage across the workspace"
printf '%s' "$summary"
echo "    ${tested} package(s) tested, ${untested} without tests, ${total} total."

if [[ $total -eq 0 ]]; then
  echo "::error::Discovered no packages under packages/*/ — the glob or the repo"
  echo "::error::layout changed. A run that tested nothing is not a pass."
  exit 1
fi
if [[ $tested -eq 0 ]]; then
  echo "::error::Found ${total} package(s) but none with a test/ directory."
  exit 1
fi

exit "$fail"

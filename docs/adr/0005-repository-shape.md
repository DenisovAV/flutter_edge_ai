# ADR 0005: Trimmed fork with the app as a workspace member

**Status:** accepted (Q24, TQ1, TQ2, TQ4, 2026-10-04) · Related: VA-0.1

## Context

The repository began as a full fork of `DenisovAV/flutter_edge_ai`: thirteen packages,
eight codelabs with step-by-step app copies, a marketing website, release tooling, agent
instructions and workflows written for upstream's release process. None of that is the
app. The owner wanted a fork to be "genuine" but has no intention of contributing back and
does not want the baggage.

## Options

1. **Keep everything** and add the app beside it. Honest fork; 70 MB of unrelated material;
   upstream's agent rules and hooks interfere with working here.
2. **Trim the fork on `develop`:** delete `codelabs/`, `website/`, `tool/`, upstream
   workflows, `.claude/`, `.fvm/`, and replace `AGENTS.md`; keep `packages/` so engine code
   can be read and patched; add the app under `apps/`.
3. **Fresh repository** depending on the published packages from pub.dev. Lightest; no
   engine source in the tree; patches require a published fork or a dependency override.

## Decision

Option 2.

- `main` stays a mirror of upstream for reference; `develop` is trimmed and diverges.
  Merging upstream later is possible but not planned (TQ24).
- The app lives at `apps/motormind/` and joins the root pub workspace, so it consumes the
  local `packages/flutter_edge_ai*` by name and `flutter pub get` at the root resolves
  everything once.
- The two pure-Dart packages, `apps/motormind/packages/vehicle_finance` and `advisor_core`,
  are **not** workspace members. They resolve on their own with plain `dart pub get`, so
  they can be tested with only a Dart SDK and no Flutter plugin resolution. The app depends
  on them by `path:`.
- Project CI is a new, scoped workflow; upstream workflows are deleted rather than left to
  trigger on `develop`.

## Consequences

- A clone is tens of megabytes lighter and a reviewer sees the app first.
- The fork relationship is still visible in git history and in `packages/`.
- If engine patches are ever needed, they are a local edit and a commit, not a publish.
- Dart and Flutter floors are inherited from upstream (Dart 3.12, Flutter 3.47 for sqlite).

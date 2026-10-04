# Motormind AI — agent instructions

This file replaces upstream `flutter_edge_ai`'s agent instructions on `develop`. The
upstream rules were written for a package maintainer's release process and do not apply.

## Ground rules

1. **Numbers come from tools.** Never let a model-generated string become a displayed
   number. Finance math lives in `apps/motormind/packages/vehicle_finance`; see ADR 0002.
2. **Pure Dart stays pure.** `vehicle_finance` and `advisor_core` must not import Flutter or
   any inference SDK. They run with `dart test` alone.
3. **Disclosure wording has one home**: `advisor_core/lib/src/policy/disclosures.dart`.
   Bump `version` when wording changes.
4. **Do not edit `packages/`** unless the app needs a fix. Prefix such commits with
   `upstream patch:`.
5. **No secrets in the tree.** Hugging Face tokens live in secure storage or
   `--dart-define`; `config.json` files are git-ignored.
6. **Keep the backlog current.** When a story lands, mark it in `BACKLOG.md` with the
   commit. New decisions get an ADR in `docs/adr/`.
7. **Commit attribution** follows the owner's decision in the questions log (pending).

## Working style

- The owner is relearning Flutter and wants trade-offs written down. When choosing a
  package or pattern, add two sentences on the alternatives to the relevant doc.
- Prefer small, reviewable commits on `develop`. Branch from `develop` for larger stories.
- Tests before merge: `dart test` in both pure packages; `flutter analyze` and
  `flutter test` in the app once it exists.

## Toolchain

See `docs/SETUP.md`. Use `fvm flutter` / `fvm dart`; the version is pinned in `.fvmrc`.

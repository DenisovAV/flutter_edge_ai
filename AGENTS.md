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
   `--dart-define`; `config.json` files are git-ignored. The committed Firebase config
   (`firebase_options.dart`, `google-services.json`) identifies the project and is not a
   secret; the analytics SDK is inert unless `MOTORMIND_ANALYTICS=true`.
6. **Keep the backlog current.** When a story lands, mark it in `BACKLOG.md` with the
   commit. New decisions get an ADR in `docs/adr/`.
7. **Commit attribution:** no AI co-author trailer on commits; the README carries one
   "built with AI coding assistance" line instead.
8. **Comments say why.** `///` on every public member of the pure-Dart packages (the lint
   enforces it), Effective Dart style: what a member means, its units, who supplies it.
   No "we", no chat tone, no references to conversations. Developer log lines go through
   `logDev` and never carry page content or the person's numbers.
9. **Strings and numbers have one home.** Person-facing chat wording lives in
   `ChatStrings`; a delay, cap or threshold is a named constant with its reason beside it.

## Working style

- The owner is relearning Flutter and wants trade-offs written down. When choosing a
  package or pattern, add two sentences on the alternatives to the relevant doc.
- Prefer small, reviewable commits on `develop`. Branch from `develop` for larger stories.
- Tests before merge: `dart test` in both pure packages; `flutter analyze` and
  `flutter test` in the app. `dart format .` everywhere (page width 100).

## Toolchain

See `docs/SETUP.md`. Flutter is installed at `~/flutter` (3.47); there is no FVM pin.

# Codelabs

The runnable code for the codelabs published at
[flutteredge.ai/codelabs](https://flutteredge.ai/codelabs).

## Layout

```
codelabs/<codelab-id>/step_NN_<name>/   a complete, runnable app
codelabs/<codelab-id>/complete/         the finished app
website/codelabs/<codelab-id>/index.md  the codelab text (claat source)
```

`<codelab-id>` is the same on both sides, and it is the URL the codelab is
published at.

**Steps are directories, not branches.** A learner opens a folder instead of
running `git checkout` in the middle of their own work, the diff between two
steps is a plain `diff -r`, and a fix is one sweep rather than a port across N
branches. It is also how [flutter/codelabs](https://github.com/flutter/codelabs)
is organised.

**A step exists where code changes hands**, not once per heading in the text.
Skipping numbers is fine: the point of a step directory is to give someone a
working app to resume from.

**Almost every step directory is an app.** The exception today is
`function-calling-flutter-gemma/step_04_finetune/`, whose step produces a model
rather than code: it holds the training data and the commands for a
[litetune](https://litetune.dev) run and has no
`pubspec.yaml`, so `tool/check_codelabs.sh` — which discovers apps by their
`pubspec.yaml` — does not see it. A step that ships something other than a
Flutter app belongs in the codelab's own directory all the same; a learner
looking for Step 4 should find it where Steps 3 and 5 are.

## Dependencies

Step apps are **not** members of the repo's pub workspace. They depend on the
*published* packages from pub.dev, exactly like a learner's checkout — so a
release that breaks the teaching material breaks this directory too, which is
the point.

They also do not commit a `pubspec.lock`, for the same reason: the codelab
tells the learner to `flutter pub add`, so the apps must resolve to whatever
that resolves to today. The price is that a PR run is not reproducible — see
the note in `codelabs/.gitignore`.

Because the apps resolve from pub.dev, a `packages/` change cannot affect them
until it is published, which is why the workflow's `paths:` filter does not
watch `packages/`. The flip side is that a release which breaks the teaching
material is caught by the nightly run — up to 24 h *after* it ships, never
before. Run `tool/check_codelabs.sh` by hand after publishing if that matters.

That also means `flutter analyze packages/` never sees them. They have their
own gate:

```bash
tool/check_codelabs.sh     # pub get + analyze + format + test, every step
```

The same script also enforces the cross-codelab invariants declared in its
`MIRRORS` table: a later codelab's starter is an earlier codelab's finished app,
`lib/` and `test/` byte for byte, because both texts tell the learner so. Add a
row there when a new codelab continues an existing one — and only then. A
starter may be its own app instead, and function-calling's is: inheriting a
finished app whose model the next step replaces makes a learner pay for a
download the codelab never uses.

And it checks **application ids**, on Android, iOS, macOS and Linux: every app
inside a codelab declares the same one — that is what lets a later step open the
model an earlier step downloaded — and no two codelabs share one. Three of them
once shipped as `dev.fluttergemma.gemma_quickstart`, which gave them a single
container: one codelab's app opened with another's model already "installed".

CI runs it on push, on pull requests, and **nightly** — a step app can rot
without anyone touching this repo, and the nightly run is what notices.

## Adding a codelab

1. `codelabs/<id>/step_01_.../` … — apps discovered automatically, no list to
   update.
2. `website/codelabs/<id>/index.md` — the text; `id:` in its front matter must
   match the directory.
3. Add the card to `website/lib/codelabs/codelabs_page.dart` and give it an
   `href` once the text is written. Cards without an `href` render as
   "Coming soon" and are deliberately not links.

## Integration tests

Some codelabs carry an `integration_test/` suite that downloads a real model
and runs inference. Those need a device and several hundred MB, so they are
**not** part of the CI gate. Run one by hand:

```bash
cd codelabs/getting-started-flutter-gemma/complete
flutter test integration_test/quickstart_test.dart -d <device-id>

cd codelabs/inference-engines-flutter-gemma/complete
flutter test integration_test/engines_test.dart -d <device-id>

cd codelabs/multimodal-flutter-gemma/complete
flutter test integration_test/multimodal_test.dart -d <device-id>

cd codelabs/function-calling-flutter-gemma/complete
flutter test integration_test/function_calling_test.dart -d <device-id>

cd codelabs/hybrid-ai-flutter-genkit/complete
flutter test integration_test/smoke_test.dart -d <device-id> \
  --dart-define=HF_TOKEN=hf_xxx --dart-define=GEMINI_API_KEY=AIza...

cd codelabs/package-skills-flutter-gemma/complete
flutter test integration_test/skills_test.dart -d <device-id>
```

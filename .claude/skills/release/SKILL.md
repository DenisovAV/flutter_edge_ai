---
name: release
description: Release flutter_edge_ai — bump versions, optionally re-publish native prebuilts (iOS/macOS/Linux/Windows/Android dylibs) to GitHub Release, update SHA256 checksums in hook/build.dart, publish to pub.dev
user_invocable: true
---

# Flutter Edge AI Release

Run as `/release <plugin-version>` (e.g. `/release 0.14.1`).

## ⛔ HARD RULES — these are not advice, and not overridable by your judgment

A checklist advises; these refuse. They exist because the steps below were read
and still skipped — twice in one session (agent 0.2.3 shipped without its README
→ had to publish 0.2.4; the 1.5.9 docs were split into a separate website PR).
When a rule here conflicts with what seems "more sensible right now", the rule
wins. If following one is genuinely impossible, SAY SO out loud and stop — do not
silently do the other thing.

1. **ONE PR: code + `website/` docs + version bumps ship together.** The Step 12
   doc changes (version pins + new/changed-API docs) go on the SAME release
   branch/PR as the code, merged in one go. A **separate website-only PR is
   FORBIDDEN** except (a) the code PR has ALREADY merged before you got to docs
   (a planning failure — do NOT let this become the pattern), or (b) a
   post-merge deploy-failure hotfix, which 12c requires be a new PR since main is
   protected. Case (a) is a failure to note in the
   PR, not the pattern to copy. Author the docs BEFORE the release PR merges.
2. **Docs are part of Done, not a follow-up.** "I'll do the docs later / in a
   follow-up" is the exact failure this skill exists to stop. `README.md`
   (pub.dev-facing) and `website/content/docs/**` are release deliverables. A
   `guard-release-docs.py` hook BLOCKS `dart pub publish` when a package's `lib/`
   changed but neither its README nor website docs did — if it fires, you skipped
   Step 12, not "hit a false positive".
3. **Reproduce this Definition-of-Done in your reply and mark every item**
   (done / N/A + reason) before you publish. Do not publish off memory of the
   skill — walk it as a literal checklist against the actual repo state.
4. **The skills are fixed in the PR that changes the API, not at release time.**
   `packages/flutter_edge_ai/skills/**` ships inside core and is read by other
   people's coding agents, so a stale sentence there becomes confident, broken
   code in someone else's app. On any PR touching `packages/*/lib/**`, a native
   build file (`android/`, `ios/`, `darwin/`, `macos/`, `windows/`, `hook/`), a
   pinned CDN version or a `pubspec.yaml` floor:

   ```bash
   bash tool/skills_review.sh origin/main   # which skills the diff puts in doubt
   dart tool/check_skills.dart              # compiles every block; exit 0 required
   dart run skills_lint@0.5.1               # file-level rules; exit 0 required
   ```

   The two gates also run in CI (`skills` job), so a rename is caught without
   you. What CI cannot catch is a symbol that survives while its MEANING moves —
   `getActiveStt(language:)` went from "the language this recognizer was built
   with" to "the default for its transcriptions" with no rename anywhere. That
   is what reading the flagged skills is for. Step 12d is the release backstop,
   not the first time this happens.

### Definition of Done (paste it; check 1a–8b before Step 10 publish; 10b right after it; 12a/12b/12e belong to the release PR and 12c is verified after merge)

```
[ ] Pre-flight: git clean · analyze 0 err · flutter test green · build web + one native target
[ ] 1a  every package whose lib/ changed is in the publish list (grep, don't guess)
[ ] 1b/c native: dylibs/build-scripts changed? → rebuild + SHA256 + native release, else N/A
[ ] 1b-bis ANY version moved that reaches a device → build-native checks 1–10 done
        on EVERY platform, no exemptions. "Version moved" = a new native-v* tag
        (including -a/-b hotfix tags), PREBUILT_REF / DEFAULT_REF / any upstream
        pin, a native-carrying dependency (qdrant_edge, sqlite3, ORT, MediaPipe),
        or a bumped platform floor. "Only one file changed" is not an exemption:
        the files that did not change also did not get tested.
        #9 NPU result written into its table (device, date, pass count), #10
        matrix (LLM + embeddings + speech, CPU AND GPU) pasted into the PR body,
        one row per device with codename + GPU.
        Android GPU = at least one Adreno AND one Mali (FTL akita / a34x).
[ ] 1b-ter an upstream pin moved → read upstream's open issues filed since that
        tag (`gh issue list --repo google-ai-edge/LiteRT-LM --search "created:>=<tag-date>"`)
        and list in the PR body the ones that touch us by number, or
        "none as of <date>" — plus the tag date the search started from
[ ] 5b  manifest gate RUN and printed "N platform(s) compared" — N == number of tarballs
[ ] 1d-bis  any packages/*/README.md changed since its published version? → that
        package needs a version bump EVEN IF its lib/ did not change; the README
        ships in the archive and is the pub.dev page (`git diff <pkg-last-published>
        HEAD -- 'packages/*/README.md'`)
[ ] 1e  core public API changed? → upgrade-genkit (realign + version), else N/A
[ ] 1f  shared code duplicated across satellites patched everywhere (grep the pattern)
[ ] 1f-bis  tool/check_macos_podfile_snippet.sh passes (every copy of the macOS
        post_install snippet byte-identical — example Podfiles, the codelab step
        apps, README, desktop.md and the inference skill's
        references/platform-setup.md; the script prints the count, do not hardcode
        one here) — RUN it, do not eyeball
[ ] 1g  each changed satellite's flutter_edge_ai: floor >= the core version it now needs
[ ] 2   versions bumped: pubspec + podspec (if any) + AGENTS.md Current-Version line
[ ] 7   CHANGELOG: one short line per package, every published package
[ ] 8   dart pub publish --dry-run → 0 warnings, every package
[ ] 8b  native bundle moved? → litertlm_native_tools_test.dart green on every
        platform in the release (the smoke suite never passes a tool), else N/A
[ ] 10b  after publishing: pub.dev actually SERVES the new versions (its API
        lags minutes behind the upload); if a package's web/ changed
        (flutter_edge_ai_litertlm or flutter_edge_ai), sync every codelab copy to
        the published one first (a PR); then dispatch Codelabs on main
[ ] 12a website + README version pins bumped to the just-published versions
[ ] 12b new/changed public API + behavior documented (README + website)  ← SAME PR
[ ] 12d skills/: `skills_review.sh <last-tag>` run, every flagged skill READ,
        updated where the prose drifted, `dart tool/check_skills.dart` green and
        `dart run skills_lint@0.5.1` green — backstop: rule 4 means the PRs in
        this release already did it
[ ] 12e LiteTune version in authored docs matches the latest PyPI release; if it
        moved, the documented prepare/tune/convert/verify/bundle commands were
        checked against that release before updating the version
[ ] 12c after merge: firebase-hosting-merge run == success (not just triggered)
```

## Architecture context (read this first)

`flutter_edge_ai` inherits the architecture introduced in the legacy
`flutter_gemma` 0.14.0 line: it has **no Kotlin/JVM/gRPC server**. Native libs
come from one of two sources, decided per-platform by `hook/build.dart` (Native
Assets):

1. **Local prebuilts** at `packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<os>_<arch>/` — populated locally by `packages/flutter_edge_ai_litertlm/native/litert_lm/build_*.sh` scripts. **NOT tracked in git** (gitignored since 0.14.3 — keeps clones lean) and **excluded from the pub package** via `.pubignore`. Maintainers regenerate them on demand and upload to a GitHub Release.
2. **GitHub Release `native-v<NATIVE_VERSION>` archives** (e.g. `native-v0.10.2-a`) — the **canonical source for both end users and CI**. URL pattern: `litertlm-<os>_<arch>.tar.gz` flat archive of the matching `prebuilt/` folder. End users fetch from there at `pub get` time via `hook/build.dart`. Maintainers re-fetch from there too if their local `prebuilt/` is missing (`gh release download native-v<X>` then extract — see Step 5).

Whether to bump `native-v<NATIVE_VERSION>` or re-publish the existing tag is the **central decision** of every release.

## Pre-flight

```bash
git status                  # all desired changes staged or already committed
git log --oneline -5
flutter analyze packages/   # 0 errors — NOT the repo root: website/ is outside
                            # the workspace and fails on unresolved deps
tool/test_all.sh            # all pass — NOT `flutter test` at the root, which
                            # has no test/ and silently tests NOTHING

# Cross-platform compile sanity — analyze/test run on host VM and skip
# conditional imports (e.g. `lib/core/ffi/*_stub.dart`). The only thing
# that catches stub/client signature drift is `flutter build <target>`.
# Skipping this is how `enableSpeculativeDecoding` web breakage shipped
# in 0.15.0 — analyze was green, tests passed, web build threw
# `No named parameter ...` at dart2js time.
cd packages/flutter_edge_ai/example
flutter build web --no-tree-shake-icons
# Android MUST be built --release, not --debug: a release build runs R8
# (shrink/minify/obfuscate) and the full native-asset packaging path, which
# debug skips. Bugs that only surface under R8 (stripped classes, missing
# keep rules, native lib packaging) are invisible to `--debug`.
flutter build apk --release
flutter build macos --debug
flutter build ios --no-codesign --debug
cd ../../..   # back to repo root
```

## Step 1: Determine release scope

Three independent dimensions — answer each:

### 1a. Plugin code changed?
```bash
# Pathspecs are repo-root relative, and a DIRECTORY pathspec needs `/**` to
# match what is inside it: `'packages/*/lib'` matches ZERO files, while
# `'packages/*/lib/**'` matches the sources. Both forms exit 0, so the wrong one
# answers "nothing changed" for a release where everything changed — the same
# silent-empty failure as the pre-monorepo form (lib/ hook/ ios/ …), which
# matches nothing here either.
#
# Do NOT read the output and move on. Read the COUNT first: a release with zero
# changed files is a broken command, not a finding.
git diff <last-tag> --name-only -- 'packages/*/lib/**' 'packages/*/hook/**' \
  'packages/*/pubspec.yaml' 'packages/*/android/**' 'packages/*/ios/**' \
  'packages/*/macos/**' 'packages/*/darwin/**' 'packages/*/web/**' \
  | tee /dev/stderr | wc -l
```

**The publish list is derived, not remembered.** Ask git which packages own the
changed `lib/`, and publish exactly those:
```bash
git diff <last-tag> --name-only | grep '/lib/' | cut -d/ -f2 | sort -u
```
If empty for a release, the command is wrong — go back and fix it before
deciding scope.

If yes → bump pub plugin version, publish to pub.dev. Always true for a release.
Then **run 1f** for every satellite whose copy of the touched code is stale — a
fix is not "done" until every duplicate across all 6 packages is patched or
shown N/A.

### 1b. Native dylibs changed (any platform)?
```bash
git diff <last-tag> -- packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/
```
If **any** dylib changed → must re-publish GitHub Release archives **and** update SHA256 checksums in `hook/build.dart`, otherwise end users will keep getting the stale dylibs.

### 1c. patch_c_api.sh / build_*.sh / WORKSPACE patch changed?
This implies (1b) — verify dylibs were actually rebuilt against the new patches. If not, rebuild before continuing (see "Rebuild native dylibs" below).

### 1d. Website (`website/`, flutteredge.ai) — ALWAYS in scope
Every release touches the site. At minimum the package versions hardcoded in its docs must be bumped to the just-published versions (Step 12a) — this is required even for a version-only release. On top of that, any new/changed public API, breaking change, or common pitfall must be documented (Step 12b). Don't defer to "later" — stale docs outlive the release.

### 1d-bis. `README.md` ships in the archive — a docs-only fix there needs its own version bump

Step 1a scopes "did the package change" to `lib/ hook/ pubspec.yaml ios/ android/ web/`, and 1d/12 scope "docs" to `website/`. **`packages/*/README.md` is in neither**, and it is the one doc that gets frozen into the published tarball and rendered as the pub.dev landing page. Fixing it on the branch changes nothing for users until a version is published.

> **What this rule prevents (core 1.5.8):** 1.5.7 shipped with a README telling Windows users their discrete GPU crashes and to fall back to CPU/NPU — published the same day the release that fixed it was being prepared. The website was corrected, `DESKTOP_SUPPORT.md` was corrected, and both reach users immediately via GitHub. The README needed 1.5.8.

Two consequences:

1. **Grep the WHOLE repo for any claim you are correcting, not just `website/`.** Same sentence, several homes, different delivery channels:
   ```bash
   grep -rniE "<the claim you are fixing>" --include='*.md' packages/ website/ | grep -v '/build/'
   ```
   A single stale statement in this repo lived in eight places: the litertlm README, the core README twice, `DESKTOP_SUPPORT.md` three times, and two site pages.
2. **Know which docs actually ship** before deciding whether a bump is needed — the answer differs per package:
   ```bash
   cd packages/<pkg> && dart pub publish --dry-run 2>&1 | grep -E "^├── .*\.md"
   ```
   In `flutter_edge_ai` only `README.md` and `CHANGELOG.md` ship; `DESKTOP_SUPPORT.md`, `MIGRATION.md` and `CONTRIBUTING.md` are GitHub-only and need no publish.

### 1e. Did the core public API change? → realign the Genkit packages
```bash
git diff <last-tag> -- packages/flutter_edge_ai/lib/flutter_edge_ai_interface.dart packages/flutter_edge_ai/lib/core
```
If the public `InferenceModel` / `InferenceChat` / `EmbeddingModel` / `Message` / `ModelResponse` / enum surface changed, the Genkit integration packages (`genkit_flutter_edge_ai`, `genkit_hybrid`) likely no longer compile or are missing the new features. **Run the `upgrade-genkit` skill** before publishing — it realigns converters + the test fakes (which must match upstream signatures) and bumps those packages. They release in lockstep with the monorepo, so don't ship a core change that leaves them broken.

### 1f. Did a fix touch shared code duplicated across satellites? → propagate it to ALL packages
The monorepo split means the SAME logic is often copy-pasted into multiple
packages' `android/build.gradle`, `hook/build.dart`, iOS podspecs, or FFI stubs.
A core-only fix that leaves a copy stale ships a **HALF-fix** — and because each
satellite publishes independently, the stale copy reaches users under its own
version number.

> **Regression #360 (what this rule prevents):** the AGP-9 Kotlin guard
> `if (agpMajor < 9)` was fixed in `flutter_edge_ai/android/build.gradle`, but the
> byte-identical guard in `flutter_edge_ai_mediapipe/android/build.gradle` was
> missed. mediapipe `1.0.3` shipped to pub.dev still broken, so every `.task`
> user on AGP 9 kept hitting the crash the core fix was supposed to close.
> (#440 later deleted the guard entirely — the plugins no longer apply KGP at
> all. The duplication lesson stands; the pattern to grep has changed.)

**Before finalizing, grep the pattern you changed across ALL packages** and
confirm every copy is patched (or provably N/A):
```bash
grep -rn "<the exact pattern you changed>" packages/
# e.g. for the #360 guard:
grep -rnE "^\s*(apply plugin: .kotlin-android|ext\.kotlin_version|classpath .*kotlin-gradle-plugin)" \
  packages/*/android/build.gradle   # post-#440 this must return NOTHING
```
Shared-code hotspots to sweep, per fix type:
- **Android Gradle** — `packages/*/android/build.gradle`. THREE packages have
  one: `flutter_edge_ai`, `flutter_edge_ai_mediapipe`, `flutter_edge_ai_builtin_ai`.
  Sweep `compileSdk`, `minSdkVersion`, the AGP classpath, and the
  `kotlin { compilerOptions { jvmTarget } }` block — which must stay
  byte-identical across all three (#360, #440).
- **Native hook** — `packages/flutter_edge_ai_litertlm/hook/build.dart` (the only
  hook that owns the LiteRT-LM bundle — `flutter_edge_ai_onnx` owns the ORT one and
  `flutter_edge_ai_sqlite` the sqlite-vec one): the `_litertlmBundle` `version:` and `checksums:`
  fields, `_cacheBaseDir()` cache-busting, `stage()` Apple-only guard.
- **Apple manifests** — `find packages -name '*.podspec' -not -path '*/example/*'`
  finds all THREE (core ios, core macos, mediapipe ios — builtin_ai has none
  since it moved onto flutter_local_ai); the `packages/*/ios/*.podspec` glob
  silently misses `macos/`. Sweep `s.version`, min-iOS/osx, dep pins, `vtool`
  minos on any bundled dylib — and the two `Package.swift` (core ios, core
  macos), whose platform floors must match their podspec.
- **macOS `post_install` snippet** — the SAME block lives in every
  `packages/*/example/macos/Podfile` and every codelab step app's, plus the core
  `README.md` (the pub.dev page users copy from), `website/content/docs/desktop.md`
  and the inference skill's `references/platform-setup.md`. The script counts
  them; do not diff them by eye:
  ```bash
  tool/check_macos_podfile_snippet.sh   # exits 1 and names the odd copy
  ```
  Why this one bites harder than the others: `pod install` freezes the block
  into every app's `project.pbxproj`, and upgrading `flutter_edge_ai_litertlm`
  does NOT re-run `pod install` (the package declares no macOS plugin, so
  Flutter's tracked plugin set never changes). A fix landed in one copy never
  reaches users who pasted another. When the check was added the copies had
  already split into three vintages — the genkit example predated all of the
  #300/#368 fixes, and the README copy was missing `input_paths`, so every app
  built from it carried the #368 incremental-build bug. Keep the block a thin
  shim that only locates and runs
  `flutter_edge_ai_litertlm/tool/stage_macos_companions.sh`: logic that lives in
  the snippet cannot be fixed by publishing a package (#457).
- **FFI / web stubs** — `lib/**/*_stub.dart`: conditional-import signatures that
  `analyze`/`test` can't catch (web stub drift).

Every affected satellite gets its **own** version bump + CHANGELOG entry +
publish. **This makes it a MULTI-package release** — before touching any
version, list every package you will publish (e.g. "publishing
`flutter_edge_ai` NEXT_CORE_VERSION AND `flutter_edge_ai_mediapipe`
NEXT_MEDIAPIPE_VERSION"), and run the whole of Steps 2/8/9/10 for each one.

### 1g. Did a satellite start CALLING a newer core API than its `flutter_edge_ai:` floor allows? → bump the floor

Each satellite (agent / speech / litertlm / mediapipe / embeddings / rag / onnx / builtin_ai)
declares a `flutter_edge_ai: ^X.Y.Z` constraint. In the pub **workspace** the local
core is always used, so `flutter analyze` / `flutter test` **and
`dart pub publish --dry-run` all pass with a too-low floor** — everything builds
green locally and dry-run only checks the constraint is *satisfiable*, never that
the code needs a *higher* one. A pub.dev consumer who pins an older core alongside
the new satellite then gets a resolve that **fails to compile** (calls a
method/param that core version lacks). This is a manual step; nothing automated
catches it.

**A floor naming an UNPUBLISHED core forces a publish ORDER — and dry-run is blind
to it.** `dart pub publish --dry-run` only checks that a constraint is satisfiable in
the workspace, never that the named version exists on pub.dev, so it reports 0
warnings even when the floor names the next, still-unpublished core. Publish
the satellite first and consumers silently backtrack to its previous version —
no error, just none of the fix. So: **publish core FIRST, then every satellite
whose floor names it**, and check before publishing any satellite:

```bash
# does the floor this satellite names actually exist on pub.dev yet?
grep -m1 "flutter_edge_ai:" packages/<satellite>/pubspec.yaml
curl -s https://pub.dev/api/packages/flutter_edge_ai | \
  python3 -c 'import sys,json; print(json.load(sys.stdin)["latest"]["version"])'
```

> **Case (builtin_ai 0.1.1, #441):** it declares an iOS 15.0 floor, but both CocoaPods
> and SwiftPM reject an app target below ANY dependency's floor — so with core ≤1.6.3
> (still 16.0) that 15.0 is unreachable. Raising the constraint to `^1.6.4` is correct
> and makes core 1.6.4 a hard publish prerequisite.

> **Legacy regression this prevents (`flutter_gemma_agent` 0.2.2):** `AgentLoop` was rewritten to call
> `generateChatResponseWithTools(onMaxToolTurns:)` — `onMaxToolTurns` landed in
> core `1.5.5` — but the satellite still declared `flutter_gemma: ^1.2.0`. A
> fresh install resolves core to latest (fine), but a consumer on
> `flutter_gemma: 1.4.0` + `flutter_gemma_agent: 0.2.2` resolves happily then
> throws `No named parameter 'onMaxToolTurns'` at build time.

**For every satellite whose own Dart code changed, bump its `flutter_edge_ai:`
floor to the core version that introduced the newest core symbol it now uses:**
```bash
git diff <last-tag> -- packages/<satellite>/lib   # what core symbols did it start using?
grep -n 'flutter_edge_ai: \^' packages/<satellite>/pubspec.yaml
```

## Step 2: Bump versions

Always:
| File | Field | Note |
|------|-------|------|
| `pubspec.yaml` | `version:` | the plugin version (e.g. `0.14.1`) |
| podspecs — **all three**, they drift independently | `s.version` | match the owning package's version. `packages/flutter_edge_ai/ios/flutter_edge_ai.podspec`, `packages/flutter_edge_ai/macos/flutter_edge_ai.podspec`, `packages/flutter_edge_ai_mediapipe/ios/flutter_edge_ai_mediapipe.podspec`. Verify with the loop below rather than by eye — core's iOS and macOS podspecs were four and five releases behind when this was last checked. |

```bash
for ps in packages/*/{ios,macos,darwin}/*.podspec; do
  [ -f "$ps" ] || continue
  pkg=$(echo "$ps" | cut -d/ -f2)
  want=$(grep -m1 '^version:' "packages/$pkg/pubspec.yaml" | awk '{print $2}')
  got=$(grep -m1 "s.version" "$ps" | sed "s/.*'\(.*\)'.*/\1/")
  [ "$want" = "$got" ] && s=OK || s="DRIFT (pubspec $want)"
  printf '  %-64s %-8s %s\n' "$ps" "$got" "$s"
done
```
| `AGENTS.md` | `Current Version:` line | match plugin version |

Only if (1b) bumps `NATIVE_VERSION`:
| File | Field |
|------|-------|
| `packages/flutter_edge_ai_litertlm/hook/build.dart` | the `version:` field of `_litertlmBundle` (a `_NativeBundle`) — bump (e.g. `'0.16.0'` → `'0.16.1'`). There is **no** `_nativeVersion` identifier; grep for `version:` inside `const _litertlmBundle`. The cache dir helper is `_cacheBaseDir()`. |

For App Store / breaking platform fixes prefer **bumping NATIVE_VERSION** rather than overwriting `native-v0.10.2` assets — keeps consumers on `0.14.0` reproducible. Overwrite only for emergency hotfixes where downstream version pinning is acceptable.

## Step 3: Rebuild native dylibs (if needed)

Per-platform rebuild scripts. `bazelisk clean --expunge` between rebuilds **only if** `patch_c_api.sh` / `WORKSPACE` patch changed (forces patch_cmds re-run on a fresh extraction). Otherwise incremental.

```bash
# Always pass the pinned tag SHA explicitly. Every script has a DEFAULT_REF and
# every DEFAULT_REF lags the release you are migrating to — build_ios.sh still
# defaulted to a v0.14.0-era commit during the v0.15.0 migration. Get the SHA
# with: gh api repos/google-ai-edge/LiteRT-LM/git/ref/tags/<tag> --jq '.object.sha'
SHA=<pinned tag SHA>
N=packages/flutter_edge_ai_litertlm/native/litert_lm

# macOS arm64
"$N/build_macos.sh" "$SHA"
# iOS device + simulator
"$N/build_ios.sh" "$SHA"
# Android arm64 (cross-compile from macOS) — needs NDK r29
"$N/build_android.sh" "$SHA"
# Android Qualcomm NPU dispatch (separate target, from the LiteRT repo)
"$N/build_qualcomm_dispatch.sh" "$SHA"
# Linux x86_64 — on a Linux VM (use GCloud per project_gcloud_vm_workflow memory)
# Windows x86_64 — on a Windows VM (same)
```

Verify each rebuilt dylib:
```bash
nm -gU prebuilt/<os>_<arch>/libLiteRtLm.dylib | grep litert_lm_engine_create  # must export
otool -D prebuilt/<os>_<arch>/libLiteRtLm.dylib                              # @rpath/libLiteRtLm.dylib
```

If patches changed — also verify patch markers are baked into the binary, e.g.:
```bash
strings prebuilt/ios_arm64/libLiteRtLm.dylib | grep '@executable_path'
```

## Step 4: Pack tar.gz archives

Each archive is a flat tar of the matching `prebuilt/` directory. Naming: `litertlm-<os>_<arch>.tar.gz`.

```bash
PREBUILT=packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt
DIST=$(mktemp -d)
# All SEVEN platforms the hook has checksums for. linux_arm64 was missing from
# this list for six native releases: the loop silently skipped it (`if -d`
# guards a directory that is there), the Step-5 glob then inherited the gap
# into checksums_litertlm.txt, and the result is a release that is internally
# consistent and still unbuildable on that platform.
PLATFORMS="macos_arm64 ios_arm64 ios_sim_arm64 android_arm64 linux_x86_64 linux_arm64 windows_x86_64"
for d in $PLATFORMS; do
  if [ -d "$PREBUILT/$d" ]; then
    (cd "$PREBUILT/$d" && tar -czf "$DIST/litertlm-$d.tar.gz" .)
    echo "  $d: $(ls -la "$DIST/litertlm-$d.tar.gz" | awk '{print $5}') bytes"
  else
    echo "  $d: NO prebuilt dir — will not be in this release"
  fi
done
```

Only archive platforms whose dylibs actually changed since the previous release. Untouched platforms keep their existing release assets — but if you are cutting a **new** `native-v*` tag, every platform must be present, because the hook verifies against its own `checksums` map regardless of which ones you touched. Assert it rather than eyeballing the loop's output:

```bash
# Count what you packed against what the hook demands.
want=$(grep -cE "'litertlm-[a-z0-9_]+\.tar\.gz'" packages/flutter_edge_ai_litertlm/hook/build.dart)
got=$(ls "$DIST"/litertlm-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
[ "$got" -eq "$want" ] || { echo "packed $got, hook expects $want"; exit 1; }
```

## Step 5: Compute SHA256 + update hook/build.dart

```bash
for f in "$DIST"/litertlm-*.tar.gz; do
  printf "  '%s':\n      '%s',\n" "$(basename "$f")" "$(shasum -a 256 "$f" | awk '{print $1}')"
done
```

Paste each `<filename>: <sha256>` into the matching entry in `hook/build.dart` `_checksums` map. **Update only the platforms whose dylibs you actually rebuilt** — leave the others.

Also regenerate `checksums_litertlm.txt` for the GitHub Release page (single text file with `sha256  filename` lines):
```bash
(cd "$DIST" && shasum -a 256 litertlm-*.tar.gz > checksums_litertlm.txt)
```

## Step 5b: ⛔ Run the manifest gate BEFORE uploading anything

The archives now exist and nothing is published yet — this is the only moment
the gate can still save you. It diffs each new tarball's file list against the
same archive in the previous tag and fails on any file that disappeared.

```bash
packages/flutter_edge_ai_litertlm/native/litert_lm/verify_tarball_manifest.sh \
  "$DIST" native-v<PREVIOUS>     # e.g. native-v0.14.0
```

**Read the last line, not the exit code alone.** A pass now states how many
platforms it compared:

```
✅ MANIFEST CHECK PASSED — 7 platform(s) compared against native-v0.14.0, no unexplained file drops.
```

If that number is lower than the number of tarballs you packed, the gate did
not examine the rest — treat it as a failure and find out why. `exit 2` means
it could not read the tag at all (bad auth, wrong tag name); it deliberately
refuses to report a pass in that case, because a check that compared nothing
is indistinguishable from a check that found nothing wrong.

> This gate was written in 1.0.1 (`ba614096`) as the answer to native-v0.13.1
> shipping without the Qualcomm/QNN and Intel OpenVino stacks — and then no
> release step ever called it, so it sat unused through native-v0.16.0. That is
> why it is a numbered step with a checklist line rather than a suggestion.

## Step 6: Update GitHub Release assets

### ⛔ NEVER overwrite a tag referenced by a published plugin version

`gh release upload --clobber` on an existing `native-v*` / `qdrant-edge-v*`
tag silently breaks every end user already on a plugin version whose
`hook/build.dart` references that tag. The published SHA256 (in their
`pubspec.lock`-pinned plugin code) no longer matches the bytes GitHub
serves, the hook deletes the archive and returns null, the build
succeeds with a missing CodeAsset, and the app crashes at runtime on
first `dlopen()`.

This is unrecoverable. `tar -czf` is not deterministic across runs
(mtime, file ordering, gzip block boundaries differ), so even with
every original dylib byte you cannot reproduce the original tar SHA256.

**Always publish a new tag instead** — `native-v0.10.3`, not
`native-v0.10.2` reuploaded. The cost of a new tag is zero; the cost
of breaking a shipped plugin version is real users with runtime
crashes who cannot upgrade until the next release cycle.

See `feedback_never_reupload_released_tarballs.md` for the full
incident write-up.

### Always: new tag (`native-v0.10.3`)
Old `native-v0.10.2` keeps working for old plugin versions. Need
GitHub Release notes describing what changed.
```bash
RELEASE=native-v0.10.3
gh release create "$RELEASE" "$DIST"/litertlm-*.tar.gz "$DIST"/checksums_litertlm.txt \
  --title "Native dylibs $RELEASE" \
  --notes-file release-notes-native.md \
  --target main
```

Verify each URL returns HTTP 200 + sha256 matches:
```bash
for f in "$DIST"/litertlm-*.tar.gz; do
  name=$(basename "$f")
  url="https://github.com/DenisovAV/flutter_edge_ai/releases/download/$RELEASE/$name"
  curl -sI "$url" | head -1
  curl -sL "$url" | shasum -a 256 | awk '{print "  "$1"  '"$name"'"}'
done
```

### ⛔ Three-way checksum consistency — MANDATORY (regression: #316)

`checksums_litertlm.txt` is informational (the build hook does NOT read it —
it verifies against the `_checksums` map baked into
`packages/flutter_edge_ai_litertlm/hook/build.dart`). But a STALE txt is
dangerous: in #316 a user (`@remingtonc`) hand-verified against the txt during a
checksum-mismatch debug, the txt said `e24804d9…` while the actual asset was
`f809c5a2…`, and it sent them down the wrong path. **For every tag you touch,
the same SHA must appear in all THREE places** — the uploaded `.tar.gz`,
`checksums_litertlm.txt` on the Release, and the hook's `_checksums` entry.
Verify after upload:

```bash
HOOK=packages/flutter_edge_ai_litertlm/hook/build.dart
for f in "$DIST"/litertlm-*.tar.gz; do
  name=$(basename "$f")
  # 1. actual asset bytes served by GitHub
  asset=$(curl -sL "https://github.com/DenisovAV/flutter_edge_ai/releases/download/$RELEASE/$name" | shasum -a 256 | awk '{print $1}')
  # 2. what checksums_litertlm.txt on the Release claims
  txt=$(curl -sL "https://github.com/DenisovAV/flutter_edge_ai/releases/download/$RELEASE/checksums_litertlm.txt" | awk -v n="$name" '$2==n{print $1}')
  # 3. what the hook expects
  hook=$(grep -A1 "'$name'" "$HOOK" | grep -oE "[0-9a-f]{64}" | head -1)
  echo "$name:"
  echo "  asset=$asset"
  echo "  txt  =$txt   $([ "$asset" = "$txt" ] && echo OK || echo '❌ STALE TXT')"
  echo "  hook =$hook   $([ "$asset" = "$hook" ] && echo OK || echo '❌ HOOK MISMATCH — users will fail to build')"
done
```
All three must match for every platform you re-uploaded. If you re-uploaded a
`.tar.gz` you MUST also re-upload a fresh `checksums_litertlm.txt` in the same
`gh release upload --clobber` — never one without the other. (#316 is what a
stale released tag looks like in the wild — see the ⛔ "NEVER overwrite a tag
referenced by a published plugin version" rule above.)

## Step 7: Update CHANGELOG.md

Add new section at top. Categories: **App Store / packaging fixes**, **Features**, **Bug fixes**, **Breaking changes**, **Native runtime updates** (if the bundle `version:` bumped). Reference issue / PR numbers (`#245`, `#239`).

### Style: terse, one line per item, mirror 0.13.x pattern

The user has rejected verbose CHANGELOG entries multiple times. Write each
bullet as **one short sentence** describing what was fixed and the
issue/PR reference. Do NOT explain root cause, history, build details,
or include workaround code blocks — that lives in commit messages and
issue threads, not in CHANGELOG.

Bad (rejected):
```
- **Fix Apple companion dylib min iOS** (#245): `libGemmaModelConstraintProvider.dylib`
  was built upstream with `minos 26.2`, causing App Store Connect to reject any
  app whose `Info.plist` minimum iOS is below 26.2. Patched to `minos 14.0` post-
  download (other companion dylibs already on 14.0/16.0). Filed upstream;
  permanent fix needs Google rebuild.
```

Good (matches 0.13.x):
```
- **Fix App Store ITMS-90208 rejection on iOS** (#245): downgraded patched
  `libGemmaModelConstraintProvider.dylib` minos 26.2 → 14.0 to match other
  companion dylibs.
```

Rule of thumb: each entry ≤ 2 lines wrapped at 100 cols. If you need more
to explain it, that's a sign it should be split into multiple entries
or moved to a separate doc.

## Step 8: Verify

```bash
flutter analyze packages/   # not the repo root — see Pre-flight
tool/test_all.sh            # not `flutter test` at the root — it tests nothing
# Cross-platform compile sanity (also in Pre-flight — rerun here after
# version bumps in case a setter/getter signature shifted):
(cd packages/flutter_edge_ai/example && flutter build web --no-tree-shake-icons)
(cd packages/flutter_edge_ai/example && flutter build apk --release)   # --release, not --debug: exercises R8 + native packaging
(cd packages/flutter_edge_ai/example && flutter build macos --debug)
(cd packages/flutter_edge_ai/example && flutter build ios --no-codesign --debug)
dart pub publish --dry-run     # 0 warnings (package size is informational — the
                               # FFI bindings + pigeon + example already push it
                               # to ~700 KB on 0.16.x; the old <=100 KB ceiling
                               # predates 0.14.0 and no longer applies)
```

**NEVER publish without dry-run first.** Publishing is IRREVERSIBLE.

### 8b. One tool call on a device — required whenever the native bundle moved

```bash
cd packages/flutter_edge_ai/example
flutter test integration_test/litertlm_native_tools_test.dart -d macos   # and every other platform in the release
```

Host tests cannot see this, and neither can the litertlm smoke suite: it never
passes a tool, so it never loads `libGemmaModelConstraintProvider`. A mismatch
between that Google prebuilt and the runtime we build segfaults on the first
tool call — `CompositeLogitMask::Apply`, no Dart error, every other gate green.
native-v0.17.0 shipped that way and broke tool calling for everyone on
litertlm 1.7.0.

The suite asserts the text that follows the tool result, not just that a call
was parsed. The weaker assertion is why a second bug — tool results sent as role
`user`, so the model answered by calling again — survived for months.

## Step 9: Commit + tag + push

```bash
git add <changed files>
git commit -m "0.14.1: <one-line summary>" \
           --author="Sasha Denisov <denisov.shureg@gmail.com>"
# No "Co-Authored-By: Claude" / no AI attribution

git tag v0.14.1
git push origin <branch> --tags
```

## Step 10: pub.dev publish

### ⛔ ALWAYS publish from `main`, and `main` MUST be up to date — no exceptions

Publishing happens **from the `main` branch only**, never from a feature/release
branch. After a PR merges, GitHub auto-deletes its head branch, so a
`dart pub publish` still sitting on that branch is publishing code from a ref
that no longer exists on origin — the **`guard-publish.py` hook blocks this**
(`refusing to publish source that is not on the remote … branch does not exist
on origin`). This is not a bug to work around; it is the guard doing its job.

The fix is always the same — get onto an up-to-date `main` first (Rule 2 says the
user owns git, but switching to `main` for a release is an explicit, expected
release action — do it, don't ask):

```bash
git switch main
git pull --ff-only origin main        # main MUST equal origin/main
# verify the release landed on main before publishing:
git rev-parse --short HEAD            # == origin/main
git show HEAD:packages/<name>/pubspec.yaml | grep '^version:'   # the version you're publishing
git status --short                    # clean tree
```

Only once `HEAD == origin/main`, the version on `main` is the one you intend to
publish, and the tree is clean, proceed:

```bash
# Run from the package dir so the guard-release-docs hook can resolve which
# package is publishing (bare `dart pub publish` with the cwd already in the
# package works too — the hook reads the payload cwd — but the explicit `cd` is
# unambiguous):
cd packages/<name>
dart pub publish --dry-run    # verify once more (expect 0 warnings on a clean main)
dart pub publish --force      # only after user approval; --force is non-interactive
```

## Step 10b: Run the Codelabs workflow — after the publish, not before

The codelab step apps depend on **published** packages — a hosted constraint
such as `flutter_edge_ai: ^1.11.4`, never a `path:` sibling — so their check
validates the world users install from rather than this repo's tree. (Floors
differ per codelab: at 1.8.4 twenty step apps pinned `^1.8.3` and four `^1.8.4`,
so "the codelabs" are never all on the version you just published.) Two things
follow, and both bit this release:

1. **It is legitimately red between the release merge and the publish.** The
   floors on the branch name versions that do not exist on pub.dev yet, so
   `pub get` fails with `… which doesn't match any versions, version solving
   failed`. That is a correct report, not a defect — do not "fix" it, and do not
   merge a lower floor to make it green.
2. **Nothing re-runs it for you.** Whatever run the release merge produces
   measures the PRE-publish world, and no later event re-measures it. Either the
   merge touched `codelabs/**` (or `tool/**`, or the workflow file) and you get
   one red run from before the packages existed — 1.8.4's merge touched 555
   files under `codelabs/` and did exactly that — or it touched none of them and
   the push filter yields no run whatsoever, as the two follow-up merges in that
   same release did. The nightly `cron: '0 3 * * *'` is what would eventually
   catch it, which is too late to be part of the release.

**If a package's `web/` changed in this release, sync the codelab copies first.**
Codelab step apps carry their own copies of two bundles — the four LiteRT files
from `flutter_edge_ai_litertlm/web/` (in every app with `web/litert_embeddings.js`)
and `cache_api.js`/`opfs_helper.js` from `flutter_edge_ai/web/` (in every app with
`web/cache_api.js`) — and the Codelabs check compares them with the version each
app resolves from pub.dev. Until the publish they must match the OLD bundle;
after it, the new one (for any release their `^` constraint admits). Copy from
the published package, not from the repo, and copy every file the package
ships, so a file the bundle added is not left out:

```
dart pub cache add flutter_edge_ai_litertlm --version <X>
P=~/.pub-cache/hosted/pub.dev/flutter_edge_ai_litertlm-<X>/web
for app in codelabs/*/*/web/litert_embeddings.js; do cp "$P"/*.js "$(dirname "$app")/"; done
```

(the same with `flutter_edge_ai` and `web/cache_api.js` if core's `web/` moved),
then land it as a PR before dispatching. `tool/check_codelab_web_copies.sh`
lists on the release PR — in CI's step summary — which copies will need it.
1.8.4 skipped this, and the post-release dispatch went red; fixed in #562.

So run it by hand once the new versions are actually being served. Uploaded is
not served: pub.dev answers a successful publish with *"it may take up-to 10
minutes before the new version is available"*, and a run started a minute after
the upload fails again on the same constraint — the resolver has not seen it
yet.

```bash
# 1. is the version SERVED, not merely uploaded? Parse the version list rather
#    than grepping the body: `grep -c` counts LINES (the string also appears
#    under `latest`), and `curl -s` without -f pipes an HTTP error body into it.
curl -sf https://pub.dev/api/packages/<pkg> \
  | python3 -c "import sys,json;print('<X.Y.Z>' in {v['version'] for v in json.load(sys.stdin)['versions']})"
# 2. only then DISPATCH a run against main as it stands now
gh workflow run codelabs.yml --ref main
# 3. find THAT run — --branch alone also matches the push and schedule runs
gh run list --workflow codelabs.yml --branch main --event workflow_dispatch \
  --limit 1 --json databaseId,headSha,status --jq '.[0]'
```

Two readings to get right: an empty result from (3) means the run has not been
registered yet — it appears a few seconds after the dispatch — not that the
dispatch failed. And a traceback from (1) means the fetch failed (`curl -f`
passed nothing on), not that the version is missing; a missing version prints
`False`.

**Dispatch, do not re-run.** `gh run rerun` replays the tree of the commit that
run was created from — and by the point above, that commit is NOT the release:
the last Codelabs run is whatever last touched `codelabs/**`, often several
merges back. A `workflow_dispatch` on `--ref main` is the only form that tests
what main holds now. Re-running the old run is right only when you deliberately
want that older tree re-measured against the new pub.dev state.

Filter the lookup, do not take the top row: unfiltered, `gh run list`
interleaves `pull_request` runs from every open branch — during the 1.8.4
release four of the five newest rows belonged to one feature branch's PR, and
acting on that row measures nothing and confuses its author.

Its concurrency group keys on the event, so a dispatched run cannot cancel the
nightly `schedule` one either.

## Step 11: Optional — GitHub plugin release

The `.github/workflows/release.yml` triggers on `v*.*.*` tag push and creates a GitHub Release with the example APK. Push the tag to fire it (already done in Step 9). Verify:
```bash
gh run list --workflow release.yml --limit 3
gh release view v0.14.1
```

## Step 12: Reflect the release on the website (flutteredge.ai)

**MANDATORY ON EVERY RELEASE.** The docs site lives in this repo at `website/` (Jaspr static site → Firebase Hosting). Stale docs are a support-burden multiplier — every doc that still shows the old version or omits a new API generates issues.

### 12a. ALWAYS bump the package versions shown on the site (even for a pure version-only release)

The site hardcodes `^X.Y.Z` in pubspec snippets across the docs — these MUST match the versions you just published, or new users copy-paste outdated deps. This is required **every single release**, regardless of whether code changed. Find every stale reference:
```bash
cd website
grep -rnE "flutter_edge_ai[a-z_]*: *\^?[0-9]+\.[0-9]+\.[0-9]+" content/
```
Update each `^X.Y.Z` for EVERY package the site pins — `flutter_edge_ai`, `flutter_edge_ai_litertlm`, `flutter_edge_ai_mediapipe`, `flutter_edge_ai_embeddings`, `flutter_edge_ai_qdrant`, `flutter_edge_ai_sqlite`, `flutter_edge_ai_speech`, `flutter_edge_ai_agent`, `flutter_edge_ai_onnx`, `flutter_edge_ai_builtin_ai`, `flutter_edge_ai_diagnostics` — AND the Genkit integration packages (`genkit_flutter_edge_ai`, `genkit_hybrid`) to the just-published versions. Common spots: `installation.md`, `getting-started.md`, `migration.md`, `packages.md`, `genkit.md`. Cross-check against pub.dev so the site never lags the published packages.

### 12b. Update docs for any behavior/API change
- **New / changed public API** → the topic doc that covers it (e.g. a new `createSession` param → `getting-started.md`; multimodal → `multimodal.md`; models → `models.md`).
- **Breaking changes / migrations** → `migration.md`.
- **A bug class users hit** → `troubleshooting.md` (e.g. the #318 `maxTokens` vs `maxOutputTokens` confusion belongs here).

### 12d. Update the shipped agent skills — they are read by a MACHINE

`packages/flutter_edge_ai/skills/` holds eight `SKILL.md` files that ship inside
the core archive and are installed into users' coding agents by
`dart run skills@ get --all`. They are not a nice-to-have copy of the docs: an agent
follows them literally when writing code against this package.

That makes stale skills worse than stale docs. A human reading an outdated
README notices the mismatch; an agent does not — it writes confident, wrong code
against an API that moved, and the user blames the package.

**If this release changed public API or behaviour, the skills change with it.**
Map the change to the skill that covers it:

| Area | Skill |
|------|-------|
| registry, install, `ModelFileType`, `maxTokens`, sessions, chat, the `.litertlm` engine, backends, platform setup | `flutter-edge-ai-inference` (+ `references/platform-setup.md`) |
| function calling | `flutter-edge-ai-function-calling` |
| `.task`/`.bin`, MediaPipe web | `flutter-edge-ai-mediapipe` |
| ONNX / ORT-GenAI | `flutter-edge-ai-onnx` |
| the OS built-in model | `flutter-edge-ai-builtin-ai` |
| STT, TTS, `VoiceSession` | `flutter-edge-ai-speech` |
| embeddings, vector stores | `flutter-edge-ai-rag` |
| `MemorySnapshot`, memory diagnostics | `flutter-edge-ai-diagnostics` |

**Do not go looking by hand.** Ask the diff which skills it puts in doubt:

```bash
bash tool/skills_review.sh <last-tag>      # e.g. v1.8.0
```

For each skill it prints the symbols that skill NAMES and this release TOUCHED.
Run against the STT release it names `flutter-edge-ai-speech` with
`getActiveStt`, `language`, `SttModelType.whisper`; against the
`createChat`-tools fix it names the function-calling skill and leaves speech
alone.
That is the routing — a skill with hits gets opened, a skill without one gets
skipped with a clear conscience.

**Then open every flagged skill and read it against the change.** This is the
step, not the script. The script cannot tell whether the prose is still true;
it only says where to look.

Finally the mechanical gate:

```bash
dart tool/check_skills.dart   # exit 0 required
```

It COMPILES the skills: every ```dart fence becomes a function body, every
inline `Type` and `Type.member` in the prose becomes a declaration, and
`dart analyze` runs over the result inside the example app, which depends on
every package. A misspelt parameter, a method that moved, a switch that is no
longer exhaustive — all fail. Read the count it prints, not just the exit code:
a run that extracted nothing exits 2 rather than reporting a pass.

It replaced a grep-based check that was green on four APIs that did not exist —
`gemma3` matched a model URL, `limit:` an unrelated argument. A text search
cannot tell "this name exists" from "this code is right".

And the file-level check, Google's linter for the Agent Skills format:

```bash
dart run skills_lint@0.5.1     # exit 0 required; config in skills_lint.yaml
```

It checks what compilation cannot: frontmatter keys the spec allows (these
skills install into eight different agents, and the reference validator rejects
anything outside its allowlist), a `name` that matches its directory, the
1024-character description budget, and every relative link resolving — that last
one is off upstream by default and an error here, so a renamed
`references/platform-setup.md` fails instead of handing an agent a dead pointer.

Both run in CI as the `skills` job (`.github/workflows/test.yml`), so a PR that
breaks either is red before it reaches this checklist.

**Why both.** `check_skills.dart` answers "does this code still compile" —
renames, deletions, signature changes. It stays green when a symbol survives and its MEANING moves,
which is the failure that actually happened here: `getActiveStt(language:)` went
from "the language this recognizer was built with" to "the default for its
transcriptions" with no rename anywhere. `skills_review.sh` is what puts that
change in front of your eyes; only reading closes it.

Skills live only in `flutter_edge_ai`, so a fix to any of them is one publish of
core. That is why they are all there rather than in the packages they describe.

### 12e. Verify the documented LiteTune version

The fine-tuning codelab pins a LiteTune version in prose, while `pip install
litetune` resolves from PyPI. Check PyPI on every release so the instructions do
not silently remain on an obsolete CLI:

```bash
LITETUNE_LATEST=$(curl -fsSL https://pypi.org/pypi/litetune/json | \
  python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["version"])')
printf 'PyPI LiteTune: %s\n' "$LITETUNE_LATEST"
grep -rnEi 'litetune +v?[0-9]+\.[0-9]+\.[0-9]+' \
  codelabs website packages --include='*.md' --exclude-dir=build
```

Every current-version claim must equal `$LITETUNE_LATEST`; historical release
notes may retain the version they describe. If the PyPI version moved, do not
only replace the number: verify the documented `prepare`, `tune`, `convert`,
`verify`, and `bundle` commands and their options against that exact release.
Use [litetune.dev](https://litetune.dev) as the primary user-facing link; the
GitHub repository may be a secondary source link.

### 12c. Deploy — it's automatic on merge to main

**You do NOT run a manual deploy.** `.github/workflows/firebase-hosting-merge.yml` auto-deploys to Firebase Hosting (`aichat-c0c27`, target `flutteredgeai` → site `flutteredge-ai`, https://flutteredge.ai → live channel) on every push to `main` that touches `website/**` or `packages/flutter_edge_ai/example/**`. So:

0. **PRE-MERGE (do this on the branch, before merging):** build the Jaspr SSG
   locally to catch a build-time crash BEFORE it takes down the live deploy. The
   CI job runs the exact same `jaspr build`, so if it fails locally it will fail
   in CI — but locally you fix it in a branch instead of leaving `main` deployed
   from the old commit.
   ```bash
   cd website && jaspr build    # must end with "Completed building project"; NO "[ERROR]"
   ```
   The most common breakage is a **code fence in a `.md` doc with a language the
   highlighter can't parse.** `syntax_highlight_lite` (via `jaspr_content`) only
   ships a **Dart** grammar — a ```` ```yaml ````/```` ```xml ````/```` ```kotlin ````/```` ```bash ````
   fence throws `Null check operator used on a null value` in `Highlighter` and
   **fails the whole SSG build → the site stays stuck on the previous version.**
   Every existing doc uses only ```` ```dart ````; for any other language use a
   **plain fence** (```` ``` ```` with no language tag). Grep before you merge:
   ```bash
   grep -rhoE '```[a-z]+' website/content/docs/*.md | sort | uniq -c   # expect: only ```dart
   ```
1. Commit the `website/` changes (same author rule, no AI attribution) on your release branch / PR.
2. When the PR merges to `main`, the workflow builds the Jaspr SSG + the Flutter web example (`/try`) and deploys automatically.
3. **VERIFY THE MERGE DEPLOY ACTUALLY SUCCEEDED — do NOT assume merge == deployed.**
   The run failing on the "Build Jaspr site (SSG)" step is silent: pub.dev shows
   the new package, but flutteredge.ai still serves the OLD build. Check the
   run **conclusion**, not just that it triggered:
   ```bash
   gh run list --workflow firebase-hosting-merge.yml --limit 3   # newest must say "success", not "failure"
   # if failure: gh run view <id> --log-failed | grep -iE 'error|Null check|Highlighter'
   # then open https://flutteredge.ai/docs/... and confirm the NEW change is live
   ```
   If the deploy failed, the fix is another PR (main is a protected branch — you
   CANNOT push a hotfix directly; branch + PR + merge, same as any change).

A manual `./deploy.sh` exists in `website/` for local one-off deploys (it does the same build + `firebase deploy`), but the merge workflow is the normal path — don't run it by hand unless the workflow is broken. The site is NOT on pub.dev; `dart pub publish` never touches it — only this workflow (or `deploy.sh`) does.

## Common gotchas

- **Website SSG build fails silently on a non-Dart code fence** — a ```` ```yaml ````/```` ```xml ````/```` ```kotlin ```` fence in any `website/content/docs/*.md` crashes the Jaspr highlighter (Dart-only grammar) → the merge deploy fails → flutteredge.ai stays on the OLD build while pub.dev shows the new package. Always `jaspr build` the site locally on the branch before merge, use plain fences for non-Dart, and after merge confirm the `firebase-hosting-merge.yml` run says **success** (Step 12c). main is protected — a website hotfix is a new PR, not a direct push.
- **A version bump verified on a subset of platforms (#545).** native-v0.17.0
  ran Android GPU once, on one Adreno phone; 0.17.0-a and 0.17.1 ran no Android
  GPU at all ("only the provider / only Skel alignment changed"). The upstream
  accelerators had been broken on every Mali GPU since v0.17.0, and upstream
  #3575 said so six days before our first release. A hotfix tag ships every
  byte in the bundle, not just the bytes it changed, so it gets the full matrix.
- **`packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/` excluded from pub package** (`.pubignore`) — end users get dylibs from GitHub Release, NOT from the pub package. Updating local prebuilts without re-uploading them is invisible to users.
- **The iOS `5e0d86b` pin is obsolete** — modern tags ship their own `prebuilt/ios_arm64/`, and `build_ios.sh` already defaults to the current tag SHA. Always pass the pinned SHA explicitly anyway: every script's `DEFAULT_REF` lags whatever release you are migrating to. The real invariant is that source and accelerator prebuilts come from one tree — see the `build-native` skill, which owns this.
- **`bazelisk clean --expunge` is NOT free** — it forces a full rebuild (~25 min for one platform). Only do it when WORKSPACE patch_cmds changed; otherwise incremental rebuild.
- **Linux/Windows builds run on remote VMs** — see `project_gcloud_vm_workflow` memory.
- **macOS dylib produced LOCALLY**, not in CI — see `project_macos_dylib_built_locally` memory. Same for iOS.
- **Pub package size is informational, NOT a hard ceiling** — `.pubignore` already excludes prebuilts, integration tests, and notebooks. The FFI bindings + pigeon + example push each published package to ~700 KB on 0.16.x; the old <=100 KB ceiling predates 0.14.0 and no longer applies. Just confirm `.pubignore` still excludes the heavy dirs.

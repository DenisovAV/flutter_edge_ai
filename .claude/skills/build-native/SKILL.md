---
name: build-native
description: Rebuild native LiteRT-LM prebuilts for flutter_edge_ai (iOS / macOS / Linux / Windows / Android) — covers required build flags, the upstream commit pin, and a mandatory post-build verification checklist that catches the bugs we have already shipped at users.
user_invocable: true
---

# Build native dylibs for flutter_edge_ai — the right way

This skill exists because we shipped 0.14.0 and 0.14.1 with native dylibs that broke real users (App Store rejection in 0.14.0, `install_name_tool` headerpad failure in 0.14.1, x86_64-not-arm64 in upstream prebuilts). Every one of those was caught **after** publish. The verification checklist below would have caught all of them locally.

The v0.16.0 migration added a second class of defect, and it is the more expensive one: **inputs we pinned once and stopped maintaining** — a Bazel define upstream had deleted, an OpenVino SDK four minor versions behind the pin, a dispatch library hardcoded to a LiteRT commit from four releases ago. None of them fails a build. All of them fail at a version boundary, which makes them look exactly like upstream regressions — and we filed two upstream issues that had to be retracted before finding that out.

**Read top to bottom before rebuilding anything.** The checklist is non-optional.

**Every path below is relative to the repo root.** This is stated because it was
not true for a long time: the paths in this file predated the 1.0 monorepo split
and pointed at `native/litert_lm/…`, which does not exist from the root. `nm` and
`otool` on a missing file print nothing, `grep -c` on nothing returns `0`, and the
whole verification checklist read as passing while touching no artifact at all —
the same defect the checklist exists to catch, applied to itself. When you add a
command here, run it from the root first and confirm it produces output.

**Use `/usr/bin/grep` when you paste a check into an interactive shell.** In the
agent's zsh, `grep` is a shell function over a ripgrep-style search that skips
binary files and hidden files. `grep -q LogitMask <provider>` then answers "no"
for a provider that has it (a false ABI MISMATCH at the v0.18.0 bump), and a
recursive search never opens `.bazelrc`. The build scripts are unaffected —
they run under bash, which does not inherit zsh functions.

---

## Pre-build setup

### Required upstream commit

**Pin the exact tag commit SHA on every platform, and pass it explicitly.** Upstream has retagged releases in place before, so a tag *name* is not a stable reference. Get the SHA with:

```bash
gh api repos/google-ai-edge/LiteRT-LM/git/ref/tags/<tag> --jq '.object.sha'
```

The scripts' `DEFAULT_REF` lags whatever release you are migrating to, so never rely on it — `build_ios.sh` still defaulted to the v0.14.0-era `80f301ff` during the v0.15.0 migration.

**The historical iOS `5e0d86b` pin is obsolete.** It existed because `5e0d86b` was the first commit shipping `libLiteRtMetalAccelerator.dylib` for iOS, and older tags produced a `libLiteRtLm.dylib` whose Metal-accelerator vtable didn't match the prebuilt framework → `EXC_BAD_ACCESS` inside `litert_lm_engine_create` on device. Modern tags ship their own `prebuilt/ios_arm64/`, so building iOS from the tag is now the *safer* option.

The real invariant is: **source and accelerator prebuilts must come from the same tree.** Mixing them is the hazard — not the choice of tag. Verify before building:

```bash
gh api "repos/google-ai-edge/LiteRT-LM/contents/prebuilt/ios_arm64?ref=<tag>" --jq '.[].name'
# needs libLiteRtMetalAccelerator.dylib + libLiteRtTopKMetalSampler.dylib
```

### The LiteRT pin is a second ABI surface — check it every time

A LiteRT-LM bump silently moves `LITERT_REF` in `WORKSPACE` (line ~6), and that is a **different upstream repo** with its own C API. This matters because three separate things bind to it:

- `flutter_edge_ai_litertlm` → LiteRT-LM C API (`c/engine.h`)
- `flutter_edge_ai_speech` → **LiteRT** C API directly, via litertlm's `lib/src/ffi/litert_bindings.dart`
- **both NPU dispatch libraries** → the `LiteRtDispatchApi` struct and the LiteRT runtime they are loaded into

So a green litertlm smoke run proves nothing about embeddings, and nothing at all about NPU. In the v0.14.0 migration the pin moved, `LiteRtCreateModelFromFile` gained a third parameter (`LiteRtEnvironment` first), and embeddings silently returned `status=500` — a full day lost before the cause was found.

```bash
for t in <old-tag> <new-tag>; do
  gh api "repos/google-ai-edge/LiteRT-LM/contents/WORKSPACE?ref=$t" --jq '.content' | base64 -d | grep '^LITERT_REF'
done
```

If it moved, diff the headers the bindings use (`litert/c/litert_{model,environment,options,tensor_buffer,compiled_model}.h`) at both refs. Symbol list — the hand-written bindings moved into the litertlm package, so the
old embeddings-only grep now misses more than half of them (23 vs 52 symbols):

```bash
grep -rohE "LiteRt[A-Za-z_]+" \
  packages/flutter_edge_ai_litertlm/lib/src/ffi/litert_bindings.dart \
  packages/flutter_edge_ai_speech/lib/src/litert/ | sort -u
```

**Diff the structs too, not only the function signatures.** A struct we mirror by hand (`LiteRtLayout`, `LiteRtRankedTensorType`) can change layout while every symbol and signature stays the same, so the symbol list above passes. LiteRT `d84656955` (2026-07-09) turned `bool has_strides : 1` into `unsigned int has_strides : 1`, which moved `dimensions[]` from offset 8 to 4 **under MSVC only**; our Windows-only mirror kept offset 8 and broke Windows embeddings and speech from native-v0.16.0 on (pitfall #16). Diff `litert/c/litert_layout.h` and `litert/c/litert_model_types.h` at both refs, and when a divergence we work around disappears upstream, delete the workaround in the same bump. `test/ffi/litert_layout_abi_test.dart` pins the current sizes.

Known pins: v0.14.0 → `622f1f3c` (**breaking** for embeddings; predates `d84656955`); v0.15.0 → `3cb830ad` (safe — four headers byte-identical, `litert_compiled_model.h` only gains `LiteRtGetCompiledModelEnvironment()`); v0.16.0 → `0ff28117f1cb5556d0e015bf80b773f74e2bee51` (contains `d84656955`); v0.17.0 → `9fe5be45564c868408e6514c8aabb83e211a0911` (headers additive; the GPU samplers' `Create` gained a leading `runtime_c_api` argument, prebuilt samplers refreshed upstream in `a24911058`); v0.18.0 → `26895c9fbcc25c43faa8c1a98cd1fd28951602c3` (the seven binding headers byte-identical, `litert_common.h` / `litert_tensor_buffer_types.h` comment-only; deletes `resolve_symbols_in_exec` in `fd031ae5`, see below).

**Never hardcode this ref in a build script.** `build_qualcomm_dispatch.sh` carried a literal `5c5b9ce6` from the native-v0.12.0 era and nobody noticed for four releases, because a stale dispatch library does not fail politely — see the NPU section below. Derive it from the WORKSPACE of the LiteRT-LM revision being built:

```bash
LITERT_REF="$(curl -fsSL \
  "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$LITERTLM_REF/WORKSPACE" \
  | sed -n 's/^LITERT_REF *= *"\([0-9a-f]*\)".*/\1/p' | head -1)"
[ -n "$LITERT_REF" ] || { echo "could not resolve LITERT_REF" >&2; exit 1; }
```

The empty-result guard matters: `curl | sed` on a moved/renamed WORKSPACE yields an empty string, and an empty `--define` or checkout ref fails much later and much less legibly than an explicit `exit 1` here.

### Bazel defines rot — confirm each one still exists in the tree

A `--define` that upstream has deleted is **not an error**. Bazel accepts any `--define=key=value`; if no `config_setting` reads that key, the flag is silently inert and you get the default build.

We passed `--define=litert_link_capi_so=true` on Windows and Linux for three releases. Upstream removed the name; **no `config_setting` reads it** in the v0.16.0 tree (a plain grep still finds one commented-out mention in `.github/workflows/ci-build-mac.yml`, which is why the recipe below greps only `.bzl`/`BUILD`/`.bazelrc`). The live name is `litert_runtime_link_mode=dynamic`. This was harmless until v0.14.0 split Dawn out of the WebGPU accelerator, from which point the statically-linked runtime is exactly what crashed GPU `engine_create` — reported upstream as #2957 and **retracted**, because the cause was ours.

Before trusting any define in a build command, grep **both** trees it can live in — LiteRT-LM, and LiteRT at the derived `LITERT_REF` (a define read only by `@litert` never appears in the LiteRT-LM tree, so grepping that alone reports "dead" for a live flag and "dead" for a dead one alike):

```bash
# Query the LiteRT-LM workspace, not the repo root (not a Bazel workspace), and
# only after a build/fetch at this pin — otherwise LR points nowhere and every
# define reads litert=0.
LR="$(cd /tmp/LiteRT-LM && bazelisk info output_base 2>/dev/null)/external/litert"
[ -d "$LR/litert" ] || echo "LiteRT not fetched at $LR — run a build or 'bazelisk fetch' first"
for d in litert_runtime_link_mode <any-other>; do
  printf "%-32s lm=%s litert=%s\n" "$d" \
    "$(/usr/bin/grep -rl "$d" /tmp/LiteRT-LM --include='*.bzl' --include='BUILD*' --include='.bazelrc' --include='*.bazelrc' 2>/dev/null | wc -l)" \
    "$(/usr/bin/grep -rl "$d" "$LR" --include='*.bzl' --include='BUILD*' 2>/dev/null | wc -l)"
done
```

Zero in both means the flag is dead — find the replacement in `docs/getting-started/build-and-run.md`, do not leave it in "just in case". The one current desktop define is documented there as **mandatory for GPU**:

| Define | Why |
|---|---|
| `litert_runtime_link_mode=dynamic` | Keeps the LiteRt C API **out** of `libLiteRtLm` so it resolves against the separately shipped `libLiteRt` at runtime — which is what the prebuilt WebGPU accelerator and the split `libwebgpu_dawn` expect. |

`resolve_symbols_in_exec=false` used to sit in this table. LiteRT `fd031ae5` (2026-08-28, inside the v0.18.0 pin) deleted the flag together with every `select` that read it and hard-wired the branch `=false` picked (the DLL import library on Windows), so dropping it changes nothing in the build. It was removed from both workflows at the v0.18.0 bump.

### Required linker flags

| Platform | Flag | Why |
|---|---|---|
| **macOS / iOS** | `-Wl,-headerpad_max_install_names` | Native Assets re-runs `install_name_tool -id @rpath/...` on every `pub get`. Without headerpad, the rewrite fails with "larger updated load commands do not fit" and `pub get` aborts. |
| **macOS** | `-mmacosx-version-min=11.0` | Without it clang stamps `LC_BUILD_VERSION` with the **build host's** OS, so the bundle's floor silently tracks whichever Mac produced it. |
| **Android** | `aarch64-linux-android24-clang` (target triple carries the API level) | Same reason, stated explicitly rather than inherited. |
| Linux | `-Wl,--dynamic-list=...` (already in patch_c_api.sh §1) | Exports LiteRt* / litert_lm_* symbols for the WebGPU accelerator's `dlsym(RTLD_DEFAULT)` |
| Windows | `/DEF:windows_exports.def` (already in patch_c_api.sh §1) | Bazel native attribute |
| All | `-fvisibility=hidden` is **WRONG** for our use case — needs default visibility on the listed export sets |

The `headerpad_max_install_names` flag is **not optional on Apple platforms**. Verify in the post-build checklist below.

**Deployment target must be stated, never inherited.** This bites only the libraries *we* compile — the upstream prebuilt companions arrive with their own sane values (11.0 / 14.0), so a single odd number in the middle of an otherwise healthy bundle is the signature. `native-v0.14.0` shipped `libStreamProxy.dylib` with `minos 26.0` for exactly this reason: `build_macos.sh` compiled it with a bare `clang -shared` on a macOS 26 host, while `example/macos/Podfile` advertises `platform :osx, '10.15'`. `build_ios.sh` never had the bug because its step 8b force-normalizes every companion to 13.0 with `vtool -set-build-version`. Check every self-built binary:

```bash
for f in prebuilt/macos_arm64/*.dylib; do
  printf "%-46s minos=%s\n" "$(basename $f)" "$(vtool -show-build "$f" | awk '/minos/{print $2; exit}')"
done
```

Anything at or near the current macOS release means the flag was dropped. Rebuilding one dylib is a two-second `clang` call — no Bazel involved — so there is never a reason to ship it wrong.

### Patches we apply

`packages/flutter_edge_ai_litertlm/native/litert_lm/patch_c_api.sh` — the surviving sections (2–9 were **deleted** at the v0.14.0 migration once upstream implemented them natively; don't go looking for them):

1. `cc_binary(linkshared=True)` target + Linux dynamic-list + Windows .def
4b. `set_use_hw_masking_for_npu` (Intel LunarLake/PantherLake — default `true` crashes their NPU)
4c. GPU smooth-UI knobs — `gpu_context_low_priority` + `kernel_batch_size` (#364)
10b. **App Store ITMS-90432 fix** — rewrite `gpu_registry.cc` dlopen to `@executable_path/...framework/<X>` on Apple. **iOS-critical.**
11. minizip/zlib mirrored off the flaky zlib.net

§10a (sampler_factory.cc) is **deliberately NOT patched** — `libLiteRtTopKMetalSampler.dylib` has 3-of-7 broken exports on Apple (#2073). Patching it surfaces a NULL-vtable crash. Leave the basename dlopen so `sampler_factory.cc` falls back to CPU sampler. Revisit when Google fixes #2073.

Run the patcher against the new tag before building anything. **There is no
dry-run mode** — it edits the tree in place, so run it on a throwaway clone.

Every section must print `OK`. A `WARN` means a patch target moved and that
section did **not** apply — and the script still exits 0, so nothing downstream
notices. Sections 2-9 died exactly this way and we only found out months later,
when the sampler stopped honouring per-session parameters. §10b is the App Store
ITMS-90432 fix (pitfall #2, already shipped to users once): if its WARN fires,
the Metal accelerator path is silently unpatched and iOS GPU breaks on device.

Make it fail instead of trusting yourself to read the log:

```bash
LOG=/tmp/patch_c_api.log
bash packages/flutter_edge_ai_litertlm/native/litert_lm/patch_c_api.sh /tmp/LiteRT-LM 2>&1 | tee "$LOG"
grep -q WARN "$LOG" && { echo "PATCH INCOMPLETE — a target moved, do not build"; exit 1; }

# Assert the artifact, not the log line. gpu_registry.cc lives in LiteRT, not
# in this tree — §10b patches WORKSPACE so Bazel rewrites it at fetch time.
grep -q FLUTTER_GEMMA_GPU_REGISTRY_PATCH /tmp/LiteRT-LM/WORKSPACE \
  || { echo "§10b did not apply — iOS GPU would ship broken"; exit 1; }
```

That proves the patch is queued, not that it compiled in — post-build check #5 (the `@executable_path` string inside the dylib) is what proves that. At v0.18.0 the WARN fired for real: upstream rewrote the `litert` `patch_cmds` entry our anchor matched, and the script exited 0. §10b now anchors on the `patch_cmds = [` list of the `litert` archive itself.

On Windows/git-bash, `python3` resolves to the Microsoft Store stub, which prints "Python was not found" **and still exits 0** — so sections 10b and 11 silently no-op. Shim it first:
`printf '#!/bin/sh\nexec "<path>/python.exe" "$@"\n' > /somewhere/python3 && chmod +x` and prepend that dir to `PATH`.

### Cloning upstream without fighting the network

The repo carries large LFS binaries; a full clone repeatedly dies mid-transfer on anything but a rock-solid link, and the failure restarts from zero. Clone the tag shallow with LFS deferred, then pull only the platforms you're building:

```bash
GIT_LFS_SKIP_SMUDGE=1 git -c http.version=HTTP/1.1 -c http.postBuffer=524288000 \
  clone --depth 1 --branch <tag> https://github.com/google-ai-edge/LiteRT-LM /tmp/LiteRT-LM
cd /tmp/LiteRT-LM
git lfs pull --include="prebuilt/macos_arm64/*,prebuilt/ios_arm64/*,prebuilt/ios_sim_arm64/*,prebuilt/android_arm64/*"
```

**Then point `origin` at a local bare mirror.** `build_*.sh` run `git fetch --tags --force origin` whenever the clone dir already exists — cheap on a full clone, near-endless on a shallow one, because every other tag's objects have to be fetched. Redirecting origin makes that fetch local and instant (measured: 0.03 s), and removes the network from the build loop entirely:

```bash
git clone --bare /tmp/LiteRT-LM /tmp/LiteRT-LM-mirror.git
cd /tmp/LiteRT-LM && git remote set-url origin /tmp/LiteRT-LM-mirror.git
# LFS follows origin, and the bare mirror has no LFS endpoint — pin it back:
git config lfs.url https://github.com/google-ai-edge/LiteRT-LM.git/info/lfs
```

That last line is not optional. Redirecting `origin` fixes the `git fetch --tags` hang and immediately breaks `git lfs pull`, which then leaves pointer files in place of the accelerator dylibs — a failure that surfaces much later, as a dylib that loads but exports nothing.

Verify the LFS pull produced real binaries, not pointers — `head -c 20 <file>` starting with `version https` means it's still a pointer.

### ⚠️ NPU dispatch libraries MUST be rebuilt from the pin — never carried forward

**This section previously said the opposite.** It claimed both NPU stacks are unbuildable and must be copied from the previous release, and instructed asserting byte-identity against it. That was wrong, and it is the single most expensive mistake this skill has recorded: it turned two of our own configuration defects into upstream bug reports (#2957, #3217) that had to be retracted, and it is the direct cause of the Android NPU crash below.

Both dispatch libraries build from the same pin as the runtime:

| Bundle | Target | Notes |
|---|---|---|
| `windows_x86_64` | `@litert//litert/vendors/intel_openvino/dispatch:LiteRtDispatch` | Bazel fetches the OpenVino SDK itself (`configurable_repo`) — no preinstalled toolkit on the runner. Built in CI. |
| `android_arm64` | `//litert/vendors/qualcomm/dispatch:dispatch_api_so` | From the **LiteRT** repo at the derived `LITERT_REF`, not LiteRT-LM. Bazel auto-downloads the QAIRT that LiteRT's `third_party/qairt/workspace.bzl` pins (~500 MB) — 2.44 at v0.16.0, 2.47 at v0.17.x, **2.50.0.260828 at v0.18.0** — or point `LITERT_QAIRT_SDK` at a local copy of that same version. The script fails unless the SDK's `sdk.yaml` version equals the hook's `qnnRuntimeVersion` (see below). Built locally by `build_qualcomm_dispatch.sh`. |

Why the old rule was believable and still wrong: a fresh LiteRT-LM build genuinely emits neither library, because neither lives in the LiteRT-LM tree — they are LiteRT vendor targets. "Absent from the output" was read as "unbuildable" instead of "wrong target".

**A stale dispatch library does not fail politely.** It is a plugin loaded into the runtime's address space and it shares the runtime's structs:

- **Windows.** Ours had been frozen since native-v0.11.0-b and shipped **OpenVino 2026.2.0**, while every LiteRT pin since has required **2026.3.0.dev20260622** (build 22242-561fc907ca4). Upstream's own `third_party/intel_openvino/openvino.bzl` warns that a mismatched pair leaves the Intel OV compiler plugin talking to the wrong `libopenvino_intel_npu_compiler` at runtime. That is what killed `engine_create` on `backend=npu`.
- **Android.** `libLiteRtDispatch_Qualcomm.so` was built against LiteRT `5c5b9ce6`. On v0.16.0 it SIGSEGVs inside `LiteRtDestroyOptions` the moment `engine_create` tears an options object down — a struct-layout mismatch, surfacing as a crash in the *runtime's* symbol, which reads as a runtime bug.

Both looked like clean regressions at a version boundary, because they were: the boundary is where upstream finally touched the code the frozen artifact depended on. **Verify a bisection's conclusion, not just its measurement** — "v0.13.1 works, v0.14.0 crashes" is a true measurement that says nothing about whose change is at fault when one input to the comparison never moved.

**The OpenVino runtime half is now asserted, in both Windows workflows.** They read the build string the SDK declares in `runtime/version.txt` and compare it against the string embedded in the `openvino.dll` being staged, throwing on mismatch — and throwing just as loudly when either side is unreadable or malformed, because a check that passes on missing data is indistinguishable from one that verified something.

Be precise about what that does and does not buy, because the first version of this note was not:

- **It asserts internal consistency, not the pin.** Both sides come out of the same Bazel-fetched `$ovRoot`, so no *input* can currently make it fail — only a future edit that stages either side from somewhere else. That is anti-regression value, not detection of an upstream SDK bump.
- **It does not cover the dispatch.** `LiteRtDispatch.dll` is copied from `bazel-bin` and embeds no version string, so the half of the pair that actually broke in #3217 is still only verified by check #9 on real silicon.
- **It cannot catch a hand-staged bundle.** `Copy-Item -Force` overwrites `artifacts\` from `$ovRoot` immediately before the check, so anything placed there by hand is gone before it could be tested.

**Put it in both workflows.** `build-litertlm-native-windows.yml` is fast iteration and ends at `upload-artifact`; `build-litertlm-native.yml` carries the `publish-release` job that creates the `native-v*` tag users fetch. A check added only to the first protects nothing that ships — which is exactly the mistake this paragraph originally shipped with.

**Android: since native-v0.18.0 the QNN runtime is NOT in the tarball.** Qualcomm licenses the QNN libraries for redistribution only inside an application, so the `android_arm64` bundle carries the dispatch alone. An app opts in with `hooks: user_defines: flutter_edge_ai_litertlm: qualcomm_npu: true` (in the app's root pubspec, or the workspace root for a workspace member), and the litertlm hook fetches `com.qualcomm.qti:qnn-runtime` from Maven Central — version and sha256 pinned in `hook/src/qnn_runtime.dart`, Skels raised to 16 KB there (`prepareQnnLibrary`), promoted into `<cacheBase>/qnn/android_arm64/<version>-<sha8>-p<format>/`. `build_android.sh` deletes any QNN `.so` left in `prebuilt/android_arm64/` and `verify_tarball_manifest.sh` lists the ten as `INTENTIONAL_DROPS`. Do not put them back in the tarball.

**The QNN runtime and the dispatch are still one matched pair.** The dispatch negotiates an **API version** with the runtime it finds, and a stale runtime does not fail politely — ours once drifted into

```
E/litert: [qnn_manager.cc:349] Qnn System library version 1.8.0 is mismatched.
          The minimum supported version is 1.11.0.
E/litert: [dispatch_api.cc:139] Failed to set up QNN manager
E/litert: [dispatch_delegate.cc:131] No usable Dispatch runtime found
```

So bumping the LiteRT pin is a two-file change whenever its `third_party/qairt/workspace.bzl` moves: `build_qualcomm_dispatch.sh` reads the Bazel-fetched SDK's `sdk.yaml` version (`2.50.0` at v0.18.0) and **refuses to build** unless it equals `qnnRuntimeVersion` in `hook/src/qnn_runtime.dart`. Bump that constant and `qnnRuntimeSha256` to the matching Maven release first (`curl -fsSL https://repo1.maven.org/maven2/com/qualcomm/qti/qnn-runtime/<v>/qnn-runtime-<v>.aar | shasum -a 256`, and compare its `.sha1` with Maven's own). The release number is the only pairing that holds: QNN carries two independent numberings, and `libQnnSystem.so` — the file that broke — has no version string at all, so never try to pair them by `strings | grep`.

`libQnnHtpV79Skel.so` must stay in the hook's list: it is **absent from `/vendor/dsp/cdsp/` even on Qualcomm reference firmware**, so shipping it is required, not a workaround for unusual devices.

Assert the dispatch per bundle before packing — `build_qualcomm_dispatch.sh` promotes exactly one file. Shipping without it fails no build and no CPU/GPU smoke test — only a user on `PreferredBackend.npu` finds out. The on-device run (check #10) is still the only coverage of the pair working together.

#### Windows CI specifics

- **Job timeout 150 minutes.** A cold Bazel cache plus the OpenVino fetch overruns anything shorter; 60 min was killing runs mid-link.
- **Exclude the Bazel output base from Defender.** Two consecutive runs died at ~52 min with `Couldn't delete action output directory: D:/b/execroot/litert_lm/bazel-out/_tmp/actions/stderr-NNNN (Permission denied)`. The build had *finished*; Defender was holding a per-action stderr file open during cleanup. `Add-MpPreference -ExclusionPath` on the output base, plus one warm-cache retry of the build step, turns a 52-minute loss into a two-minute one.
- **Allow-list the OpenVino components; never copy `runtime\bin` wholesale.** A blanket copy drags in the CPU/GPU/auto/hetero plugins, every model frontend, and a full parallel set of **debug builds** — and those are named `openvinod.dll`, `*_plugind.dll`, `*_frontendd.dll`, so a `_d.dll` filter misses all of them. Two near-identically named sets side by side is precisely how the OpenVino core binds the wrong plugin. The allow-list took the bundle from 45 files to 28 (253 MB uncompressed, 93 MB packed):

  ```
  openvino.dll, openvino_intel_npu_plugin.dll, openvino_intel_npu_compiler.dll,
  openvino_intel_npu_compiler_loader.dll, openvino_tensorflow_lite_frontend.dll, tbb*
  ```

  TBB lives outside `runtime\bin` (`3rdparty\tbb\bin`), so search the whole SDK. `throw` on any missing member — a silently short NPU stack is the failure mode this whole section exists to prevent.

  The `tbb*` wildcard at the end of that list is itself a small leak: it also matches `tbb12_debug.dll`, `tbbbind_2_5_debug.dll`, `tbbmalloc_debug.dll` and `tbbmalloc_proxy_debug.dll`. Only ~1.8 MB of a 253 MB bundle, and unlike `openvinod.dll` the names are distinct enough not to be mis-bound, so it is dead weight rather than a hazard — but add `-and $_.Name -notlike '*_debug.dll'` next time the workflow is touched.

#### Qualcomm dispatch: `-gcc-toolchain` means you are building the wrong ref

`clang: error: unknown argument: '-gcc-toolchain'` looks like an NDK-version problem and is not one. It means the tree you are building resolves the Android toolchain through the **legacy** `--crosstool_top=//external:android/crosstool`, which wants the NDK ≤ r22 layout (`toolchains/aarch64-linux-android-4.9/`) that no modern NDK ships.

Only old LiteRT does that. Compare the two pins:

| | `5c5b9ce6` (our old hardcoded ref) | `0ff28117` (the v0.16.0 pin) |
|---|---|---|
| WORKSPACE | no `android_ndk_repository` at all | `rules_android_ndk` + `register_toolchains` |
| `build:android_arm64` | platforms only | adds `--incompatible_enable_cc_toolchain_resolution` and `--incompatible_enable_android_toolchain_resolution` |
| NDK 26+ | unsupported | supported (`# Need latest rules_android_ndk to use NDK 26+`) |

So the `-gcc-toolchain` failure was a **symptom of the hardcoded `LITERT_REF`**, not a separate constraint: the script was compiling a four-release-old tree that genuinely cannot use a modern NDK. Deriving the ref fixes the crash *and* the build. **NDK r29 is correct here** — same value `build_android.sh` requires, no per-invocation juggling.

Feed the NDK path with `--repo_env`, not `--action_env`:

```bash
bazelisk build --repo_env=ANDROID_NDK_HOME="$ANDROID_NDK_HOME" \
  --config=android_arm64 --compilation_mode=opt --strip=always \
  --linkopt=-Wl,-z,max-page-size=16384 \
  //litert/vendors/qualcomm/dispatch:dispatch_api_so
```

The new wiring gates on a repository rule — `check_android_ndk_env` calls `ctx.getenv("ANDROID_NDK_HOME")` and, when unset, registers `@android_ndk_env//:all`, a repo with an **empty BUILD file**. Zero toolchains, and the failure surfaces far from its cause. `--action_env` populates action environments, which repo rules never read; the generated `.litert_configure.bazelrc` (`--action_env ANDROID_NDK_HOME`, `ANDROID_NDK_API_LEVEL`, …) is the old TF-era mechanism and is dead weight at this pin — `api_level` now lives in the WORKSPACE call.

Expect ~3 minutes warm and a 707-724 KB stripped `ELF 64-bit aarch64` exporting exactly one symbol, `LiteRtDispatchGetApi`. Verify that symbol before packing; the library has no other public entry point, so its absence is the whole failure mode.

`bazelisk clean --expunge` between attempts only if you changed WORKSPACE-level wiring — Bazel caches toolchain resolution, and a cached failure re-prints the previous error without recompiling, which reads as "the fix didn't work".

---

## Build commands

Always pass the pinned SHA explicitly — the scripts' `DEFAULT_REF` lags the release you're migrating to.

```bash
REF=<tag-commit-sha>          # v0.17.0 = e9fd8c53ff968071774206163027dd84bedfe925 (v0.16.0 = 924e79c9…)
export ANDROID_NDK_HOME="$HOME/Library/Android/sdk/ndk/29.0.14206865"   # r29 mandatory

packages/flutter_edge_ai_litertlm/native/litert_lm/build_macos.sh   "$REF"    # macOS arm64
packages/flutter_edge_ai_litertlm/native/litert_lm/build_ios.sh     "$REF"    # iOS device + simulator
packages/flutter_edge_ai_litertlm/native/litert_lm/build_android.sh "$REF"    # Android arm64, cross-compiled

# Qualcomm NPU dispatch — separate build, separate repo (LiteRT), separate NDK.
# Derives LITERT_REF from the LiteRT-LM WORKSPACE; see the NPU section above.
LITERTLM_REF="$REF" packages/flutter_edge_ai_litertlm/native/litert_lm/build_qualcomm_dispatch.sh
```

`ANDROID_NDK_HOME` must be **exported explicitly**: `build_android.sh` auto-detects the newest NDK *only when the variable is unset*, so a stale value in your shell silently selects the wrong toolchain (r26 fails on a C++20 concept in the minijinja chat template).

**Linux x86_64/arm64 and Windows x86_64 build in CI**, not on a VM: dispatch `build-litertlm-native.yml` with `-f litertlm_version=<SHA>`. Use `--ref <branch>` if the migration carries source changes — the workflow compiles `stream_proxy.c` from the checked-out tree **and** builds the Intel NPU dispatch, so dispatching from `main` would silently ship a stale shim and a stale dispatch.

`build-litertlm-native-windows.yml` is a Windows-only copy of that job for fast iteration. It duplicates the job body rather than sharing it — **when you change one, change both**, or the standalone workflow quietly builds with the previous release's flags.

**`bazelisk clean --expunge` before rebuild only if WORKSPACE patch_cmds changed** (otherwise incremental is fine and ~5× faster — a warm cache can finish a platform in 2–5 min, which is normal and not a sign that nothing was built).

### Never trust a build's exit code — verify artifacts

Wrapper scripts have reported success while producing nothing (a failed `git clone` inside the script, an `echo` after the build masking its status, `gh` printing a network error and still exiting 0). Confirm each platform by **artifact**, not by status line:

```bash
f=prebuilt/<dir>/libLiteRtLm.dylib      # or .so
printf "exists=%s mtime=%s newversion_symbol=%s\n" \
  "$([ -f "$f" ] && echo yes || echo NO)" \
  "$(stat -f '%Sm' -t '%H:%M' "$f" 2>/dev/null)" \
  "$([ -f "$f" ] && nm -gU "$f" 2>/dev/null | grep -c '<symbol-new-in-this-version>')"
```

Print `exists` **next to** the symbol count. `nm` on a missing file emits nothing and `grep -c` turns that into a perfectly innocent `0` — "feature absent" and "check never ran" must not look identical. The same applies to shell globs: in zsh an unmatched `*.so` aborts the whole `ls`, so use `find … \( -name '*.dylib' -o -name '*.so' \)` in verification loops.

`set -o pipefail` is not enough when the build is not the last command in the chain: `bazel … | tail -20` exits with `tail`'s status, and `build_macos.sh` reported success through a genuine failure that way. Put the build last, or capture `${PIPESTATUS[0]}`.

### Fetching artifacts is part of the build — verify those too

Both of our download paths fail silently:

- **`gh run download`** leaves an empty directory rather than erroring when the artifact name doesn't match, and has no `--clobber`, so a re-download into a populated directory can mix two runs' outputs. Always download into a **fresh** directory and assert the file count.
- **`curl`** exits `0` on a truncated transfer. One 2877 MB model arrived as 45 MB with a clean exit. Use `--retry 5 --retry-all-errors -C -` and verify the byte count against `Content-Length` before using the file.

---

## ⚠️ Post-build verification — MANDATORY before pushing prebuilts to repo

Every freshly-built dylib must pass **all** of these checks. Skipping any one of them has shipped a regression to users.

### 1. Mach-O architecture (iOS / macOS / desktop)

```bash
file packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libLiteRtLm.dylib
```

Expected: `arm64` for iOS device, `arm64` for iOS Sim, `arm64` for macOS_arm64. **Not x86_64.** Upstream `5e0d86b` shipped `libLiteRt.dylib` and `libLiteRtTopKMetalSampler.dylib` as **x86_64 macOS binaries inside `prebuilt/ios_arm64/`** (#2072) — when you copy them across, double-check.

```bash
otool -hv packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libLiteRtLm.dylib | tail -2
# → cputype 16777228 (arm64), filetype 6 (DYLIB)
```

### 2. Header padding (macOS / iOS) — measure it with check #4, not with `sizeofcmds`

Native Assets re-runs `install_name_tool -id @rpath/...` on every `pub get`. Without enough header padding the rewrite fails with:

> `install_name_tool: changing install names or rpaths can't be redone for: ... larger updated load commands do not fit`

**This is what bit users in 0.14.1 (#247).** Padding cannot be added to an already-linked binary — you must rebuild with `-Wl,-headerpad_max_install_names`.

**Do not test this by comparing `sizeofcmds` against a threshold.** An earlier version of this skill said "need `sizeofcmds >= 4096`", which is wrong: `sizeofcmds` is the *current* size of the load commands, while `-headerpad_max_install_names` enlarges the *free space* after them. A small library legitimately has small load commands — `libStreamProxy.dylib` reports ~1136 and rewrites perfectly. At the v0.15.0 migration that threshold flagged 8 healthy dylibs, including three upstream ones, and would have blocked the release for nothing.

**Check #4 below is the only authoritative test** — it performs the exact operation Native Assets performs. Run it over every dylib in the directory and trust its result.

For dylibs we don't build ourselves (upstream prebuilts like `libGemmaModelConstraintProvider.dylib`, `libLiteRtMetalAccelerator.dylib`, `libLiteRtTopKMetalSampler.dylib`) that genuinely fail check #4: file an upstream bug, then either rebuild from source with the flag, or relink with `optool` / `ld -r` for bigger headerpad.

### 3. install_name + rpath

```bash
otool -D <file>  # → @rpath/libLiteRtLm.dylib (NOT absolute path)
otool -l <file> | grep -A2 LC_RPATH | grep " path "
# Expected for macOS: @loader_path/../../..
# Expected for iOS:   @loader_path or @executable_path/Frameworks/...
```

### 4. install_name_tool smoke test

The mandatory test that catches headerpad bugs:

```bash
cp packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libX.dylib /tmp/test.dylib
chmod +w /tmp/test.dylib
install_name_tool -id @rpath/this_is_a_long_test_path_pad_to_native_assets_target/libX.dylib /tmp/test.dylib
# → must succeed silently. If it fails with "larger updated load commands do not fit", headerpad is too small. STOP and rebuild.
```

Run this for **every** dylib in `prebuilt/<dir>/`, not just the one you rebuilt. Native Assets rewrites all of them.

**One known, accepted failure: `ios_sim_arm64/libLiteRtMetalAccelerator.dylib`.** It is an upstream prebuilt with only **48 bytes** of header slack, so the 91-character test path above does not fit. The name the iOS build actually writes, `@rpath/LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator` (62 characters), does fit — test that one for this file. The published native-v0.17.1-a carried a file with the same slack, so this is not a regression; it surfaced at the v0.18.0 bump. The device slice (`ios_arm64`) passes the long path. If a future upstream refresh shrinks the slack further, the framework name stops fitting too, and then it is a blocker: relink or report upstream (see "When upstream is broken").

### 5. Phase 8 patch markers (iOS / macOS only)

```bash
strings packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libLiteRtLm.dylib | grep '@executable_path.*LiteRtMetalAccelerator'
```

Expected: 1 hit (path to `LiteRtMetalAccelerator.framework/LiteRtMetalAccelerator`). If 0 hits, `patch_c_api.sh` §10b didn't apply — your build was against a tree where `WORKSPACE.patch_cmds` didn't run. Run `bazelisk clean --expunge` and rebuild.

```bash
strings packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libLiteRtLm.dylib | grep -c '^libLiteRtMetalAccelerator.dylib$'
```

Expected: 0. If non-zero, the basename dlopen string is still in the binary — patch failed.

### 6. Required exports

```bash
nm -gU packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/libLiteRtLm.dylib | grep _litert_lm_engine_create
# → must show the symbol as T (text section, exported)
```

Run `nm -gU | grep -c '_litert_lm_'` — expect ~50 symbols (matches `bindings.dart` lookupFunction count).

### 7. **Real `pub get` smoke test in a fresh project**

This catches problems no static check sees. Mandatory before commit:

```bash
REPO=/Users/sashadenisov/Work/flutter_edge_ai
cd /tmp
rm -rf test_flutter_edge_ai_native
flutter create test_flutter_edge_ai_native --platforms=macos,ios
cd test_flutter_edge_ai_native
# The repo ROOT is the workspace package (name: flutter_edge_ai_workspace,
# publish_to: none) — pointing --path at it fails with "name field doesn't
# match expected name". And core owns NO native bundle: its hook has
# `const _bundles = <_NativeBundle>[];`. Adding core alone exercises zero
# CodeAssets, so the check that exists to catch the 0.14.1 headerpad bug
# would have passed while testing nothing. Add the package that owns the
# dylibs.
flutter pub add flutter_edge_ai --path="$REPO/packages/flutter_edge_ai"
flutter pub add flutter_edge_ai_litertlm --path="$REPO/packages/flutter_edge_ai_litertlm"
# flutter_edge_ai_embeddings is pure Dart and shares no bundle — never in this list
rm -rf .dart_tool build
flutter pub get
# → must complete without "Failed to set install names" or any other error
flutter build macos --debug    # mandatory
flutter build ios --debug --no-codesign   # mandatory (catches dylib loading)

# Assert the dylibs actually landed. A green build with zero CodeAssets looks
# identical to a green build with all of them.
find build -name 'libLiteRtLm*' -o -name 'LiteRtLm*' | head
```

**This is the smoke test I skipped in 0.14.1.** Doing this once would have caught the `libGemmaModelConstraintProvider.dylib` headerpad issue before publish — provided it points at the package that carries the bundle.

**But note what it still does NOT cover** — see the next check.

### 7b. Build with `prebuilt/` moved aside — the only test of what users actually get

`_resolveLibDir` tries local `packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/<dir>/`, then the cache; its caller falls back to `_downloadAndExtract` from `native-v<version>`. The cache path is NOT version-scoped — staleness is decided by the marker file. **End users only ever reach the download** — `prebuilt/` is gitignored and ships in no pub package (confirm with `dart pub publish --dry-run | grep -ciE 'prebuilt|\.so$|\.dylib|\.dll'` → must be `0`).

On a maintainer machine the first source always hits. So every build you run locally — including check #7 and the release skill's `flutter build apk --release` pre-flight — silently validates **your** bundle and never touches the download, checksum verification, or extraction. Green means nothing about the artifact you are about to publish.

After the release exists and the hook's `checksums` are updated, force the real path:

```bash
mv packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt /tmp/prebuilt-aside
# Cache location is per-OS (_cacheBaseDir()). On the Windows NPU VM the macOS
# path wipes nothing and you silently re-test the cache instead of the download.
#   macOS   ~/Library/Caches/flutter_gemma/native
#   Linux   ~/.cache/flutter_gemma/native
#   Windows %LOCALAPPDATA%\flutter_gemma\native
rm -rf "$HOME/Library/Caches/flutter_gemma/native"     # kill the cache too, or you test source #2
cd packages/flutter_edge_ai/example && flutter clean && flutter pub get && flutter build apk --release
mv /tmp/prebuilt-aside packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt
```

Pack the tarballs **from the exact directory you device-tested**, so the published bytes match the verified bytes by construction rather than by coincidence.

This is the same failure shape as the frozen NPU dispatches: local state standing in for what goes out the door.

### 8. (App Store-bound builds) Frameworks/ structural check

After `flutter build ipa --release` or archive:

```bash
R=build/ios/iphoneos/Runner.app
ls "$R/Frameworks" | wc -l                                    # must be NON-ZERO
ls "$R/Frameworks" | grep -E 'LiteRtLm|LiteRtMetalAccelerator|GemmaModelConstraintProvider|StreamProxy'
find "$R/Frameworks" -maxdepth 1 -type l                      # must be empty
find "$R/Frameworks" -maxdepth 1 -name "*.dylib" -type f      # must be empty
```

If anything other than `.framework/` is in there, App Store will reject with ITMS-90432 ("Unexpected file found in Frameworks").

**Count the contents first — an empty `Frameworks/` passes every "must be empty" test.** `flutter build ios` can leave a half-assembled `Runner.app` behind: the Xcode phase reports `Xcode build done`, then flutter_tools dies cleaning up its own temp dir (`PathNotFoundException: Deletion failed … flutter_ios_build_temp_dir…`), and the frameworks are never embedded. The bundle exists, the two negative checks come back perfectly clean, and nothing distinguishes "compliant" from "nothing was built". Re-running the build fixes it; a healthy debug build of the example carries ~10 frameworks, four of them ours. Same failure shape as `nm` on a missing file — assert the positive before trusting the negative.

### 9. A tool call, on every platform you shipped

The litertlm smoke suite never passes a tool to a session, so nothing in checks
1–8 loads `libGemmaModelConstraintProvider`. That library is a Google prebuilt
you did not build, against a `Constraint` interface that lives in the runtime
you did — and when the two disagree, the first tool call segfaults in
`CompositeLogitMask::Apply`, with no Dart-side error and every other check
green. native-v0.17.0 shipped exactly that.

```bash
cd packages/flutter_edge_ai/example
flutter test integration_test/litertlm_native_tools_test.dart -d <device>
```

Six cases: FunctionGemma and Gemma 4, a manual round and the SDK loop, plus a
session switch. Each asserts the **text after the tool result**, not merely that
a call was parsed — a suite that stops at "a call was detected" stayed green for
months while the model was answering its own tool result by calling again.

Stage the four models first (`functiongemma-270M-it`, `mobile_actions_q8_ekv1024`,
`tiny_garden`, `gemma-4-E2B-it`) in the app documents dir, or in
`/data/local/tmp/flutter_gemma_test/` on Android.

The static pre-check, before any device is involved — the provider must carry
the type the runtime asks it for:

```bash
H=/tmp/LiteRT-LM/runtime/components/constrained_decoding/constraint.h
P=<prebuilt>/libGemmaModelConstraintProvider.dylib   # or .so / .dll — ONE file
if [ ! -f "$H" ] || [ ! -s "$P" ]; then
  echo "cannot check: need both $H and a non-empty $P"
elif [ "$(grep -q ComputeMask "$H" && echo 1 || echo 0)" \
     = "$(grep -q LogitMask "$P" && echo 1 || echo 0)" ]; then
  echo "provider ABI: source and provider agree"
else
  echo "MISMATCH — every tool call on that platform would segfault"
fi
```

Three things this shape is deliberate about: `grep` reads the binary directly
(`strings … | grep -q` exits at the first match and, under `set -o pipefail`,
the SIGPIPE makes the whole pipeline report failure — the guard then says "no
LogitMask" for every provider that has one); it names ONE file rather than a
glob, because a glob over a directory holding both a `.so` and a `.dylib`
answers for the union; and it prints rather than `exit`s, because you paste it
into your own shell.

Two-sided, and `-f` first, for the same reason the CI guard is: a provider
OLDER than the runtime segfaults, a NEWER one segfaults the same way from the
other side (which is what happens if you build an older ref while `PREBUILT_REF`
still points at main), and a `grep` on a missing header silently answers "no".

### 9b. 16 KB page alignment (Android) — Google finds this, not you

Google Play rejects an app when **any** `.so` in its APK has a `PT_LOAD`
`p_align` below 16 KB: *"Your app does not support 16 KB memory page sizes"*.
Play scans `lib/**/*.so` and does not care that a Hexagon blob is parsed by the
DSP rather than mapped by the kernel.

This is not hypothetical and it is not caught by anything else. `native-v0.17.0-a`
shipped four Qualcomm Skel blobs at `p_align=0x1000` — straight from the QAIRT
SDK, unchanged by us — and because `androidExtraLibs` puts them in every
consumer APK, every app shipping `flutter_edge_ai_litertlm` was rejected. The
build was green, every test passed, the manifest gate passed, and the report
came from a downstream app's store submission (#529).

`build_qualcomm_dispatch.sh` now raises `p_align` on the staged blobs (and
refuses when `p_vaddr` and `p_offset` are not congruent mod 16 KB, because a
bump there would produce a binary that does not load). `verify_tarball_manifest.sh`
asserts it for every ELF object inside every tarball. Read its output:

```
  [ok]   litertlm-android_arm64.tar.gz — 19 ELF object(s), all 16 KB-aligned
```

A run that reports 0 objects inspected has found nothing, not proven anything.
Google's own `check_elf_alignment.sh` is the second opinion if you want one.

### 9c. Every Android import is reachable through its own NEEDED

Bionic resolves a library's undefined symbols only through that library's own
`DT_NEEDED` chain — never through whatever else is already loaded in the
process, so preloading from the app cannot fix it. A `GLOBAL` import that misses
fails `dlopen`, which at least is loud. A `WEAK` one fails nothing: it binds to
NULL, `dlopen` succeeds, and the process jumps to address 0 the first time a
code path calls it — which may be one GPU vendor's path only.

That is #545. Upstream v0.17.0's `libLiteRtOpenClAccelerator.so` and
`libLiteRtGpuAccelerator.so` import `AHardwareBuffer_allocate/_release` weakly
with no `libandroid.so` in NEEDED. Adreno never calls them; Mali does, and
`engine_create` SIGSEGVs at pc 0. We shipped those bytes unchanged in three
releases, because the only Android GPU run was on an Adreno phone. #270 was the
same rule broken by a sampler (GLOBAL `LiteRtCreateEnvironment` without
`libLiteRtLm.so`), fixed then as a one-off — which is why it came back.

`check_android_needed.py` asserts the rule for every aarch64 library: each
import that some NDK platform stub or bundle library provides must have a
provider in the importer's NEEDED closure. `build_android.sh` runs it as step
8d, `verify_tarball_manifest.sh` runs it on the packed tarball. The fix, when it
fails, is `patchelf --add-needed` on the importer (steps 8b/8c), never an
allowlist. patchelf missing is a build error, not a warning.

It also asserts that every NEEDED entry is loadable at all — in the bundle, an
NDK platform library, or a vendor library the core manifest requests with
`<uses-native-library>` (`VENDOR` in the script; keep the two in step). The
symbol rule alone cannot see a NEEDED library that is simply absent: its
exports are unknown, so every symbol it would provide reads as "no known
provider" and is skipped. That is pitfall #18.

```
  [ok]   12 aarch64 libraries checked against API 35 stubs
```

12, not 15: since native-v0.18.0 the Android bundle no longer carries the three
Dawn-dependent companions (`libLiteRtGpuAccelerator.so`,
`libLiteRtWebGpuAccelerator.so`, `libLiteRtTopKWebGpuSampler.so`). Android GPU
is OpenCL only — the same as Google's `litertlm-android` AAR (one
`liblitertlm_jni.so` with ML Drift OpenCL linked in) and `litert-gpu` (only
`libLiteRtClGlAccelerator.so`). Do not "fix" the bundle by adding
`libwebgpu_dawn.so`: that puts `libLiteRtGpuAccelerator` first in
`gpu_registry`'s Android order, a path no shipped SDK uses.

### 10. NPU on real silicon — the only check that covers the dispatch libraries

Nothing in checks 1–8 touches NPU. Both dispatch libraries load only when `PreferredBackend.npu` is requested on matching hardware, so they need real devices:

- **Intel NPU** — LunarLake/PantherLake. Our access is the Intel Tiber box `pdx88-k0687` (see the `project_intel_npu_vm` memory): ssh over ngrok with the mandatory `-i ~/.ssh/flutter_gemma_win_v14`, `cmd.exe` shell, commands in the **foreground** (a detached task dies with the ssh session). The console entry is the reservation's **Connect** button (Guacamole). The model is not on HF — it lives on the box at `%USERPROFILE%\dev-gemma4-2b-lnl\gemma4_2b_lnl.litertlm`. Put the bundle under test in the checkout's `prebuilt/windows_x86_64/` (the hook reads it before the cache), then run the litertlm smoke suite with `--plain-name "NPU"` **on its own**: inside the full file the NPU group runs after GPU, and async WebGPU teardown blows the per-test timer on the first NPU `engine_create`. Reference numbers (0.15.2): `engine_create` ~1 s, ~54 chunks/s, greedy run1 == run2.
- **Qualcomm NPU** — Snapdragon 8 Gen 3 / 8 Elite. Ours is Qualcomm Device Cloud (QDC); the exact sequence is below.

The NPU group **skips** (and counts as passed) when its model file is absent, so a green run means nothing until the log shows `engine_create` on the NPU. Grep for it; a `[Gemma4 NPU] SKIP` line means the check did not run.

**Record the outcome here, every release** — device, date, pass count. The method was written down long before any result was, and a finished check kept reading as pending:

| Native | Qualcomm (QDC) | Intel (Tiber) |
|---|---|---|
| v0.15.2 | — | ✅ 18/18, Lunar Lake 258V, 2026-05-15 |
| v0.16.0 | ✅ 23/23, Snapdragon 8 Elite, 2026-08-15 | ⚠️ not recorded |
| v0.17.0 | ⏳ pending | ⏳ pending — Tiber gateway unreachable since 2026-09-18 |

Both are slow, awkward, and easy to skip. Skipping them is what shipped the two frozen dispatch libraries described above.

#### QDC and Android instrumentation, in the order that works

QDC gives you an SSH tunnel that forwards the **ADB server port (5037)**, not a device port. Consequences:

1. `adb kill-server` **first**, then open the tunnel. A local ADB server already holding `127.0.0.1:5037` makes ssh bind IPv6 only, and the symptom is a device list that is simply empty.
2. `nohup … & disown` — there is no `setsid` on macOS, and with it the tunnel never starts at all.
3. `flutter test -d <device>` **cannot work here.** It needs `adb forward` for the Dart VM Service, and with the server itself proxied the forward binds on the remote side. Use an Espresso instrumentation run instead.
4. Sessions are time-capped (100 min standard, 300 on request). A tunnel that stops responding mid-run is usually just an expired session — check that before debugging the transport.

The tunnel itself (key file and session host come from the QDC session page; the host changes per session — it was `sa762844`, then `sa763293`). The run on 2026-08-14 wrapped it in a small loop that re-spawns ssh when it drops:

```bash
adb kill-server
nohup ssh -i ~/Downloads/qdc_id_<date>.pem -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 \
  -L 5037:<session-host>.sa.svc.cluster.local:5037 -N sshtunnel@ssh.qdc.qualcomm.com > tunnel.log 2>&1 & disown
adb devices -l   # must list the QDC device; check ro.soc.model before anything else
```

The NPU model is SoC-specific and is not on the device: `gemma-4-E2B-it_qualcomm_sm8750.litertlm` (sm8750 = Snapdragon 8 Elite, QNN HTP V79, ~2.9 GB) from `litert-community/gemma-4-E2B-it-litert-lm`. `engine_create` rejects it on any other SoC. The QDC device has internet, so download it **on the device** — pushing 3 GB through the tunnel eats the session and drops (keep `adb push` with retries only as the fallback):

```bash
adb shell 'mkdir -p /data/local/tmp/flutter_gemma_test && cd /data/local/tmp/flutter_gemma_test && \
  curl -sL -o gemma-4-E2B-it_qualcomm_sm8750.litertlm \
  https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it_qualcomm_sm8750.litertlm'
```

Check first, before spending minutes: `getprop ro.soc.model` must say `SM8750` (platform `sun`). `/vendor/dsp/cdsp/` carries **no** `libQnnHtpV79Skel.so` even on Qualcomm's own reference image — that is why the bundle ships the Skel libraries itself.

Build **both** APKs with the test as the target, install both, and run the instrumentation (the app id and runner are in `example/android/app/build.gradle.kts`):

```bash
T=<absolute path to integration_test/litertlm_ffi_test.dart>
./gradlew app:assembleDebug -Ptarget="$T" app:assembleDebugAndroidTest -Ptarget="$T"
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
adb shell am instrument -w -r dev.flutterberlin.flutter_gemma_example.test/androidx.test.runner.AndroidJUnitRunner
```

`OK (N tests)` is the pass line. On v0.16.0 the first full pass was `Tests run: 23, Failures: 2`, and the rerun went `OK (23 tests)` — read the failures before rerunning.

Building the instrumentation APK: `flutter build apk` is **wrong**, it packs `main.dart`. The app APK must carry the test entrypoint:

```bash
cd packages/flutter_edge_ai/example/android
./gradlew app:assembleDebug -Ptarget=<absolute path to integration_test/xxx_test.dart>
```

Verify the entrypoint actually landed with **binary** grep — `strings` misses it in the compiled kernel blob:

```bash
grep -ac "<a string unique to the test file>" app/build/outputs/apk/debug/app-debug.apk
```

And beware the Espresso idle timeout: `Could not launch intent within 45000 ms` is usually not a broken test but app startup doing real work — ours was restoring a 3 GB active model, so the main thread never went idle. Clear app state, or start from a build that doesn't auto-restore.

### 10. Functional matrix — every platform, every native consumer

The bundle has **three** consumers — LLM inference (LiteRT-LM C API), embeddings and speech (LiteRT C API through hand-mirrored structs) — and a platform can break one while the others pass. Windows embeddings **and** speech were broken from native-v0.16.0 until 2026-09-18 while every Windows GPU and NPU run was green, because nobody ran them there (pitfall #16). Run all three everywhere:

| Suite | What it covers |
|---|---|
| `litertlm_ffi_test.dart` (full) | CPU + GPU text/streaming/vision/audio/thinking, chat, multi-session (several `engine_create` per process), embeddings (`Embedding non-blocking (#299)`) |
| `stt_moonshine_test.dart` | STT through the LiteRT C API (~104 MB model from HF) |
| `tts_smoke_test.dart` | Matcha TTS; compares against a golden (`rms 0.0781`, error < 1e-5 on every platform in v0.17.0) |
| `qwen3_tts_test.dart` | only when Qwen3 code changed (~1 GB download); macOS is enough |

Where and how, with the traps that cost time in the v0.17.0 cycle:

- **macOS** — local. The example's Podfile stager copies companions from the **cache** (`~/Library/Caches/flutter_gemma/native/macos_arm64/`), not from the build, so a maintainer machine runs a 0.16/0.17 mix. For the run, move the cache's `libGemmaModelConstraintProvider.dylib` aside (the stager picks its source by that one file and falls back to `prebuilt/`), restore it in a `trap`.
- **iOS device** — USB only (`ioreg -p IOUSB` must show `iPhone@…`; `transportType: localNetwork` ⇒ "Cannot start app on wirelessly tethered iOS device"). On Xcode 26+ `enable-lldb-debugging` must be `true`, otherwise flutter never sees the VM Service URL and hangs at "not discovered" (memory `project_ios_device_xcode26_lldb`). The simulator is CPU-only by design.
- **Android** — GPU/OpenCL needs real devices, and **at least one Adreno and one Mali**: Adreno and Mali take different paths through the same accelerator (#545 crashed only on Mali). On FTL: `e1q` (Galaxy S24, Adreno 750), `akita` (Pixel 8a, Mali-G715), `a34x` (Galaxy A34, Mali-G68 — the #545 device). Write codename + GPU per row in the PR body; "Galaxy S24" alone does not say which GPU ran. The `gemma_api36_arm64` emulator is enough for CPU speech.
- **Linux** — GCE `flutter-gemma-linux` (T4) and `flutter-gemma-linux-gpu` (L4, often stocked out in `us-central1-b`). The T4 box boots a mainline 6.16 kernel without the NVIDIA module (Vulkan falls back to `llvmpipe`); for GPU runs `kexec` once into `6.8.0-*-gcp`. Prove the GPU was used from throughput (T4: ~42 chunks/s GPU vs ~2.4 CPU), not from test names.
- **Windows** — Tiber for NPU + Arc; GCE `flutter-gemma-gpu` (T4) covers CPU, discrete-GPU WebGPU, embeddings and speech when Tiber is down. On GCE: Scheduled Task (`S4U`) + log polling, `powershell -EncodedCommand` for anything with `$`.

Put a worktree of the branch on each VM instead of switching its checkout, drop the CI artifact into `prebuilt/<platform>/`, and **prove provenance per run**: sha256 (Linux/Windows) or LC_UUID (Apple) of the libraries inside the built app against the artifact. Record the matrix in the PR body.

---

## Common pitfalls (regressions we already shipped)

| # | Bug | Caught by | Hit users in |
|---|---|---|---|
| 1 | iOS dylib built from `v0.10.2` (no Metal accelerator), EXC_BAD_ACCESS | Check #5 (patch markers absent) + iPhone smoke | dev session, never shipped |
| 2 | App Store ITMS-90432 — `lib*.dylib` symlinks in Frameworks/ | Check #8 | **0.14.0** |
| 3 | `dart:ffi` in web build — missing conditional import | `flutter build web --release` | **0.14.0** |
| 4 | `libGemmaModelConstraintProvider.dylib` headerpad too small | Check #2 + #4 + #7 | **0.14.1** |
| 5 | `lipo` "same architectures (arm64)" — Native Assets called twice for iOS | hook/build.dart `_prebuiltDirName` returns null for iOS x64 | dev session |
| 6 | upstream `libLiteRt.dylib` was x86_64 macOS binary in `prebuilt/ios_arm64/` (#2072) | Check #1 (`file`) | 5e0d86b commit (upstream bug, but we should detect on copy) |
| 7 | NPU dispatch stacks dropped from the tarballs — packed without them | Count per bundle before packing | **caught pre-publish** at v0.14.0 *and* v0.15.0 |
| 8 | LiteRT pin moved, `LiteRtCreateModelFromFile` 2→3 args → embeddings `status=500` | Header diff at both `LITERT_REF`s | v0.14.0 dev cycle, ~1 day lost |
| 9 | `RTLD_DEFAULT` undeclared on glibc — needs `_GNU_SOURCE` before every include | CI Linux job (macOS compiles it happily) | **caught in CI** at v0.15.0 |
| 10 | v0.15.0 changed `LiteRtLmStreamCallback` 4-arg → 2-arg, no compat overload | ACCESS_VIOLATION (Windows) / malformed UTF-8 (macOS) at first token | **caught pre-publish** at v0.15.0 |
| 11 | `--define=litert_link_capi_so=true` deleted upstream — inert, statically linked runtime → Windows GPU `engine_create` crash | Grep the define in the tree being built | v0.14.0 → v0.16.0, **misfiled upstream as #2957** |
| 12 | Intel NPU dispatch carried forward at OpenVino 2026.2.0 against a pin requiring 2026.3.0 | Build the dispatch from the pin; CI asserts the staged `openvino.dll` matches the SDK's `version.txt` | v0.11.0-b → v0.16.0, **misfiled upstream as #3217** |
| 13 | Qualcomm dispatch hardcoded to LiteRT `5c5b9ce6` — SIGSEGV in `LiteRtDestroyOptions`, and `-gcc-toolchain` when rebuilt | Derive `LITERT_REF` from WORKSPACE; check #9 on device | native-v0.12.0 → v0.16.0; rebuilt and **verified on Snapdragon 8 Elite via QDC** at v0.16.0 |
| 14 | Blanket copy of OpenVino `runtime\bin` ships debug DLLs (`openvinod.dll`) beside release | Explicit allow-list + `throw` on missing | caught pre-publish at v0.16.0 |
| 15 | QNN runtime libs left at an old QAIRT while the dispatch moved — `Qnn System library version 1.8.0 is mismatched` | Check #9 on device; compare file sizes against the SDK | native-v0.12.0 → v0.16.0, **caught on device** |
| 16 | Windows-only `LiteRtLayoutMsvc` mirror kept after LiteRT `d84656955` unified the layout — every host-memory tensor buffer got a shape 4 bytes off: `CreateTensorBufferFromHostMemory` `status=3` in embeddings and STT | Check #10 on Windows; struct diff at both `LITERT_REF`s | **native-v0.16.0 → fixed in `67b9857f`**; seen on Tiber 2026-08-10 and misread as a bad box cache |
| 17 | Upstream companion imports a symbol its NEEDED cannot reach: sampler without `libLiteRtLm.so` (#270, silent CPU fallback); v0.17.0 accelerators without `libandroid.so` (#545, SIGSEGV on Mali only) | Check #9c (`check_android_needed.py`); Android GPU on Adreno **and** Mali | #270: 0.14.x; **#545: native-v0.17.0 → v0.17.1**, upstream #3575 open six days before our first release |
| 18 | Three Android companions NEED `libwebgpu_dawn.so`, which the bundle never carried — `dlopen` fails, `gpu_registry` silently moves on to OpenCL, ~18 MB of unloadable code in every APK | Check #9c (now also asserts every NEEDED is loadable); compare against what Google's own AARs ship | **native-v0.14.0 → v0.17.x**, found by a Codex review at the v0.18.0 bump; fixed by dropping the three, not by adding Dawn |

Every one of those would have been caught by checks 1-10 before commit. **Run them all every time.**

Three patterns deserve emphasis because nothing in the build output hints at them:

- **#7, #12 and #13 are silent.** The tarball packs, the checksums verify, every smoke test on CPU/GPU passes. Only a user on `PreferredBackend.npu` finds out.
- **#8 and #10 are ABI drift, not code changes on our side.** C linkage means a stale call shape still links; you get register garbage instead of a compiler error. When a bump touches any callback or C-API signature, verify the shape at both refs rather than assuming source that compiles is source that's correct.
- **#11, #12 and #13 are the same organizational defect wearing three costumes.** Every one is an input we pinned once and stopped maintaining — a define, an SDK version, a commit SHA — that only misbehaves when upstream touches the code depending on it. Each surfaced at a version boundary and each was reported upstream before the real cause was found. **Before filing an upstream regression, list every input to the comparison and confirm which ones moved.** If one of them is ours and frozen, it is ours until proven otherwise.

---

## When upstream is broken

We import some dylibs as-is from upstream LiteRT-LM (`libGemmaModelConstraintProvider.dylib`, `libLiteRtMetalAccelerator.dylib`, sampler dylibs). When upstream ships them with insufficient headerpad / wrong arch / broken exports:

0. **Before adopting an upstream tag, read what is already reported against it.** `gh issue list --repo google-ai-edge/LiteRT-LM --search "created:>=<tag-date>"` and skim for crashes on platforms we ship. #545 was upstream #3575 — same crash, same BuildId, same `patchelf` workaround — open six days before our first release with those bytes.
1. **Rule out our own frozen inputs first.** Before writing the issue, enumerate every input to the failing comparison — defines, SDK versions, pinned SHAs, carried-forward binaries — and confirm which ones actually moved between the working and broken versions. Two of our four most recent upstream reports (#2957, #3217) were our configuration and had to be retracted; in both the "regression" was upstream finally exercising something we had frozen years earlier. A bisection that lands on a version boundary tells you *when*, never *whose*.
2. **File an issue with reproducer** — see `project_litertlm_upstream_*` memories for our open ones (#1990, #2072, #2073, #2080).
3. **Don't ship them blindly.** Run check #4 (install_name_tool smoke) on every upstream-sourced dylib **before** copying to `prebuilt/`. If it fails, **don't publish** — find a workaround first (relink, or ship without that lib + change Dart code path).
4. **Add a memory entry** documenting the bug + workaround in `~/.claude/projects/.../memory/project_*.md` so future sessions don't re-discover it.

---

## After successful build

1. **Run the verification checklist 1-10 above. All checks must pass.**
2. Do NOT try to commit the dylibs — `prebuilt/` is gitignored (`.gitignore` `**/packages/flutter_edge_ai_litertlm/native/litert_lm/prebuilt/`) and `git ls-files` returns nothing under it. The bundles reach users through the GitHub Release only; the working copy is yours alone. (This step used to say `git add prebuilt/<dir>/*.dylib`, which cannot succeed.)
3. Pack tarballs + update `hook/build.dart` `checksums` + re-upload to GitHub Release `native-v<version>` (see `release` skill).
4. Run `dart pub publish --dry-run` — must show 0 warnings.
5. Only then publish.

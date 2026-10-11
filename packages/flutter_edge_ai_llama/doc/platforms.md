# Platforms, capabilities and qualification

The connector targets Android, iOS, macOS, Windows, Linux and Web. A platform
runner or passing build establishes packaging, not every model/backend feature.
This package is an unpublished monorepo contribution; final maintainer ownership
and release approval remain pending.

## Runtime contracts

| Capability | Five native platforms | Web |
| --- | --- | --- |
| GGUF text, independent histories, cancellation | Implemented; one serialized runtime context | Implemented; worker/Wasm runtime |
| CPU inference | Baseline qualification lane | Baseline browser lane |
| GPU inference | Runtime/backend/driver dependent; explicit CPU fallback rejected | Browser/device dependent; unknown offload remains unknown |
| Tools and thinking | Implemented; compatible model/template required | Implemented; compatible template/grammar required |
| Embeddings | Implemented; trained embedding GGUF required | Implemented; bridge embedding capability required |
| Images/audio | Matching app-owned projector and capability probe required | Same; bridge/device memory constraints apply |
| LoRA | Implemented, exclusive turn ownership and fail-closed cleanup | Unsupported by pinned llamadart API |
| OPFS model handles | Not applicable | Unsupported; use cacheApi or network URLs |
| NPU, separate media encoder backend, engine-specific activation/rank controls | Unsupported by this GGUF adapter | Unsupported |

There is no fallback from strict tools to best-effort text. Runtime grammar
capability failures propagate as typed errors. CPU/GPU selection is a preference
passed to the runtime; verified zero offload is rejected for explicit GPU, while
unreported offload cannot prove either CPU or GPU execution.

## Automated gates

Current gates use Flutter **3.47.1 / Dart 3.13.1**, `flutter_edge_ai 2.2.0`,
`llamadart 0.11.1`, Apple runtime companion `0.0.21`, native llama.cpp artifacts `v0.5.0-2`,
and browser assets
`v0.1.54`. The browser manifest itself is SHA-256 pinned, and its asset checksums
are validated before staging and again in the final deployable artifact.

The checked-in workflows provide:

- VM/Chrome contracts, native-import and phone/desktop/keyboard widget tests,
  static analysis, formatting, tooling negative tests and package-content validation.
- Release builds for Android ARM64, unsigned iOS ARM64, macOS, Windows x64,
  Linux x64 and Web Wasm.
- Required real desktop CPU facade smokes: Linux VM, macOS/Windows packaged apps.
- Required packaged Linux/Windows, Android emulator and ARM64 iOS simulator CPU smokes:
  installation, two-turn memory, cancellation/retry, three load/close cycles.
- Real isolated Chrome worker/Wasm CPU generation from an installed model blob.

Small CPU fixture: `bartowski/SmolLM2-135M-Instruct-GGUF`, revision
`09816acd5d99df7be770d85ea30822623dab342c`, Q8_0, 144,811,360 bytes,
SHA-256 `5a1395716f7913741cc51d98581b9b1228d80987a9f7d3664106742eb06bba83`.
`tool/fetch_test_model.py` verifies bytes before reuse. Required lanes reject
absent fixtures instead of producing a successful skipped test suite.

```sh
python3 tool/verify.py contracts
# PR preparation against the matching local core:
python3 tool/verify.py package --core-path ../flutter_edge_ai
# Required before publication, after core 2.2.0 is published:
python3 tool/verify.py package
python3 tool/fetch_test_model.py
python3 tool/verify.py native --model-path tool/fixtures/chat.gguf
python3 tool/verify.py build --platform android
python3 tool/verify.py build --platform ios
python3 tool/verify.py build --platform macos
python3 tool/verify.py build --platform windows
python3 tool/verify.py build --platform linux
python3 tool/verify.py build --platform web
python3 tool/verify.py device --device <device-id> --model-url <immutable-gguf-url>
```

The package preparation lane stages the matching local core outside the archive,
keeps the exact hosted dependency constraint, and uses an excluded temporary
override. It validates archive contents and development dependency compatibility;
it does not establish hosted consumer resolution. The default `package` lane
uses hosted dependencies and remains required before publication. Core 2.2.0 is
not yet published at the time of this compatibility update.

The native lane uses a VM facade smoke on Linux and the packaged
three-cycle desktop smoke on macOS/Windows. A macOS hosted VM smoke timed out
without identifying its stalled operation; local VM inference passed. The CI
lane qualifies the application framework layout explicitly instead. That does
not establish the cause of the VM timeout. With these published pins,
`flutter_tester.exe` cannot reliably load the split Windows backend modules;
the app's executable-adjacent DLL layout works without an environment override.
The Windows lane requires the same fixture and strict memory/cancel/retry/close
assertions, and reports the packaged host explicitly rather than skipping.

Device file paths refer to the target filesystem. Prefer the model URL lane on
mobile devices. The Web test proxy runner currently requires Linux/macOS; the
connector itself also runs in browsers on Windows. For browser smokes:

```sh
python3 tool/serve_web_fixture.py --model-path tool/fixtures/chat.gguf
# In another terminal:
python3 tool/verify.py web --model-url http://127.0.0.1:8098/chat.gguf \
  --storage-helper-url http://127.0.0.1:8098/cache_api.js
```

Deploy the validated `example/build/web` directory with COOP `same-origin` and
COEP `require-corp`, including worker and Wasm responses. `_headers` is supplied
for hosts that recognize it; other hosts must configure equivalent response
headers. The test proxy only supplies Flutter test-server headers and does not
establish correct production hosting configuration.

## Consumer setup

The package is a Dart adapter: no extra native plugin implementation is needed.
Applications select llama.cpp in their own `hooks.user_defines.llamadart` map;
package-local hook settings are not a replacement for consumer settings.
For pub workspaces, these settings belong in the workspace root pubspec.
Use `llamadart_native_runtimes: [llama_cpp]`, as shown in the
[integration guide](../README.md#add-it-to-your-app). Without an app selection,
published llamadart defaults to llama.cpp plus LiteRT-LM wherever available;
registering the GGUF provider does not remove native assets at build time.
The pinned Flutter Edge AI core itself bundles no inference runtime, but
adding its separate LiteRT-LM engine package would bring that runtime back.
Apple Flutter apps also depend on the matching `llamadart_llama_cpp_flutter`
companion directly for SwiftPM linkage; omit `llamadart_litert_lm_flutter`
for a llama.cpp-only app. The example demonstrates these exact pins.

Example floors: Flutter 3.47.1, iOS 16.4, macOS 14.0, Android API 24.
The API floors do not prove oldest-device qualification. Android examples use
AGP 9.1.0 / Kotlin 2.4.0 / Gradle 9.3.1 (binary distribution), with Flutter's
legacy DSL/Kotlin compatibility flags for current native plugin dependencies.
The demo selects only CPU backends on Android, Linux and Windows to avoid
bundling unused GPU libraries. Consumers can opt into Vulkan/CUDA where
available through their own backend hook configuration; that requires
separate GPU qualification.
The example APK uses development signing; distribution needs the app owner's
release key. Windows deployment must include the matching Microsoft Visual C++
runtime required by the selected native artifact.

Native model picking copies files into application-support storage. This needs
space for the imported model; originals are preserved. The copy avoids a full
Dart model buffer and removes dependence on a picker permission after restart.
Multimodal projectors remain app-managed, and LoRA restart identity still needs
explicit reinstallation or `loraPath` under core 2.2.0.

## Local validation, 2026-10-11

These historical checks used core **2.1.3** and the other pinned dependencies above. The host is macOS ARM64,
Xcode 27; Chrome is 154. Logs are in the local task directory
`/tmp/flutter-edge-ai-research/`. Workflow definitions pass `actionlint`; the
initial GitHub matrix stopped at the core-version mismatch before runtime checks. Runtime smokes exercise the public Edge AI facade.

| Platform | Build evidence | Real runtime evidence | Remaining qualification |
| --- | --- | --- | --- |
| Android | ARM64 release APK PASS, 42.5 MB | ARM64 Pixel 9 Pro emulator, API 36, CPU: install plus three load/generate/memory/cancel/retry/close cycles PASS | Physical devices, API 24 floor, Vulkan, advanced model families |
| iOS | ARM64 simulator and unsigned ARM64 release builds PASS; release app 34.0 MB | iPhone 17 Pro simulator, iOS 26.4, CPU: same three cycles PASS | Physical devices, iOS 16.4 floor, GPU/advanced families |
| macOS | Release app PASS, 77.7 MB | CPU facade, 384-dimensional BGE embeddings, Qwen3 tools/thinking, LoRA/base alternation and verified Metal offload PASS | Oldest supported OS and broader device/model combinations |
| Web | Wasm release and final runtime-file integrity PASS | Installed blob → dedicated worker/Wasm nonempty CPU-requested generation PASS; resolved offload unreported | Hardware WebGPU and model-backed advanced features; hosting isolation configuration |
| Windows | GCE x64 release bundle PASS, 46.8 MB | Windows Server 2022 x64, Xeon CPU: packaged three-cycle memory/cancel/retry/close PASS with normal DLL lookup | Client Windows versions/architectures, GPUs and advanced model families |
| Linux | GCE x64 release bundle PASS, 50.3 MB | Ubuntu 24.04 x64, Xeon CPU: public facade plus packaged GTK/Xvfb three-cycle memory/cancel/retry/close PASS | Other distributions/architectures, GPUs and advanced model families |

CPU chat fixture is the immutable SmolLM2 model above. Native tools/thinking use
Qwen3-0.6B-Q8_0; embeddings use BGE-small-en-v1.5-Q8_0 (SHA in `development.md`); LoRA uses
stories15M_MOE-Q8_0 with moe_shakespeare15M. Media model evidence from the
original POC remains in [contributor checks](development.md); audio/vision were not rerun in this pass.

Current contract suite: 41 VM passes; 40 Chrome passes with three explicit skips
(two native LoRA tests and the separately required real Web fixture smoke);
seven demo/import tests; eight Python tooling tests. Formatting, static analysis
and workflow linting passed before migration. The former llamadart checkout
workspace preparation, 599-file format check, analyzer, platform boundaries and 26 focused package/pin/workspace
regression tests also passed. That root analyzer and archive excluded only this
connector at its former POC location. These are historical pre-migration checks;
monorepo validation must be recorded separately.
Package-content validation stages a standalone copy without workspace resolution
and checks hosted consumer dependencies. Three documented warnings are allowed
during contribution preparation; normal warning-free publication is a release gate.

Relevant logs: `final-contracts.log`, `final-native-facade.log`,
`final-native-capabilities.log`, `final-android-device-2.log`,
`final-ios-device.log`, `final-android-release-2.log`,
`final-ios-release.log`, `final-macos-release.log`, `final-web-release.log`,
`final-web-smoke.log`, `final-publish-validation.log`.

Android's first semantic smoke failed a differently worded prompt with the
135M-parameter fixture. Aligning the device prompt and system instruction with
the desktop smoke passed the same strict word-recall assertion on both mobile
simulators. No retry or weaker assertion is added to CI. Android release
validation initially encountered a stale integration-test plugin registration
when Flutter lanes ran concurrently; sequential regeneration/build passed.
Run lanes sequentially in a shared checkout. Only inactive task-generated build
outputs were removed to work around host disk pressure.

The Android CPU-only demo APK decreased from 68.9 MB to 42.5 MB (about 38%).
Archive inspection confirms it contains no Vulkan library. This is packaging
evidence, not an inference-speed benchmark. The connector still allows apps to
choose and qualify their own Android GPU backend configuration.

## GCE desktop validation, 2026-10-11

Linux ran on an isolated GCE `e2-standard-4` (4 vCPU, 16 GB), Ubuntu 24.04 x64,
Intel Xeon with AVX2. The public-facade CPU smoke and the packaged GTK/Xvfb
three-cycle lifecycle smoke passed. The latter passed again after selecting
only CPU libraries. The release bundle decreased from 103,071,811 to
50,265,789 bytes (about 51%); inspection confirms no Vulkan/CUDA libraries.
This measures packaging size, not inference speed or GPU capability.

Windows used a separate `e2-standard-4`, Windows Server 2022 Datacenter x64
(build 20348), Intel Xeon with four logical processors and Visual Studio 2022.
Its release bundle is 46,819,316 bytes, without Vulkan/CUDA libraries. The
packaged Win32 lifecycle smoke passed all three cycles using normal DLL lookup,
and the final `verify.py native` route repeated those checks successfully.
The standalone Windows package gate passed with the same three documented
warnings.
This does not establish client Windows, ARM64, GPU or advanced-family qualification.

The fresh Windows image initially lacked the trusted model-download issuer;
a verified PowerShell HTTPS HEAD request populated the normal trust chain,
after which Python's verified download passed the immutable fixture checksum.
The initial Flutter VM smoke could not discover CPU DLLs beside
`flutter_tester.exe`. An explicit directory override registered a CPU backend
but still failed model loading. Windows's required native lane therefore uses
the tested packaged desktop host; raw Flutter VM model inference remains
unqualified with these pins. SDK, package and runtime sources were not patched
or copied into SDK directories.

The working-tree source archive SHA-256 was
`1e5a9b892a0d545ea25069da0245f0e018abeaf576913b5d4125e6e7f89315fc`.
The final demo pubspec overlay SHA-256 was
`1dc22fb6fecb57d6f15cac146c2323b88d155c514fab2205b7ff6c8026a98e29`.
Runtime Dart sources and model fixture were unchanged by the packaging pass.
Logs and the checksummed Linux release artifact are retained under
`/tmp/flutter-edge-ai-gce/`: `edge-ai-run.log`, `edge-ai-cpu-run.log` and
`linux-release-cpu.tar.gz`. Windows evidence includes `windows-build.log`,
`windows-device.log`, `windows-native-final.log`, `windows-package.log`,
`ci-sdk.log` and `windows-release-cpu.tar.gz`. The two failed raw VM attempts
are retained in `qualification.log` and `windows-native.log`. Both task-created
VMs and their boot disks were deleted after evidence was preserved. The pre-existing unrelated GPU validation VM was left untouched.

Flutter's official release manifests and Linux stable SDK archive returned
HTTP 404 during setup. The exact upstream Git tag `3.47.1`, revision
`6655482ec06e547f90abf8ae7590466f4415978d`, bootstrapped successfully with
Dart 3.13.1 and engine `5d531788691ec3404cac0cee66ead4007b177363`.
The connector CI action now uses that same verified Git revision without
modifying downloaded SDK/runtime sources. The exact CI setup script also passed
under Windows Git Bash, including its native Windows PATH output. The GitHub workflow itself still requires an
actual run on the release revision.

## Monorepo migration validation, 2026-10-11

The contribution was prepared against upstream `90fa4e5e3d1bf16f12cd460c79b20197d6745068`
with Flutter 3.47.1 / Dart 3.13.1. Adapter `lib/` and Dart contract tests were
copied unchanged from the qualified POC; migration changes cover workspace,
metadata, example dependency resolution, tooling, CI and documentation.

- Root `flutter pub get`: PASS; pub regenerated the lockfile with four new
  hosted dependencies (`llamadart`, `archive`, `dinja`, `posix`).
- Connector format/analyze: PASS; VM 41, Chrome 40 plus three explicit skips,
  demo seven, and Python tooling nine tests passed.
- Root `flutter analyze packages/ --no-fatal-infos`: PASS with existing info
  diagnostics and no blocking warnings/errors.
- Root `tool/test_all.sh`: PASS; 2,594 tests passed and 38 explicitly skipped
  across 18 tested packages/examples. The speech example has no host tests.
- macOS ARM64 real CPU facade smoke: PASS; GGUF installation, generation,
  history, cancellation/retry and reload exercised through the workspace core.
- Real Chrome worker/Wasm smoke: PASS; installed GGUF generated a nonempty
  73-character reply. This remains CPU-requested evidence, not hardware WebGPU.
- Standalone package dry-run: PASS with the three documented warnings. It
  removes workspace resolution and checkout-only example overrides before
  resolving hosted consumer dependencies, so sibling paths cannot mask errors.
- New workflow `actionlint`, SDK action YAML and relative package doc links: PASS.
- User-guide polish: relative links/anchors and chat/embedding/tools/projector
  snippets pass analysis; a fresh external app resolves the documented local
  dependency setup. The pinned Jaspr 0.23.1 build generated all 25 pages,
  including `/docs/llama`; its content and browser layout were checked.
  Package-content validation retained only the three documented warnings.

Root formatting reports 100 files that are byte-identical to upstream HEAD;
none belongs to this contribution. The existing workflow treats its full-root
format check as non-blocking. Those files were not reformatted. The connector
and the changed website navigation file pass the pinned formatter.

These are local migration checks. The contribution revision still needs its
GitHub workflow run and independent review. Previous Android/iOS/GCE evidence
above is historical; those platforms were not rerun after the move. This
contribution is not a publication or a claim that every GPU/advanced feature
combination is qualified.

## Core 2.2.0 compatibility validation, 2026-10-11

The contribution includes upstream main `fb6f38d8b9d9f5345802bf4f9b0c44bf62f1d9e7`
and targets core 2.2.0 with the unchanged llamadart/runtime/SDK pins above.
Nullable sampling is resolved through core's shared family/thinking defaults.
The installed family reaches every session/chat path; chat overrides affect
sampling while user text remains unchanged. Invalid sampling fails before
replacing a usable legacy session.

Local macOS ARM64 checks:

- Connector format/analyze: PASS; VM 51, Chrome 50 plus three explicit skips,
  demo seven, and Python tooling 16 tests passed.
- Workspace analysis: PASS with 570 info diagnostics and no warnings/errors.
- Shipped skills: 46 Dart blocks and 115 inline references compiled without errors.
- Real macOS CPU facade: PASS for install, generation, two-turn recall,
  cancellation/retry and reload with the immutable SmolLM2 fixture.
- Documentation snippets, relative links/anchors and a fresh external app using
  the documented matching-core override: PASS.
- Package archive preparation against the staged matching core: PASS with the
  three documented preparation warnings and one explicit development-override hint.
  The archive retains hosted version constraints and excludes the overrides.
- Workflow lint and published runtime-asset contract checks: PASS.

A separate temporary macOS app identity passed the packaged three-cycle CPU
smoke with a checksum-verified loopback fixture installed into app-owned storage.
An isolated iPhone 17 Pro simulator on iOS 26.4 passed the same three cycles with
core 2.2.0 and the unchanged runtime pins. Hosted macOS VM and mobile failures
are being investigated; the local pass does not establish their cause. The
packaged smoke now prints each lifecycle stage. The SDK action explicitly enables
SwiftPM for consistent setup, although Flutter 3.47.1 already defaults it on.

Core 2.2.0 is not yet hosted on pub.dev. The default hosted `package` gate
correctly fails dependency resolution until that version is published; local
preparation is not publication qualification. Current-head GitHub platform and
model-backed jobs remain required. The full-workspace test count in the migration
section and earlier Android/iOS/GCE evidence belong to their stated older bases.

## Before a production release

1. Run every required workflow on the release revision. Do not count workflow
   definitions as passing platform evidence.
2. Qualify real Android/iOS devices for lifecycle, storage, memory pressure,
   permission/restart behavior and the CPU/GPU combinations being advertised.
3. Run model-backed tools, thinking, embeddings, vision, audio and LoRA checks
   for each platform/backend combination claimed as qualified. Native macOS
   has the original model-specific evidence in `development.md`; other combinations need
   their own evidence. Web hardware WebGPU and advanced families are open.
4. Review exact-pin compatibility shims against core's public extension APIs;
   retain bounded dependencies until the restore/identity/projector/tokenizer
   contracts are stable. Test migrations before widening dependency ranges.
5. Complete independent blocking QA, choose ownership/repository metadata and
   version, cut the changelog, then run normal publish validation with no
   unexplained warnings. Publication requires separate approval.

# Flutter Edge AI — Agent Instructions

# 🚨 CRITICAL RULES 🚨

## Rule 1: NEVER EDIT CODE WITHOUT EXPLICIT APPROVAL ⛔
- Always propose changes first, show diff/code, **WAIT FOR APPROVAL**
- Only after user says "yes"/"go ahead"/"ok" → apply changes

## Rule 2: NEVER USE `git checkout` ⛔
- Use Edit tool to manually revert changes. User manages git.

## Rule 3: GIT COMMITS & PR/ISSUE BODIES ⛔
- No "Co-Authored-By: Claude" or AI attribution/footers — in **commits, PR bodies, PR/issue comments, and release notes**
- This OVERRIDES the harness default that says "End PR bodies with 🤖 Generated with Claude Code" / "Claude-Session: …" — NEVER add those here, in any git-visible text
- Always use `--author="Sasha Denisov <denisov.shureg@gmail.com>"`

## Rule 4: NEVER HARDCODE SECRETS ⛔
- Use `String.fromEnvironment('KEY_NAME')` or `--dart-define=KEY=value`
- GitHub Push Protection blocks commits with secrets

## Rule 5: SEARCH ALL FILES ⛔
- Never use file extension filters unless explicitly requested
- Use `grep -rn "pattern" /path/ 2>/dev/null | grep -v node_modules | grep -v ".gradle/"`

## Rule 6: `flutter drive` ON NATIVE TARGETS ⛔
- Native targets (Android, iOS, macOS, Linux, Windows) integration tests ALWAYS use `flutter test integration_test/<file>.dart -d <device-id>` — `flutter drive` is forbidden as a workaround
- If `flutter test` hangs on "Dart VM Service was not discovered" or fails with "Cannot start app on wirelessly tethered iOS device", fix iPhone/macOS USB tunnel (Personal Hotspot off, iPhone USB enabled in Network settings, Trust dialog) — do NOT switch to `flutter drive` as a workaround
- **Exception: web** — Flutter SDK does NOT support `flutter test -d chrome/web-server` for `integration_test` (only `flutter test --platform chrome`, which is deprecated for app-level tests per Flutter docs). The **only** officially supported web integration test runner is `flutter drive --driver=test_driver/integration_test.dart --target=integration_test/<file>.dart -d chrome` (or `-d web-server` headless). On web `flutter drive` is the canonical Flutter-supported path, not a workaround — use it.

## Rule 6b: NO `setUp` IN A SUITE THAT RUNS UNDER `flutter drive` ⛔
- A `setUp`/`setUpAll` that THROWS under `flutter drive` is reported as **"All tests passed"**, exit 0 — not an error, not a skip. `package:integration_test` writes a result only from inside `runTest`, a failed setUp means `runTest` never runs, so the test is **absent** from the report — and absent reads as "no failure".
- **Measured, both ways.** `flutter drive` on `-d web-server`: green over a corpus that failed to insert. `flutter test integration_test/<file>.dart -d macos` with the same throwing setUp: `+0 -1: Some tests failed`, exit **1**. So the 40-odd native suites here are safe *because* Rule 6 keeps them off `flutter drive`; only the web ones are exposed.
- Put anything that can fail **inside the test body** (a guarded `_ensure…()` helper called first thing). `example/integration_test/rag_sqlite_web_parity_test.dart` and `litertlm_web_test.dart` are the pattern.
- This is not hypothetical: a web suite here was green twice over a corpus it had never inserted, and only a mutation of its expectations exposed it. If a `flutter drive` run says "All tests passed", confirm the suite is not empty before believing it.

## Rule 7: CHANGELOG ENTRIES ARE ONE LINE ⛔
- **ONE line per ISSUE**, not per change. A fix that touched nine things is still one bullet
- Every `## X.Y.Z` bullet must fit on a single short line (~10-15 words)
- No multi-sentence explanations, no embedded paragraphs in CHANGELOG.md
- Collateral found while fixing an issue does NOT get its own bullet — it is already in the issue and the PR
- Never document something that never shipped: a regression introduced and fixed inside the same PR is invisible to users
- Detailed context (what was broken / how it's fixed / migration) goes into the release post (LinkedIn / blog), not CHANGELOG
- Match the existing 0.15.x entries' brevity

---

## Project Overview

**Flutter Edge AI** — multi-platform Flutter plugin for running Gemma and other on-device LLMs (Qwen, DeepSeek, Phi, FastVLM, SmolLM, …) on Android, iOS, Web, macOS, Windows, Linux. Supports multimodal vision, function calling, thinking mode, GPU acceleration, LoRA weights.

## Architecture Quick Reference

### Core Principles
- **1.12 modular split** (monorepo, Dart pub workspace): core `flutter_edge_ai` owns model installation and inference/embedding/speech registries, but no engine and no RAG API. Engines/backends register through `FlutterEdgeAi.initialize(...)`. Independent `flutter_edge_ai_rag` instances own RAG orchestration and the vector-store contract; `flutter_edge_ai_qdrant` and `flutter_edge_ai_sqlite` depend on RAG and provide pluggable stores through `FlutterEdgeAiRag(providers:).open(...)`. Core never creates or disposes a `RagIndex`. The one intentional runtime-sharing edge remains `flutter_edge_ai_speech` → `flutter_edge_ai_litertlm`, because speech imports `LiteRtBindings` and consumes litertlm's native bundle.
- **`flutter_edge_ai_builtin_ai`** (opt-in): OS built-in AI engine — Gemini Nano via ML Kit GenAI/AICore (Android), Apple Foundation Models (iOS/macOS), Phi Silica via Windows AI Foundry (Windows) and the Chrome Prompt API (web). Since 0.3.0 a pure-Dart adapter over the external `flutter_local_ai` package, which owns every native layer; `flutter_local_ai` never depends on flutter_edge_ai. Registers via `inferenceEngines: [BuiltInAiEngine()]`; models use `ModelFileType.builtIn` (core has no file to install — the OS owns the weights).
- **`flutter_edge_ai_onnx`** (new, opt-in): ONNX Runtime engines — text generation via ORT-GenAI (`OnnxEngine`) + embeddings via plain ORT (`OnnxEmbeddingBackend`), both `dart:ffi` worker-isolate. `hook/build.dart` bundles native archives for macOS arm64, linux_x64, windows_x64, android_arm64 (ORT from Maven `onnxruntime-android`, genai from the `onnxruntime-genai` GitHub release), and iOS arm64 (device + Apple-Silicon sim slices from the single self-contained `onnxruntime-genai-ios` xcframework — ORT statically linked in, one binary exporting both `Oga*` and `OrtGetApiBase`, so no separate ORT and no co-location problem); `OnnxEngine.canHandle`/`OnnxEmbeddingBackend._isSupportedHost` are gated to **macOS arm64 + linux x64 + windows x64 + android arm64 + iOS arm64** (in lockstep with the hook table). All five arm/x64 hosts are **device-verified**: ORT-GenAI generation + embeddings run end-to-end (macOS ~54 tok/s M4 Pro, **Android ~10.4 tok/s Pixel 8 Pro FTL**, Linux ~5.3-5.8, Windows ~3.3 tok/s on the CPU test VMs; Phi-3.5-mini 3.8B int4 ≈3.74 GB peak RSS → needs a 6GB+ phone). On **iOS** the app builds, signs, installs and launches on a real iPhone, and the `@executable_path`-anchored dlopen resolves the framework + generation runs. **Co-location** (genai's bare-name `dlopen("libonnxruntime")` resolving to the sibling CodeAsset): macOS+Linux via the `ORT_LIB_PATH`/`dladdr` export in `gen_ai_client.dart` (`_exportOrtLibPath`, mac/linux only), **Windows + Android resolve on their own** (genai's self-directory dlopen finds the co-located lib under Flutter's flat CodeAsset layout), **iOS has no second lib** (ORT static in genai; the Dart loader opens the one framework via the `@executable_path/Frameworks/…framework/…` anchor iOS dyld 4 requires — bare `.framework` names don't resolve). `OnnxEngine.canHandle` declines + logs off-host; `OnnxEmbeddingBackend.canHandle` stays extension-based on every platform (so LiteRT's catch-all can't silently claim an `.onnx` file) and gates in `createModel` instead. ORT-GenAI model installs are a DIRECTORY (`genai_config.json` + `.onnx`[+`.onnx_data`] + tokenizer) — single-file network install doesn't cover this yet.
- **`flutter_edge_ai_diagnostics`** (opt-in, 0.1.0, contributed in #541 for #517): `MemorySnapshot(anonymousBytes, availableBytes, takenAt)` read from the OS — Android `Private_Dirty + SwapPss` (`/proc/self/smaps_rollup`) + `MemAvailable`; iOS `phys_footprint` (`task_info(TASK_VM_INFO)`, offset 144 / REV1 count 38) + `os_proc_available_memory()`. Pure `dart:io`/`dart:ffi`, no native code, **no dependency on core** (it measures the process, whichever engine runs in it). Android + iOS only; elsewhere `memorySnapshot()` throws `UnsupportedError`. A null field = the value does not exist on this platform/OS version; a failed read throws `MemoryReadException` — never collapse the two. Android GPU memory (KGSL/Mali/dmabuf) is mostly outside `anonymousBytes`.
- **Probe-chain registry**: `EngineRegistry`/`EmbeddingRegistry` select a provider by `canHandle(spec)` + `priority` (descending priority, ascending registration index). Engines are pure factories; core owns singleton lifecycle via `CloseNotifier`/`addCloseListener`.
- **ModelSource**: Type-safe sealed class (`NetworkSource`, `AssetSource`, `BundledSource`, `FileSource`). See `packages/flutter_edge_ai/lib/core/domain/`
- **Install vs Runtime separation**: Installation stores identity (modelType + fileType), runtime accepts config (maxTokens, backend, etc.) via `RuntimeConfig`
- **Engine selection by declared `ModelFileType`** (via `canHandle(spec)` — NOT by sniffing the file name): `task`/`binary` → MediaPipe, `litertlm` → LiteRT-LM, `builtIn` → BuiltInAi. `installModel` defaults `fileType` to `task`, so `.litertlm` must be declared explicitly or it is routed to MediaPipe
- **All five platforms (Android/iOS/macOS/Linux/Windows)**: Dart → `dart:ffi` → LiteRT-LM C API for inference and LiteRT C API for embeddings, both implemented in `flutter_edge_ai_litertlm`. `flutter_edge_ai_embeddings` contains tokenizer implementations only; it owns no native backend or bundle. Native prebuilts are fetched at build time from GitHub release `native-v0.17.1-a` (Native Assets). `flutter_edge_ai_litertlm/hook/build.dart` is the **sole** hook carrying the LiteRT native version; `flutter_edge_ai_speech` has no hook of its own and consumes the bundle through its direct litertlm dependency. The cycle-fix `stage()` in the hooks is **Apple-only** (Xcode `directoryTreeSignature` cycle; staging on Windows splits companion DLLs and hangs cancel/close).

### Supported Models

| Model Family | Function Calling | Thinking Mode | Multimodal | Platform Support |
|--------------|------------------|---------------|------------|------------------|
| Gemma 4 E2B/E4B | ✅ | ✅ ¹ | ✅ vision; audio on native | Android, iOS, Web, Desktop |
| Gemma3n E2B/E4B | ⚠️ Downloadable catalog: E4B `.litertlm` only; local E2B `.task` fixture also enables it | ❌ | ✅ vision + audio on native; Web text-only | Android, iOS, Web, Desktop |
| Gemma 3 1B | ❌ | ❌ | ❌ | Android, iOS, Web, Desktop |
| Gemma 3 270M | ❌ | ❌ | ❌ | Android, iOS, Web, Desktop |
| FastVLM 0.5B | ❌ | ❌ | ✅ vision | Desktop (`.litertlm`) |
| FunctionGemma 270M | ✅ | ❌ | ❌ | Android, iOS, Web, Desktop |
| Phi-4 Mini | ✅ | ❌ | ❌ | Android, iOS, Web, Desktop |
| DeepSeek R1 | ✅ | ✅ | ❌ | Android, iOS |
| Qwen3 0.6B | ✅ | ✅ ² | ❌ | Android, iOS, Web, Desktop |
| Qwen 2.5 (0.5B/1.5B) | ✅ | ❌ | ❌ | Android, iOS |
| SmolLM 135M | ❌ | ❌ | ❌ | Android, iOS |
| LFM2.5 230M | ❌ | ❌ | ❌ | Android, iOS, Desktop |

> ¹ Thinking Mode for Gemma 4: Android, iOS, Desktop only. MediaPipe Web has no thinking API, and the measured Web `.litertlm` path emits text but no thinking channel even though it receives the thinking configuration.
> ² Qwen3 generates tag-based thinking by default; core parses it platform-independently, including Web when the model emits the tags. Gemma 4's separate Web channel is not supported by the measured `.litertlm` path.

### Platform Limitations

| Platform | Vision/Multimodal | Audio | Embeddings | Notes |
|----------|-------------------|-------|------------|-------|
| Android | ✅ | ✅ | ✅ | Full support |
| iOS Device | ✅ | ✅ | ✅ | GPU via Metal delegate (FFI). No host-side Podfile `post_install` since 0.14.1 — accelerators load by full `@executable_path/Frameworks/<X>.framework/<X>` path; the old `lib*.dylib` symlinks caused ITMS-90432 (#245) |
| iOS Simulator | ❌ GPU | ❌ GPU | ✅ | CPU only — Metal sim has 256 MB single-allocation cap, LLM weights exceed |
| Web | ✅ MediaPipe | ❌ | ✅ | MediaPipe/LiteRT-LM use WebGPU; ONNX also provides CPU/WASM generation and embeddings |
| macOS | ✅ | ✅ LiteRT-LM only | ✅ | Vision + audio verified on Metal (Gemma 4 + Gemma 3n); Gemma 3n audio GPU is ~2× faster than CPU |
| Windows | ✅ | ✅ LiteRT-LM only | ✅ | Desktop via FFI; GPU via WebGPU/DX12 |
| Linux | ✅ | ✅ LiteRT-LM only | ✅ | Desktop via FFI; GPU via WebGPU/Vulkan |

### PreferredBackend

| Value | Android | iOS | Web | Desktop |
|-------|---------|-----|-----|---------|
| `cpu` | ✅ | ✅ | ✅ ONNX/WASM | ✅ |
| `gpu` | ✅ | ✅ | ✅ MediaPipe/LiteRT-LM | ✅ |
| `npu` | ✅ (.litertlm) | ❌ | ❌ | ✅ Windows (Intel LunarLake/PantherLake) |

## SDK Gotchas (Non-Obvious)

### ⚠️ maxTokens = CONTEXT window, not output length (#318)
`maxTokens` (on `getActiveModel`/`createModel`) is the whole **context window** — input (system + history + message) **plus** generated output, i.e. the KV-cache budget. It is **NOT** the response length. CPU/GPU `.litertlm` bundles bake a `kv_cache_max_len` (1024 for the supported bundles — Gemma 4 E2B, FunctionGemma, …); a `maxTokens` below it underflows the native magic-number KV-cache resize and `DYNAMIC_UPDATE_SLICE` fails to allocate tensors at generation (cryptic `Stream error: INTERNAL: …executor.cc:734`). Verified on Pixel 8a (CPU): 100/256/512 crash, 1024/4096 work.
- The litertlm engine **clamps `maxTokens` up to 1024 for CPU/GPU attempts** with an `edgeAiLog` warning (`clampLitertlmContextTokens` in `flutter_edge_ai_litertlm/lib/src/litert_lm_engine.dart`). It deliberately does **not** clamp `PreferredBackend.npu`: an NPU bundle has one compiled `cache_length`, and raising working Qualcomm configurations such as 896 to 1024 can make every prefill chunk after the first disappear without an error. The caller must use that bundle's required context size; if NPU falls back to GPU/CPU, the clamp is applied to the fallback attempt. MediaPipe `.task` also is not clamped.
- To cap **generation length**, use the new **`maxOutputTokens`** on `createSession`/`openSession` → native `set_max_output_tokens` (litertlm only; MediaPipe has no session-level output cap and logs that it's ignored).
```dart
// ❌ WRONG - meant "100-token reply", actually shrinks the context → crash on .litertlm
await FlutterEdgeAi.getActiveModel(maxTokens: 100);
// ✅ CORRECT - context stays 1024+, output is capped at 100
final model = await FlutterEdgeAi.getActiveModel(maxTokens: 1024);
final session = await model.createSession(maxOutputTokens: 100);
```

### ⚠️ Message.isUser defaults to false!
```dart
// ❌ WRONG - empty response (isUser defaults to false)
const Message(text: 'Hello')
// ✅ CORRECT
const Message(text: 'Hello', isUser: true)
```

### ⚠️ Always close sessions/models
```dart
await session.close();
await inferenceModel.close();
```

### ⚠️ No inline string keys — use PreferencesKeys constants
```dart
// ❌ BAD: prefs.getString('model_path');
// ✅ GOOD: prefs.getString(PreferencesKeys.installedModelFileName);
```
Exception: Migration files may use inline strings for deprecated keys.

### ⚠️ Always read SDK before implementing
Check `lib/flutter_edge_ai_interface.dart`, implementation files, and `example/` before making changes.

### ⚠️ Generated pigeon is `flutter_edge_ai_mediapipe/lib/pigeon.g.dart` — DO NOT EDIT MANUALLY
Core has NO pigeon (dropped at the 1.0 cut; its value types are hand-written in `lib/core/domain/platform_types.dart`). Only `flutter_edge_ai_mediapipe` still uses pigeon (it owns the `PlatformService` HostApi).

## Versions & Dependencies

- **Flutter**: `>=3.44.0` (raised at the 1.0 cut: `large_file_handler` 0.5.0 + dart2wasm need it).
  **Exception: `flutter_edge_ai_sqlite` declares `>=3.47.0`** — sqlite3 3.6.0, the first
  release whose web `flush()` awaits an in-flight write batch, requires `hooks ^2.2.0` →
  `record_use` → `meta ^1.19.0`, and every Flutter 3.44.x pins `meta` to 1.18.0 exactly.
  Under the old name, consumers on 3.44 resolve to flutter_gemma_rag_sqlite 1.3.2;
  `flutter_edge_ai_sqlite` has no release below 3.47. The **workspace dev floor is
  therefore 3.47** (`.fvmrc`, and the two `flutter-version`-pinned website workflows)
- **Dart SDK**: `>=3.12.0 <4.0.0`
- **iOS**: Minimum 15.0; **16.0 only with `flutter_edge_ai_mediapipe`** (MediaPipe GenAI). Core, litertlm, built-in AI and embeddings build from 15 (#441)
- **MediaPipe Web**: v0.10.29, Android/iOS: v0.10.33
- **LiteRT-LM**: native libs from `native-v0.17.1-a` GitHub Release (= `native-v0.17.1` plus the two Android GPU accelerators patched with `libandroid.so` in `DT_NEEDED` — without it Mali GPUs SIGSEGV at `engine_create`, #545; `build_android.sh` step 8d lints every import against its NEEDED chain). LiteRT-LM pin `5e58e9a0` = upstream v0.17.1, LiteRT pin `9fe5be45` unchanged since v0.17.0, companion prebuilts from upstream main `4453b286` — the v0.17.x tags carry a `libGemmaModelConstraintProvider` built against the pre-`ComputeMask` `Constraint`, so with a runtime built from their own source every tool call segfaults in `CompositeLogitMask::Apply`). v0.17.1: a tool-call argument declared `"type": "integer"` reaches the app as an integer instead of `1000.0`; the Android tarball's four Qualcomm Skel blobs are raised to `p_align=0x4000`, because at 4 KB Google Play rejects every app that ships them (#529). v0.17.0: the GPU samplers' `Create` gained a leading `runtime_c_api` argument (upstream refreshed the prebuilt samplers); `LiteRtLayout` has been one layout on every compiler since LiteRT `d84656955` (already in the v0.16.0 pin) — our Windows-only MSVC mirror broke Windows embeddings and speech from native-v0.16.0 until litertlm 1.7.0 dropped it. Android tarball bundles the Qualcomm QNN dispatch stack and Windows tarball bundles Intel NPU dispatch (`LiteRtDispatch.dll` + OpenVino runtime + TBB) for `PreferredBackend.npu` (Qualcomm Snapdragon / Intel LunarLake/PantherLake) — both dispatch libs are **rebuilt from the pin every release**; carrying them forward is what silently broke NPU on both platforms (see the `build-native` skill). v0.16.0: fixes the Android OpenCL per-turn memory leak (LiteRT-LM #2699, #348/#402); v0.15.0 **broke the stream-callback ABI** (4-arg → 2-arg chunk object) with no compat path, handled by a runtime probe in `stream_proxy.c`. Windows discrete GPU works again — the crash was our own dead `litert_link_capi_so` Bazel define, not an upstream regression (#2957 retracted).
- **sqlite-vec**: `flutter_edge_ai_sqlite` fetches the per-platform `vec0` loadable from the `native-sqlite-vec-v<X>` GitHub Release (`sqlite-vec-<target>.tar.gz` + `checksums_sqlite_vec.txt`), SHA256-verified by its `hook/build.dart`. `<X>` names the **upstream sqlite-vec release** the bytes were built from; a letter suffix (`0.1.9-a`) is only for RE-releasing changed bytes under an already-published number. The loadables are NOT committed — `native/sqlite_vec/prebuilt/` is a maintainer override produced by `build_local.sh`, gitignored and `.pubignore`d.
- **large_file_handler**: `^0.5.0` (core dep; 0.5.0 declares all 6 platforms — needed for pana platform support + the dart2wasm-clean web graph)
- **Current Version**: core `flutter_edge_ai` `1.12.0`, RAG `flutter_edge_ai_rag` `1.0.0`, `flutter_edge_ai_sqlite` `1.5.0`, `flutter_edge_ai_qdrant` `1.4.0`; `flutter_edge_ai_litertlm` `1.8.7`, `flutter_edge_ai_mediapipe` `1.0.9`, `flutter_edge_ai_embeddings` `2.2.2`, `flutter_edge_ai_speech` `0.5.3`; `flutter_edge_ai_agent` `0.2.7`, `flutter_edge_ai_builtin_ai` `0.3.1`, `flutter_edge_ai_onnx` `0.5.2`, `flutter_edge_ai_diagnostics` `0.1.0`; `genkit_flutter_edge_ai` `0.6.3`, `genkit_hybrid` `0.2.2`. The family shipped as `flutter_gemma*` up to core 1.11.3 / litertlm 1.8.5; the old names stay published as they are.
- **0.15.2**: embedding unified on LiteRT C API via Dart FFI on all native platforms (Android + iOS + Desktop). Drops `localagents-rag` JVM dep on Android and the separate TFLite C 0.12.7 tarball on Desktop; `TensorFlowLiteC` pod no longer needed on iOS. Single source of truth for `TaskType.prefix` in Dart, fixes cross-platform embedding drift (#264).

## Platform-Specific Setup

### iOS
```ruby
platform :ios, '15.0'   # 16.0 if the app uses flutter_edge_ai_mediapipe
use_frameworks! :linkage => :static
```
Entitlements needed: `extended-virtual-addressing`, `increased-memory-limit`

### Android
The core plugin manifest (`packages/flutter_edge_ai/android/src/main/AndroidManifest.xml`) declares these, plus `libcdsprpc.so` for the Qualcomm NPU, and the manifest merger folds them into every consumer app — apps add nothing (verified in the example's merged manifest):
```xml
<!-- libvndksupport.so is required for the GPU backend on Android 12+: the
     v0.13.x OpenCL loader uses its android_load_sphal_library() to dlopen the
     vendor OpenCL ICD. Without it OpenCL fails to load → WebGPU fallback →
     hard-freeze on some Mali drivers (#324). -->
<uses-native-library android:name="libvndksupport.so" android:required="false"/>
<uses-native-library android:name="libOpenCL.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-car.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-pixel.so" android:required="false"/>
```

- **The plugins do NOT apply KGP** (#440). `flutter_edge_ai` and `flutter_edge_ai_mediapipe`
  declare no `kotlin-android`, no `ext.kotlin_version`, no KGP classpath
  (`flutter_edge_ai_builtin_ai` has no `android/` at all since 0.3.0 — but its dependency
  `flutter_local_ai` DOES apply KGP itself and needs Kotlin 2.3.21, so an app using it
  cannot set `android.builtInKotlin=true`). Flutter's own Gradle plugin applies `kotlin-android` to any plugin subproject
  that doesn't (`FlutterPluginUtils.detectApplyingKotlinGradlePlugin`), which is what makes
  `flutter: '>=3.44.0'` load-bearing rather than cosmetic. Re-adding a version guard is the
  #323/#360 regression, not a fix. `android.builtInKotlin=true` fails on AGP 9 for any app
  that still has a plugin applying KGP itself — today nearly every app
  (`shared_preferences`, `background_downloader`). A bare `flutter create` app with no
  plugins builds fine. Not ours to fix; `false` is what Flutter's own migrator writes.
- **`flutter_edge_ai_builtin_ai` requires `minSdk 26`** (ML Kit GenAI / AICore floor, declared by `flutter_local_ai`) — apps using that package must raise their `android/app/build.gradle(.kts)` `minSdk` to 26 or the manifest merger fails (`uses-sdk:minSdkVersion` conflict).

### Web
```html
<script type="module">
import { FilesetResolver, LlmInference } from 'https://cdn.jsdelivr.net/npm/@mediapipe/tasks-genai@0.10.29';
window.FilesetResolver = FilesetResolver;
window.LlmInference = LlmInference;
</script>
```

### Desktop (macOS/Windows/Linux)
- Architecture: Dart → `dart:ffi` → LiteRT-LM C API (no JVM, no gRPC)
- Native libs fetched at build time by `flutter_edge_ai_litertlm/hook/build.dart` (the only hook that carries the version) from the `native-v0.17.1-a` GitHub release; SHA256-verified, bundled via Native Assets
- LiteRT-LM on desktop uses `.litertlm` format (not `.task`). The opt-in ONNX
  engine instead installs a directory (`genai_config.json`, model and tokenizer)
  on macOS arm64, Linux x64 and Windows x64.
- Windows GPU requires `dxil.dll` + `dxcompiler.dll` (DirectXShaderCompiler runtime) — bundled in the Windows native archive
- Windows NPU (`PreferredBackend.npu`) requires Intel LunarLake/PantherLake silicon — `LiteRtDispatch.dll` + OpenVino runtime + TBB bundled in the Windows native archive (0.15.1+)

macOS entitlements: `network.client` (model download) and `cs.disable-library-validation` (takes effect under Hardened Runtime, which notarization requires — the stager signs LiteRT-LM ad hoc). The iOS `kernel.*` memory entitlements do NOT exist on macOS: without a signing team they fail the build, with a team Xcode drops them.

## Code Quality

```bash
flutter analyze packages/   # every workspace package (not website/ — it is
                            # outside the workspace, so its deps are unresolved)
dart format .
tool/test_all.sh     # every package, each from its own directory
```

> `flutter test` at the root tests **nothing** (the workspace root has no
> `test/`), and `flutter test packages/<pkg>` runs from the wrong working
> directory — 20 of `flutter_edge_ai_agent`'s suites read fixtures by a path
> relative to the package and fail on a missing file. `tool/test_all.sh` is
> what CI runs, so local green and CI green mean the same thing.

> ⚠️ **A green local `analyze` does not mean CI is green.** CI installs
> `channel: stable` (whatever is current), while a dev box is usually pinned —
> so CI's analyzer carries lints yours does not. `unawaited_return_in_try_block`
> reached CI months before a 3.44.0 checkout could see it. Warnings fail the
> build (`--no-fatal-infos` only spares `info`), so read the CI log rather than
> trusting the local run.
>
> Analyze `packages/`, not the repo root: `website/` is deliberately outside the
> workspace, its deps are never resolved by the root `pub get`, and analyzing it
> fails — except on a machine that happens to have built the site once.

## Before Committing
```bash
flutter analyze && dart format . && tool/test_all.sh
```

## Key Files

> **1.0 monorepo:** paths below are under `packages/<pkg>/`. The repo is a Dart
> pub workspace (root `pubspec.yaml` `workspace:` list); core = `flutter_edge_ai`,
> engines/RAG = opt-in sibling packages.

**Core (`packages/flutter_edge_ai/`):**

| File | Purpose |
|------|---------|
| `lib/flutter_edge_ai_interface.dart` | Abstract InferenceModel / EmbeddingModel / Session + CloseNotifier seam |
| `lib/core/api/flutter_edge_ai.dart` | `FlutterEdgeAi.initialize/getActiveModel/installModel/installEmbedder/reset/dispose` |
| `lib/core/message.dart` | Message class (isUser gotcha) |
| `lib/core/domain/` | ModelSource sealed classes |
| `lib/core/registry/{inference_engine_provider,embedding_backend_provider,engine_registry,embedding_registry,runtime_config}.dart` | Probe-chain registry contracts engines/backends implement |
| `lib/core/lifecycle/close_notifier.dart` | `CloseNotifier` mixin (addCloseListener / fireCloseListeners) |
| `lib/core/embedding/` | The embedding seam engines implement: `EmbeddingForwardPass` + `ForwardResult` + `ForwardPassDescriptor`, the `EmbeddingTokenizer` adapter, `meanPoolAndNormalize`, and the isolate worker behind `CommonEmbeddingModel` — tokenizer IMPLEMENTATIONS stay in `flutter_edge_ai_embeddings`. Plus two pieces core OWNS rather than exposes: `EmbedderCache` (cached embedder + its params as one field, the reuse rule, and the lane serialising the entry point — each shell holds one instead of its own hand-rolled model/params bookkeeping) and `noticeEmbedderBackendIgnored` (says once per isolate that `preferredBackend` reached nothing; debug-only, so `EmbeddingModel.activeBackend` is the release answer) |
| `lib/core/registry/embedding_tokenizer_{provider,registry}.dart` | Probe chain for tokenizers, so an engine asks for one instead of naming one (which is what made it depend on a sibling package) |
| `lib/mobile/flutter_edge_ai_mobile.dart` | Mobile shell — registry-dispatch createModel + EmbeddingModelSpec |
| `lib/web/flutter_edge_ai_web.dart` | Web shell — registry-dispatch |
| `lib/desktop/flutter_edge_ai_desktop.dart` | Desktop shell — registry-dispatch |
| `lib/web/web_model_source.dart`, `web_model_manager.dart` | Public shared web infra (imported by litertlm-web + mediapipe-web) |
| `lib/core/domain/platform_types.dart` | Plain-Dart `PreferredBackend` and `ActivationDataType`. Core has NO pigeon/PlatformService; only `flutter_edge_ai_mediapipe` owns a Pigeon bridge. |
| `hook/build.dart` | Native Assets hook — empty bundle list (core owns no native lib) |
| `android/src/.../FlutterEdgeAiPlugin.kt`, `{ios,macos}/flutter_edge_ai/Sources/flutter_edge_ai/FlutterEdgeAiPlugin.swift` | Slim native plugin — hosts only the `flutter_gemma_bundled` channel (file-ops + litertlm NPU `getNativeLibraryDir`) |
| `example/lib/gemma_bootstrap.dart` | Single source of truth for the example's engine/backend lists + RAG switcher |
| `example/lib/models/model.dart` | Model configurations & URLs |

**`packages/flutter_edge_ai_litertlm/` (.litertlm FFI inference; owns the shared libLiteRtLm bundle):**

| File | Purpose |
|------|---------|
| `lib/src/litert_lm_engine*.dart` | `LiteRtLmEngine` (InferenceEngineProvider; native + web arms via conditional export) |
| `lib/src/embedding/web/`, `web/*.js`, `tool/web_build/` | The LiteRT.js embedding bundle — `WebEmbeddingModel`, `LiteRtWebRuntime` (WASM runtime URL, pinned `@litertjs/core`) and the vite build that emits all four JS files. Moved here in 1.8.0: it is LiteRT, and keeping it beside the engine is what removes the sibling dependency |
| `lib/src/ffi/litert_lm_client.dart` | Per-platform FFI client (loading, preload, log capture) |
| `lib/src/ffi/litert_lm_bindings.dart` | Generated dart:ffi bindings to LiteRT-LM C API (inference) |
| `lib/src/ffi/ffi_inference_model.dart` | FFI inference model (mixes CloseNotifier) |
| `lib/src/web/litert_lm_web*.dart` | Web `.litertlm` via `@litert-lm/core` (Engine handshake) |
| `hook/build.dart` | Native Assets hook — OWNS the litertlm bundle; `stage()` is **Apple-only** (Xcode cycle) |
| `native/litert_lm/{build_ios.sh,patch_c_api.sh,stream_proxy.c}` | iOS dylib rebuild + C API patcher + preload helper |

**`packages/flutter_edge_ai_embeddings/` (tokenizer implementations — 2.2.2; depends ONLY on core, and NOTHING depends on it: engines get a tokenizer from core's registry, which the app fills from here):**

| File | Purpose |
|------|---------|
| `lib/src/tokenizer_provider.dart` | `GemmaEmbeddingTokenizers` — the registrable `EmbeddingTokenizerProvider` an app passes to `initialize(embeddingTokenizers:)` |
| `lib/src/tokenizer_router.dart` | `resolveEmbeddingTokenizer` — sniffs the tokenizer file and routes WordPiece / SigLIP2-refusal / SentencePiece (moved from `flutter_gemma_onnx`; never was ONNX-specific) |
| `lib/src/wordpiece_tokenizer_json.dart` | The WordPiece `tokenizer.json` parse step, split out so it carries no `dart:js_interop` and stays VM-testable |
| `lib/src/embedding_tokenizer.dart` | Gemma SentencePiece tokenize + BOS=2/EOS=1 + TaskType prefix (`.json`/`.model` loader) |
| *(no engine dep, no `hook/build.dart`, no `web/`)* | The seam, worker, pooling and facade moved to core’s `lib/core/embedding/` in 1.9.0; the LiteRT.js web bundle moved to the litertlm package in `flutter_gemma_litertlm` 1.8.0 |

**`packages/flutter_edge_ai_mediapipe/` (.task MediaPipe; mobile + web, NO desktop):**

| File | Purpose |
|------|---------|
| `lib/src/mediapipe_engine*.dart` | `MediaPipeEngine` (io/mobile + web arms); `_mapBackend` core↔package PreferredBackend |
| `pigeon.dart` | Package pigeon: `PlatformService` HostApi + redeclared `PreferredBackend` |
| `android/src/.../FlutterEdgeAiMediaPipePlugin.kt`, `PlatformServiceImpl.kt`, `engines/*` | Android MediaPipe (own pluginClass + channel) |
| `ios/Classes/FlutterEdgeAiMediaPipePlugin.swift`, `PlatformServiceImpl.swift`, `InferenceModel.swift` | iOS MediaPipe |

**`packages/flutter_edge_ai_rag/` (instance-scoped RAG orchestration and provider contracts):**

| File | Purpose |
|------|---------|
| `lib/src/flutter_edge_ai_rag.dart` | `FlutterEdgeAiRag` provider registry and `open()` validation |
| `lib/src/rag_index.dart` | Owned `RagIndex` lifecycle, text/vector operations and concurrency gate |
| `lib/src/embedding.dart` | `EmbeddingProfile`, custom `RagEmbedder`, and borrowed active-core adapter |
| `lib/src/{vector_store,vector_store_provider,filter}.dart` | Store/provider contracts and backend-neutral filter DSL |

**`packages/flutter_edge_ai_qdrant/` (native RAG via the official `qdrant_edge` UniFFI SDK; no web):**

| File | Purpose |
|------|---------|
| `lib/src/qdrant_vector_store.dart` | `QdrantVectorStore` (VectorStoreRepository) |
| `lib/src/{qdrant_edge_client,point_id_hasher,filter_codec}.dart` | thin wrapper over the `qdrant_edge` SDK + UUIDv5 hasher + Filter codec |
| *(no `hook/build.dart`, no `native/`)* | 1.3.0: the engine and its Native Assets hook moved to the `qdrant_edge` SDK |

**`packages/flutter_edge_ai_sqlite/` (first-class SQLite vector store — in-SQLite `sqlite-vec`/`vec0` KNN on all 6 platforms):**

| File | Purpose |
|------|---------|
| `lib/src/{sqlite_vector_store,web_sqlite_vector_store}.dart` | `SqliteVectorStore` (native, `package:sqlite3` FFI) / `WebSqliteVectorStore` (web, `package:sqlite3/wasm.dart`) — both on `vec0` |
| `lib/src/filter_to_vec0.dart` | `Filter` DSL → vec0 declared-column SQL `WHERE` + binds (one dialect, both arms) |
| `hook/build.dart` | Native Assets hook — fetches the per-platform `vec0` loadable extension |
| `web/rag/sqlite3.wasm` | custom `sqlite3.wasm` with `sqlite-vec`/`vec0` statically linked (app copies to its web root) |

**`packages/flutter_edge_ai_builtin_ai/` (OS built-in AI; pure Dart since 0.3.0 over `flutter_local_ai` ^0.2.1 — Gemini Nano on Android and desktop Chrome via the Prompt API, Apple Foundation Models on iOS/macOS, Phi Silica on Windows; no Linux):**

| File | Purpose |
|------|---------|
| `lib/src/builtin_ai_engine.dart` | `BuiltInAiEngine` (InferenceEngineProvider; `canHandle` matches `ModelFileType.builtIn`) |
| `lib/src/builtin_ai_model.dart` | `BuiltInAiModel` (InferenceModel over a `LocalAiModel`; `localAiModel` escape hatch is `@experimental`) |
| `lib/src/builtin_ai_session.dart` | `BuiltInAiSession` (InferenceModelSession over a `LocalAiSession`; `localAiSession` is `@experimental`) |
| `lib/src/availability.dart` | `BuiltInAi` (availability probe + `ensureReady`; Linux answers `unavailableDeviceUnsupported` itself) |
| `lib/src/availability_types.dart` | `BuiltInAiAvailability` / `BuiltInAiUnavailableException` — typedef aliases of the `LocalAi*` types |
| `lib/src/builtin_ai_models.dart` | `BuiltInAiModels.geminiNano` / `.appleFoundationModels` / `.windowsAiFoundry` / `.chromePromptApi` specs, plus `all` and `forCurrentPlatform` (null on Linux) |
| *(no `android/`, `darwin/`, pigeon or `flutter: plugin:` block)* | The native layer (ML Kit, FoundationModels, Windows AI Foundry, Prompt API) lives in `flutter_local_ai`; macOS apps need a 12.0 deployment target because of it |

**`packages/flutter_edge_ai_onnx/` (ONNX Runtime — ORT-GenAI inference + plain-ORT embeddings on macOS arm64 / Linux x64 / Windows x64 / Android arm64 / iOS arm64; web via Transformers.js + onnxruntime-web):**

| File | Purpose |
|------|---------|
| `lib/src/onnx_engine.dart` | `OnnxEngine` (InferenceEngineProvider; platform-gated `canHandle` + belt-and-suspenders `createModel` guard) |
| `lib/src/onnx_inference_model.dart`, `onnx_session.dart` | `OnnxInferenceModel` (singleton-session lane) / `OnnxSession` (buffers query chunks, drives `GenAiClient.generate`) |
| `lib/src/ffi/gen_ai_client.dart` | `GenAiFfiClient` — worker-isolate ORT-GenAI FFI client (mutex-serialized generate/countTokens; `ORT_LIB_PATH` co-location fix) |
| `lib/src/ffi/gen_ai_protocol.dart` | Isolate message protocol (src-only, not barrel-exported) — the injection seam for a scripted fake worker in tests |
| `lib/src/embedding/onnx_embedding_backend.dart` | `OnnxEmbeddingBackend` (EmbeddingBackendProvider; priority 10 over LiteRT's catch-all 0) |
| `lib/src/embedding/{ort_client,ort_ffi_client,onnx_embedding_forward_pass}.dart` | Plain ORT C API FFI client + forward pass (WordPiece/SentencePiece, `pooledFinal`/`tokenLevel` contracts) |
| `hook/build.dart` | Native Assets hook — owns the ORT + ORT-GenAI CodeAssets, sourced from Microsoft's own releases (not a `native-vX` repo tag); `_archivesFor` covers macOS arm64, Linux x64, Windows x64, Android arm64 (AARs), and iOS arm64 device + Apple-Silicon simulator (self-contained xcframework) |

**`packages/flutter_edge_ai_diagnostics/` (memory diagnostics; Android + iOS; no native code, no core dependency):**

| File | Purpose |
|------|---------|
| `lib/src/diagnostics_io.dart` / `diagnostics_stub.dart` | `FlutterEdgeAiDiagnostics.isSupported` / `memorySnapshot()` — conditional export on `dart.library.ffi`; the stub keeps the web graph dart:io/ffi-free |
| `lib/src/memory_snapshot.dart` | `final class MemorySnapshot` — per-platform meaning of each field; new fields must stay optional/nullable |
| `lib/src/android/proc_memory.dart` | `/proc/self/smaps_rollup` + `/proc/meminfo` parsers; only `PathNotFoundException` on a documented-optional file maps to null |
| `lib/src/ios/mach_memory.dart` | `task_info(TASK_VM_INFO)` → `phys_footprint` and `os_proc_available_memory()` via `DynamicLibrary.process()` |
| `lib/src/memory_read_exception.dart` | `MemoryReadException` — a read that should have worked and failed |

## Project Structure

```
flutter_edge_ai/                     # Dart pub workspace (monorepo root)
├── pubspec.yaml                     # root: workspace: [packages/*] + melos config
├── packages/
│   ├── flutter_edge_ai/               # CORE — no engine; registry, contracts, shells, slim native plugin
│   │   ├── lib/{core,mobile,web,desktop}/   # registry-dispatch shells + contracts
│   │   ├── android/ ios/ windows/   # slim native plugin (bundled channel only)
│   │   ├── hook/build.dart          # empty bundle list
│   │   └── example/                 # example app + integration tests + MIGRATION.md/README.md
│   ├── flutter_edge_ai_litertlm/      # .litertlm FFI (owns libLiteRtLm) + native/litert_lm/ build scripts
│   ├── flutter_edge_ai_embeddings/    # tokenizer implementations only; no engine or native bundle
│   ├── flutter_edge_ai_mediapipe/     # .task MediaPipe (own pigeon + Kotlin + Swift + web JS)
│   ├── flutter_edge_ai_rag/           # instance-scoped RAG orchestration + contracts
│   ├── flutter_edge_ai_qdrant/    # native RAG (official qdrant_edge UniFFI SDK)
│   ├── flutter_edge_ai_sqlite/    # SQLite RAG — in-SQLite vec0 KNN (native sqlite3 FFI + web wasm)
│   ├── flutter_edge_ai_builtin_ai/    # OS built-in AI over flutter_local_ai — Gemini Nano / Apple FM / Phi Silica / Chrome Prompt API
│   ├── flutter_edge_ai_onnx/          # ONNX Runtime — native arm64/x64 hosts + Transformers.js/ORT Web
│   ├── flutter_edge_ai_diagnostics/   # opt-in memory diagnostics (anonymous footprint + available memory, Android + iOS; no core dependency)
│   ├── flutter_edge_ai_speech/        # opt-in on-device STT (moonshine) + TTS (Matcha) via LiteRT C API (shares libLiteRtLm)
│   ├── flutter_edge_ai_agent/         # opt-in on-device agent skills (SKILL.md: text/JS/native-intent/MCP) over the function-calling loop
│   ├── genkit_flutter_edge_ai/        # Firebase Genkit integration (flutter_edge_ai runtime + converters)
│   └── genkit_hybrid/               # Genkit hybrid on-device + cloud helpers
└── docs/                            # design docs, testing, benchmarks
```

## Repository

- **GitHub**: https://github.com/DenisovAV/flutter_edge_ai
- **Pub.dev**: https://pub.dev/packages/flutter_edge_ai
- **Issues**: `gh issue list --repo DenisovAV/flutter_edge_ai --state open`
- **Changelog**: See `CHANGELOG.md`

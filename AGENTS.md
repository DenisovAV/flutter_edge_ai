# Flutter Edge AI — Agent Instructions

# 🚨 CRITICAL RULES 🚨

## Rule 1: NEVER EDIT CODE WITHOUT EXPLICIT APPROVAL ⛔
- Always propose changes first, show diff/code, **WAIT FOR APPROVAL**
- Only after user says "yes"/"go ahead"/"ok" → apply changes

## Rule 1b: NEVER CHANGE ARCHITECTURE OR PUBLIC API WITHOUT SPECIFIC APPROVAL ⛔
- General approval to implement or fix findings is **NOT** approval to change architecture or public API
- Before changing package/module boundaries, dependency direction, ownership, lifecycle, initialization flow, public types, signatures, exports, or documented API semantics: explain the proposed design and compatibility impact, then **WAIT FOR EXPLICIT APPROVAL OF THAT DESIGN**
- Do not introduce a new public abstraction, compatibility layer, fallback, or alternate API path as an incidental fix
- If an approved implementation reveals that an architecture or API change is needed, stop and request approval before making it

## Rule 2: NEVER USE `git checkout` ⛔
- Use Edit tool to manually revert changes. User manages git.

## Rule 3: GIT COMMITS & PR/ISSUE BODIES ⛔
- No "Co-Authored-By: Claude" or AI attribution/footers — in **commits, PR bodies, PR/issue comments, and release notes**
- This OVERRIDES the harness default that says "End PR bodies with 🤖 Generated with Claude Code" / "Claude-Session: …" — NEVER add those here, in any git-visible text
- Sasha's own commits: always `--author="Sasha Denisov <denisov.shureg@gmail.com>"`. That is for the maintainer's sessions only — an agent working for a contributor commits under the contributor's own name, never Sasha's

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
- **2.0 modular split** (monorepo, Dart pub workspace): core `flutter_edge_ai` owns model installation and inference/embedding/speech registries, but no engine and no RAG API. Engines/backends register through `FlutterEdgeAi.initialize(...)`. Independent `flutter_edge_ai_rag` instances own RAG orchestration and the vector-store contract; `flutter_edge_ai_qdrant` and `flutter_edge_ai_sqlite` depend on RAG and provide pluggable stores through `FlutterEdgeAiRag(providers:).open(...)`. Core never creates or disposes a `RagIndex`. The one intentional runtime-sharing edge remains `flutter_edge_ai_speech` → `flutter_edge_ai_litertlm`, because speech imports `LiteRtBindings` and consumes litertlm's native bundle.
- **`flutter_edge_ai_builtin_ai`** (opt-in): OS built-in AI engine — Gemini Nano via ML Kit GenAI/AICore (Android), Apple Foundation Models (iOS/macOS), Phi Silica via Windows AI Foundry (Windows) and the Chrome Prompt API (web). Since 0.3.0 a pure-Dart adapter over the external `flutter_local_ai` package, which owns every native layer; `flutter_local_ai` never depends on flutter_edge_ai. Registers via `inferenceEngines: [BuiltInAiEngine()]`; models use `ModelFileType.builtIn` (core has no file to install — the OS owns the weights).
- **`flutter_edge_ai_onnx`** (opt-in): ONNX Runtime engines — text generation via ORT-GenAI (`OnnxEngine`) + embeddings via plain ORT (`OnnxEmbeddingBackend`), both `dart:ffi` worker-isolate. `hook/build.dart` bundles native archives for macOS arm64, linux_x64, windows_x64, android_arm64 (ORT from Maven `onnxruntime-android`, genai from the `onnxruntime-genai` GitHub release), and iOS arm64 (device + Apple-Silicon sim slices from the single self-contained `onnxruntime-genai-ios` xcframework — ORT statically linked in, one binary exporting both `Oga*` and `OrtGetApiBase`, so no separate ORT and no co-location problem); `OnnxEngine.canHandle`/`OnnxEmbeddingBackend._isSupportedHost` are gated to **macOS arm64 + linux x64 + windows x64 + android arm64 + iOS arm64** (in lockstep with the hook table). All five arm/x64 hosts are **device-verified**: ORT-GenAI generation + embeddings run end-to-end (macOS ~54 tok/s M4 Pro, **Android ~10.4 tok/s Pixel 8 Pro FTL**, Linux ~5.3-5.8, Windows ~3.3 tok/s on the CPU test VMs; Phi-3.5-mini 3.8B int4 ≈3.74 GB peak RSS → needs a 6GB+ phone). On **iOS** the app builds, signs, installs and launches on a real iPhone, and the `@executable_path`-anchored dlopen resolves the framework + generation runs. **Co-location** (genai's bare-name `dlopen("libonnxruntime")` resolving to the sibling CodeAsset): macOS+Linux via the `ORT_LIB_PATH`/`dladdr` export in `gen_ai_client.dart` (`_exportOrtLibPath`, mac/linux only), **Windows + Android resolve on their own** (genai's self-directory dlopen finds the co-located lib under Flutter's flat CodeAsset layout), **iOS has no second lib** (ORT static in genai; the Dart loader opens the one framework via the `@executable_path/Frameworks/…framework/…` anchor iOS dyld 4 requires — bare `.framework` names don't resolve). `OnnxEngine.canHandle` declines + logs off-host; `OnnxEmbeddingBackend.canHandle` stays extension-based on every platform (so LiteRT's catch-all can't silently claim an `.onnx` file) and gates in `describe()` instead. ORT-GenAI model installs are a DIRECTORY (`genai_config.json` + `.onnx`[+`.onnx_data`] + tokenizer) — `installModel(…).fromHuggingFace(repo)` installs the whole directory (the ONNX resolver carried by `OnnxEngine` picks a CPU execution-provider folder).
- **`flutter_edge_ai_diagnostics`** (opt-in, contributed in #541 and #600 for #517): `MemorySnapshot(anonymousBytes, availableBytes, fileBackedBytes, takenAt)` read from the OS — Android `Private_Dirty + SwapPss` (`/proc/self/smaps_rollup`) + `MemAvailable`, and `fileBackedBytes` = `Private_Clean + Shared_Clean`: resident clean pages (mapped files on a CPU backend, but also GPU driver buffers on Adreno: the `/dev/kgsl-3d0` mapping is ~88% clean: one Gemma 4 E2B GPU run added ~980 MiB there on the vivo, ~115 MiB of it dirty and so in `anonymousBytes`; all file mappings together were ~260 MiB; Mali not measured) and clean anonymous pages (zram readback, `MADV_FREE`), so a before/after delta is not an exact count of model weights; iOS `phys_footprint` (`task_info(TASK_VM_INFO)`, offset 144 / REV1 count 38) + `os_proc_available_memory()`, `fileBackedBytes` null (not read yet; `TASK_VM_INFO.external` is the follow-up). Pure `dart:io`/`dart:ffi`, no native code, **no dependency on core** (it measures the process, whichever engine runs in it). Android + iOS only; elsewhere `memorySnapshot()` throws `UnsupportedError`. A null field = the value is not reported on this platform/OS version; a failed read throws `MemoryReadException` — never collapse the two. Android GPU memory (KGSL/Mali/dmabuf) is mostly outside `anonymousBytes`; on Adreno most of it is counted in `fileBackedBytes` instead (clean pages of the `/dev/kgsl-3d0` mapping).
- **Probe-chain registry**: `EngineRegistry`/`EmbeddingRegistry` select a provider by `canHandle(spec)` + `priority` (descending priority, ascending registration index). Engines are pure factories; core owns singleton lifecycle via `CloseNotifier`/`addCloseListener`.
- **ModelSource**: Type-safe sealed class (`NetworkSource`, `AssetSource`, `BundledSource`, `FileSource`). See `packages/flutter_edge_ai/lib/src/domain/`
- **Install vs Runtime separation**: Installation stores identity (modelType + fileType), runtime accepts config (maxTokens, backend, etc.) via `RuntimeConfig`
- **Engine selection by declared `ModelFileType`** (via `canHandle(spec)` — NOT by sniffing the file name): `task`/`binary` → MediaPipe, `litertlm` → LiteRT-LM, `builtIn` → BuiltInAi, `onnx` → OnnxEngine, `gguf` → a llama.cpp engine (none in this repo yet; core treats its chat template as the file's own and cleans replies as for `binary`). `installModel` defaults `fileType` to `task`, so `.litertlm` must be declared explicitly or it is routed to MediaPipe
- **All five platforms (Android/iOS/macOS/Linux/Windows)**: Dart → `dart:ffi` → LiteRT-LM C API for inference and LiteRT C API for embeddings, both implemented in `flutter_edge_ai_litertlm`. `flutter_edge_ai_embeddings` contains tokenizer implementations only; it owns no native backend or bundle. Native prebuilts are fetched at build time from GitHub release `native-v0.18.0-e` (Native Assets). `flutter_edge_ai_litertlm/hook/build.dart` is the **sole** hook carrying the LiteRT native version; `flutter_edge_ai_speech` has no hook of its own and consumes the bundle through its direct litertlm dependency. The cycle-fix `stage()` in the hooks is **Apple-only** (Xcode `directoryTreeSignature` cycle; staging on Windows splits companion DLLs and hangs cancel/close).

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

> ¹ Thinking Mode for Gemma 4: Android, iOS, Desktop and Web `.litertlm` (measured on Gemma 4 E2B in Chrome once the web path sent `enable_thinking`; it used to send `thinking`, a key no template reads). MediaPipe Web has no thinking API.
> ² Qwen3 generates tag-based thinking by default; core parses it platform-independently, including Web when the model emits the tags.

Embedding models (not in the table above): EmbeddingGemma 2 — one `.litertlm` with its own tokenizer, Android/iOS/macOS/Linux/Windows, CPU, `maxInputTokens` 1024: text since litertlm 1.13.0 (270m, 440m, 740m), images since 1.13.1 on the bundles with a vision encoder (440m, 740m; JPEG/PNG/GIF/BMP; 140 vision tokens per image, 70 opt-in), Web (text and images, on WebGPU via `@litert-lm/core`'s `EmbeddingEngine`, needs `window.EmbeddingEngine = m.EmbeddingEngine;` in `index.html`; `@litert-lm/core` 0.18.0 cannot load the EG2 bundles on its CPU/WebAssembly path, so there is no CPU fallback and a page without WebGPU is refused at load) since 1.13.1, audio since 1.13.1 on the bundle with an audio encoder (740m; WAV/MP3/FLAC, about 25 tokens per second) and combined inputs (`EmbeddingInput(text:, images:, audio:)`, one vector) — natively since 1.13.1, on the Web since 1.13.2 (audio tower on WebGPU: ~0.3 s per 3 s clip on a T4 vs ~18 s on its CPU/WebAssembly path; the 270m/440m refused from the container header read through `fetch()`, because `EmbeddingEngine.create` accepts `audioBackend` on them and only the first clip fails) — with exact overflow counts (needs `native-v0.18.0-e`), and on Qualcomm NPUs (1.13.1): `preferredBackend: npu` with a per-SoC `…_Qualcomm_<SoC>.litertlm` bundle, Android arm64 and Linux arm64, `qualcomm_npu` opt-in, its own profile id (`…-npu-<soc>`; NPU vectors are not the CPU ones — measured cos mean 0.83 on short texts, rising to 0.995 at 400 words, images 0.86–0.88), verified on SM8650 (FTL Galaxy S24), QCS8275 (QDC VENTUNO Q, 4/4: text 15 ms vs 361 ms on its CPU, an image 410 ms, text→image 10/10) and SM8850 (QDC phone, 4/4: text 5.6 ms vs 25.7 ms on its CPU, an image 218 ms, text→image 10/10, text cos to CPU identical to SM8650's); the 740m per-SoC bundles compile the audio encoder for cpu/gpu only, so the pass names `audio_backend = "cpu"` on the NPU when audio is declared (1.13.2; NULL failed create, "Audio backend constraint mismatch"), measured on a DDP Galaxy S26+ (SM8850) 2026-10-13: text 6 ms vs 31 ms on its CPU, an image ~240 ms vs 513 ms, an audio clip ~145 ms vs 166 ms, query 22–33 ms, 8/8 ranked first; and on the Intel Panther Lake NPU (1.13.2, owner-approved without a hardware run): `…_Intel_PTL.litertlm` (stamp `IntelOpenVINO`/`PTL`), Windows x64 only, no opt-in — dispatch dir = the executable's directory, refused when `LiteRtDispatch.dll` is not there — profile id `…-npu-ptl` shared by 270m/440m, NOT verified on device (the embedding C API has no `use_hw_masking_for_npu` setter); EmbeddingGemma 1 and Gecko — `.tflite` + tokenizer, every platform (web via LiteRT.js); MiniLM / EmbeddingGemma ONNX — `.onnx` + `tokenizer.json` via `flutter_edge_ai_onnx`. All take the nine `TaskType`s; none truncates an over-long input.

### Platform Limitations

| Platform | Vision/Multimodal | Audio | Embeddings | Notes |
|----------|-------------------|-------|------------|-------|
| Android | ✅ | ✅ | ✅ | Full support |
| iOS Device | ✅ | ✅ | ✅ | GPU via Metal delegate (FFI). No host-side Podfile `post_install` since 0.14.1 — accelerators load by full `@executable_path/Frameworks/<X>.framework/<X>` path; the old `lib*.dylib` symlinks caused ITMS-90432 (#245) |
| iOS Simulator | ❌ GPU | ❌ GPU | ✅ | CPU only — Metal sim has 256 MB single-allocation cap, LLM weights exceed |
| Web | ✅ MediaPipe | ❌ | ✅ `.tflite`/ONNX; EmbeddingGemma 2 text + images (litertlm 1.13.1), audio + combined inputs (1.13.2) on WebGPU, no CPU path | MediaPipe/LiteRT-LM use WebGPU; ONNX also provides CPU/WASM generation and embeddings |
| macOS | ✅ | ✅ LiteRT-LM only | ✅ | Vision + audio verified on Metal (Gemma 4 + Gemma 3n); Gemma 3n audio GPU is ~2× faster than CPU |
| Windows | ✅ | ✅ LiteRT-LM only | ✅ | Desktop via FFI; GPU via WebGPU/DX12 |
| Linux | ✅ | ✅ LiteRT-LM only | ✅ | Desktop via FFI; GPU via WebGPU/Vulkan |

### PreferredBackend

| Value | Android | iOS | Web | Desktop |
|-------|---------|-----|-----|---------|
| `cpu` | ✅ | ✅ | ✅ ONNX/WASM | ✅ |
| `gpu` | ✅ | ✅ `.litertlm` (not MediaPipe `.task`) | ✅ MediaPipe/LiteRT-LM | ✅ |
| `npu` | ✅ (.litertlm, app opts in with `qualcomm_npu: true`) | ❌ | ❌ | ✅ Windows (Intel LunarLake/PantherLake; EmbeddingGemma 2 `…_Intel_PTL` bundles since litertlm 1.13.2, not verified on device); Linux arm64 (Qualcomm, same `qualcomm_npu` opt-in) |

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

### ⚠️ Unset sampling is the model's own, not greedy (#572)
`temperature`, `topK`, `topP` and `randomSeed` on `createSession`/`openSession`/`createChat`/`openChat` are nullable (core 2.2.0). An unset one resolves, field by field, in `SamplingParams.resolve`: the model file's sampler (native `.litertlm`: read in Dart from the container header and its `LlmMetadata` section, `litertlm_bundle_sampler.dart` — NOT LiteRT-LM's `litert_lm_loaded_file_create`, which copies vision sections and, without `max_num_tokens`, the whole main graph into the heap: 1 GB for Gemma 4 E2B; ONNX `genai_config.json`) → `SamplingParams.forModelType` (publishers' `generation_config.json` values) → `SamplingParams.fallback` (0.8 / 40 / 0.95 / seed 1). `topK: 1` or `temperature: 0` is greedy (`isGreedy`); a caller who sets a temperature or topP but no topK skips greedy layers (`needsSamplingTopK`), and invalid values throw `ArgumentError`. A failed bundle read is not the same as "no sampler": it sets `LiteRtLmFfiClient.bundleSamplerError` and prints once. Native `.litertlm` always sends a resolved TOP_P sampler: a config without one makes LiteRT-LM copy the bundle's sampler whole, and its CPU sampler rejects TOP_K/GREEDY. Web `.litertlm` cannot read the bundle, so it uses the family defaults, and must send `type: 2` or the engine discards the values. MediaPipe holds an unset topK to 40, its own default top-k. `LlmInferenceOptions.maxTopK`, which the plugin leaves at 40, is not a ceiling: on Android CPU and GPU (Mali, Adreno) an explicit topK 64 samples beyond the top 40 (FTL 2026-10-11); iOS and web are not measured. A temperature of 0 is sent to MediaPipe as 1.0 with topK 1: it picks greedy from top-k alone, its CPU sampler treats temperature 0 as 1.0, and its GPU sampler divides by it. Built-in AI sends `flutter_local_ai`'s own 0.8 / topK 1 for unset values: it takes no null, and a larger topK could exceed a browser's `maxTopK`. Still true: the sampler is fixed by the engine's first generation (LiteRT-LM#2080) — `EngineSamplerLatch` records it at the first send (native client and web model) and prints a one-time warning when a later session asks for other values and the caller set either side — its random state carries across conversations, and NPU decodes greedily whatever is sent. Measured 2026-10-10 on macOS CPU: Gemma 4 E2B and FunctionGemma 270M tool calls and Gemma 4 JSON are equally accurate under the family defaults and greedy, at the same speed.

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
Check `lib/src/interface.dart`, implementation files, and `example/` before making changes.

### ⚠️ MediaPipe LLM Inference is maintenance-only; iOS GPU `.task` does not load
Google's docs put the LLM Inference API (Android, iOS, Web) in maintenance-only mode, with new features and optimizations focused on LiteRT-LM; the iOS SDK (0.10.33+) marks `LlmInference`, `Session` and their `Options` `deprecated: Migrate to LiteRT LM`, and `mediapipe-samples` removed its iOS/Android LLM samples (2026-08-05). Measured 2026-10-10 on an iPhone 17 Pro, iOS 26.5.2: `gemma3-1b-it-int4.task` (529 MB) on `PreferredBackend.gpu` grows ~300 MB/s inside `LlmInference(options:)` to that iPhone's 6655 MB per-process limit (memory entitlements present) and jetsam kills the app — no crash report (`.ips`); `idevicesyslog` shows the jetsam `per-process-limit` kill — on 0.10.33 and 0.10.35, with `waitForWeightUploads` true or false, `maxTokens` 1024 or 2048, `sequenceBatchSize` 0 or 1. `gemma-3n-E2B-it-int4.task` fails `ModifyGraphWithDelegate`. CPU works, and the same Gemma 3 1B as `.litertlm` loads on the iPhone GPU in under 1 GB. Point iOS GPU users to `.litertlm`. Repro, one test at a time: `example/integration_test/ios_mediapipe_gpu_memory_test.dart`; re-run it when the MediaPipe pod moves.

### ⚠️ Generated pigeon is `flutter_edge_ai_mediapipe/lib/pigeon.g.dart` — DO NOT EDIT MANUALLY
Core has NO pigeon (dropped at the 1.0 cut; its value types are hand-written in `lib/src/domain/platform_types.dart`). Only `flutter_edge_ai_mediapipe` still uses pigeon (it owns the `PlatformService` HostApi).

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
- **LiteRT-LM**: native libs from `native-v0.18.0-e` GitHub Release (= `native-v0.18.0-d` with `libLiteRtLm` rebuilt on all seven targets: on Linux and Windows EmbeddingGemma 2's external weights are addressed by the bundle's path inside each model flatbuffer instead of a C++ map handed to Google's prebuilt libc++ `libLiteRt` — the libstdc++/MSVC STL mismatch failed the create on Linux and was an access violation on Windows (`patch_c_api.sh` §13, `external_weights_by_path.{h,cc}`; Apple and Android compile it out); `patch_c_api.sh` §14 adds `litert_lm_embedding_response_get_input_length` / `_get_truncated_length`; every other file is byte-identical to -d — Windows `LiteRtDispatch.dll` carried from -d byte for byte, CI's `StreamProxy.dll` differs only in link stamps). `native-v0.18.0-d` = `native-v0.18.0-c` with the two Linux `libLiteRtLm.so` rebuilt: the three Gemma data processors no longer `reinterpret_cast` the prebuilt `libGemmaModelConstraintProvider` object — on Linux it is Google libc++ (`std::__u`, `trivial_abi` `unique_ptr`, size-based `vector`) and our runtime is libstdc++, so every native tool call aborted on its first constrained token (#551, upstream #3821); `patch_c_api.sh` §12 wraps it with `gemma_constraint_abi_bridge.h`, whose layout constants are measured on the shipped providers (x86_64 `dded89d4…`, arm64 `016f5d61…`, unchanged since native-v0.17.1-a). `native-v0.18.0-c` = `native-v0.18.0-b` plus two files in the linux_arm64 archive: our Qualcomm dispatch and a `libcdsprpc.so` shim — the QNN Stubs NEED the bare name, Ubuntu ships only `libcdsprpc.so.1` — for Linux arm64 NPU behind the same `qualcomm_npu` flag, whose hook reads the QNN runtime out of Qualcomm's public QAIRT 2.50 zip by HTTP range (`lib/src/hook/qairt_linux.dart`, per-library SHA-256 pins); the dispatch is built in CI by `build_qualcomm_dispatch.sh TARGET=linux_arm64` against a SHA-pinned header slice (`fetch_qairt_sdk_slim.py`). `native-v0.18.0-b` = `native-v0.18.0-a` with only the three Apple `libLiteRtLm.dylib` rebuilt: in an app with flutter_litert, LiteRT's `gpu_registry` tried the generic `libLiteRtGpuAccelerator` first and, on the failed `dlopen`, bound flutter_litert's accelerator through `dlsym(RTLD_DEFAULT, …)` — a crash in `LiteRtCreateCompiledModel`; `patches/litert_gpu_registry_apple.patch`, applied by `patch_c_api.sh` §10b as the `litert` archive's `patches=`, makes Apple try only our framework path with the default lookup off, and `build_{ios,macos}.sh` refuse a `libLiteRtLm` that still names another accelerator. `native-v0.18.0-a` = `native-v0.18.0` with only the two Linux `libLiteRtLm.so` rebuilt: `patch_c_api.sh` §11 applies the Qualcomm NPU options — HTP burst — on Linux too, which upstream sets on Android only). LiteRT-LM pin `b2f686e2` = upstream v0.18.0, LiteRT pin `26895c9f`, Qualcomm dispatch built against QAIRT 2.50.0, Intel NPU stack on OpenVINO 2026.3.1; companion prebuilts come from the tag itself (its constraint provider has the `ComputeMask` ABI). v0.18.0: Android ships no QNN runtime (opt-in, see below) and none of the three Dawn-dependent GPU libraries (they could never load — Android GPU is OpenCL only, so a failed OpenCL load now falls back to CPU, not WebGPU); Apple ships the Metal accelerator as `LiteRtLmMetalAccelerator`, because flutter_litert embeds a framework under the upstream name and an app holds one framework per name; `verify_tarball_manifest.sh` gates per-platform required/forbidden files. native-v0.17.1-a = v0.17.1 plus the two Android GPU accelerators patched with `libandroid.so` in `DT_NEEDED` (Mali SIGSEGV at `engine_create`, #545; `build_android.sh` step 8d lints every import against its NEEDED chain); the v0.17.x tags' `libGemmaModelConstraintProvider` was pre-`ComputeMask`, so those releases took it from upstream main `4453b286`. v0.17.1: a tool-call argument declared `"type": "integer"` reaches the app as an integer instead of `1000.0`; the Android tarball's four Qualcomm Skel blobs are raised to `p_align=0x4000`, because at 4 KB Google Play rejects every app that ships them (#529). v0.17.0: the GPU samplers' `Create` gained a leading `runtime_c_api` argument (upstream refreshed the prebuilt samplers); `LiteRtLayout` has been one layout on every compiler since LiteRT `d84656955` (already in the v0.16.0 pin) — our Windows-only MSVC mirror broke Windows embeddings and speech from native-v0.16.0 until litertlm 1.7.0 dropped it. Android tarball bundles the Qualcomm dispatch only — the QNN runtime is opt-in (app sets `hooks: user_defines: flutter_edge_ai_litertlm: qualcomm_npu: true`, in the workspace root's pubspec if the app is a workspace member) and the litertlm hook fetches `com.qualcomm.qti:qnn-runtime` from Maven Central (version + sha256 pinned in `lib/src/hook/qnn_runtime.dart`, Skels raised to 16 KB there), because Qualcomm's AI Stack License allows redistribution only inside an application; the runtime gate reads `NativeAssetsManifest.json`, not file presence, and core's `prepareNpuDispatchDir` stages the libs (split APKs included). Windows tarball bundles Intel NPU dispatch (`LiteRtDispatch.dll` + OpenVino runtime + TBB) for `PreferredBackend.npu` (Qualcomm Snapdragon / Intel LunarLake/PantherLake) — both dispatch libs are **rebuilt from the pin every release**; carrying them forward is what silently broke NPU on both platforms (see the `build-native` skill). v0.16.0: fixes the Android OpenCL per-turn memory leak (LiteRT-LM #2699, #348/#402); v0.15.0 **broke the stream-callback ABI** (4-arg → 2-arg chunk object) with no compat path, handled by a runtime probe in `stream_proxy.c`. Windows discrete GPU works again — the crash was our own dead `litert_link_capi_so` Bazel define, not an upstream regression (#2957 retracted).
- **sqlite-vec**: `flutter_edge_ai_sqlite` fetches the per-platform `vec0` loadable from the `native-sqlite-vec-v<X>` GitHub Release (`sqlite-vec-<target>.tar.gz` + `checksums_sqlite_vec.txt`), SHA256-verified by its `hook/build.dart`. `<X>` names the **upstream sqlite-vec release** the bytes were built from; a letter suffix (`0.1.9-a`) is only for RE-releasing changed bytes under an already-published number. The loadables are NOT committed — `native/sqlite_vec/prebuilt/` is a maintainer override produced by `build_local.sh`, gitignored and `.pubignore`d.
- **large_file_handler**: `^0.5.0` (core dep; 0.5.0 declares all 6 platforms — needed for pana platform support + the dart2wasm-clean web graph)
- **Current Version**: core `flutter_edge_ai` `2.3.2`, RAG `flutter_edge_ai_rag` `1.1.0`, `flutter_edge_ai_sqlite` `2.1.0`, `flutter_edge_ai_qdrant` `2.1.0`; `flutter_edge_ai_litertlm` `1.13.2`, `flutter_edge_ai_mediapipe` `1.2.2`, `flutter_edge_ai_embeddings` `2.3.0`, `flutter_edge_ai_speech` `0.5.6`; `flutter_edge_ai_agent` `0.2.9`, `flutter_edge_ai_builtin_ai` `0.3.5`, `flutter_edge_ai_onnx` `0.5.8`, `flutter_edge_ai_diagnostics` `0.2.2`; `genkit_flutter_edge_ai` `0.9.1`, `genkit_hybrid` `0.3.1`. The family shipped as `flutter_gemma*` up to core 1.11.3 / litertlm 1.8.5; the old names stay published as they are.
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
  (`flutter_edge_ai_builtin_ai` has no `android/` at all since 0.3.0; its dependency
  `flutter_local_ai` stopped applying `kotlin-android` in 0.2.0 but still puts KGP 2.3.21
  on its buildscript classpath, and apps need Kotlin 2.3.21 for the ML Kit `beta4` metadata). Flutter's own Gradle plugin applies `kotlin-android` to any plugin subproject
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
- Native libs fetched at build time by `flutter_edge_ai_litertlm/hook/build.dart` (the only hook that carries the version) from the `native-v0.18.0-e` GitHub release; SHA256-verified, bundled via Native Assets
- LiteRT-LM on desktop uses `.litertlm` format (not `.task`). The opt-in ONNX
  engine instead installs a directory (`genai_config.json`, model and tokenizer)
  on macOS arm64, Linux x64 and Windows x64.
- Windows GPU requires `dxil.dll` + `dxcompiler.dll` (DirectXShaderCompiler runtime) — bundled in the Windows native archive
- Windows NPU (`PreferredBackend.npu`) requires Intel LunarLake/PantherLake silicon — `LiteRtDispatch.dll` + OpenVino runtime + TBB bundled in the Windows native archive (0.15.1+)

macOS App Nap: a backgrounded app is throttled after about a minute, and `flutter test integration_test/<file>.dart -d macos` runs the app in the background — model work then slows 3-8x late in a suite (EmbeddingGemma 2 images: 0.35 s early, 2.3-6.9 s late, memory flat; measured 2026-10-12). The example's `macos/Runner/AppDelegate.swift` holds an `NSProcessInfo` activity for its lifetime to opt out — an `NSAppSleepDisabled` key in `Info.plist` is NOT honored (measured); for a one-off run, `defaults write ~/Library/Containers/<bundle id>/Data/Library/Preferences/<bundle id> NSAppSleepDisabled -bool YES` works. Do not read a late-suite slowdown on macOS as a leak before ruling this out.

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
flutter analyze packages/ && dart format . && tool/test_all.sh
```

## Key Files

> **1.0 monorepo:** paths below are under `packages/<pkg>/`. The repo is a Dart
> pub workspace (root `pubspec.yaml` `workspace:` list); core = `flutter_edge_ai`,
> engines/RAG = opt-in sibling packages.

**Core (`packages/flutter_edge_ai/`):**

| File | Purpose |
|------|---------|
| `lib/flutter_edge_ai.dart` | Public app library — every export has a `show` list |
| `lib/engine.dart`, `lib/engine_io.dart`, `lib/engine_web.dart` | Public engine SPI (re-exports the app library), its `dart:io`/`dart:ffi` helpers and its `dart:js_interop` helpers. Satellites import only these (and `genai.dart`); everything under `lib/src` is private (`tool/check_core_surface.sh`, `implementation_imports: error`) |
| `test/public_surface/` | Symbol golden of the five public libraries, plus a member golden of the embedding SPI (`embedding_spi_members_test.dart`); `UPDATE_GOLDENS=1` regenerates, refused when `CI` is set |
| `lib/src/interface.dart` | Abstract InferenceModel / Session + CloseNotifier seam (re-exports `EmbeddingModel`, which lives in `lib/src/embedding/`) |
| `lib/src/api/flutter_edge_ai.dart` | `FlutterEdgeAi.initialize/getActiveModel/installModel/installEmbedder/reset/dispose` |
| `lib/src/message.dart` | Message class (isUser gotcha) |
| `lib/src/domain/` | ModelSource sealed classes |
| `lib/src/registry/{inference_engine_provider,embedding_backend_provider,engine_registry,embedding_registry,runtime_config}.dart` | Probe-chain registry contracts engines/backends implement |
| `lib/src/lifecycle/close_notifier.dart` | `CloseNotifier` mixin (addCloseListener / fireCloseListeners) |
| `lib/src/lifecycle/{inference_model_cache,model_close_gate}.dart` | `InferenceModelCache` — the cached inference model and its reuse / in-flight / rebuild rules, one copy for the mobile, desktop and web shells (as `EmbedderCache` is for the embedder); each shell supplies only the active spec, the knobs (`ActiveModelParams`, turned into the engine's `RuntimeConfig` by `runtimeConfigFor`) and how to build — its install and file checks and the engine call. `ModelCloseGate` keeps a build from starting while the previous model is still closing (60 s, then `TimeoutException`) and reports a failed close with `print`, so release builds see it |
| `lib/src/embedding/` | The embedding API and SPI. App types: `EmbeddingModel` (`abstract base`: `embed`/`embedAll`/`dimension`/`modalities`/`maxInputTokens`; `generateEmbedding(s)`/`getDimension` are deprecated forwarders until 2.5.0), `EmbeddingInput`, `EmbeddingModality`, `TaskType`, the `EmbeddingException` family. Engine SPI (via `engine.dart`): an `EmbeddingBackendProvider.describe()` returns an `EmbeddingPassDescriptor<C>` whose `EmbeddingPass` reports `EmbeddingPassInfo` at load; `TokenEmbeddingPass` + `TokenPassGraph` are the template for engines that tokenize in Dart; plus `ForwardResult`/`EmbeddingOutputContract`/`finalizeEmbedding`, the `EmbeddingTokenizer` adapter and `meanPoolAndNormalize` — tokenizer IMPLEMENTATIONS stay in `flutter_edge_ai_embeddings`. Core builds every model itself and keeps the machinery internal: `CommonEmbeddingModel` (request validation, two media permits, the `embedAll` window) over an `EmbeddingHost` — `embedding_host_io.dart` (worker isolate, native; close never kills it) or `embedding_host_web.dart` (inline, web) — sharing `request_lanes.dart`, `load_check.dart` and `wire.dart`; `embedder_loader.dart` (the one path the three shells build through); `EmbedderCache` (cached embedder + its params, the cover/widen reuse rule, the bounded wait for a replaced embedder's close, and the lane serialising the entry point) and `noticeEmbedderBackendIgnored` (says once per isolate that `preferredBackend` reached nothing; debug-only, so `EmbeddingModel.activeBackend` is the release answer) |
| `lib/src/registry/embedding_tokenizer_{provider,registry}.dart` | Probe chain for tokenizers, so an engine asks for one instead of naming one (which is what made it depend on a sibling package) |
| `lib/src/mobile/flutter_edge_ai_mobile.dart` | Mobile shell — registry-dispatch createModel + EmbeddingModelSpec |
| `lib/src/web/flutter_edge_ai_web.dart` | Web shell — registry-dispatch |
| `lib/src/desktop/flutter_edge_ai_desktop.dart` | Desktop shell — registry-dispatch |
| `lib/src/web/web_model_source.dart`, `lib/src/web/web_model_url.dart`, `lib/src/media/encoded_media_format.dart` | Shared web infra for engine web arms (litertlm, mediapipe, onnx), reached through `engine_web.dart` / `engine.dart` (`detectImageMimeType` sits on the one media sniffer, `sniffEncodedMediaFormat`) |
| `lib/src/model_management/managers/web_model_manager.dart` | Web model manager (install/storage on web) |
| `lib/src/domain/platform_types.dart` | Plain-Dart `PreferredBackend` and `ActivationDataType`. Core has NO pigeon/PlatformService; only `flutter_edge_ai_mediapipe` owns a Pigeon bridge. |
| `hook/build.dart` | Native Assets hook — empty bundle list (core owns no native lib) |
| `android/src/.../FlutterEdgeAiPlugin.kt`, `{ios,macos}/flutter_edge_ai/Sources/flutter_edge_ai/FlutterEdgeAiPlugin.swift` | Slim native plugin — hosts only the `flutter_gemma_bundled` channel (file-ops + litertlm NPU `getNativeLibraryDir`) |
| `example/lib/gemma_bootstrap.dart` | Single source of truth for the example's engine/backend lists + RAG switcher |
| `example/lib/models/model.dart` | Model configurations & URLs |
| `example/lib/image_search_screen.dart`, `example/lib/image_search/` | EmbeddingGemma 2 image search (every platform; on web picked photos are kept in OPFS, `photo_store_web.dart`): the active embedder with `supportImage: true`, a RAG image index over SQLite (`<text profile id>-vis140`), samples from `assets/eg2_vision/` (generated by `integration_test/tools/generate_eg2_vision_images.py`) or `image_picker`, text→image and image→image |

**`packages/flutter_edge_ai_litertlm/` (.litertlm FFI inference; owns the shared libLiteRtLm bundle):**

| File | Purpose |
|------|---------|
| `lib/src/litert_lm_engine*.dart` | `LiteRtLmEngine` (InferenceEngineProvider; native + web arms via conditional export) |
| `lib/src/embedding/litert_embedding_backend{,_web}.dart`, `litert_embedding_pass.dart` | `LiteRtEmbeddingBackend` (both arms) — `describe()` hands core the `.tflite` `LiteRtEmbeddingPass` (a `TokenEmbeddingPass`; `maxInputTokens` = the compiled sequence dimension) natively, the LiteRT.js pass on web; a self-contained `.litertlm` spec gets the EG2 pass below natively and the web EG2 pass (next rows) on web — both arms claim `.litertlm` (web routes by the spec's file name: its paths are URLs). `LiteRtEmbeddingBackend(visionTokensPerImage:)` 140 (default) or 70 on both arms; any other value refused in every `describe()` (`vision_budget.dart`) |
| `lib/src/embedding/litert_lm_embedding_pass.dart`, `embedding_parts.dart` | `LiteRtLmEmbeddingPass` — EmbeddingGemma 2 text, images and audio over LiteRT-LM's EmbeddingEngine C API (R5 §4.8-§4.11): ModelInfo read and freed before any settings (image support from `vision_signature_selection`, never `supports_input_modality`; an LLM bundle refused by name), `set_max_input_length(1024)` and an engine-owned cache dir (`<appCache>/flutter_edge_ai/emb/<8-hex hash of the file name>-<base36 size>-<base36 mtime ms>/` — path_provider's cache directory, never backed up (iOS iCloud, Android Auto Backup's 25 MB quota), rebuilt at the next create if purged; short for Windows MAX_PATH: the engine's cache file below it repeats the model's name, 232 characters for the example app with a 20-character user name; stale siblings of the same file name deleted only after a successful create and only when untouched for 10 minutes; an empty dir after create is printed as a warning) always, tower backends NULL, special tokens on, overflow kTruncate on every request: a response whose `truncated_length` (`patch_c_api.sh` §14 getter, `native-v0.18.0-e`) is > 0, or whose `input_length` exceeds the limit read at load, = `EmbeddingInputTooLongException(maxInputTokens: truncated_length, actualTokens: input_length)` with media tokens counted, the truncated vector never returned; a NULL response is never an overflow. Images (1.13.1): declared images on a bundle without vision signatures refused from ModelInfo naming the 440m bundle; `{text, image}` + JPEG/PNG/GIF/BMP reported when the bundle has them; `set_vision_tokens_per_image` (the budget must be in the bundle's vision signatures) only when images are declared; each image one part (`embeddingParts`: encoded bytes, never a prefix); status 3 on an image = stb decode failure → `EmbeddingEngineException(nativeCode: 3)`. Audio and combined inputs (1.13.1): declared audio needs a `TFLiteModel` section whose `model_type` starts with `tf_lite_audio_encoder` (`litertlm_container.dart` over the shared FlatBuffer walker `litertlm_flatbuffer.dart`; ModelInfo claims audio on the 270m and the 440m), read only when audio is declared and checked in `describe()` (core calls it before it closes the cached embedder) with the pass's `load()` as a backstop — refused naming the 740m; WAV/MP3/FLAC (`liteRtLmAudioFormats`), status 2 on audio = miniaudio could not open it; `combinedInputs: true` — `embeddingParts` sends the text (with its prefix), then the images in order, then the audio as parts of one request, and a later part that fails to build deletes the earlier ones. NPU (1.13.1, `litert_lm_npu.dart` + `litertlm_npu_target.dart`): `describe()` reads what a bundle is compiled for from its own bytes — the `LiteRtStamp` metadata the AOT compiler writes into each `DISPATCH_OP`-compiled TFLiteModel section (`readLiteRtLmNpuTarget`), never the file name, since ModelInfo reports the same for both and `engine_create` succeeds on any backend — after the audio check, then `placeLiteRtLmEmbedder` decides: generic bundle → CPU, per-SoC bundle + `npu` → the NPU with the dispatch dir from `prepareAndroidNpuDispatchDir` / `prepareLinuxNpuDispatchDir` (prepared on the caller's isolate: the worker has no platform channels), handed to the main, vision and audio executors; every other combination (generic + npu, per-SoC without npu, non-Qualcomm or another platform, no `qualcomm_npu`, no reachable FastRPC/DSP, …) is one of 12 `EmbeddingLoadException`s, never a silent fallback. The NPU load embeds one probe text and refuses unless it gets a finite, non-zero vector of the right size (create only logs a failed warm-up); on Linux create, compute and delete run with SIGPROF blocked (`withSigprofBlocked`: the debug VM profiler's signal breaks QNN). Every create has its delete on every path |
| `lib/src/embedding/web/litert_lm_web_embedding_pass.dart`, `litert_lm_web_embedding_runtime.dart`, `litert_lm_embedding_common.dart` | `LiteRtLmWebEmbeddingPass` (1.13.1; audio and combined inputs 1.13.2) — EmbeddingGemma 2 on web over `@litert-lm/core` 0.18.0's `EmbeddingEngine`: pure Dart over an injected `LiteRtLmWebRuntime` (VM-tested); `WindowLiteRtLmWebRuntime` is the `dart:js_interop` side (awaits `window.litertLmReady`, then needs `window.EmbeddingEngine`, else `EmbeddingLoadException` naming the shim line). `create({model, backend: GPU (4), maxInputLength: 1024, visionBackend: GPU + visionTokensPerImage only with declared images, audioBackend: GPU only with declared audio (1.13.2)})` — WebGPU only: 0.18.0's CPU/WebAssembly path cannot load the EG2 bundles ("Failed to get external weight"), so there is no CPU fallback, and a page without WebGPU (no `navigator.gpu` or no adapter) is refused before `create` with an `EmbeddingLoadException`; CPU stays selectable only for the drive suite's record. An over-long probe under TRUNCATE reads the dimension and refuses NaN/zero; on WebGPU the runtime splits an over-long input into windows and averages them, so the enforced limit is the window (1024 tokens one window, 1025 two); every request TRUNCATE → `truncatedLength` or `numChunks` > 1 = `EmbeddingInputTooLongException` with exact `inputLength` (media tokens included: a 60 s clip is 1504, as natively); `opfs://` → `blob:` resolved and revoked; one engine per pass. Audio (1.13.2): declared audio is checked against the container header (`litertlm_container.dart`, web-safe; the `dart:io` reader is `litertlm_container_io.dart`; `litertlmHeaderEnd` reads the uint64 as two uint32 halves for dart2js) through `LiteRtLmWebRuntime.readPrefix` (the page's `fetch()`, a few KB) — in `describe()` and again before `create` — because `EmbeddingEngine.create` accepts `audioBackend` on the 270m/440m and only the first clip fails; an audio part is `{type: 'audio', data: ArrayBuffer}`, a combined input one JS array of parts in the native order (`combinedInputs: true`). `lib/src/web/litert_lm_page_lock.dart`: one FIFO page lock (internal) that the LLM web session (Engine.create, createConversation, a generation from `sendMessageStreaming` until its JS stream ENDS — drained after a consumer cancel) and this pass (create + probe, each `computeEmbedding`) take, because both engines share the page's one WASM module and Asyncify builds hold one suspended call (`Asyncify.currData`); `delete()`/`cancel()` never suspend and do not take it. VM: `test/litert_lm_page_lock_test.dart`; browser: `test/web/litert_lm_page_lock_web_test.dart`; real runtime: `example/integration_test/web_eg2_llm_test.dart`. CPU only for the drive suite's record (`example/integration_test/web_eg2_test.dart`). Shared constants (engine tag, the no-audio-encoder refusal both arms throw, 1024, JPEG/PNG/GIF/BMP, WAV/MP3/FLAC) live in the web-safe common file. Real runtime, audio: `example/integration_test/web_eg2_audio_test.dart` |
| `lib/src/ffi/litert_lm_embedding_bindings.dart`, `ffigen_embedding.yaml`, `native/litert_lm/include/c/` | ffigen bindings (20.1.1) for the EmbeddingEngine, ModelInfo and error-reporter C API, from upstream's `c/` headers vendored verbatim at the pin; regenerate on every pin bump. The D23-misleading ModelInfo calls and the batch API are deliberately not bound |
| `lib/src/ffi/litert_lm_library.dart` | The one plain libLiteRtLm opener shared by the LLM client's isolate helpers and the EG2 pass (Android: `openLiteRtLmPreferringDefaultScope`, #447) |
| `lib/src/embedding/web/`, `web/*.js`, `tool/web_build/` | The LiteRT.js embedding bundle — `LiteRtJsEmbeddingPass` (pure Dart over an injected `LiteRtJsBundle`, the window API of `web/litert_embeddings.js` — bundle API v2: Dart builds `taskType.prefix + text`, the bundle reports the model's dimension and input length and answers `too_long` instead of truncating, and a copy that does not announce `liteRtEmbeddingsApiVersion = 2` is refused by name; page-wide load/dispose lane), `LiteRtWebRuntime` (WASM runtime URL, pinned `@litertjs/core`) and the vite build that emits all four JS files. Moved here in 1.8.0: it is LiteRT, and keeping it beside the engine is what removes the sibling dependency |
| `lib/src/ffi/litert_lm_client.dart` | Per-platform FFI client (loading, preload, log capture) |
| `lib/src/ffi/litert_lm_bindings.dart` | Generated dart:ffi bindings to LiteRT-LM C API (inference) |
| `lib/src/ffi/ffi_inference_model.dart` | FFI inference model (mixes CloseNotifier) |
| `lib/src/web/litert_lm_web*.dart` | Web `.litertlm` via `@litert-lm/core` (Engine handshake) |
| `hook/build.dart` | Native Assets hook — OWNS the litertlm bundle; `stage()` is **Apple-only** (Xcode cycle) |
| `native/litert_lm/{build_ios.sh,patch_c_api.sh,stream_proxy.c}` | iOS dylib rebuild + C API patcher + preload helper |
| `native/litert_lm/check_embedding_exports.py` | Release gate run by `verify_tarball_manifest.sh`: each tarball's libLiteRtLm must export the 33 C functions the EG2 pass calls (among them `patch_c_api.sh` §14's two response getters, from `native-v0.18.0-e`, and the three dispatch-directory setters the NPU path uses) (reads ELF/Mach-O/PE export tables itself; a VM test keeps its list equal to the pass's) |

**`packages/flutter_edge_ai_embeddings/` (tokenizer implementations — 2.3.0; depends ONLY on core, and NOTHING depends on it: engines get a tokenizer from core's registry, which the app fills from here):**

| File | Purpose |
|------|---------|
| `lib/src/tokenizer_provider.dart` | `GemmaEmbeddingTokenizers` — the registrable `EmbeddingTokenizerProvider` an app passes to `initialize(embeddingTokenizers:)` |
| `lib/src/tokenizer_router.dart` | `resolveEmbeddingTokenizer` — sniffs the tokenizer file and routes WordPiece / SigLIP2-refusal / SentencePiece (moved from `flutter_gemma_onnx`; never was ONNX-specific) |
| `lib/src/wordpiece_tokenizer_json.dart` | The WordPiece `tokenizer.json` parse step, split out so it carries no `dart:js_interop` and stays VM-testable |
| `lib/src/embedding_tokenizer.dart` | Gemma SentencePiece tokenize + BOS=2/EOS=1 + TaskType prefix (`.json`/`.model` loader) |
| *(no engine dep, no `hook/build.dart`, no `web/`)* | The seam, worker, pooling and facade moved to core’s `lib/core/embedding/` in 1.9.0 (now `lib/src/embedding/`); the LiteRT.js web bundle moved to the litertlm package in `flutter_gemma_litertlm` 1.8.0 |

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
| `lib/src/flutter_edge_ai_rag.dart` | `FlutterEdgeAiRag` provider registry; `open(embedder:)` resolves the profile and binds `(profile, spec.documents)` at open, `openVectors(profile:)` for vector-only indexes |
| `lib/src/rag_index.dart` | Owned `RagIndex` lifecycle, `add`/`search` over `EmbeddingInput`, vector operations, filter-field validation and concurrency gate |
| `lib/src/embedding.dart` | `EmbeddingProfile`, the `RagEmbedder` role API, and `FlutterEdgeAiActiveEmbedder` (re-resolves the core model per operation, retries once on `EmbedderClosedException`, `forActiveModel` ids) |
| `lib/src/{vector_store,vector_store_provider,filter}.dart` | Store/provider contracts (`VectorStoreBinding`: v1 record always written, image/audio under a U+001F-qualified id plus a v2 record), `VectorStoreSpec.documents`, backend-neutral filter DSL |
| `../../tool/rag_store_compat/` | Store compatibility harness: hosted rag 1.0.0 + sqlite/qdrant 2.0.1 must refuse the train's image/audio stores (`run_downgrade_harness.sh`); generator of the committed `test/fixtures/v2_0_1/` stores |

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
| `lib/src/ffi/gen_ai_client.dart` | `GenAiFfiClient` — main side of the ORT-GenAI worker (mutex-serialized generate/countTokens; shutdown waits for the call in flight and never kills the worker) + `_FfiGenAiEngine`, the `dart:ffi` engine (`ORT_LIB_PATH` co-location fix) |
| `lib/src/ffi/gen_ai_worker.dart` | `serveGenAiWorker` — the worker loop (one request at a time; close fails what has not started, frees the engine, exits via `Isolate.exit`) — and `GenAiWorkerEngine`, the interface the FFI engine and the test fake implement (src-only) |
| `lib/src/ffi/gen_ai_protocol.dart` | Isolate message protocol (src-only, not barrel-exported); the test fake worker runs the real loop over a scripted engine through `GenAiFfiClient(workerEntry:)` |
| `lib/src/embedding/onnx_embedding_backend.dart` | `OnnxEmbeddingBackend` (EmbeddingBackendProvider; priority 10 over LiteRT's catch-all 0) |
| `lib/src/embedding/{ort_client,ort_ffi_client,ort_token_graph,onnx_embedding_pass}.dart` | Plain ORT C API FFI client + `OnnxEmbeddingPass` (+ `OnnxEmbeddingConfig`, exported natively), a `TokenEmbeddingPass` (WordPiece/SentencePiece, `pooledFinal`/`tokenLevel` contracts; static graph → `maxInputTokens` = its sequence dim, dynamic → null); the web arm's `OnnxWebEmbeddingPass` shares the graph description |
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
│   │   ├── android/ ios/ macos/ linux/ windows/   # slim native plugin (bundled channel only)
│   │   ├── hook/build.dart          # empty bundle list
│   │   ├── MIGRATION.md README.md   # migration guide + package README
│   │   └── example/                 # example app + integration tests
│   ├── flutter_edge_ai_litertlm/      # .litertlm FFI (owns libLiteRtLm) + native/litert_lm/ build scripts
│   ├── flutter_edge_ai_embeddings/    # tokenizer implementations only; no engine or native bundle
│   ├── flutter_edge_ai_mediapipe/     # .task MediaPipe (own pigeon + Kotlin + Swift + web JS)
│   ├── flutter_edge_ai_rag/           # instance-scoped RAG orchestration + contracts
│   ├── flutter_edge_ai_qdrant/    # native RAG (official qdrant_edge UniFFI SDK)
│   ├── flutter_edge_ai_sqlite/    # SQLite RAG — in-SQLite vec0 KNN (native sqlite3 FFI + web wasm)
│   ├── flutter_edge_ai_builtin_ai/    # OS built-in AI over flutter_local_ai — Gemini Nano / Apple FM / Phi Silica / Chrome Prompt API
│   ├── flutter_edge_ai_onnx/          # ONNX Runtime — native arm64/x64 hosts + Transformers.js/ORT Web
│   ├── flutter_edge_ai_diagnostics/   # opt-in memory diagnostics (anonymous footprint + available memory, Android + iOS; no core dependency)
│   ├── flutter_edge_ai_speech/        # opt-in on-device STT (moonshine/Whisper/Parakeet) + TTS (Matcha/Qwen3/Inflect) via LiteRT C API (shares libLiteRtLm)
│   ├── flutter_edge_ai_agent/         # opt-in on-device agent skills (SKILL.md: text/JS/native-intent/MCP) over the function-calling loop
│   ├── genkit_flutter_edge_ai/        # Firebase Genkit integration (flutter_edge_ai runtime + converters)
│   └── genkit_hybrid/               # Genkit hybrid on-device + cloud helpers
└── docs/                            # LEGACY_API.md + benchmarks/
```

## Repository

- **GitHub**: https://github.com/DenisovAV/flutter_edge_ai
- **Pub.dev**: https://pub.dev/packages/flutter_edge_ai
- **Issues**: `gh issue list --repo DenisovAV/flutter_edge_ai --state open`
- **Changelog**: See `CHANGELOG.md`

## 2.1.0
- **Breaking:** `isThinking` is `enableThinking`; `ModelRuntimeDefaults.isThinking` is `thinkingDeclared`.
- Add `ModelType.qwen35`; thought-channel reasoning is a `ThinkingResponse` for every type; no ` /no_think` on audio.
- Print a one-time note per chat when reasoning was hidden with thinking off.
- TTS installs from assets, files and native bundles too; its `install()` throws on web.
- Fix `fromAsset` installs on desktop.

## 2.0.0
- **Breaking:** RAG APIs and storage contracts move to `flutter_edge_ai_rag`.
- **Breaking:** remove `ModelFileManager.setActiveModel`; use `ensureModelReadyFromSpec`.
- **Breaking:** remove the `flutter_gemma` name aliases; `dart fix --apply` still migrates.

## 1.11.4
- Renamed from `flutter_gemma`; `dart fix --apply` migrates, old names deprecated until 2.0.0.
- Web: keep plain-string SDK responses; an unexpected content shape now fails the stream.

## 1.11.3
- New `flutter-gemma-diagnostics` agent skill for `flutter_gemma_diagnostics`.

## 1.11.2
- Web setup pins `@mediapipe/tasks-genai` 0.10.29, `@litert-lm/core` 0.17.1, ORT-web 1.30.0, Transformers.js 4.3.0.

## 1.11.1
- The built-in AI skill describes `flutter_gemma_builtin_ai` 0.3.0: Windows, Linux and setup.

## 1.11.0
- New `EmbeddingModel.activeBackend`: `getActiveEmbedder(preferredBackend:)` no longer goes unremarked.
- **Breaking for `implements EmbeddingModel`:** add `activeBackend` and `isClosed`; `extends` inherits defaults.
- The cached embedder is rebuilt when its model file changes, and built once under concurrent calls.

## 1.10.0
- Add `activationDataType` to `getActiveModel`; `float32` fixes wrong digits on some GPUs.

## 1.9.0
- New `initialize(embeddingTokenizers:)` — register one or embeddings throw; engines no longer bundle a tokenizer.
- Drop the dead `web/rag/` build from the published archive.

## 1.8.4
- FunctionGemma on `.litertlm` answers a tool result instead of repeating the call.
- Drop the example's 800 KB sqlite-vec wasm from the published archive.

## 1.8.3
- Inference skill: NPU needs a Gemma 4 bundle; Gemma 3 drops prefill chunks silently.
- Inference skill: macOS setup no longer adds iOS-only entitlements that break unsigned builds.
- Speech skill: recording needs microphone permission on iOS, macOS and Android.
- Fix `.litertlm` on iOS wrapping every prompt in turn markers twice; deprecate `StopTokenFilter`.

## 1.8.2
- Ship agent skills — `dart run skills@ get --all` teaches your AI assistant this package.

## 1.8.1
- Add `VectorStoreRepository.flush()`; custom implementations must declare it (#492).

## 1.8.0
- Whisper output language on `getActiveStt` and `transcribe` (#500).
- **Breaking for custom `SpeechRecognizer` implementations**: `transcribe` gained `language:` and the type gained a `language` field.

## 1.7.4
- Example: LFM2.5-230M and the `fromHuggingFace` install path.

## 1.7.3
- Fix `createChat` dropping `tools` — function calling on every non-FFI engine.
- Docs: bump web `@litert-lm/core` setup snippet to 0.17.0.

## 1.7.2
- Fix web sessions failing right after install because the active model was only half-saved.

## 1.7.1
- macOS setup snippet is now a thin shim; the staging logic ships with `flutter_gemma_litertlm` (#457).
- Drop the package-wide `kotlinx.coroutines` keep from the Android consumer rules so R8 can shrink them (#486).

## 1.7.0
- Hugging Face install (#454): `resolveHuggingFace` / one-call `installModel(…).fromHuggingFace(repo)`, with engines auto-registering their resolver.

## 1.6.5
- Tool-declaration injection is a declarative `InferenceChat` flag, not a hardcoded gemma4 check (no behavior change).

## 1.6.4
- Android plugin no longer applies KGP — Flutter's Gradle plugin does (#440).
- iOS floor is 15.0; only `flutter_gemma_mediapipe` still needs 16.0 (#441).

## 1.6.3
- Download updates are scoped to our own task group; `FileDownloader().updates` stays the host's (#445).

## 1.6.2
- Web: `ModelFileType.onnx` install is fileless — Transformers.js owns the repo, install just sets it active.

## 1.6.1
- `getActiveModel` compares every runtime param before reusing the cached model.
- Racing `getActiveModel` calls no longer share a model built for other params.
- Add `FilterField.validateSchema` — rejects duplicate field names, checked in release.
- Storage-specific name rules moved to the stores that have them, out of core.
- Document the canonical `FieldEquals` / `FieldRange` semantics both stores must honour.

## 1.6.0
- Add `ModelFileType.onnx` + ONNX engine chat-format routing — enables the new `flutter_gemma_onnx` engine.

## 1.5.9
- Add getActiveModel(preferredVisionBackend:, preferredAudioBackend:) — per-encoder backend override (default CPU).

## 1.5.8
- docs: Windows discrete GPU is fixed in litertlm 1.4.0 — the README said it was still broken.

## 1.5.7
- fix: getInstalledModels(stt/tts/embedding) returns installed models — were mistagged inference (#391; concurrent fix by @o-mid in #421).

## 1.5.6
- fix: Gemma 4 streaming no longer leaks raw tool-call JSON into the text channel.

## 1.5.5
- Add optional onMaxToolTurns to generateChatResponseWithTools (lets a driving consumer surface its own maxToolTurns terminal).

## 1.5.4
- fix: balance committed tool-calls when the generation stream errors mid-turn (generateChatResponseWithTools).

## 1.5.3
- Add InferenceChat.generateChatResponseWithTools — the reusable function-calling driver loop.
- Add TtsModelType.inflect — Inflect-Nano-v2 TTS bundle, with cross-repo G2P file routing.
- fix: record the Gemma 4 SDK tool-call in history on the streaming path (was orphaned).

## 1.5.2
- Add TtsModelType.qwen3.

## 1.5.1
- fix: namespace companion install files (tokenizers, TTS bundle aux) per model, fixing STT/embedding tokenizer collisions.
- fix: migrate legacy (pre-namespacing) tokenizer installs on restore, so existing STT/embedding models keep working after upgrade.

## 1.5.0
- Add genai_primitives support via `package:flutter_gemma/genai.dart` — use `ChatMessage` with `InferenceChat` (#181).
- New `sendMessage`/`generateContent` (+ streams) covering text, vision, audio, thinking, and tool calls (#181).
- Add facade identity getters `activeModelSpec`/`activeEmbedderSpec`/`activeSttSpec`/`activeTtsSpec` + `getModelPath`.
- Add facade storage `getStorageInfo`/`getOrphanedFiles`/`cleanupStorage`/`performCleanup` — surface real errors, not success-shaped defaults.
- Add `FlutterGemma.rag` namespace (add/search/removeDocument/stats/clear); plumb `removeDocument` (#390 audit).
- Add `uninstallEmbedder`/`uninstallStt`/`uninstallTts` (delete all files); route `uninstallModel` off the deprecated path.
- Export `ModelSource` + `FileSystemService` from the barrel (required public parameter types).
- Document `FlutterGemmaPlugin` as the low-level SPI tier; `FlutterGemma` facade is the canonical entry.

## 1.4.2
- docs: document the on-device voice loop (VoiceSession, STT → LLM → TTS) shipped in flutter_gemma_speech 0.3.0.

## 1.4.1
- feat: on-device text-to-speech — selectable TTS model (Matcha today) via `installTts()`/`getActiveTts()`/`synthesize()`, raw PCM output.
- feat: core TTS contracts (SpeechSynthesizer, TtsModelType, TtsBackendProvider/TtsRegistry, ModelManagementType.tts) + `RuntimeConfig.artifactPaths`.
- fix: model-load failure no longer emits a spurious unhandled-async (orphaned completer in createStt/createModel/createEmbedding, #394).

## 1.4.0
- feat: on-device speech-to-text — new opt-in `flutter_gemma_speech` runs a selectable ASR model (moonshine today) on all native platforms via `installStt()`/`getActiveStt()`/`transcribe()`.
- feat: STT contracts (SpeechRecognizer, SttModelSpec/SttModelType, SttBackendProvider/SttRegistry) + LiteRT engine consolidation into flutter_gemma_litertlm.
- fix: Windows fresh downloads landed in a `$PWD`-relative dir, not `%LOCALAPPDATA%` — model installed but not found at load.

## 1.3.2
- Docs: add community models to the README model list (SmolLM3-3B, Phi-4-mini-reasoning, Qwen2-VL, SmolVLM2, LLaVA-OneVision).
- Docs: bump web `@litert-lm/core` setup snippet to 0.14.0.

## 1.3.1
- Fix multi-GB background_downloader temp-file leak on Android (#383).
- Deterministic download task IDs (sha256 of path triple) — stable across restarts and signed-URL rotation (#383).
- getOrphanedFiles()/cleanupStorage() now surface and delete orphaned downloader fragments (#383).
- Cancel tasks before reset in cleanup so paused temp files are deleted (#383).
- Resume watchdog cancels the dead native task instead of leaking it (#383).

## 1.3.0
- Add ModelFileType.builtIn for OS system models (Gemini Nano / Apple FM)

## 1.2.3
- Cancel native `.litertlm` decoding before session teardown to avoid an ANR (#364, #373).
- Re-run macOS companion staging on incremental builds so LiteRtLm stays patched (#368).
- Fix FunctionGemma parser dropping array, number, boolean and object arguments (#366).
- Fix FunctionGemma streaming truncating a tool call at the first `}` (#366).
- Fix FunctionGemma tools prompt to match the model's `chat_template` (#367).
- Keep tool properties in declared order; sorting them would break existing fine-tunes (#367).
- Reject union-typed properties with a clear error instead of a raw `_TypeError` (#367).
- Emit `parameters:{type:OBJECT}` for no-argument FunctionGemma tools (#367).
- Keep an empty `required:[]` inside FunctionGemma `items`, as the template does (#367).
- Stop `<end_function_call>` leaking into FunctionGemma chat text and history (#366).
- Infer a FunctionGemma property type from `properties`/`items`, else require it (#367).
- Render numbers, booleans and `None` the way the template's Python does (#367).
- Parse a bare `None` argument as null instead of the string `"None"` (#366).
- Refuse a FunctionGemma call whose body cannot be parsed in full (#366).
- Warn instead of silently ignoring `ToolChoice.required` on FunctionGemma (#367).
- Send FunctionGemma tool results as the template does, not as `result:{json}` (#367).
- Stop opening a second model turn after a FunctionGemma tool response (#367).

## 1.2.2
- Fix AGP 9 build on `android.builtInKotlin=false` — apply KGP unless built-in Kotlin is on, so the plugin's Kotlin compiles (#360).

## 1.2.1
- Fix SmartDownloader resume-loop hang — cap resume attempts + arm a watchdog timer (#355).
- Fix foreground downloads on Android — configure a running notification so the service actually activates (#356).
- Scope foreground notification to explicit flag + auto-request `POST_NOTIFICATIONS` at runtime (#356).
- Document Android 14+ manifest requirement: host app needs `FOREGROUND_SERVICE_DATA_SYNC` + service merge (#356).
- Guard double-complete, add permission timeout, check `resume()`'s bool, arm reattach watchdog (#355 #356).

## 1.2.0
- Add `skillExecutors:` to `FlutterGemma.initialize` + the `SkillExecutorProvider`/`SkillExecutorRegistry` seam for the new opt-in `flutter_gemma_agent` package.
- Declare `libOpenCL.so` (+ `-car`/`-pixel` ICDs) in the plugin manifest — completes the #324 Mali GPU fix (#349; 1.1.1 only opened the SP-HAL door).
- Fix web "No active inference model set" right after install — await the model manager's rehydrate before reading the active model.
- Fix web Gemma 4 tool-calling — parse the raw `<|tool_call>` tokens the browser runtime leaves unconverted, and guard a crash when the SDK returns `content` as a String.

## 1.1.2
- Migrate Android module to Built-in Kotlin — apply KGP only on AGP < 9, ready for AGP 9+ (#323).
- Add optional `downloadUpdatesStream`/`fileSystemService` injection to `FlutterGemma.initialize` (#342, thanks @hughesyadaddy).

## 1.1.1
- Declare `libvndksupport.so` for the Android GPU backend — fixes Mali GPU hard-freeze on Android 12+ (#324).

## 1.1.0
- Add declared-column `Filter` support: `FilterSchema`/`FilterField`/`FilterFieldType` + `configure(FilterSchema)` on `VectorStoreRepository`.
- Add optional `filterSchema:` to `FlutterGemma.initialize` (threaded to the vector store at registration).
- Deprecate `enableHnsw` (no-op; vector search now runs inside the store engine).

## 1.0.3
- Add `clearActiveInferenceIdentity`/`clearActiveEmbeddingIdentity` (non-breaking defaults on `ModelFileManager`).
- Export `DownloadError`/`DownloadException` from `flutter_gemma.dart`.
- Example: downloaded-models list screen with delete/copy-path/load and gated-model 401/403 dialog.

## 1.0.2
- Add `maxOutputTokens` on `createSession`/`openSession`/`createChat`/`openChat` to cap generation length (#318).
- Clarify `maxTokens` dartdoc: it's the context window (input + output), not reply length.

## 1.0.1
- Fix empty assistant turn polluting chat history after `stopGeneration()` — cancelled/empty responses are no longer recorded (#325).
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0 of the modular package split (see 1.0.0-rc.1 below for full notes).
- dart2wasm-clean public graph — `dart:io` is off the web/wasm import graph.
- Dropped pigeon from core; value types are plain Dart in `core/domain/platform_types.dart`.
- SDK floor raised to Dart 3.12 / Flutter 3.44; `large_file_handler` `^0.5.0`.

## 1.0.0-rc.1
- **Modular package split**: core `flutter_gemma` + opt-in `flutter_gemma_litertlm` / `flutter_gemma_mediapipe` / `flutter_gemma_embeddings` / `flutter_gemma_rag_qdrant` / `flutter_gemma_rag_sqlite`.
- **New `FlutterGemma.initialize(inferenceEngines:, embeddingBackends:, vectorStore:)`** — register the opt-in packages you added; core registers none by default.
- **No API changes** to model / session / chat / embedding / RAG calls — see [MIGRATION.md](MIGRATION.md).
- **Removed** the legacy sqlite + local_hnsw vector store (native RAG → qdrant-edge).
- **Fix Windows cancel/close hang**: gate the cycle-fix dylib staging to Apple only (Windows registers straight from the cache).

## 0.16.4
- **Fix embedding freezing the UI thread** (#299): forward pass runs on a background isolate.
- **Fix Windows build on non-UTF-8 locales** (#212): add `/utf-8` to the MSVC plugin target.
- **Fix macOS "Cycle inside Flutter Assemble" build error** (#300, thanks @fotiDim): stage native dylibs out of the cache dir.

## 0.16.3
- **Android Qualcomm NPU** (`PreferredBackend.npu`): auto-extracts QNN dispatch libs from APK at runtime (#293).
- **Fix Android GPU sampler CPU fallback** (#270): GPU OpenCL/WebGPU samplers now resolve correctly, restoring ~3× decode speed.
- **qdrant-edge 0.7.1**: drops vendored fork, `wal_options` now native in upstream.

## 0.16.2
- **Concurrent sessions** (#226): `openSession()`/`openChat()` run independent dialogues on one loaded model.
- **Web `.litertlm` inference** via `@litert-lm/core` early preview (WebGPU/WASM, text-only).
- **Fix `getActiveModel()` after app restart** (#227): mobile + web auto-restore from prefs.
- **Report initialized backend** (#288, thanks @merlinnot): `InferenceModel.activeBackend` getter + NPU→GPU→CPU fallback on the FFI path with `BackendInitException` carrying per-attempt details.
- Bump `large_file_handler` ^0.3.1 → ^0.4.0.

## 0.16.1
- **LiteRT-LM v0.12.0** native bump (commit `ffed38a`): NPU dispatch now available on Linux/macOS as well as Windows.
- **Fix iOS App Store upload (ITMS-90208)** (#286): iOS LiteRT-LM and qdrant-edge artifacts repacked.
- **Fix iOS Native Assets strip step on Xcode 26** (#289, thanks @merlinnot): emit `libLiteRtLm.dylib` with `-Wl,-x` so `xcrun strip -x -S` succeeds during release builds.
- **Fix Windows install path** when `%LOCALAPPDATA%` env var is relative — falls back to `USERPROFILE\AppData\Local` then `getApplicationSupportDirectory()`.

## 0.16.0
- **Native vector store: qdrant-edge by default.** Replaces sqlite + local_hnsw on every native platform. Web unchanged (wa-sqlite). Old impl `@Deprecated`, removal in 1.0.
- **Filter DSL** for `searchSimilar(... filter: Filter(must: [...], should: [...], mustNot: [...]))`. Honored on native; silently ignored on Web.
- Fix desktop install/validate path mismatch — all paths now route through `FileSystemService`; legacy `Documents/` reads kept as fallback.

## 0.15.3
- example: add TranslateGemma 4B translation demo via task-first home navigation (#177).

## 0.15.2
- Unified embedding on LiteRT C API + Dart FFI on all native platforms (#264).

## 0.15.1
- **Fix Android GPU sampler dlopen failure** (#270, thanks @prithidevghosh): `patchelf --add-needed libLiteRtLm.so` on `libLiteRtTopK{OpenCl,WebGpu}Sampler.so`.
- **Desktop storage** (#179, co-author @ProjectEdge-Jim): use Application Support instead of Documents on Windows/macOS/Linux to avoid cloud-synced paths breaking FFI mmap.
- **Multi-image, FFI session metrics, prefix replay** (#262, thanks @frdteknikelektro): `Message.withImages([...])` for multi-image input, `chat`/`Conversation` session metrics via FFI, persistent prefix messages replayed on session rebuild after history truncation. Backward-compatible (`Message.withImage(...)` still works).
- **Skip sampler params on NPU backend**: `temperature`/`topK`/`topP`/`seed` are silently ignored when `PreferredBackend.npu` is selected — LiteRT-LM NPU executor only supports internal greedy sampling.
- **Windows Intel NPU end-to-end**: native-v0.11.0-b Windows tarball bundles Intel dispatch (`LiteRtDispatch.dll`), OpenVino runtime, TBB (~30 MB); FFI client passes `dispatch_lib_dir` + `use_hw_masking_for_npu=false` at engine_create so `PreferredBackend.npu` works on Intel LunarLake/PantherLake silicon without manual DLL placement.
- **Fix web build broken by 0.15.0**: `LiteRtLmFfiClient` stub on web was missing the `enableSpeculativeDecoding` parameter — dart2js failed compilation when web target was actually built.
- **CI**: standalone `build-litertlm-native-windows.yml` workflow for Windows-only rebuilds.

## 0.15.0
- **LiteRT-LM 0.11.0**: MTP-capable Gemma 4 + speculative decoding on macOS / iOS / Android / Windows.
- **`enableSpeculativeDecoding` flag** on `getActiveModel()` (null = model default; true/false to override).
- **Restore Android NPU support for `.litertlm`** (regression from 0.14.0): `PreferredBackend.npu` on Android `.litertlm` models routes through LiteRT-LM's `Backend::NPU` again — same as 0.13.x's Kotlin path before the FFI migration silently dropped it. Requires a Qualcomm QNN / Google Tensor / MediaTek dispatch lib on the device; without one, `engine_create` fails with a dispatch error. MediaPipe `.task` models still don't support NPU (MediaPipe SDK limitation, unchanged).
- **`PreferredBackend.npu` on desktop** (#261): macOS / Linux / Windows backend arm wired. Same dispatch-lib requirement as Android.
- **Linux known limitation**: post-MTP HF Gemma 4 revisions blocked upstream — `libLiteRtWebGpuAccelerator.so` segfaults during graph compile (filed `google-ai-edge/LiteRT-LM#2225`) and multi-signature vision encoder rejected by native (`engine_create` error). Workaround: pin pre-MTP HF revision `7fa1d78473894f7e736a21d920c3aa80f950c0db` for Linux users. Other platforms unaffected.
- **hook native cache**: marker-file based invalidation (`.flutter_gemma_native_version`) — bumps clean stale companion libs automatically.

## 0.14.5
- **Fix desktop embedding on pub.dev installs** (#250 follow-up): `tensorflowlite_c.{dll,so,dylib}` now bundled via Native Assets — regression from 0.14.0 setup-script removal.

## 0.14.4
- **Fix macOS dylib loading on pub.dev installs** (#255).
- **Fix `fromAsset` install on desktop** (#250 mode 2).
- **Fix Android x86_64 emulator crash on embedding init** (#250 mode 3).
- **Reduce native lib size**: iOS -63%, macOS -43%, Android -28%, Linux -16-18%.

## 0.14.3
- **Fix App Store ITMS-90208 rejection on iOS** (#245): downgraded patched `libGemmaModelConstraintProvider.dylib` minos 26.2 → 14.0 to match the other companion dylibs.
- **Fix Android Google Play 16KB page-size requirement** (#253): rebuilt `libLiteRtLm.so` with `-Wl,-z,max-page-size=16384`.
- **Fix Web RAG build pipeline** (#251): cross-platform `npm run build`, bundles `cache_api.js` + LiteRT WASM into `dist/`, ships `package.json` + `vite.config.js` in pub tarball.

## 0.14.2
- **Fix macOS `install_name_tool` failure** (#247): `dart run` / `build_runner` / `flutter test` on a pure-Dart library aborted with `larger updated load commands do not fit` because upstream Apple companion dylibs lack `-headerpad_max_install_names`. Skip them from Native Assets on macOS and bundle via `Podfile post_install` instead.
- **Fix Gemma 4 escape-token leakage in chat history** (#248): `<|"|>` tokens from `tool_calls.arguments` were written to history raw, making the model echo them on later turns. Strip recursively before persist via new `SdkResponseParser.cleanRawForHistory`.
- **Fix `modelFromAsset` install on desktop** (#250): the `large_file_handler` channel call threw `MissingPluginException` on macOS / Windows / Linux because the package only ships Android + iOS plugins. Now catches it and falls back to the in-memory `loadAsset → writeFile` path. Embedding (`localagents-rag`) and `.litertlm` FFI paths additionally fail fast with a typed message on non-arm64 Android (x86_64 emulator / armeabi-v7a) instead of a generic JVM crash — see new "Platform & Architecture Support" section in README.
- **macOS Podfile setup (BREAKING for macOS app projects)**: app projects must update `macos/Podfile post_install` to the new snippet (see README → macOS Setup). iOS / Linux / Windows / Android unaffected.
- **Perf debug logs**: `[*/perf]` lines break out cost of dylib load, `engine_create`, prefill, decode — visible via `debugPrint` in both debug and release builds.

## 0.14.1
- **Web build fix (#244)**: 0.14.0 broke web compilation by statically importing `core/ffi/litert_lm_client.dart` (which imports `dart:ffi`) through the `flutter_gemma_interface.dart` → `mobile/flutter_gemma_mobile.dart` chain. JS/Wasm targets cannot compile `dart:ffi`. Added conditional imports in `mobile/flutter_gemma_mobile.dart` that swap `litert_lm_client.dart` and `ffi_inference_model.dart` for `*_stub.dart` shims on `dart.library.js_interop`. The web plugin (`FlutterGemmaWeb`) registers itself as `FlutterGemmaPlugin.instance` before any FFI code path runs, so the stubs' constructors (which throw `UnsupportedError`) are never actually invoked on web.
- **App Store fix (#245, ITMS-90432)**: 0.14.0 dropped `lib*.dylib` symlinks alongside the bundled `.framework/` accelerators in `Runner.app/Frameworks/` so LiteRT-LM's `gpu_registry` could `dlopen` them by basename — App Store Connect rejected those builds with "Unexpected file found in Frameworks". 0.14.1 patches the upstream LiteRT-LM source (`runtime/components/sampler_factory.cc` and `litert/runtime/accelerators/gpu_registry.cc`) to load Apple platform accelerators via `@executable_path/../Frameworks/<X>.framework/<X>` (macOS) / `@executable_path/Frameworks/<X>.framework/<X>` (iOS) instead of `libX.dylib`. Native Assets bundles the framework bundles correctly out of the box; no host-side Podfile symlinks needed. Patch applied during local Bazel rebuild — see `native/litert_lm/patch_c_api.sh` section 10.
- **Gemma 4 native function calling**: New `ModelType.gemma4` routes tool definitions to LiteRT-LM SDK via `litert_lm_conversation_config_set_tools` (OpenAI Chat Completions JSON). SDK applies `chat_template.jinja` through minja, renders native `<|tool>declaration:...<tool|>` tokens, and parses the model's `<|tool_call>...<tool_call|>` response back into structured `tool_calls` JSON. flutter_gemma reads the result via `SdkResponseParser.extractToolCalls` (handles parallel calls and the multimodal `content[]` path) and returns `FunctionCallResponse` to the app — no Dart-side prompt engineering needed.
- **Escape token cleanup**: Strips leftover `<|"|>` Gemma 4 escape tokens from string arguments (recursively, including nested maps/lists).
- **`example/lib/models/model.dart`**: Gemma 4 E2B / E4B entries switched to `modelType: ModelType.gemma4`.

## 0.14.0
- **Desktop FFI rewrite**: macOS, Linux, Windows now run LiteRT-LM directly via `dart:ffi` against the C API. Removed Kotlin/JVM gRPC server, Azul Zulu JRE 24 download, and `litertlm-server.jar` bundling. Engine creation ~2 s (was ~10–15 s incl. JVM cold-start)
- **iOS GPU acceleration**: Metal delegate for `.litertlm` models on iPhone (Gemma 3 1B, Gemma 3n E2B, Gemma 4 E2B). Multimodal vision + audio work on device
- **Linux + Windows GPU**: WebGPU/Vulkan on Linux, WebGPU/DX12 on Windows; DXC runtime (`dxil.dll` + `dxcompiler.dll` v1.9.2602) bundled in the Windows native archive — no manual install required
- **Android: drop Kotlin LiteRtLm dependency** — `.litertlm` models on Android now go through the same Dart FFI path as desktop/iOS (was `com.google.ai.edge.litertlm:litertlm-android` AAR before). MediaPipe stays for `.task`/`.bin` models
- **iOS Simulator**: CPU-only — Metal sim has 256 MB single-allocation cap, LLM weight tensors exceed it
- **Unified FFI client**: All five platforms (Android, iOS, macOS, Linux, Windows) share `LiteRtLmFfiClient` (`lib/core/ffi/`)
- **Native log capture**: `stream_proxy_redirect_stderr` exposes glog/abseil output on iOS/Android via temp file; helps diagnose engine init failures
- **Native prebuilts**: Fetched at build time via `hook/build.dart` from GitHub release `native-v0.10.2`; SHA256-verified, bundled via Native Assets
- **macOS / iOS setup**: requires a small `post_install` block in your `Podfile` to symlink `lib*.dylib` next to the bundled `.framework`s — `gpu_registry` calls `dlopen` by basename. See the [macOS Setup section in README](README.md#macos-setup) for the exact snippet (iOS works via the same pattern in `example/ios/Podfile`)

## 0.13.6
- **ModelType.qwen3**: New model type for Qwen3 models with thinking support
- **Disable Qwen3 thinking at model level**: `/no_think` appended automatically when `isThinking: false` — faster TTFT
- **Configurable maxFunctionBufferLength** (#229): `createChat(maxFunctionBufferLength: 2048)` for long function call args
- **Fix Windows path parsing** (#233): `FileSource` now handles backslash paths correctly
- **removeDocument** (#232): `VectorStoreRepository.removeDocument(id:)` to delete documents from vector store

## 0.13.5
- **Fix Qwen3 thinking mode (#224)**: Qwen3 `<think>` tags now stripped automatically

## 0.13.4
- **Fix iOS compile error (#222)**: XNNPack delegate type mismatch in `EmbeddingModel.swift`
- **Fix iOS arm64 simulator (#216)**: Removed `TensorFlowLiteSelectTfOps` — simulator builds work on Apple Silicon

## 0.13.3
- **Fix macOS SIGSEGV (#219)**: Per-conversation mutex in gRPC server prevents `conversation.close()` racing with `sendMessageAsync` on a native thread → use-after-free in C++ fixed
- **Fix macOS desktop Metal accelerator**: `setup_desktop.sh` now downloads `libLiteRtMetalAccelerator.dylib` from GitHub Release so GPU inference uses the Metal delegate instead of falling back to static C API
- **Fix iOS pod install hanging (#220)**: Replaced `TensorFlowLiteSwift` (source pod — cloned entire TensorFlow repo) with direct `TensorFlowLiteC` C API in `EmbeddingModel.swift`
- **Fix Windows >2 GB model error (#212)**: Clear error message when model file exceeds 2 GB on Windows (known upstream 32-bit stat() overflow in litertlm_jni.dll, google-ai-edge/LiteRT-LM#1494)
- **Fix iOS arm64 simulator build (#216)**: Excluded arm64 from simulator archs to fix build on Apple Silicon Macs

## 0.13.2
- **FileSource absolute paths**: Accept both Unix (`/path`) and Windows (`C:\path`) absolute paths in FileSource validation
- **Package metadata**: Updated pubspec description to reflect current feature set (desktop, vision, audio, function calling, embeddings, on-device RAG)
- **Desktop CI**: Added Linux smoke tests for gRPC server integration

## 0.13.1
- **LiteRT-LM 0.10.0**: Updated Android and JVM SDK from 0.9.0 to 0.10.0
- **Gemma 4 Thinking Mode**: `isThinking: true` now works with Gemma 4 E2B/E4B models (Android, iOS, Desktop; not Web)
- **Fix cancel download**: Cancel download now works correctly (#196)
- **Fix `large_file_handler` platform support**: Conditional imports for pub.dev platform analysis compatibility

## 0.13.0
- **Gemma 4 E2B/E4B**: Added support for next-gen multimodal models (text + image + audio)
- **systemInstruction**: New parameter in `createChat()` and `createSession()` for setting system-level context
- **ModelFileType.litertlm**: New file type to properly handle `.litertlm` models across platforms
- **iOS LiteRT-LM support**: `.litertlm` models now work on iOS
- **stopGeneration on iOS**: Supported for `.litertlm` models
- **MediaPipe GenAI 0.10.33**: Updated iOS (from 0.10.24) and Android (from 0.10.29)
  - iOS: GPU backend selection via `preferredBackend` (Metal delegate now activated)
  - iOS: Audio modality support (`addAudio` + `enableAudioModality`)
  - Android: Unified inference engine (CPU-only path removed), improved error handling
  - Web: Updated to 0.10.27
- **Example WASM compatibility**: Replaced direct `dart:io` imports with conditional imports for WASM compilation support
- **Benchmark integration test**: `example/integration_test/benchmark_comparison_test.dart` for comparing model performance on device

## 0.12.8
- **ToolChoice enum**: `auto` / `required` / `none` parameter in `createChat()` to control tool calling behavior
- **Parallel Tool Calls**: `ParallelFunctionCallResponse` for multiple function calls in one response
- **Strategy Pattern Parser**: Per-model `FunctionCallFormat` implementations (Gemma, Qwen, DeepSeek, Llama, Phi, FunctionGemma)
- **`<tool_call>` Format**: Qwen/Mistral-style function call parsing
- **ModelType.phi**: Dedicated model type for Phi-4 with `<|tool_calls|>` format support
- **NPU Fix**: Pass `nativeLibraryDir` to LiteRT-LM `Backend.NPU()`
- **Embeddings**: Models return L2-normalized vectors (dot product = cosine similarity)
- **Windows/Linux Embeddings Fix**: TFLite C library now correctly copied to build output (#200)

## 0.12.7
- **Dual-Prefix Embeddings (TaskType)**: Improved RAG retrieval quality with query/document prefixes
  - `TaskType.retrievalQuery` (default) — for search queries
  - `TaskType.retrievalDocument` — for document indexing
  - Follows Google RAG SDK convention (`EmbedData.TaskType`)
  - All platforms: Android, iOS, Web, Desktop
  - `addDocument()` automatically uses document prefix
- **Desktop Embeddings**: Run `.tflite` embedding models (EmbeddingGemma, Gecko) on macOS, Windows, Linux
  - LiteRT C API via `dart:ffi` — no gRPC, no JVM overhead
  - Pure Dart tokenizer via `dart_sentencepiece_tokenizer` (BPE + Unigram, auto-detect format)
  - LiteRT C library built from google-ai-edge/LiteRT v2.1.3
  - XNNPACK delegate with default options (QS8/QU8 quantization support)
  - Desktop scores match Android/Python exactly (cosine similarity 0.708)
  - CI workflow for building LiteRT C library on all 4 platform/arch combinations
- **Unified VectorStore**: Single Dart implementation using `sqlite3` dart:ffi replacing platform-specific code
- **Test Migration**: Removed `patrol` dependency, migrated all integration tests to standard `integration_test`

## 0.12.6
- **LiteRT-LM 0.9.0-beta**: Updated from 0.9.0-alpha02 on Android and Desktop (JVM)
  - Breaking API change: Backend enum to Backend factory constructors
- **Cancel Generation**: Implemented on Android, Desktop, and Web
  - Android LiteRT-LM: `Conversation.cancelProcess()`
  - Desktop: gRPC `CancelGeneration` RPC
  - Web: `LlmInference.cancelProcessing()` (MediaPipe 0.10.26)
- **MediaPipe Web 0.10.26**: Pinned CDN version (was @latest)
- **E2E Integration Tests**: Full inference test suite
  - Parameterized tests for both MediaPipe and LiteRT-LM engines
  - Multimodal tests: vision (Android, iOS, Web, Desktop) + audio (Android, Desktop)
  - Cancel, lifecycle, dual-engine tests

## 0.12.5
- **iOS Tokenizer Rewrite**: Replaced SentencePiece C++ with pure Swift tokenizers (BPE + Unigram)
  - Eliminates protobuf symbol conflict between SentencePiece and TensorFlow Lite (#184)
  - Auto-detects tokenizer type from `model.type` field in tokenizer.json
  - Supports both EmbeddingGemma (BPE) and Gecko (Unigram) models
- **HNSW Vector Search**: O(log n) approximate nearest neighbor search for VectorStore
  - Cross-platform: Android (Kotlin), iOS (Swift), Web (JavaScript)
  - Configurable M and efConstruction parameters
  - Falls back to brute-force for small datasets
- **iOS Embeddings**: `iosPath` parameter for platform-aware tokenizer downloads
  - Pre-converted tokenizer.json files on CDN (no SentencePiece dependency on iOS)
- **Desktop JAR Fix**: Updated `litertlm-server.jar` URL to v0.12.5 (#189)
- **Bug Fixes**:
  - Fixed iOS embedder crash due to protobuf symbol conflict (#184)
  - Removed deprecated `package` attribute from AndroidManifest.xml

## 0.12.4
- **Android ProGuard Fix**: Added ProGuard rules for LiteRT-LM classes (#185)

## 0.12.3
- **Android LiteRT-LM Engine**: Added LiteRT-LM inference engine for Android
  - Automatic engine selection based on file extension (`.litertlm` → LiteRT-LM, `.task/.bin` → MediaPipe)
  - NPU acceleration support (Qualcomm, MediaTek, Google Tensor)
- **Audio Input Support**: Audio input for Gemma 3n models via LiteRT-LM
  - Platforms: Android + Desktop (macOS, Windows, Linux)
  - WAV format (16kHz, mono, 16-bit PCM)
  - `supportAudio` parameter in session configuration
- **Desktop LiteRT-LM Fixes**: Fixed text chat and audio on desktop platforms
  - Switched from Flow-based to Callback-based async API (matches Android)
  - Audio transcription now works correctly
- **Bug Fixes**:
  - Fixed model deletion not removing metadata
  - Fixed model creation failure blocking switching to another model
  - Fixed download issues for large models

## 0.12.2
- **Model Deletion Fix**: Fixed model deletion not removing metadata (#169)
- **Model Switch Fix**: Fixed model creation failure blocking switching to another model (#170)
- **Android SDK**: Updated to API 36

## 0.12.1
- **Web Large Model Support**: `WebStorageMode` for models >2GB via OPFS streaming (#162)
- **Desktop JAR Checksum Fix**: Fixed JAR checksum mismatch in setup scripts (#167)

## 0.12.0
- 🖥️ **Desktop Support**: Full support for macOS, Windows, and Linux platforms
  - **macOS**: Apple Silicon (M1/M2/M3/M4) with Metal GPU acceleration
  - **Windows**: x86_64 with DirectX 12 GPU acceleration
  - **Linux**: x86_64 and ARM64 with Vulkan GPU acceleration
- 🏗️ **LiteRT-LM Architecture**: Desktop uses gRPC server with bundled JRE for inference
  - Automatic JRE 21 download and native library extraction
  - Dynamic port allocation prevents conflicts
  - Supports `.litertlm` model format only (MediaPipe `.task`/`.bin` not supported on desktop)
- 📚 **Desktop Documentation**: Comprehensive setup guide in DESKTOP_SUPPORT.md

## 0.11.16
- 🐛 **iOS Embeddings Fix**: Fix crash on repeated embedding inference (#155)

## 0.11.15
- 🤖 **FunctionGemma Single-Turn Mode**: FunctionGemma now operates in single-turn mode by design (clears history after each response)
- 🐛 **Download Resume Fix**: Fixed model download resume after interruption

## 0.11.14
- 🤖 **FunctionGemma Support**: Added `ModelType.functionGemma` for Google's specialized function calling model
  - Pre-converted models available on HuggingFace
  - Fine-tuning Colab notebooks (3-step pipeline)
- 🐛 **Batch Embeddings Fix**: Fixed type cast issue in platform channel for batch embeddings (#142)

## 0.11.13
 - ✅ **iOS Embeddings Fix**: XNNPACK + SentencePiece integration for better results on iOS
 - 🌐 **Web CDN**: Modules available via jsDelivr (`@0.11.13/web/*.js`)

## 0.11.12
 - 🌐 **Web VectorStore**: Full RAG support on web with SQLite WASM
   - Uses wa-sqlite with OPFS storage (10x faster than IndexedDB)
   - Cross-platform parity: Android, iOS, and Web now all support VectorStore
 - 🐛 **Android 16KB Page Size Fix**: Updated `tasks-vision-image-generator` to 0.10.26.1 for Android 15+ compatibility
 - ⬆️ **Kotlin Update**: Upgraded to Kotlin 2.1.0 in example app

## 0.11.11
 - 🐛 **Mobile Build Fix**: Fixed compilation errors on iOS/Android platforms

## 0.11.10
 - 💾 **Web Persistent Caching**: Models now persist across browser restarts using Cache API
 - ⚠️ **BREAKING CHANGE**: Explicit initialization now required
   - **ACTION REQUIRED**: Add `await FlutterGemma.initialize()` in `main()` before using the plugin

## 0.11.9
 - 🌐 **Web Embedding Support**: Added support for embedding generation on web platform
 - 🐛 **Web Example App**: Fixed bugs in example app on web platform

## 0.11.8
 - 🤖 **CI/CD Automation**: Added GitHub Actions workflows for automated testing and release builds
 - ☕ **Support the Project**: Added Ko-fi donation button for community support

## 0.11.7
 - 🚀 **VectorStore Optimization** ⚠️ **BREAKING (RAG only)**:
   - **71% smaller storage**: Binary BLOB format instead of JSON (3 KB vs 10.5 KB per 768D embedding)
   - **6.7x faster reads**: ~75 μs vs ~500 μs per document search
   - **3.3x faster writes**: ~45 μs vs ~150 μs per document insertion
   - **Dynamic dimensions**: Auto-detect any embedding size (256D, 384D, 512D, 768D, 1024D, 1536D, 3072D, 4096D+)
   - **iOS implementation**: Full VectorStore support on iOS (was stubs only)
   - **Cross-platform parity**: Identical behavior on Android and iOS
   - ⚠️ **ACTION REQUIRED**: Existing vector databases will be recreated on upgrade (re-index required)

## 0.11.6
 - 🐛 **iOS Simulator Fix**: Fixed "Filename cannot contain path separators" crash on iOS Simulator (#127)
 - 🔧 **Download Service Refactoring**: Unified download implementation, removed legacy code (~100 lines)
 - 🚫 **Download Cancellation**: Added CancelToken pattern (Dio-style) for cancelling downloads (NON-BREAKING)
 - 🧹 **API Cleanup** ⚠️ **BREAKING**: Removed unused `canResume()`, `resume()`, `cancel()` methods from DownloadService interface

## 0.11.5
 - 🐛 Fixes: Some fixes for new Modern API
 - ⚠️ Deprecated: Marked legacy asset/file management methods as deprecated with migration hints
 - 📚 Documentation: Updated README with Modern API examples and complete parameter documentation

## 0.11.4
- **New**: Fluent builder API with `FlutterGemma.installModel().fromNetwork/fromAsset/fromBundled/fromFile()`
- **Architecture**: Sealed classes for type-safe sources, dependency injection via ServiceRegistry, platform-specific handlers
- **Bundled Models**: Support for including small models in production builds via native bundles (iOS: Bundle.main, Android: assets)
- **Backward Compatible**: Legacy API (`modelManager.downloadModelWithProgress()`) still works as facade

## 0.11.3
- 🌐 **Web Multimodal Support**: Added full multimodal image processing support for web platform
- 📚 **MediaPipe 0.10.25**: Updated to MediaPipe GenAI v0.10.25 for web compatibility
- 📦 **LiterTLM Format Support**: Added support for `.litertlm` model files optimized for web platform

## 0.11.2
- 🛡️ **Fixed**: Updated ProGuard rules for Android release build compatibility

## 0.11.1
- 🐛 **Fixed**: Export missing ModelType and other public API types to resolve import issues

## 0.11.0
- 🚀 **Embedding Models Support**: Added full support for text embedding models
- 🔧 **Unified Model System**: All models (inference and embedding) now use the same download and management pipeline
- 📝 **ModelSpec Architecture**: Introduced `InferenceModelSpec` and `EmbeddingModelSpec` for better model organization
- 🛡️ **Smart Cleanup System**: Added automatic cleanup of orphaned files with resume detection capabilities
- 🔄 **Model Replace Policies**: Separate policies for model downloading `replace` and `keep`
- 📱 **Example App Integration**: Added embedding models download screen and embeddings generation demo screen

## 0.10.6
- 🔧 **Model Replace Policy**: Added configurable model replacement system with keep/replace options and `ensureModelReady()` method
- 📥 **Enhanced Downloads**: Added HuggingFace CDN ETag issue handler with smart retry logic and exponential backoff
- 🔄 **Download Reliability**: New `HuggingFaceDownloader` wrapper to handle CDN server inconsistencies and resume failures
- 📁 **ModelFileType System**: Introduced distinction between `.task` files (MediaPipe-handled) and `.bin/.tflite` files (manual formatting)
- 🔐 **Android Security**: Added network security configuration for HuggingFace CDN access with proper permissions
- 🐛 **Download Fixes**: Fixed Android download timeouts, stream management, and ETag mismatch issues
- 🖼️ **Image Corruption Fix**: Added comprehensive image processing system to prevent AI model corruption on Android
- 🔄 **Example App**: Added sync/async response method selection in chat interface

## 0.10.5
- 🛑 **Stop Generation**: Added Android support for stopping text generation mid-process with `session.cancelRequestGenerationAsync()` (#89, #19, #34)
- 🐛 **Screen Close Fix**: Fixed crash when closing screen during active generation by implementing proper StreamSubscription cleanup (#89)  
- 🐛 **Model Loading Fix**: Fixed model install check with partial downloads by adding orphaned files cleanup (#84)
- 🗑️ **File Management**: Added automatic cleanup of corrupted/incomplete model files with atomic SharedPrefs updates
- 📱 **iOS Requirements**: Updated deployment target to 16.0 for MediaPipe GenAI compatibility
- 🔧 **Error Handling**: Improved error recovery with automatic file cleanup on failed downloads
- 📚 **Documentation**: Updated model capabilities table and comprehensive usage examples

## 0.10.4
- 📚 **Documentation**: Updated README with comprehensive model information and usage examples

## 0.10.3
- 📥 **Background Downloads**: Added background download support for model files

## 0.10.2
- 🚀 **New Models**: Added support for 4 new compact models:
  - [Gemma 3 270M](https://huggingface.co/litert-community/gemma-3-270m-it) - Ultra-compact text-only model (0.3GB)
  - [TinyLlama 1.1B](https://huggingface.co/litert-community/TinyLlama-1.1B-Chat-v1.0) - Lightweight chat model (1.2GB)
  - [Hammer 2.1 0.5B](https://huggingface.co/litert-community/Hammer2.1-0.5b) - Action model with strong function calling (0.5GB)
  - [Llama 3.2 1B](https://huggingface.co/litert-community/Llama-3.2-1B-Instruct) - Instruction-tuned model (1.1GB)
- ⚙️ **Backend Switching**: Added individual CPU/GPU backend switcher for each model in the example app
- 🔍 **Advanced Model Filtering**: Added expandable filter section with feature-based filtering:
  - Filter by Multimodal support (vision capabilities)
  - Filter by Function Calling support 
  - Filter by Thinking Mode support
  - Animated expandable UI with clear visual indicators
- 📊 **Model Sorting**: Added comprehensive sorting options:
  - Sort alphabetically (A-Z)
  - Sort by model size (smallest to largest)
  - Default order (Gemma models prioritized)
- 📏 **Improved Model Display**: Separated size information from model names for cleaner presentation
- 🌐 **Full English Localization**: Converted all UI text from Russian to English
- 📊 **Results Counter**: Added dynamic counter showing filtered results ("Showing X models")
- 🎨 **Enhanced Filter UI**: FilterChip components with color-coded selections matching feature badges
- 🎯 **Model Organization**: Reorganized model list with Gemma models prioritized at the top
- 🛠️ **Function Calling**: Enhanced function calling support with Hammer 2.1 action model
- 📱 **UI Improvements**: New card-based design with individual backend controls per model
- ✅ **Model Capabilities**: Fixed and verified multimodal support flags for all models
- 📚 **Documentation**: Updated README and model feature support table with new models

## 0.10.1
- 🧠 **Thinking Mode**: Added thinking mode support for DeepSeek models with persistent thinking bubbles
- 🔧 **Function Call Fixes**: Fixed function calls detection in the middle of responses
- 💬 **UI Improvements**: Fixed loading indicator display after function calls
- 🔄 **JSON Response Handling**: Enhanced handling of JSON responses after function execution
- 📚 **Documentation**: Updated README with latest API changes and improved examples
- 🎨 **Code Quality**: Removed Russian comments and improved code consistency

## 0.10.0
- ✨ **Function Calling**: Added support for function calling, allowing models to interact with external tools.
- 🔧 **Improved Chat API**: Enhanced the chat API to support function calls and tool responses.

## 0.9.0
- 🖼️ **MULTIMODAL SUPPORT**: Added full support for text + image input with Gemma 3 Nano vision models
- 🎯 **Enhanced Message API**: New `Message` class with support for text, image, and multimodal content
    - `Message.text()` - for text-only messages
    - `Message.withImage()` - for text + image messages
    - `Message.imageOnly()` - for image-only messages
    - `message.hasImage` - to check if message contains image
- 📱 **Vision Models**: Full support for Gemma 3n E2B and E4B models with image understanding
- 🌐 **Web Platform**: Added graceful degradation with debug warnings for unsupported features

## 0.8.6
- 🚀 **GEMMA 3 NANO SUPPORT**: Added full support for Gemma 3 Nano models
- ⚡ Optimized session parameters for Gemma 3n models (temperature: 0.6, topK: 40, topP: 0.9)
- 🛡️ Added automatic fallback session creation for `input_pos != nullptr` errors
- 🎯 Added Gemma 3n model detection and compatibility handling
- 💪 Enhanced error handling for TensorFlow Lite model initialization
- 🔧 Fixed iOS session initialization with proper input position handling
- 📱 Improved mobile inference model with optimized parameters
## 0.8.5
- Upgraded Mediapipe to 0.10.24 for iOS and Android
- Added support of **Gemma3**, **Phi-4** and **DeepSeek** models for iOS
## 0.8.4
- iOS LoRA support added
- iOS topP support added
## 0.8.3
- Readme updated
## 0.8.2
- Readme updated
## 0.8.1
- Migrate to js-interop
- Add web platform support in pubspec.yaml
## 0.8.0
- Upgraded Mediapipe to 0.10.22 for Android and Web
- Upgraded Mediapipe to 0.10.21 for iOS
- Added opportunity to set *topP* and *preferredBackend* for inference
- Added support of **Gemma3**, **Phi-4** and **DeepSeek** models for Android and Web
## 0.7.0
- Added Chat functionality for instruction tuned model
- Added sizeInTokens method for analysis of the size of the input prompt
## 0.6.0
- Added opportunity to manage inference session
## 0.5.1
- Fixed crash on generation for Android
## 0.5.0
- IMPORTANT: Breaking changes in the API
- FlutterGemma instance was replaced with ModelManager and InferenceModel
- ModelManager to manage models and LoRA weights
- InferenceModel to manage inference
- Added opportunity to set model and LoRA weights paths manually
- Added opportunity to delete model and LoRA weights
- Added opportunity to load LoRA weights from assets and network
## 0.4.6
- Added close method
## 0.4.5
- Small fixes for Android
## 0.4.4
- Small fixes for iOS
## 0.4.3
- Upgraded Mediapipe to 0.10.20
- Updated LoRA support
## 0.4.2
- Added error handling
- Updated example for error handling
- Upgraded Mediapipe to 0.10.18 for iOS
- Fixed ios issue with model freezing
## 0.4.1
- Fixed ios issue
## 0.4.0
- Upgraded Mediapipe to 0.10.16
- Added LoRA support
- Fixed some issues
## 0.3.1
- Updated example and readme
## 0.3.0
- Added support for loading models from assets and network.
- Added progress updates for model loading.
## 0.2.4
- Fixed Mediapipe ios version
## 0.2.3
- Updated Mediapipe ios version
## 0.2.2
- Added opportunity to configure folder (Android only)
- Fixed android release issue
- Updated Mediapipe for Android
- Updated readme
## 0.2.1
- Updated chat functionality for instruction tuned model
- Updated readme
## 0.2.0
- Added chat functionality for instruction tuned model
- Updated example
## 0.1.4
- Updated readme for GPU models on Android devices
- Updated example
## 0.1.3
- Updated readme
## 0.1.2
- Updated example
## 0.1.1
- Updated example
## 0.1.0
- Added web support
- Added opportunity to set *randomSeed*, *topK* and temperature
## 0.0.4
- Updated example
- Updated readme
## 0.0.3
- Added getResponseAsync method
## 0.0.2
- Added description in Readme.md
- Added opportunity to setup a model before initiation
## 0.0.1
- Initial release




























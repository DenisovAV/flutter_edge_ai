## Unreleased
- `LiteRtBindings` binds the opaque-options calls the speech-to-text GPU options use (#747).
- The option-scoring self-check runs in debug and profile builds only.
- `InferenceModel.createDecider` scores on the GPU too; the NPU stays refused.

## 1.19.0
- EmbeddingGemma 2 text on the GPU on Linux x64; image and audio towers stay on CPU.
- Windows: Gemma 4 12B on an Intel GPU answers prompts under 512 tokens (`native-v0.18.0-h`, LiteRT-LM#4083).
- macOS: apps with Swift Package Manager on need no Podfile block; requires macOS 14 (#689).
- Require `flutter_edge_ai` ^2.5.4.

## 1.18.0
- `LiteRtLmEngine(thinkingTokenBudget:)` caps the thinking of each generation with thinking on (native).
- Another package's libLiteRtLm in the app is refused at load with the cause and the fix (#722).

## 1.17.0
- MediaTek NPU on Android, opt-in with `mediatek_npu: true`; run on a Dimensity 9300+ (MT6989).
- Windows Intel NPU on OpenVINO 2026.4.1 (`native-v0.18.0-g`): Intel's 12B loads; stale `%TEMP%` banks are deleted.
- Windows: LiteRT-LM's native log follows a redirected stderr (`app.exe 2> err.log`).
- A macOS app that cannot load LiteRT-LM is told why and how to fix it (#689).
- macOS and Linux debug builds: `print` output stays in `flutter run` after a model loads.
- Docs: which Gemma 3 bundles lose prefill chunks on the NPU (LiteRT-LM#3508).
- Require `flutter_edge_ai` ^2.5.1.

## 1.16.0
- `InferenceModel.createDecider` on CPU, natively, from a `.litertlm`'s `litetune.decision` section.
- Several open models at once (`FlutterEdgeAi.openModel`).
- `LiteRtLmEngine(nativeLogLevel:)` sets LiteRT-LM's native log level.
- Require `flutter_edge_ai` ^2.5.0.

## 1.15.0
- Google Tensor NPU on Android, opt-in with `google_tensor_npu: true` (#670).
- A stopped turn is rewound in place, so the chat keeps earlier images and audio (#682).
- Intel NPU on Windows loads its model again (LiteRT-LM #4023, #679).
- `npu` on a bundle compiled for no NPU runs on the GPU, then the CPU, instead of reporting `npu` (#683).
- Streaming reads each chunk through accessors resolved on the loaded library (#453).
- Native bundle `native-v0.18.0-f`; require `flutter_edge_ai` ^2.4.1.

## 1.14.0
- **Behaviour change:** Gemma 4 gets its audio after the text; `getActiveModel(multimodalOrder:)` changes it.
- EmbeddingGemma 2 reports its image token budget, so image-fitted deciders are bound to it.
- FunctionGemma bundles that declare no `prefer_activation_type` run on the GPU at float32 (#552).
- **Behaviour change:** backends follow the file (`readLiteRtLmBundleInfo`); incomplete or wrong-backend loads throw `LiteRtLmBundleException`.
- `LiteRtLmEngine(backendFallback: false)`: one attempt, failing with LiteRT-LM's own reason.
- `LiteRtEmbeddingBackend(requireWeightCache: true)` fails an EmbeddingGemma 2 load that wrote no weight cache.
- Require `flutter_edge_ai` ^2.4.0.

## 1.13.3
- README: Qwen3 0.6B bundle that loads (#659); NPU mask formula corrected.

## 1.13.2
- Web: EmbeddingGemma 2 audio and combined-input embeddings on WebGPU.
- EmbeddingGemma 2 on the Intel Panther Lake NPU (Windows).
- Fix: EmbeddingGemma 2 740m NPU bundles failed to load with audio declared.
- Build hook says so when Windows ARM64 has no LiteRT-LM native archive (#326).

## 1.13.1
- EmbeddingGemma 2 image embeddings on native platforms.
- Web: EmbeddingGemma 2 text and image embeddings on WebGPU via @litert-lm/core 0.18.0.
- EmbeddingGemma 2 audio (WAV, MP3, FLAC) and combined-input embeddings on native platforms.
- Over-long EmbeddingGemma 2 inputs report their exact token count.
- EmbeddingGemma 2 per-SoC bundles run on Qualcomm NPUs (Android, Linux arm64).
- Require `flutter_edge_ai` ^2.3.1.

## 1.13.0
- Run EmbeddingGemma 2 (`.litertlm`) text embeddings on Android, iOS, macOS, Linux and Windows.
- Web EmbeddingGemma uses the same prefixes and token ids as native for every `TaskType` (re-copy `litert_embeddings.js`).
- **Breaking:** require `flutter_edge_ai` ^2.3.0; `WebEmbeddingModel` is no longer exported.
- Native libraries from `native-v0.18.0-e`.

## 1.12.1
- `close()` sets `isClosed` at once; a second call waits for the teardown.
- Require `flutter_edge_ai` ^2.2.1.

## 1.12.0
- Unset sampling uses the `.litertlm` sampler; web applies the values you pass (#572).
- Require `flutter_edge_ai` ^2.2.0.

## 1.11.3
- Web setup pins `@litert-lm/core` 0.18.0.
- Web: image or audio sent to a `.litertlm` LLM throws instead of being dropped.

## 1.11.2
- Allow `code_assets` 2.x, which other native plugins now require (#603).

## 1.11.1
- Linux: native tool calls no longer crash (#551, `native-v0.18.0-d`).

## 1.11.0
- Linux arm64: Qualcomm NPU behind the same `qualcomm_npu` flag (`native-v0.18.0-c`).

## 1.10.1
- iOS/macOS: GPU no longer crashes in apps that also use `flutter_litert` (`native-v0.18.0-b`).

## 1.10.0
- **Breaking:** Android Qualcomm NPU is opt-in: set `qualcomm_npu: true` in `hooks: user_defines`.
- iOS/macOS: Metal accelerator is `LiteRtLmMetalAccelerator`, so `flutter_litert`'s GPU keeps working beside it.
- LiteRT-LM v0.18.0 (`native-v0.18.0-a`).
- Require `flutter_edge_ai` ^2.1.1.

## 1.9.0
- **Breaking:** `createChat(isThinking:)` is `enableThinking`.
- Send `enable_thinking` both ways, on web under the key templates read; Qwen3.5 and later resolve to `qwen35`.
- Require `flutter_edge_ai` ^2.1.0.

## 1.8.7
- Require `flutter_edge_ai` 2.x.

## 1.8.6
- Renamed from `flutter_gemma_litertlm`.
- Web: fail the response stream when LiteRT-LM returns an unexpected content shape.

## 1.8.5
- Web setup pins `@litert-lm/core` 0.17.1.

## 1.8.4
- Web reports the accelerator embeddings ran on, and whether it was fully accelerated.
- `activeBackend` no longer claims NPU on macOS, Linux, iOS or non-Qualcomm Android.

## 1.8.3
- Apply `activationDataType` to the engine; `float32` fixes wrong digits on some GPUs.

## 1.8.2
- The Android GPU backend no longer crashes on Mali GPUs (#545).

## 1.8.1
- A chat stopped mid-reply answered every later message with nothing (#325).

## 1.8.0
- Google Play no longer rejects apps over 16 KB page sizes (#529).
- Native runtime LiteRT-LM v0.17.1: integer tool-call arguments stay integers.
- Web embeddings work: the four JS files ship here now, rebuilt on `@litertjs/core` 2.5.3.
- No longer depends on `flutter_gemma_embeddings`; asks core for a tokenizer, so register `embeddingTokenizers:`.
- Refuse a multi-input .tflite at load with a named error instead of a bare native status.

## 1.7.1
- Native runtime `native-v0.17.0-a`: tool calls no longer crash the app.
- FunctionGemma on `.litertlm` takes the runtime's tool path — needs core 1.8.4.
- Windows needs no Visual C++ runtime beyond what a Flutter app ships (#456).

## 1.7.0
- Native runtime: LiteRT-LM v0.17.0 (`native-v0.17.0`).
- Windows: embeddings and speech failed with `CreateTensorBufferFromHostMemory` status 3.

## 1.6.4
- `maxTokens` is no longer clamped up to 1024 on `PreferredBackend.npu`.

## 1.6.3
- Web: move `@litert-lm/core` 0.14.0 -> 0.17.0.
- Web: `maxOutputTokens` now caps generation instead of being ignored.
- Web: function calling works; constrained decoding off (upstream #2434).

## 1.6.2
- Fix macOS companion staging: repoint the load command LiteRtLm actually carries instead of a hardcoded one (#457).

## 1.6.1
- Docs: the README and library docs show the engine-carried resolver and the one-call `fromHuggingFace(repo)` install.

## 1.6.0
- Add `LitertlmManifestResolver`: manifest-driven Hugging Face install for repos shipping `litertlm_manifest.json`, auto-registered from `LiteRtLmEngine` (#454).

## 1.5.3
- Fix a rebuilt native library not reaching the build.

## 1.5.2
- Android: embeddings no longer poison the loader, fixing zero-chunk streams and SIGABRT (#447).

## 1.5.1
- Share the host-side native library lookup with core instead of a private copy.

## 1.5.0
- Add LiteRT embedding forward-pass + `LiteRtEmbeddingBackend` (moved from flutter_gemma_embeddings).
- internal: wire the new `tokenizerFactory` descriptor field; byte-identical vectors, no API change.

## 1.4.3
- fix: a native-archive checksum mismatch now fails the build instead of shipping no library.
- fix: `sizeInTokens` asks the model's tokenizer on native; web still estimates (no tokenizer).
- fix: sampler params and maxOutputTokens now reach the NPU backend; the guards had expired upstream.
- fix: find the dev prebuilt from any package's directory, not only this one's.

## 1.4.2
- fix: vision + audio encoders default to CPU (fixes GPU vision hard-fail on Metal/WebGPU); overridable.

## 1.4.1
- Fix Windows NPU: the OpenVino compiler DLLs shipped but were never bundled into the app.
- Drop the debug TBB variants that were being bundled alongside the release set.

## 1.4.0
- Migrate to LiteRT-LM v0.16.0 (native-v0.16.0) — fixes the Android OpenCL per-turn leak (#348, #402).
- Detect the stream-callback ABI at runtime — v0.15.0 changed it with no compat path.
- Fix Windows discrete GPU: a Bazel define we passed had been removed upstream.
- Rebuild both NPU dispatch stacks from the pin instead of shipping stale prebuilts.
- Pin the macOS deployment target of `libStreamProxy.dylib` to 11.0 instead of the build host's.
- Native platforms only — web stays on `@litert-lm/core` 0.14.0 (the 0.16.0 npm publish ships no `dist/`).

## 1.3.1
- Clearer engine-create error for GPU-only `.litertlm` models run on CPU (#390).

## 1.3.0
- Also expose the LiteRt interpreter (`LiteRtBindings`) for embeddings/speech; own web `litert.js`.

## 1.2.0
- Migrate FFI to LiteRT-LM v0.14.0 — native per-session sampler (opaque session-config); native-v0.14.0.
- Fix #214 GPU output garbage via the v0.14.0 runtime — verified on Xclipse.
- Bump web `@litert-lm/core` 0.12.1 → 0.14.0 (text path; API-compatible).
- Known regression: Windows discrete GPU broken upstream (LiteRT-LM #2957) — use CPU/NPU on Windows.

## 1.1.0
- Smooth UI during Android GPU prefill — flush the OpenCL queue every 2 ops (#364).

## 1.0.4
- Guard native cancel against a freed conversation — fixes a use-after-free SIGSEGV on close-mid-stream (#379).

## 1.0.3
- Create the native conversation off the main isolate to avoid ANRs on multimodal models (#365).
- Serialize native conversation create on the engine mutex to prevent a heap-corrupting race (#372).
- Cancel native decode before tearing a conversation down to avoid a multi-second ANR (#364, #373).

## 1.0.2
- Clamp `maxTokens` up to 1024 (min context for .litertlm) to fix the DYNAMIC_UPDATE_SLICE crash (#318).
- Honor `maxOutputTokens` (session + chat) via native `set_max_output_tokens`; skipped on NPU.

## 1.0.1
- Fix `PreferredBackend.npu` on Android (Qualcomm) + Windows (Intel): native-v0.13.1-a restores the NPU dispatch libs omitted from 1.0.0 (#155).
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0.0; spec imports redirected off the `dart:io` mobile lib for a wasm-clean web graph.

## 1.0.0-rc.1
- Initial release: LiteRT-LM (`.litertlm`) on-device inference engine for flutter_gemma via dart:ffi.
- Provides `LiteRtLmEngine` (InferenceEngineProvider). Owns the shared LiteRT-LM native library.
- Android, iOS, macOS, Linux, Windows + web (`@litert-lm/core`, early preview).

## 0.20.0+1
- Pub analysis: a signature list uses a null-aware element (no lint info left).

## 0.20.0
- LiteRT-LM 0.20.0 on `native-v0.20.0`; web on `@litert-lm/core` 0.20.0.
- Breaking (web): the page hands over `@litert-lm/core` once as `window.litertLm`; see the README.
- Breaking: `SpeculativeDecodingConfig` (mode, lenience; null inherits) replaces `SpeculativeDecodingMode`; `benchmark()` takes it.
- `ToolChoice` per message on `sendMessage`/`sendMessageStream` (native), as Kotlin and Swift send it.
- Text and audio LoRA: `ConversationConfig.loraConfig`, `EngineConfig.loraRank`/`audioLoraRank`.
- `EngineConfig.selectedSignatures`.
- Per-message `maxOutputTokens`; `visualTokenBudget` on `EngineConfig` and `ConversationConfig`.
- `ConversationConfig.chatTemplate` and `enableToolCallStreaming`; tool call ids (`ToolCall.id`).
- `Conversation.clone()`, `getTokenCount()`, `renderMessageIntoString()`, `renderPrefaceIntoString()`.
- `Engine.createSession()` (Kotlin's `Session`), text only; refused on PowerVR GPUs and MediaTek NPUs.
- Breaking: `ActivationDataType.int16` and `int8` (exhaustive switches); refused on the GPU for Gemma models.
- `Backend.googleTensor()` is refused: LiteRT-LM 0.20.0 has no executor for it.
- `ToolChoice` other than auto is refused for model families that drop it.
- Breaking: a tool response on a conversation without tools is an `ArgumentError`.
- Tool calls constrained with LLGuidance; Google's prebuilt constraint provider no longer ships.
- Each native CPU/GPU conversation keeps its own sampler (LiteRT-LM #2080).
- macOS needs no companions: `macos_companions` is ignored; see the README for the Podfile.
- A define under the old user_defines key now fails the build; see the README.
- Windows: `libLiteRt.dll` needs no Visual C++ runtime.
- Android Qualcomm NPU on QNN 2.52.0; Linux arm64 on QAIRT 2.51.1.
- Windows Intel GPU: prefill up to ~2x slower, so that Gemma 4 12B keeps answering.
- `LlmBenchmarkResult.initTime` counts the engine creation only, as in LiteRT-LM 0.20.
- `EmbeddingOptions` per request on `computeEmbedding`: `outputSize`, `normalize`, special tokens, vision budget.
- `EmbeddingEngineConfig.maxInputLength` and `activationDataType` (native), as Kotlin's.
- Web: the page's runtime is checked for `createSession`, `Session`, `Responses` and `Conversation.clone`.
- `benchmark()` takes `loraConfig` and `repetitionPenaltyConfig`, as Kotlin's.

## 0.19.1+4
- Plain Dart programs (`dart run`, `dart test`, `dart build cli`) on every backend; see the README.

## 0.19.1+3
- Automatic tool calling: `Tool.execute` and `ConversationConfig.automaticToolCalling`, as in Kotlin.

## 0.19.1+2
- Runs on the web over `@litert-lm/core` 0.19.0, images and audio included.
- Breaking: `EmbeddingEngineConfig.cacheDir` is now `String?`; natively a null one is refused.
- `maxNumTokens` unset: the bundle's context or 4096 (was 2048), so Gemma 4 GPU runs float32 off Android.
- Experimental `benchmark()`: exactly N prefill and N decode tokens, as in Kotlin.

## 0.19.1+1
- LiteRT-LM 0.19.1 on `native-v0.19.1-c`; replaces 0.1.x.
- An `Engine`/`Conversation`/`EmbeddingEngine` API shaped like LiteRT-LM's Kotlin and Swift APIs.

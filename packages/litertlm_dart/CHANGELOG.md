## 0.20.0
- LiteRT-LM 0.20.0 on `native-v0.20.0`; web on `@litert-lm/core` 0.20.0.
- Breaking (web): the page hands over `@litert-lm/core` once as `window.litertLm`; see the README.
- Breaking: `SpeculativeDecodingConfig` (mode, lenience) replaces `SpeculativeDecodingMode`; `benchmark()` takes it.
- `ToolChoice` per message on `sendMessage`/`sendMessageStream` (native).
- Text and audio LoRA: `ConversationConfig.loraConfig`, `EngineConfig.loraRank`/`audioLoraRank`.
- `EngineConfig.selectedSignatures`.
- Tool calls constrained with LLGuidance; Google's prebuilt constraint provider no longer ships.
- Each native CPU/GPU conversation keeps its own sampler (LiteRT-LM #2080 fixed).
- macOS needs no companions: the `macos_companions` define and the Podfile stager block are no-ops.
- Windows: `libLiteRt.dll` needs no Visual C++ runtime.
- Android Qualcomm NPU on QNN 2.52.0; Linux arm64 on QAIRT 2.51.1.
- Windows Intel GPU: prefill ~2x slower than 0.19 (E2B ~1.5x) to keep Gemma 4 12B answering.
- `LlmBenchmarkResult.initTime` counts the engine creation only, as in LiteRT-LM 0.20.

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

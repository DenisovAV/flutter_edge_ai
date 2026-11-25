## Unreleased
- Web reads `@litert-lm/core` from `window.litertLm`, one shim line; see the README.
- `ToolChoice` per message on `sendMessage`/`sendMessageStream` (native).
- `SpeculativeDecodingConfig` (mode, lenience) replaces `SpeculativeDecodingMode` in the configs; `benchmark()` takes it.
- `EngineConfig.selectedSignatures`.
- Text and audio LoRA: `ConversationConfig.loraConfig` (`LoraConfig`), `EngineConfig.loraRank`/`audioLoraRank`.

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

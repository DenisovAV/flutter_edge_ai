## Unreleased
- Runs on the web over `@litert-lm/core` 0.18.0.
- Breaking: `EmbeddingEngineConfig.cacheDir` is now `String?`; natively a null one is refused.
- `maxNumTokens` unset: the bundle's context or 4096 (was 2048), so Gemma 4 GPU runs float32 off Android.
- Experimental `benchmark()`: exactly N prefill and N decode tokens, as in Kotlin.

## 0.19.1+1
- LiteRT-LM 0.19.1 on `native-v0.19.1-c`; replaces 0.1.x.
- An `Engine`/`Conversation`/`EmbeddingEngine` API shaped like LiteRT-LM's Kotlin and Swift APIs.

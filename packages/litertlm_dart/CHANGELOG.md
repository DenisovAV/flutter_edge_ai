## Unreleased
- `EngineConfig.maxNumTokens` unset leaves the context to LiteRT-LM (the bundle's, else 4096), as in Kotlin; `flutter_edge_ai_litertlm` always sets it.
- Experimental `benchmark()`: LiteRT-LM's benchmark mode with exactly N prefill and N decode tokens.

## 0.19.1+1
- LiteRT-LM 0.19.1 on `native-v0.19.1-c`, carved out of `flutter_edge_ai_litertlm`; replaces 0.1.x.
- An `Engine`/`Conversation`/`EmbeddingEngine` API shaped like LiteRT-LM's Kotlin and Swift APIs.

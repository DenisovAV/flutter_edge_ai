## Unreleased
- `native-v0.19.1-d`: Android GPU no longer fails with "Invalid work group size" on Adreno 830 FP32 and Adreno 610.
- `maxNumTokens` unset: the bundle's context or 4096 (was 2048), so Gemma 4 GPU runs float32 off Android; core unaffected.
- Experimental `benchmark()`: exactly N prefill and N decode tokens, as in Kotlin.

## 0.19.1+1
- LiteRT-LM 0.19.1 on `native-v0.19.1-c`, carved out of `flutter_edge_ai_litertlm`; replaces 0.1.x.
- An `Engine`/`Conversation`/`EmbeddingEngine` API shaped like LiteRT-LM's Kotlin and Swift APIs.

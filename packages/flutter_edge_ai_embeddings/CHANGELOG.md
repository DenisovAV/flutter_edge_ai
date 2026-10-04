## 2.2.2
- Require `flutter_edge_ai` 2.x.

## 2.2.1
- Renamed from `flutter_gemma_embeddings`.
- README: engine authors pass `activeBackend:` to `ForwardPassDescriptor`.

## 2.2.0
- Register `GemmaEmbeddingTokenizers()` via `initialize(embeddingTokenizers:)` — engines no longer name a tokenizer.
- The web bundle moved to `flutter_gemma_litertlm`; re-copy the four JS files from there.
- BREAKING on web: `web_embedding_model.dart` moved to `flutter_gemma_litertlm` — bump it to 1.8.0.

## 2.1.1
- Lift the `dart_sentencepiece_tokenizer` cap — 1.4.1 is now required, not excluded.

## 2.1.0
- Add a SigLIP2 text-embedding profile (no BOS, single trailing EOS, lowercased, fixed 64-token width).
- No longer pulls `dart:io` into the web graph; `fromPath` throws `UnsupportedError` there.
- Cap `dart_sentencepiece_tokenizer` below 1.4.0, which rejects EmbeddingGemma's and SigLIP2's `tokenizer.json`.

## 2.0.0
- BREAKING: runtime-agnostic embedder; `LiteRtEmbeddingBackend` moved to flutter_gemma_litertlm.
- Add tokenizer-factory seam (`ForwardPassDescriptor.tokenizerFactory`) so engines can bring WordPiece too.
- Add `EmbeddingForwardPass.outputContract` override + `ForwardResult.attentionMask` for the mask thread.
- Add `WordPieceEmbeddingTokenizer` (BERT-style, e.g. MiniLM) alongside the existing Gemma SentencePiece adapter.

## 1.0.4
- internal: run on the flutter_gemma_litertlm LiteRT engine (no API change).

## 1.0.3
- Migrate to LiteRT v0.14.0 3-arg `LiteRtCreateModelFromFile` (adds `LiteRtEnvironment`); native-v0.14.0.

## 1.0.2
- Realign the shared LiteRT-LM native bundle to native-v0.13.1-b (#364). No API change.

## 1.0.1
- Rebuild on native-v0.13.1-a (shares the LiteRT-LM native bundle; restores NPU dispatch libs, #155). No embeddings API change.
- Point `homepage` to fluttergemma.dev. No code change.

## 1.0.0
- Stable 1.0.0; spec imports redirected off the `dart:io` mobile lib for a wasm-clean web graph.

## 1.0.0-rc.1
- Initial release: on-device text embeddings (Gecko / EmbeddingGemma `.tflite`) via the LiteRT C API + dart:ffi.
- Provides `LiteRtEmbeddingBackend` (EmbeddingBackendProvider); forward pass runs on a background isolate.
- Autonomous (no dependency on flutter_gemma_litertlm); shares the LiteRT-LM native library when both are present.
- Android, iOS, macOS, Linux, Windows + web (LiteRT.js).

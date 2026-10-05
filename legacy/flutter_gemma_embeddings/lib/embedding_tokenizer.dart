/// Public, native-only export of the Gemma SentencePiece [EmbeddingTokenizer]
/// adapter (`loadGemmaSentencePieceEmbeddingTokenizer`,
/// `loadEmbeddingTokenizer`, `encodeForEmbedding`) for native-only leaves
/// that need to import it from a file that is itself native-only (never
/// reached on web) — engine packages' embedding backends (e.g.
/// `flutter_gemma_litertlm`'s `LiteRtEmbeddingBackend`).
///
/// Prefer this over `package:flutter_gemma_embeddings/src/embedding_tokenizer.dart`
/// in native-only files, matching the same pattern
/// `flutter_gemma_litertlm/lib/litert_bindings.dart` uses for its FFI
/// bindings: a stable public entry point instead of an `implementation_imports`
/// lint on a `src/` path.
///
/// This library is unconditional — importing it from code that is also
/// reachable on web will fail to compile there (it pulls in
/// `dart_sentencepiece_tokenizer`, which imports `dart:io`/`dart:isolate`
/// unconditionally). It is deliberately NOT re-exported from this package's
/// main barrel (`flutter_gemma_embeddings.dart`) for exactly that reason —
/// see that barrel's module doc.
library;

export 'src/embedding_tokenizer.dart';

/// Public, native-only export of [WordPieceEmbeddingTokenizer] for
/// native-only leaves that need to import it from a file that is itself
/// native-only (never reached on web) — engine packages' embedding backends
/// (e.g. `flutter_gemma_onnx`'s ONNX tokenizer loader, which sniffs a
/// `tokenizer.json` and routes to either this WordPiece adapter or the
/// Gemma SentencePiece one in `embedding_tokenizer.dart`).
///
/// Prefer this over
/// `package:flutter_gemma_embeddings/src/wordpiece_embedding_tokenizer.dart`
/// in native-only files — same pattern as `embedding_tokenizer.dart` at this
/// package's root and `flutter_gemma_litertlm/lib/litert_bindings.dart`.
///
/// Unlike `embedding_tokenizer.dart` (SentencePiece, which pulls in
/// `dart_sentencepiece_tokenizer` and its unconditional `dart:io`/
/// `dart:isolate` imports), this file is actually web-safe as of the ONNX
/// web PR (`feat/onnx-web`) — `flutter_gemma_onnx`'s web embedding arm
/// imports `src/wordpiece_embedding_tokenizer.dart` directly. Still not
/// re-exported from this package's main barrel
/// (`flutter_gemma_embeddings.dart`), to keep that barrel's surface stable —
/// engine packages reach it through this file instead.
library;

export 'src/wordpiece_embedding_tokenizer.dart';

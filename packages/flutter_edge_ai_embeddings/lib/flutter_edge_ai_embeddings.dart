/// The embedding tokenizers for flutter_edge_ai.
///
/// Gemma SentencePiece and BERT-family WordPiece, task-type prefixing, and the
/// routing that picks between them — registered as a [GemmaEmbeddingTokenizers]
/// provider. The embedding pass SPI, the hosts that run passes and the pooling
/// live in `flutter_edge_ai` itself (`package:flutter_edge_ai/engine.dart`), so
/// no engine depends on this package.
///
/// To actually run embeddings, add an engine package that provides an
/// `EmbeddingBackendProvider` — e.g. `flutter_edge_ai_litertlm`'s
/// `LiteRtEmbeddingBackend` — and register it:
///
/// ```dart
/// import 'package:flutter_edge_ai/flutter_edge_ai.dart';
/// import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
///
/// await FlutterEdgeAi.initialize(
///   embeddingBackends: [LiteRtEmbeddingBackend()],
///   embeddingTokenizers: [GemmaEmbeddingTokenizers()],
/// );
/// ```
///
/// A `.litertlm` embedder (EmbeddingGemma 2) carries its own tokenizer and
/// needs nothing from this package.
library;

// The tokenizer families this package implements, as a registrable provider.
// This is what lets an engine ask core for a tokenizer instead of naming one —
// and therefore what lets it not depend on this package. The seam types
// (`EmbeddingTokenizer`, `TokenizedInput`, `ForwardResult`, …) are imported
// from `package:flutter_edge_ai/engine.dart`; this barrel no longer
// re-exports them.
export 'src/tokenizer_provider.dart' show GemmaEmbeddingTokenizers;

// NOTE: `src/embedding_tokenizer.dart` and `src/wordpiece_embedding_tokenizer.dart`
// are native-only leaves (`dart:io`, and for the former
// `dart_sentencepiece_tokenizer`, which imports `dart:io`/`dart:isolate`
// unconditionally) — deliberately NOT exported from this barrel so importing
// this package can never break a web build. Native-only engine/test code that
// needs them imports `package:flutter_edge_ai_embeddings/embedding_tokenizer.dart`
// / `wordpiece_embedding_tokenizer.dart`.

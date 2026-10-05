/// The embedding tokenizers for flutter_gemma.
///
/// Gemma SentencePiece and BERT-family WordPiece, task-type prefixing, and the
/// routing that picks between them — registered as a [GemmaEmbeddingTokenizers]
/// provider. The seam engine packages implement, the isolate worker and the
/// pooling live in `flutter_gemma` itself, so no engine depends on this.
///
/// To actually run embeddings, add an engine package that provides an
/// `EmbeddingBackendProvider` — e.g. `flutter_gemma_litertlm`'s
/// `LiteRtEmbeddingBackend` — and register it:
///
/// ```dart
/// import 'package:flutter_gemma/flutter_gemma.dart';
/// import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
///
/// await FlutterGemma.initialize(
///   embeddingBackends: [LiteRtEmbeddingBackend()],
///   embeddingTokenizers: [GemmaEmbeddingTokenizers()],
/// );
/// ```
///
/// See the embedder decoupling design (docs/superpowers/specs/
/// 2026-08-17-flutter-gemma-onnx-engine-design.md §2, §11 D3/D4) for why the
/// seam exists: it lets `flutter_gemma_litertlm` and (later)
/// `flutter_gemma_onnx` share one tokenizer/worker/pooling implementation
/// instead of each reimplementing the isolate facade.
library;

// The runtime-agnostic `ForwardPass` seam (design doc §2, §11 D3/D4): pure
// Dart, no engine dependency. Engine packages (flutter_gemma_litertlm,
// flutter_gemma_onnx) implement `EmbeddingForwardPass` and build a
// `ForwardPassDescriptor` from a top-level factory tear-off to plug into the
// common embedder below.
// Moved to core so an engine package can implement the seam without depending
// on this one. Re-exported here so a single import still covers the whole
// embedding surface for app and test code.
export 'package:flutter_gemma/core/embedding/forward_pass.dart';
export 'package:flutter_gemma/core/embedding/pooling.dart';
// The tokenizer seam (design D-T1): pure Dart, no engine dependency, no
// native library at all — engine packages implement `EmbeddingTokenizer` and
// build a `ForwardPassDescriptor.tokenizerFactory` from a top-level factory
// tear-off, same shape as `EmbeddingForwardPassFactory` above.
export 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart';
// The tokenizer families this package implements, as a registrable
// provider. This is what lets an engine ask for a tokenizer instead of
// naming one — and therefore what lets it stop depending on this package.
export 'src/tokenizer_provider.dart';

// NOTE: `src/embedding_tokenizer.dart` and `src/wordpiece_embedding_tokenizer.dart`
// are native-only leaves (`dart:io`, and for the former
// `dart_sentencepiece_tokenizer`, which imports `dart:io`/`dart:isolate`
// unconditionally) — deliberately NOT exported from this barrel so importing
// this package can never break a web build. They're used internally by
// engine backends (reached only via the native-only
// `common_embedding_model.dart` arm below); native-only engine/test code
// that needs them directly imports
// `package:flutter_gemma_embeddings/src/embedding_tokenizer.dart` /
// `package:flutter_gemma_embeddings/src/wordpiece_embedding_tokenizer.dart`.

// The common embedder: background-isolate worker + `EmbeddingModel` facade
// over any `ForwardPassDescriptor`. Conditional export — the real worker
// needs `dart:isolate` semantics that only make sense on native platforms;
// web engine packages build their own `EmbeddingModel` directly (see
// `flutter_gemma_litertlm`'s web arm) and never reach this file.
export 'package:flutter_gemma/core/embedding/common_embedding_model.dart'
    if (dart.library.js_interop)
        'package:flutter_gemma/core/embedding/common_embedding_model_stub.dart';

import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizerFactory;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;

/// A pluggable source of [EmbeddingTokenizerFactory] — the "text -> token ids"
/// half of an embedding.
///
/// Same probe-chain shape as [EmbeddingBackendProvider], and it exists for the
/// same reason: which tokenizer a model needs is a property of the MODEL, not
/// of the engine that runs it. EmbeddingGemma needs SentencePiece whether its
/// weights are executed by LiteRT or by ONNX Runtime; MiniLM needs WordPiece
/// either way. An engine that named a tokenizer would be asserting something
/// it cannot know, and — because the implementations pull
/// `dart_sentencepiece_tokenizer` — would have to depend on the package that
/// owns them, which is the sibling edge `Packages -> core, never to each
/// other` forbids.
///
/// So the engine asks the registry instead, and the app supplies the
/// implementation:
///
/// ```dart
/// FlutterGemma.initialize(
///   embeddingBackends: [LiteRtEmbeddingBackend()],
///   embeddingTokenizers: [GemmaEmbeddingTokenizers()],
/// );
/// ```
///
/// An app that never embeds anything passes neither and pays for neither.
abstract class EmbeddingTokenizerProvider {
  /// Human-readable name for diagnostics / error messages.
  String get name;

  /// Selection precedence on overlap. Core providers use 0.
  int get priority => 0;

  /// Whether this provider can tokenize for [spec]. Probed by the registry.
  ///
  /// Coarse on purpose: the fine-grained choice between tokenizer families is
  /// made from the tokenizer file's own bytes, inside the worker isolate, by
  /// the factory below — not here, where the file has not been read yet.
  bool canHandle(EmbeddingModelSpec spec);

  /// A top-level function tear-off, never a closure over instance state: the
  /// worker sends this across an isolate boundary, and a closure would not
  /// survive the trip.
  EmbeddingTokenizerFactory get factory;
}

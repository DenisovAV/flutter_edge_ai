import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizerFactory;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_gemma/core/registry/embedding_tokenizer_provider.dart';

// Real arm by default, web overrides -- core's own convention. The native
// router reads the file with dart:io and can reach SentencePiece; the web one
// fetches it and is WordPiece-only, because dart_sentencepiece_tokenizer
// cannot be compiled for the web at all.
import 'tokenizer_router.dart'
    if (dart.library.js_interop) 'web/tokenizer_router_web.dart'
    show resolveEmbeddingTokenizer;

/// The tokenizer families this package implements: Gemma SentencePiece,
/// BERT-family WordPiece, and a loud refusal for a SigLIP 2 `tokenizer.json`
/// that would otherwise be silently mis-tokenized with Gemma's convention.
///
/// Register it beside the embedding backends that will use it:
///
/// ```dart
/// FlutterGemma.initialize(
///   embeddingBackends: [LiteRtEmbeddingBackend()],
///   embeddingTokenizers: [GemmaEmbeddingTokenizers()],
/// );
/// ```
///
/// [canHandle] is `true` for every spec: the actual family is chosen from the
/// tokenizer file's own bytes, inside the worker isolate, by
/// [resolveEmbeddingTokenizer]. Register a provider at a higher [priority] to
/// take precedence for a family this one does not cover.
class GemmaEmbeddingTokenizers implements EmbeddingTokenizerProvider {
  const GemmaEmbeddingTokenizers();

  @override
  String get name => 'Gemma tokenizers (SentencePiece + WordPiece)';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  EmbeddingTokenizerFactory get factory => resolveEmbeddingTokenizer;
}

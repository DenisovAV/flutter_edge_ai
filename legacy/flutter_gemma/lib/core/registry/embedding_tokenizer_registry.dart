import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart'
    show EmbeddingTokenizerFactory;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_gemma/core/registry/embedding_tokenizer_provider.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Holds embedding tokenizer providers registered via `FlutterGemma.initialize`.
/// Same probe-chain selection as [EmbeddingRegistry] and [EngineRegistry].
class EmbeddingTokenizerRegistry {
  EmbeddingTokenizerRegistry._();
  static final EmbeddingTokenizerRegistry instance =
      EmbeddingTokenizerRegistry._();

  final _registered = <EmbeddingTokenizerProvider>[];

  void registerAll(List<EmbeddingTokenizerProvider> providers) {
    for (final p in providers) {
      if (!_registered.contains(p)) _registered.add(p);
    }
  }

  EmbeddingTokenizerProvider? findFor(EmbeddingModelSpec spec) {
    final matches = _registered.where((p) => p.canHandle(spec)).toList();
    if (matches.isEmpty) return null;
    final indexed = [for (var i = 0; i < matches.length; i++) (i, matches[i])];
    indexed.sort((a, b) {
      final byPriority = b.$2.priority.compareTo(a.$2.priority);
      return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
    });
    if (kDebugMode &&
        indexed.length > 1 &&
        indexed[0].$2.priority == indexed[1].$2.priority) {
      gemmaLog(
        '[flutter_gemma] Ambiguous embedding tokenizer: '
        '${indexed.map((e) => e.$2.name).join(", ")} all handle this spec at '
        'priority ${indexed[0].$2.priority}; using "${indexed[0].$2.name}".',
      );
    }
    return indexed.first.$2;
  }

  /// The factory an embedding backend passes into its `ForwardPassDescriptor`.
  ///
  /// Throws rather than returning null, and names the fix: a backend that
  /// silently fell back to one tokenizer family would not fail — it would
  /// return vectors that are quietly the wrong point in the embedding space,
  /// which no test downstream can distinguish from a working model.
  EmbeddingTokenizerFactory resolveFor(EmbeddingModelSpec spec) {
    final provider = findFor(spec);
    if (provider == null) {
      throw StateError(
        'No embedding tokenizer is configured. flutter_gemma core ships the '
        'tokenizer CONTRACT but no implementation — they are opt-in, like RAG '
        'stores. Add flutter_gemma_embeddings to pubspec.yaml and pass its '
        'provider to FlutterGemma.initialize(embeddingTokenizers: ...):\n'
        '  • flutter_gemma_embeddings → GemmaEmbeddingTokenizers()\n'
        'Spec: ${spec.name}',
      );
    }
    return provider.factory;
  }

  List<EmbeddingTokenizerProvider> get registered =>
      List.unmodifiable(_registered);

  bool get hasAny => _registered.isNotEmpty;

  void reset() => _registered.clear();
}

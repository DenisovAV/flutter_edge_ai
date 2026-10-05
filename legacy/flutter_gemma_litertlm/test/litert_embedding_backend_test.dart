// Moved from flutter_gemma_embeddings/test/litert_embedding_backend_test.dart
// (embedder decoupling plan Task 4/5 — LiteRtEmbeddingBackend now lives in
// this package).

import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart';
import 'package:flutter_gemma/core/embedding/forward_pass.dart';
import 'package:flutter_gemma/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/registry/embedding_tokenizer_provider.dart';
import 'package:flutter_gemma/core/registry/embedding_tokenizer_registry.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';
import 'package:flutter_gemma_litertlm/src/embedding/litert_embedding_backend.dart'
    show liteRtEmbeddingDescriptor;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LiteRtEmbeddingBackend identity', () {
    const b = LiteRtEmbeddingBackend();
    expect(b.name, 'LiteRT Embedding');
    expect(b.priority, 0);
  });

  group('the descriptor LiteRtEmbeddingBackend hands the worker', () {
    setUp(
      () => EmbeddingTokenizerRegistry.instance.registerAll([_AnyTokenizer()]),
    );
    tearDown(EmbeddingTokenizerRegistry.instance.reset);

    ForwardPassDescriptor build() => liteRtEmbeddingDescriptor(
      EmbeddingModelSpec(
        name: 'embeddinggemma',
        modelSource: ModelSource.file('/m.tflite'),
        tokenizerSource: ModelSource.file('/t.model'),
      ),
      RuntimeConfig(maxTokens: 0, modelPath: '/m.tflite'),
    );

    test('declares CPU, so EmbeddingModel.activeBackend is not null', () {
      // `activeBackend` is optional on the descriptor, and this line is the
      // only place LiteRT's answer comes from. Delete it and
      // `getActiveEmbedder(preferredBackend:)` is unanswerable again in the one
      // build where the debug notice does not exist.
      expect(build().activeBackend, PreferredBackend.cpu);
    });

    test('declares pooledFinal, so the worker does not pool twice', () {
      // LiteRT's compiled graph already emits the final pooled, normalised
      // vector; tokenLevel would route it through meanPoolAndNormalize again.
      expect(build().outputContract, EmbeddingOutputContract.pooledFinal);
    });
  });
}

/// Claims every spec. The factory is never called — these tests inspect the
/// descriptor, they do not spawn a worker.
class _AnyTokenizer implements EmbeddingTokenizerProvider {
  @override
  String get name => 'any';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  EmbeddingTokenizerFactory get factory => _unused;
}

Future<EmbeddingTokenizer> _unused(String _) =>
    throw UnimplementedError('descriptor tests never tokenize');

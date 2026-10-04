// LiteRT C API embedding backend — native arm (embedder decoupling plan
// Task 4). Moved from `flutter_edge_ai_embeddings/lib/src/litert_embedding_backend.dart`
// unchanged in shape: builds a `ForwardPassDescriptor` for
// `createLiteRtEmbeddingForwardPass` and hands it to the runtime-agnostic
// `CommonEmbeddingModel`.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/core/registry/embedding_backend_provider.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart' show EmbeddingModel;
import 'package:flutter_edge_ai/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'package:flutter_edge_ai/core/embedding/common_embedding_model.dart'
    show CommonEmbeddingModel;
import 'package:flutter_edge_ai/core/embedding/forward_pass.dart'
    show EmbeddingOutputContract, ForwardPassDescriptor;
import 'package:flutter_edge_ai/core/registry/embedding_tokenizer_registry.dart';

import 'litert_embedding_forward_pass.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;

/// LiteRT C API embedding backend (Gecko / EmbeddingGemma `.tflite`). Pure
/// factory; core owns the singleton lifecycle via [EmbeddingModel.addCloseListener].
class LiteRtEmbeddingBackend implements EmbeddingBackendProvider {
  const LiteRtEmbeddingBackend();

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true; // sole embedding backend

  @override
  Future<EmbeddingModel> createModel(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    final tokenizerPath = config.tokenizerPath;
    if (tokenizerPath == null) {
      throw StateError(
        'LiteRtEmbeddingBackend requires config.tokenizerPath (resolved by '
        'core from the active embedding model).',
      );
    }
    return CommonEmbeddingModel.create(
      descriptor: liteRtEmbeddingDescriptor(spec, config),
      tokenizerPath: tokenizerPath,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}

/// The descriptor [LiteRtEmbeddingBackend.createModel] hands the embedding
/// worker.
///
/// Split out so a test can inspect what this backend DECLARES without spawning
/// a worker, which needs the native library. Above all `activeBackend`: the
/// field is optional on [ForwardPassDescriptor], so deleting that one line made
/// `EmbeddingModel.activeBackend` null — the release-visible answer this backend
/// exists to give — and no test went red.
@visibleForTesting
ForwardPassDescriptor liteRtEmbeddingDescriptor(
  EmbeddingModelSpec spec,
  RuntimeConfig config,
) {
  // outputContract MUST be pooledFinal — LiteRT's compiled graph already
  // produces the final pooled/normalized vector; routing it through
  // `meanPoolAndNormalize` a second time would silently add an
  // L2-normalize the LiteRT path never had (Invariant I0).
  return ForwardPassDescriptor(
    engineTag: 'LiteRT',
    modelPath: config.modelPath,
    factory: createLiteRtEmbeddingForwardPass,
    // Asked for, not named. Which family this model needs is a fact about
    // the model, not about LiteRT — and hardcoding Gemma SentencePiece
    // here is what made `canHandle => true` a trap: a WordPiece model was
    // accepted and then tokenized with the wrong convention.
    tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
    // CPU, and by decision rather than omission: the GPU delegate
    // compiles and then returns all-zero vectors for EmbeddingGemma's int4
    // weights (removed in ab3df2bf). Surfaced as
    // EmbeddingModel.activeBackend so a caller who asked for GPU can see
    // what happened in a release build.
    activeBackend: PreferredBackend.cpu,
    outputContract: EmbeddingOutputContract.pooledFinal,
  );
}

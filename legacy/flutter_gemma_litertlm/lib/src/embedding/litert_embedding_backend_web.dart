// Web LiteRT embedding backend. It builds [WebEmbeddingModel], which runs on
// the LiteRT.js bundle in this package's `web/` — so unlike the native arm it
// never asks core's tokenizer registry: tokenization happens inside
// `sentencepiece.js`, not in Dart.

import 'package:flutter_gemma/core/registry/embedding_backend_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show EmbeddingModel;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;
import 'web/web_embedding_model.dart';

/// Web LiteRT embedding backend — builds [WebEmbeddingModel] (LiteRT.js).
class LiteRtEmbeddingBackend implements EmbeddingBackendProvider {
  const LiteRtEmbeddingBackend();

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  @override
  bool canHandle(EmbeddingModelSpec spec) => true;

  @override
  Future<EmbeddingModel> createModel(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    return WebEmbeddingModel(
      modelPath: config.modelPath,
      tokenizerPath: config.tokenizerPath,
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}

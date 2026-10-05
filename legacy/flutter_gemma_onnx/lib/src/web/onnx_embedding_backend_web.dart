// Web arm of `OnnxEmbeddingBackend` (ONNX web PR, `feat/onnx-web`, Task 2.4).
// Same public shape as the native arm (`../embedding/onnx_embedding_backend.dart`,
// HARD RULE 2) — no host gate here: onnxruntime-web's WASM fallback always
// exists in a browser (unlike the native arm's per-platform archive gate).

import 'package:flutter_gemma/core/registry/embedding_backend_provider.dart';
import 'package:flutter_gemma/core/registry/runtime_config.dart';
import 'package:flutter_gemma/core/registry/embedding_tokenizer_registry.dart';
import 'package:flutter_gemma/flutter_gemma_interface.dart' show EmbeddingModel;
import 'package:flutter_gemma/core/model_management/model_specs.dart'
    show EmbeddingModelSpec;

import 'onnx_web_embedding_model.dart';

/// ONNX Runtime embedding backend — web arm (`onnxruntime-web`, WordPiece
/// `.onnx`/`.ort` exports only in v1 — the tokenizer arrives as a registered
/// [EmbeddingTokenizerProvider] factory, whose web arm is WordPiece-only).
///
/// Priority 10 (above LiteRT's web catch-all 0) — same rationale as the
/// native arm: an app that registers both backends and installs an `.onnx`
/// model gets this one.
class OnnxEmbeddingBackend implements EmbeddingBackendProvider {
  const OnnxEmbeddingBackend();

  @override
  String get name => 'ONNX Embedding';

  @override
  int get priority => 10;

  /// Same extension-based rule as the native arm — `.onnx` (single-file
  /// export) and `.ort` (ORT-optimized format) both route here.
  @override
  bool canHandle(EmbeddingModelSpec spec) {
    final modelFilename = spec.files.first.filename;
    return modelFilename.endsWith('.onnx') || modelFilename.endsWith('.ort');
  }

  @override
  Future<EmbeddingModel> createModel(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    final tokenizerPath = config.tokenizerPath;
    if (tokenizerPath == null) {
      throw StateError(
        'OnnxEmbeddingBackend requires config.tokenizerPath (resolved by '
        'core from the active embedding model).',
      );
    }
    return OnnxWebEmbeddingModel(
      modelPath: config.modelPath,
      tokenizerPath: tokenizerPath,
      tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
      onClose: () {}, // core resets its state via addCloseListener
    );
  }
}

// Web arm of `OnnxEmbeddingBackend`: describes the onnxruntime-web pass, which
// core hosts inline on the page. Same public shape as the native arm
// (`../embedding/onnx_embedding_backend.dart`) — no host gate here:
// onnxruntime-web's WASM fallback always exists in a browser.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;

import '../embedding/ort_token_graph.dart';
import 'onnx_web_embedding_pass.dart';
import 'ort_web_client.dart' show OrtWebClient, revokeObjectUrl;

/// ONNX Runtime embedding backend — web arm (`onnxruntime-web`). The
/// tokenizer comes from core's tokenizer registry, whose web arm is
/// WordPiece-only, so MiniLM-family `.onnx`/`.ort` exports run here.
///
/// Priority 10 (above LiteRT's 0) — same rationale as the native arm: an app
/// that registers both backends and installs an `.onnx` model gets this one.
final class OnnxEmbeddingBackend extends EmbeddingBackendProvider {
  const OnnxEmbeddingBackend();

  @override
  String get name => 'ONNX Embedding';

  @override
  int get priority => 10;

  /// Same rule as the native arm: `.onnx` or `.ort`, ASCII case-insensitive.
  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      isOnnxEmbeddingFilename(spec.files.first.filename);

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (config.supportImage || config.supportAudio) {
      throw const EmbeddingLoadException(
        'ONNX embeddings are text-only',
        engine: _onnx,
      );
    }
    final tokenizerPath =
        config.tokenizerPath ??
        (throw EmbeddingLoadException(
          'identity corrupt: the active embedder ${spec.name} names a '
          'tokenizer, but core resolved no tokenizer path for it. Install the '
          'embedder again.',
          engine: _onnx,
        ));
    return EmbeddingPassDescriptor<OnnxWebEmbeddingConfig>(
      engineTag: _onnx,
      factory: buildOnnxWebEmbeddingPass,
      config: OnnxWebEmbeddingConfig(
        modelPath: config.modelPath,
        tokenizerPath: tokenizerPath,
        tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
        // Under WebStorageMode.streaming both paths are `opfs://`; the pass
        // resolves each (model AND tokenizer) to a `blob:` URL before it is
        // fetched.
        resolveUrl: resolveWebModelUrl,
        revokeUrl: revokeObjectUrl,
        clientFactory: OrtWebClient.new,
      ),
      // onnxruntime-web resolves `['webgpu', 'wasm']` in order and keeps the
      // first that initialises; it does not report which. Null = unknown.
      activeBackend: null,
    );
  }
}

const _onnx = 'ONNX';

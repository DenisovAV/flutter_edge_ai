// LiteRT embedding backend — web arm. It describes the LiteRT.js pass over the
// bundle in this package's `web/`; core hosts it inline on the page. Unlike
// the native arm it never asks core's tokenizer registry: tokenization happens
// inside the bundle's `sentencepiece.js`, not in Dart.
//
// It does not claim `.litertlm` bundles: web has no EmbeddingGemma 2 pass, so
// `installEmbedder()` refuses such a spec before any download.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;

import 'web/litert_js_embedding_pass.dart';
import 'web/litert_web_embeddings.dart'
    show WindowLiteRtJsBundle, revokeObjectUrl;

/// LiteRT embedding backend, web: EmbeddingGemma `.tflite` through LiteRT.js.
final class LiteRtEmbeddingBackend extends EmbeddingBackendProvider {
  const LiteRtEmbeddingBackend();

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  /// A two-file spec (model + tokenizer).
  @override
  bool canHandle(EmbeddingModelSpec spec) => spec.tokenizerSource != null;

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    if (config.supportImage || config.supportAudio) {
      throw EmbeddingLoadException(
        '${spec.files.first.filename} is a text-only model',
        engine: liteRtJsEngine,
      );
    }
    final tokenizerPath =
        config.tokenizerPath ??
        (throw EmbeddingLoadException(
          'identity corrupt: the active embedder ${spec.name} names a '
          'tokenizer, but core resolved no tokenizer path for it. Install the '
          'embedder again.',
          engine: liteRtJsEngine,
        ));
    return EmbeddingPassDescriptor<LiteRtJsEmbeddingConfig>(
      engineTag: liteRtJsEngine,
      factory: buildLiteRtJsEmbeddingPass,
      config: LiteRtJsEmbeddingConfig(
        modelPath: config.modelPath,
        tokenizerPath: tokenizerPath,
        bundle: const WindowLiteRtJsBundle(),
        // Under WebStorageMode.streaming both paths are `opfs://`; the pass
        // resolves each to a `blob:` URL before the bundle fetches it.
        resolveUrl: resolveWebModelUrl,
        revokeUrl: revokeObjectUrl,
      ),
      // The runtime picks the accelerator itself and the answer does not
      // exist until it has run; the bundle reports it through
      // `window.getLiteRtEmbeddingAccelerator()`. Null = unknown, never CPU.
      activeBackend: null,
    );
  }
}

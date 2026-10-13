// LiteRT embedding backend — web arm. Core hosts what it describes inline on
// the page. Two passes, chosen by the installed file's name (on the web the
// path core resolves is a URL, not a file name):
// - a `.litertlm` bundle (EmbeddingGemma 2: text, images and audio, alone or
//   combined) → the `@litert-lm/core` EmbeddingEngine pass, which needs
//   `window.EmbeddingEngine = m.EmbeddingEngine;` in the page's module script;
// - a two-file spec (EmbeddingGemma 1 `.tflite` + tokenizer) → the LiteRT.js
//   pass over the bundle in this package's `web/`.
// Unlike the native arm it never asks core's tokenizer registry: tokenization
// happens inside the runtime (the `.litertlm` bundle's own tokenizer, or the
// LiteRT.js bundle's `sentencepiece.js`), not in Dart.

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart' show resolveWebModelUrl;

import 'litert_lm_embedding_common.dart';
import 'vision_budget.dart';
import 'web/litert_js_embedding_pass.dart';
import 'web/litert_lm_web_embedding_pass.dart';
import 'web/litert_lm_web_embedding_runtime.dart';
import 'web/litert_web_embeddings.dart'
    show WindowLiteRtJsBundle, revokeObjectUrl;

/// LiteRT embedding backend, web: EmbeddingGemma 2 `.litertlm` bundles (text,
/// images on a bundle with a vision encoder, audio on a bundle with an audio
/// encoder, and combinations of them in one vector) through
/// `@litert-lm/core`'s EmbeddingEngine on WebGPU — a browser without WebGPU is
/// refused with `EmbeddingLoadException`, as there is no CPU path for these
/// bundles in `@litert-lm/core` 0.18.0 — and EmbeddingGemma 1 `.tflite`
/// through LiteRT.js.
final class LiteRtEmbeddingBackend extends EmbeddingBackendProvider {
  /// [visionTokensPerImage] is how many vision tokens an EmbeddingGemma 2
  /// image gets: 140 (the default) or 70; any other value is refused with
  /// `EmbeddingLoadException` when a model loads. The same parameter as the
  /// native arm, so one registration compiles everywhere.
  const LiteRtEmbeddingBackend({this._visionTokensPerImage = 140});

  final int _visionTokensPerImage;

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  /// A two-file spec (model + tokenizer), or a `.litertlm` bundle — the same
  /// rule as the native arm.
  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      spec.tokenizerSource != null ||
      isLiteRtLmFilename(spec.files.first.filename);

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    final fileName = spec.files.first.filename;
    final bundle = isLiteRtLmFilename(fileName);
    // Wherever it is used: a misconfigured backend fails at its first load,
    // not on the day the first image arrives.
    checkVisionTokensPerImage(
      _visionTokensPerImage,
      engine: bundle ? liteRtLmEngineTag : liteRtJsEngine,
    );
    if (bundle != spec.isSelfContained) {
      throw EmbeddingLoadException(
        'identity corrupt: the active embedder ${spec.name} installs '
        '$fileName, which ${bundle ? 'is' : 'is not'} a .litertlm bundle, '
        'while its spec ${spec.isSelfContained ? 'carries no' : 'names a'} '
        'tokenizer. Install the embedder again.',
        engine: bundle ? liteRtLmEngineTag : liteRtJsEngine,
      );
    }
    if (bundle) {
      return _describeBundle(config, fileName, _visionTokensPerImage);
    }
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

/// A `.litertlm` embedding bundle (EmbeddingGemma 2) on the web. Declared
/// audio on a bundle without an audio encoder (the 270m, the 440m) is refused
/// here, from the container header — a few KB of the installed file, read
/// through the page's `fetch()` — as natively: core calls describe() before
/// it closes the embedder it holds, so that embedder keeps working. Whether
/// the bundle has a vision encoder for declared images is answered by the
/// runtime when the pass creates the engine.
Future<EmbeddingPassDescriptor<LiteRtLmWebEmbeddingConfig>> _describeBundle(
  RuntimeConfig config,
  String fileName,
  int visionTokensPerImage,
) async {
  // An EmbeddingGemma 2 NPU bundle needs a native dispatch (Qualcomm,
  // Intel); asked for here it is refused, never run elsewhere.
  if (config.preferredBackend == PreferredBackend.npu) {
    throw const EmbeddingLoadException(
      liteRtLmWebNpuRefusal,
      engine: liteRtLmEngineTag,
    );
  }
  final passConfig = LiteRtLmWebEmbeddingConfig(
    modelPath: config.modelPath,
    fileName: fileName,
    runtime: const WindowLiteRtLmWebRuntime(),
    // Under WebStorageMode.streaming the path is `opfs://`; the pass
    // resolves it to a `blob:` URL before the engine fetches it.
    resolveUrl: resolveWebModelUrl,
    revokeUrl: revokeObjectUrl,
    declaredMedia: {
      if (config.supportImage) EmbeddingModality.image,
      if (config.supportAudio) EmbeddingModality.audio,
    },
    visionTokensPerImage: visionTokensPerImage,
  );
  if (config.supportAudio) await requireLiteRtLmWebAudioEncoderFor(passConfig);
  return EmbeddingPassDescriptor<LiteRtLmWebEmbeddingConfig>(
    engineTag: liteRtLmEngineTag,
    factory: buildLiteRtLmWebEmbeddingPass,
    config: passConfig,
    // The pass asks for the GPU (WebGPU) backend by name, for the text tower
    // and the vision and audio towers alike, and refuses a page without
    // WebGPU rather than fall back — so this is known, unlike LiteRT.js,
    // which picks its own accelerator.
    activeBackend: PreferredBackend.gpu,
  );
}

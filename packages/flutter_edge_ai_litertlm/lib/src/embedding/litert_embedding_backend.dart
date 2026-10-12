// LiteRT embedding backend — native arm. It only DESCRIBES what to run
// (`describe()` is pure: no native library, no isolate); core builds the pass
// in its embedding worker, hosts it, checks every request and closes it.
//
// Routing is by the file core actually opens (`config.modelPath`): a
// `.litertlm` bundle (EmbeddingGemma 2, through LiteRT-LM's EmbeddingEngine)
// or a `.tflite` graph with a separate tokenizer (EmbeddingGemma 1, Gecko,
// through the LiteRT C API).

import 'dart:io' show Platform;

import 'package:flutter_edge_ai/engine.dart';
import 'package:path_provider/path_provider.dart';

import 'litert_embedding_pass.dart';
import 'litert_lm_embedding_pass.dart';

/// LiteRT embedding backend: `.tflite` embedders (EmbeddingGemma 1, Gecko)
/// over the LiteRT C API, and `.litertlm` embedding bundles (EmbeddingGemma 2,
/// text) over LiteRT-LM's EmbeddingEngine.
final class LiteRtEmbeddingBackend extends EmbeddingBackendProvider {
  const LiteRtEmbeddingBackend();

  @override
  String get name => 'LiteRT Embedding';

  @override
  int get priority => 0;

  /// A two-file spec (model + tokenizer), or a `.litertlm` bundle. A future
  /// self-contained spec of another kind (an ONNX directory) is not claimed.
  @override
  bool canHandle(EmbeddingModelSpec spec) =>
      spec.tokenizerSource != null ||
      isLiteRtLmFilename(spec.files.first.filename);

  @override
  Future<EmbeddingPassDescriptor<Object>> describe(
    EmbeddingModelSpec spec,
    RuntimeConfig config,
  ) async {
    final file = spec.files.first.filename;
    final opensBundle = isLiteRtLmFilename(config.modelPath);
    if (opensBundle != spec.isSelfContained) {
      throw EmbeddingLoadException(
        'identity corrupt: the active embedder ${spec.name} opens '
        '${config.modelPath}, which ${opensBundle ? 'is' : 'is not'} a '
        '.litertlm bundle, while its spec '
        '${spec.isSelfContained ? 'carries no' : 'names a'} tokenizer. '
        'Install the embedder again.',
        engine: opensBundle ? _liteRtLm : _liteRt,
      );
    }
    if (opensBundle) return _describeBundle(config);
    return _describeTflite(spec, file, config);
  }
}

const _liteRt = 'LiteRT';
const _liteRtLm = liteRtLmEngineTag;

/// A `.litertlm` embedding bundle (EmbeddingGemma 2) never asks the tokenizer
/// registry: the bundle carries its own. Declared media are refused here, before
/// any isolate exists (text only in 1.13.0); whether the bundle has a tower is
/// the pass's question, answered from the bundle itself at load.
Future<EmbeddingPassDescriptor<LiteRtLmEmbeddingConfig>> _describeBundle(
  RuntimeConfig config,
) async {
  if (config.supportImage || config.supportAudio) {
    throw const EmbeddingLoadException(
      liteRtLmTextOnlyRefusal,
      engine: _liteRtLm,
    );
  }
  // The platform CACHE directory, not application support: iOS backs that up
  // to iCloud and Android Auto Backup includes it under a 25 MB per-app quota,
  // which a 71-385 MB weight cache would break. If the OS purges the cache,
  // the next engine create rebuilds it. Resolved here: the pass runs in core's
  // worker isolate, which has no platform channels.
  final cache = (await getApplicationCacheDirectory()).path;
  final sep = Platform.pathSeparator;
  return EmbeddingPassDescriptor<LiteRtLmEmbeddingConfig>(
    engineTag: _liteRtLm,
    factory: buildLiteRtLmEmbeddingPass,
    config: LiteRtLmEmbeddingConfig(
      modelPath: config.modelPath,
      // Short on purpose: the engine's cache file name repeats the model's
      // name below it, and Windows paths must stay under MAX_PATH.
      cacheBase: '$cache${sep}flutter_edge_ai${sep}emb',
      declaredMedia: {
        if (config.supportImage) EmbeddingModality.image,
        if (config.supportAudio) EmbeddingModality.audio,
      },
    ),
    // `settings_create(path, "cpu", NULL, NULL)`: the text tower on CPU.
    activeBackend: PreferredBackend.cpu,
  );
}

EmbeddingPassDescriptor<LiteRtEmbeddingConfig> _describeTflite(
  EmbeddingModelSpec spec,
  String file,
  RuntimeConfig config,
) {
  if (config.supportImage || config.supportAudio) {
    throw EmbeddingLoadException('$file is a text-only model', engine: _liteRt);
  }
  final tokenizerPath =
      config.tokenizerPath ??
      (throw EmbeddingLoadException(
        'identity corrupt: the active embedder ${spec.name} names a tokenizer, '
        'but core resolved no tokenizer path for it. Install the embedder '
        'again.',
        engine: _liteRt,
      ));
  return EmbeddingPassDescriptor<LiteRtEmbeddingConfig>(
    engineTag: _liteRt,
    factory: buildLiteRtEmbeddingPass,
    config: LiteRtEmbeddingConfig(
      modelPath: config.modelPath,
      tokenizerPath: tokenizerPath,
      // Asked for, not named. Which family this model needs is a fact about
      // the model, not about LiteRT — and hardcoding Gemma SentencePiece here
      // is what made a catch-all `canHandle` a trap: a WordPiece model was
      // accepted and then tokenized with the wrong convention.
      tokenizerFactory: EmbeddingTokenizerRegistry.instance.resolveFor(spec),
    ),
    // CPU, and by decision rather than omission: the GPU delegate compiles
    // and then returns all-zero vectors for EmbeddingGemma's int4 weights
    // (removed in ab3df2bf). Surfaced as EmbeddingModel.activeBackend so a
    // caller who asked for GPU can see what happened in a release build.
    activeBackend: PreferredBackend.cpu,
  );
}

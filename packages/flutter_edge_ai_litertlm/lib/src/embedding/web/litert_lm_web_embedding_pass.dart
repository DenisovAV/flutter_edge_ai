// The EmbeddingGemma 2 `.litertlm` embedding pass on the web: core's
// EmbeddingPass over litertlm_dart's LiteRtLmWebEmbedder (`@litert-lm/core`'s
// EmbeddingEngine in the page), what the web `LiteRtEmbeddingBackend.describe`
// hands core for a self-contained `.litertlm` spec. Core hosts it inline on the
// page, checks every request against what `load()` reported, and closes it
// (R5 §4.5, §7 P2w). As natively, the runtime decides — the page check,
// WebGPU, the towers, the probe, the input limit, the page lock — and this
// file maps core's request and words onto it.
//
// Pure Dart: the runtime arrives in the config ([LiteRtLmWebEmbedderConfig]),
// so the VM tests drive it with a fake.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal.dart'
    show EmbedderModality, LiteRtLmWebEmbedder, LiteRtLmWebEmbedderConfig;

import '../../adapter/runtime_log_binding.dart';
import '../embedder_core_errors.dart';
import '../litert_lm_embedding_common.dart';

/// The descriptor factory.
EmbeddingPass buildLiteRtLmWebEmbeddingPass(LiteRtLmWebEmbedderConfig config) =>
    LiteRtLmWebEmbeddingPass(config);

/// The `.litertlm` embedding pass on the web: text, images when declared on a
/// bundle with a vision encoder, audio when declared on a bundle with an
/// audio encoder, and any combination of them in one vector.
final class LiteRtLmWebEmbeddingPass extends EmbeddingPass {
  LiteRtLmWebEmbeddingPass(LiteRtLmWebEmbedderConfig config)
    : _embedder = LiteRtLmWebEmbedder(config);

  final LiteRtLmWebEmbedder _embedder;

  Set<EmbedderModality> _modalities = const {};
  bool _loading = false;
  bool _loaded = false;
  bool _closed = false;

  /// The embedder this pass drives.
  @visibleForTesting
  LiteRtLmWebEmbedder get embedder => _embedder;

  @override
  Future<EmbeddingPassInfo> load() async {
    if (_loading || _loaded || _closed) {
      throw StateError(
        'LiteRtLmWebEmbeddingPass.load() runs once, before close',
      );
    }
    _loading = true;
    bindRuntimeLogToCore();
    final info = await withCoreEmbedderErrors(_embedder.load);
    final images = info.modalities.contains(EmbedderModality.image);
    final audio = info.modalities.contains(EmbedderModality.audio);
    _modalities = info.modalities;
    _loaded = true;
    return EmbeddingPassInfo(
      dimension: info.dimension,
      maxInputTokens: info.maxInputTokens,
      modalities: {for (final m in info.modalities) coreModalityOf(m)},
      imageFormats: images ? liteRtLmImageFormats : const {},
      audioFormats: audio ? liteRtLmAudioFormats : const {},
      combinedInputs: true,
      visionTokensPerImage: info.visionTokensPerImage,
    );
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    if (!_loaded || _closed) {
      throw const EmbeddingEngineException(
        'LiteRtLmWebEmbeddingPass.embed() needs a loaded, open pass',
        engine: liteRtLmEngineTag,
      );
    }
    final images = input.images.isNotEmpty;
    final audio = input.audio != null;
    if ((input.text == null && !images && !audio) ||
        (images && !_modalities.contains(EmbedderModality.image)) ||
        (audio && !_modalities.contains(EmbedderModality.audio))) {
      // Core refuses all of these before calling (only the modalities the
      // model was loaded with, and never an input without a part); reaching
      // here is a host bug.
      throw EmbeddingEngineException(
        'flutter_edge_ai_litertlm embeds text and the media this model was '
        'loaded with, got $input',
        engine: liteRtLmEngineTag,
      );
    }
    // The task prefix in front of the text (the one prefix function); the
    // runtime sends the text, then the images, then the audio.
    return withCoreEmbedderErrors(
      () => _embedder.embed(embedderInputOf(input, taskType)),
    );
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _embedder.close();
  }
}

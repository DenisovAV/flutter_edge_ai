// Core's EmbeddingPass for an EmbeddingGemma 2 `.litertlm`, natively: the
// runtime's LiteRtLmEmbedder (lib/src/embedder/litert_lm_embedder.dart) does
// the work; this maps core's request (the task prefix goes in front of the
// text) and core's load info, and turns each runtime exception into the core
// one an app catches, under the engine tag it always carried.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import '../adapter/runtime_log_binding.dart';
import '../adapter/runtime_mapping.dart';
import 'package:litertlm_dart/common.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:litertlm_dart/bindings.dart';
import 'litert_lm_embedding_common.dart';

export 'package:litertlm_dart/litertlm_dart.dart'
    show LiteRtLmEmbeddingConfig, checkLiteRtLmEmbeddingSymbols;
export 'litert_lm_embedding_common.dart'
    show
        liteRtLmAudioFormats,
        liteRtLmEngineTag,
        liteRtLmImageFormats,
        liteRtLmMaxInputLength;

/// The pass core runs for [config].
EmbeddingPass buildLiteRtLmEmbeddingPass(LiteRtLmEmbeddingConfig config) =>
    LiteRtLmEmbeddingPass(config);

/// Core's request as the runtime's: [taskType]'s prefix in front of the text
/// (the text part only; a media part is the encoded file as it is).
EmbedderInput embedderInputOf(EmbeddingInput input, TaskType taskType) =>
    EmbedderInput(
      text: switch (input.text) {
        final text? => '${taskType.prefix}$text',
        null => null,
      },
      images: input.images,
      audio: input.audio,
    );

/// Core's [EmbeddingModality] as the runtime's.
EmbedderModality embedderModalityOf(EmbeddingModality modality) =>
    switch (modality) {
      EmbeddingModality.text => EmbedderModality.text,
      EmbeddingModality.image => EmbedderModality.image,
      EmbeddingModality.audio => EmbedderModality.audio,
    };

EmbeddingModality _coreModality(EmbedderModality modality) =>
    switch (modality) {
      EmbedderModality.text => EmbeddingModality.text,
      EmbedderModality.image => EmbeddingModality.image,
      EmbedderModality.audio => EmbeddingModality.audio,
    };

/// The core exception for a runtime one, or [error] itself.
Object _coreError(Object error) => switch (error) {
  EmbedderLoadException(:final message, :final nativeCode, :final cause) =>
    EmbeddingLoadException(
      message,
      engine: liteRtLmEngineTag,
      nativeCode: nativeCode,
      cause: cause,
    ),
  EmbedderEngineException(:final message, :final nativeCode, :final cause) =>
    EmbeddingEngineException(
      message,
      engine: liteRtLmEngineTag,
      nativeCode: nativeCode,
      cause: cause,
    ),
  EmbedderInputTooLongException(
    :final message,
    :final maxInputTokens,
    :final actualTokens,
  ) =>
    EmbeddingInputTooLongException(
      message,
      maxInputTokens: maxInputTokens,
      actualTokens: actualTokens,
    ),
  _ => error,
};

/// The runtime's audio-encoder check (`requireLiteRtLmAudioEncoder`), with
/// core's EmbeddingLoadException: describe() runs it before core closes the
/// embedder it holds.
void requireLiteRtLmAudioEncoderForCore(String modelPath) {
  try {
    requireLiteRtLmAudioEncoder(modelPath);
  } on EmbedderLoadException catch (e, st) {
    Error.throwWithStackTrace(_coreError(e), st);
  }
}

/// The runtime's container read of the vision and audio towers
/// (`readLiteRtLmMediaTowers`), with core's EmbeddingLoadException.
({bool vision, bool audio}) readLiteRtLmMediaTowersForCore(String modelPath) {
  try {
    return readLiteRtLmMediaTowers(modelPath);
  } on EmbedderLoadException catch (e, st) {
    Error.throwWithStackTrace(_coreError(e), st);
  }
}

Future<T> _withCoreErrors<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e, st) {
    final mapped = _coreError(e);
    if (identical(mapped, e)) rethrow;
    Error.throwWithStackTrace(mapped, st);
  }
}

/// Core's [EmbeddingPass] over the runtime's [LiteRtLmEmbedder].
final class LiteRtLmEmbeddingPass extends EmbeddingPass {
  LiteRtLmEmbeddingPass(
    LiteRtLmEmbeddingConfig config, {
    @visibleForTesting LiteRtLmEmbeddingBindings Function()? openBindings,
    @visibleForTesting Allocator allocator = calloc,
    @visibleForTesting DateTime Function()? clock,
  }) : _embedder = LiteRtLmEmbedder(
         config,
         openBindings: openBindings,
         allocator: allocator,
         clock: clock,
       );

  final LiteRtLmEmbedder _embedder;

  /// The engine-owned cache directory [load] created; null before.
  @visibleForTesting
  String? get cacheDir => _embedder.cacheDir;

  @override
  Future<EmbeddingPassInfo> load() => _withCoreErrors(() async {
    bindRuntimeLogToCore();
    final info = await _embedder.load();
    final images = info.modalities.contains(EmbedderModality.image);
    final audio = info.modalities.contains(EmbedderModality.audio);
    return EmbeddingPassInfo(
      dimension: info.dimension,
      maxInputTokens: info.maxInputTokens,
      modalities: {for (final m in info.modalities) _coreModality(m)},
      imageFormats: images ? liteRtLmImageFormats : const {},
      audioFormats: audio ? liteRtLmAudioFormats : const {},
      combinedInputs: true,
      visionTokensPerImage: info.visionTokensPerImage,
      activeBackend: info.activeBackend.toCore,
    );
  });

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) =>
      _withCoreErrors(() => _embedder.embed(embedderInputOf(input, taskType)));

  @override
  Future<void> close() => _embedder.close();
}

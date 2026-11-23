// The EmbeddingGemma 2 runtime's words in core's: the request, the
// modalities and the exceptions, for the native pass (litert_lm_embedding_pass
// .dart) and the web one (web/litert_lm_web_embedding_pass.dart) alike.
// Web-safe.

import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal.dart'
    show
        EmbedderEngineException,
        EmbedderInput,
        EmbedderInputTooLongException,
        EmbedderLoadException,
        EmbedderModality;

import '../adapter/core_hints.dart';
import 'litert_lm_embedding_common.dart' show liteRtLmEngineTag;

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

/// The runtime's [EmbedderModality] as core's.
EmbeddingModality coreModalityOf(EmbedderModality modality) =>
    switch (modality) {
      EmbedderModality.text => EmbeddingModality.text,
      EmbedderModality.image => EmbeddingModality.image,
      EmbedderModality.audio => EmbeddingModality.audio,
    };

/// The core exception for a runtime one, or [error] itself.
Object coreEmbedderError(Object error) => switch (error) {
  EmbedderLoadException(:final message, :final nativeCode, :final cause) =>
    EmbeddingLoadException(
      withCoreHint(message),
      engine: liteRtLmEngineTag,
      nativeCode: nativeCode,
      cause: cause,
    ),
  EmbedderEngineException(:final message, :final nativeCode, :final cause) =>
    EmbeddingEngineException(
      withCoreHint(message),
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

/// Runs [body] with the runtime's exceptions turned into core's.
Future<T> withCoreEmbedderErrors<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e, st) {
    final mapped = coreEmbedderError(e);
    if (identical(mapped, e)) rethrow;
    Error.throwWithStackTrace(mapped, st);
  }
}

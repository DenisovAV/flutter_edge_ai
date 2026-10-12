// Every way an embedding request or an embedder load can fail. Every
// EmbeddingModel method that can fail delivers one of these as a FAILED
// FUTURE, never as a synchronous throw.

import 'package:flutter_edge_ai/src/media/encoded_media_format.dart';

import 'embedding_modality.dart';

/// Common base of every embedding failure. Not sealed, so a later kind of
/// failure is an additive change; catch this to handle them all.
abstract base class EmbeddingException implements Exception {
  const EmbeddingException(this.message, {this.cause});

  /// What happened, in words meant for a developer.
  final String message;

  /// The underlying error, when there is one. Not carried across the embedding
  /// worker boundary (it may not be sendable); there the message says it.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType: $message${cause == null ? '' : ' (cause: $cause)'}';
}

/// The model was closed, or closed before this request started — so the
/// request never ran.
final class EmbedderClosedException extends EmbeddingException {
  const EmbedderClosedException([
    super.message = 'The embedding model is closed.',
  ]);
}

/// The previous embedder's close did not finish within the limit (60 s),
/// measured from the moment that close STARTED, so
/// `FlutterEdgeAi.getActiveEmbedder` built nothing: two native models are
/// never resident at once.
///
/// The close keeps running — nothing is killed, since a killed worker never
/// frees its native model. Until it ends, every `getActiveEmbedder` call
/// fails at once with this exception; a call made after it ends builds
/// normally.
final class EmbedderCloseTimeoutException extends EmbeddingException {
  const EmbedderCloseTimeoutException(super.message, {required this.waited});

  /// How long THIS call waited for the close: up to what was left of the
  /// limit when it arrived, so about zero for a call made after the limit had
  /// already passed.
  final Duration waited;
}

/// The input carries [modality], which this model was not loaded with
/// ([loaded] is what it was loaded with). Declare media at load:
/// `getActiveEmbedder(supportImage: true)`.
final class EmbeddingModalityNotLoadedException extends EmbeddingException {
  const EmbeddingModalityNotLoadedException(
    super.message, {
    required this.modality,
    required this.loaded,
  });

  final EmbeddingModality modality;
  final Set<EmbeddingModality> loaded;
}

/// The input carries several modalities ([requested]) and the engine embeds
/// one modality per vector.
final class UnsupportedEmbeddingCombinationException
    extends EmbeddingException {
  const UnsupportedEmbeddingCombinationException(
    super.message, {
    required this.requested,
  });

  final Set<EmbeddingModality> requested;
}

/// A media part's container is not one the engine accepts (e.g. HEIC where
/// the engine decodes JPEG/PNG/GIF/BMP only).
final class EmbeddingFormatNotSupportedException extends EmbeddingException {
  const EmbeddingFormatNotSupportedException(
    super.message, {
    required this.modality,
    required this.detected,
    required this.accepted,
  });

  final EmbeddingModality modality;

  /// What the bytes look like; null when they match no known container.
  final EncodedMediaFormat? detected;

  /// What the engine accepts for [modality].
  final Set<EncodedMediaFormat> accepted;
}

/// The input is longer than [maxInputTokens] — task prefix, BOS and EOS
/// included. Nothing was truncated; split the text and embed the pieces.
final class EmbeddingInputTooLongException extends EmbeddingException {
  const EmbeddingInputTooLongException(
    super.message, {
    required this.maxInputTokens,
    this.actualTokens,
  });

  final int maxInputTokens;

  /// The exact count when the engine has one; null when the runtime reports
  /// the overflow without a count.
  final int? actualTokens;
}

/// `embedAll` was cancelled through its `CancelToken`. No partial results are
/// returned.
final class EmbeddingCancelledException extends EmbeddingException {
  const EmbeddingCancelledException([
    super.message = 'embedAll was cancelled.',
  ]);
}

/// The engine could not load the model, or refused the requested
/// configuration (e.g. a modality it cannot serve).
final class EmbeddingLoadException extends EmbeddingException {
  const EmbeddingLoadException(
    super.message, {
    required this.engine,
    this.nativeCode,
    super.cause,
  });

  /// Which engine refused, e.g. `LiteRT`.
  final String engine;

  /// The runtime's status code, when it reported one.
  final int? nativeCode;
}

/// The engine failed while embedding.
final class EmbeddingEngineException extends EmbeddingException {
  const EmbeddingEngineException(
    super.message, {
    required this.engine,
    this.nativeCode,
    super.cause,
  });

  /// Which engine failed, e.g. `LiteRT`.
  final String engine;

  /// The runtime's status code, when it reported one.
  final int? nativeCode;
}

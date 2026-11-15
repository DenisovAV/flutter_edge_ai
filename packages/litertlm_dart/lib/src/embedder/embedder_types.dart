// What the EmbeddingGemma 2 embedder runtime (litert_lm_embedder.dart) takes
// and reports, in its own words. The Flutter adapter's LiteRtLmEmbeddingPass
// maps core's EmbeddingInput / TaskType to [EmbedderInput], [EmbedderInfo] to
// core's EmbeddingPassInfo, and each exception here to core's
// EmbeddingLoadException / EmbeddingEngineException /
// EmbeddingInputTooLongException.

import 'dart:typed_data';

import 'package:meta/meta.dart' show immutable;

import '../runtime/types.dart';

/// A kind of input an embedder takes.
enum EmbedderModality { text, image, audio }

/// One embedding request: text, images and audio, embedded as one vector.
@immutable
final class EmbedderInput {
  const EmbedderInput({this.text, this.images = const [], this.audio});

  /// The text, its task prefix already in front of it.
  final String? text;

  /// Encoded images (JPEG, PNG, GIF, BMP), in order.
  final List<Uint8List> images;

  /// One encoded audio clip (WAV, MP3, FLAC).
  final Uint8List? audio;
}

/// What a loaded embedder reports.
@immutable
final class EmbedderInfo {
  const EmbedderInfo({
    required this.dimension,
    required this.maxInputTokens,
    required this.modalities,
    required this.visionTokensPerImage,
    required this.activeBackend,
  });

  /// The length of every vector.
  final int dimension;

  /// The longest input, in tokens (media tokens counted).
  final int maxInputTokens;

  /// What this load embeds: text, and the media it declared and the bundle has.
  final Set<EmbedderModality> modalities;

  /// The vision budget the engine was created with; null without images.
  final int? visionTokensPerImage;

  /// Where the text tower runs.
  final Backend activeBackend;
}

/// The embedder could not load. Core: `EmbeddingLoadException`.
final class EmbedderLoadException implements Exception {
  const EmbedderLoadException(this.message, {this.nativeCode, this.cause});

  final String message;

  /// LiteRT-LM's status code, when a native call failed.
  final int? nativeCode;

  /// What failed underneath, when something did.
  final Object? cause;

  @override
  String toString() => 'EmbedderLoadException: $message';
}

/// A loaded embedder failed a request. Core: `EmbeddingEngineException`.
final class EmbedderEngineException implements Exception {
  const EmbedderEngineException(this.message, {this.nativeCode, this.cause});

  final String message;

  /// LiteRT-LM's status code, when a native call failed.
  final int? nativeCode;

  /// What failed underneath, when something did.
  final Object? cause;

  @override
  String toString() => 'EmbedderEngineException: $message';
}

/// An input longer than the embedder takes; never truncated. Core:
/// `EmbeddingInputTooLongException`.
final class EmbedderInputTooLongException implements Exception {
  const EmbedderInputTooLongException(
    this.message, {
    required this.maxInputTokens,
    this.actualTokens,
  });

  final String message;
  final int maxInputTokens;
  final int? actualTokens;

  @override
  String toString() => 'EmbedderInputTooLongException: $message';
}

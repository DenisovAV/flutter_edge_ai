// What the EmbeddingGemma 2 embedder runtime (litert_lm_embedder.dart) takes
// and reports, in its own words. The Flutter adapter's LiteRtLmEmbeddingPass
// maps core's EmbeddingInput / TaskType to [EmbedderInput], [EmbedderInfo] to
// core's EmbeddingPassInfo, and each exception here to core's
// EmbeddingLoadException / EmbeddingEngineException /
// EmbeddingInputTooLongException.

import 'dart:typed_data';

import 'package:meta/meta.dart' show immutable;

import '../runtime/types.dart';
import '../runtime/errors.dart';

/// A kind of input an embedder takes.
enum EmbedderModality { text, image, audio }

/// One embedding request: text, images and audio, embedded as one vector.
@immutable
final class EmbedderInput {
  /// [images] is copied into an unmodifiable list (the bytes are not).
  EmbedderInput({this.text, List<Uint8List> images = const [], this.audio})
    : images = List.unmodifiable(images);

  /// The text, its task prefix already in front of it.
  final String? text;

  /// Encoded images (JPEG, PNG, GIF, BMP), in order.
  final List<Uint8List> images;

  /// One encoded audio clip (WAV, MP3, FLAC).
  final Uint8List? audio;
}

/// How one embedding is computed: LiteRT-LM's Kotlin `EmbeddingOptions` and
/// Swift `EmbeddingOptions`, per request. A null field keeps the engine's
/// default, which is also what a request without options gets.
///
/// The fields are checked when a request uses them (`computeEmbedding` throws
/// an [ArgumentError]), not here, so the default can be `const`.
@immutable
final class EmbeddingOptions {
  const EmbeddingOptions({
    this.normalize,
    this.insertSpecialTokens,
    this.outputSize,
    this.visionTokensPerImage,
  });

  /// L2-normalise the vector (null: yes). With [outputSize] the engine
  /// truncates first and normalises the truncated vector, as LiteRT-LM does.
  /// `false` returns the vector as the model computed it.
  final bool? normalize;

  /// Add BOS, EOS and the start and end tokens of each image and audio part
  /// (null: yes). The bundles' vectors are computed with them: without them
  /// a text embeds to another vector, so turn them off only for vectors
  /// compared with others computed the same way.
  final bool? insertSpecialTokens;

  /// Matryoshka truncation: the first [outputSize] values of the vector,
  /// then L2-normalised unless [normalize] is false (null: the whole
  /// vector). From 1 to the engine's dimension.
  final int? outputSize;

  /// Vision tokens per image for this request's images (null: the engine's
  /// own). Only on an engine loaded with images: natively 70 or 140, at most
  /// the engine's `visionTokensPerImage` (LiteRT-LM prepares the vision
  /// signatures up to the engine's budget); on the web only the engine's own
  /// (the web runtime prepares that one signature).
  final int? visionTokensPerImage;

  @override
  bool operator ==(Object other) =>
      other is EmbeddingOptions &&
      other.normalize == normalize &&
      other.insertSpecialTokens == insertSpecialTokens &&
      other.outputSize == outputSize &&
      other.visionTokensPerImage == visionTokensPerImage;

  @override
  int get hashCode => Object.hash(
    normalize,
    insertSpecialTokens,
    outputSize,
    visionTokensPerImage,
  );

  @override
  String toString() =>
      'EmbeddingOptions(normalize: $normalize, insertSpecialTokens: '
      '$insertSpecialTokens, outputSize: $outputSize, visionTokensPerImage: '
      '$visionTokensPerImage)';
}

/// Internal to the runtime: the public library does not export it.
extension EmbeddingOptionsDefaults on EmbeddingOptions {
  /// No field set: the engine's defaults.
  bool get isDefault =>
      normalize == null &&
      insertSpecialTokens == null &&
      outputSize == null &&
      visionTokensPerImage == null;
}

/// Throws [ArgumentError] for [options] an engine of [dimension] cannot
/// apply: an [EmbeddingOptions.outputSize] outside 1..[dimension], or an
/// [EmbeddingOptions.visionTokensPerImage] on an engine loaded without images
/// ([engineVisionTokensPerImage] null), not one of [budgets], above the
/// engine's own, or — with [onlyEngineBudget], the reason — other than it.
void checkEmbeddingOptions(
  EmbeddingOptions options, {
  required int dimension,
  required int? engineVisionTokensPerImage,
  required List<int> budgets,
  String? onlyEngineBudget,
}) {
  if (options.outputSize case final size? when size < 1 || size > dimension) {
    throw ArgumentError.value(
      size,
      'outputSize',
      'must be from 1 to the dimension, $dimension',
    );
  }
  final budget = options.visionTokensPerImage;
  if (budget == null) return;
  if (engineVisionTokensPerImage == null) {
    throw ArgumentError.value(
      budget,
      'visionTokensPerImage',
      'applies to images, and this engine was loaded without them',
    );
  }
  if (!budgets.contains(budget)) {
    throw ArgumentError.value(
      budget,
      'visionTokensPerImage',
      'must be one of $budgets',
    );
  }
  if (onlyEngineBudget != null && budget != engineVisionTokensPerImage) {
    throw ArgumentError.value(
      budget,
      'visionTokensPerImage',
      "must be the engine's own, $engineVisionTokensPerImage: "
          '$onlyEngineBudget',
    );
  }
  if (budget > engineVisionTokensPerImage) {
    throw ArgumentError.value(
      budget,
      'visionTokensPerImage',
      "must be at most the engine's own, $engineVisionTokensPerImage: "
          'LiteRT-LM prepares the vision signatures up to the budget the '
          'engine was created with',
    );
  }
}

/// What a loaded embedder reports.
@immutable
final class EmbedderInfo {
  /// [modalities] is copied into an unmodifiable set.
  EmbedderInfo({
    required this.dimension,
    required this.maxInputTokens,
    required Set<EmbedderModality> modalities,
    required this.visionTokensPerImage,
    required this.activeBackend,
  }) : modalities = Set.unmodifiable(modalities);

  /// The length of every vector.
  final int dimension;

  /// The longest input, in tokens (media tokens counted).
  final int maxInputTokens;

  /// What this load embeds: text, and the media it declared and the bundle has.
  final Set<EmbedderModality> modalities;

  /// The vision budget the engine was created with; null without images.
  final int? visionTokensPerImage;

  /// Where the text tower runs.
  final BackendKind activeBackend;
}

/// The embedder could not load. Core: `EmbeddingLoadException`.
final class EmbedderLoadException extends LiteRtLmException {
  const EmbedderLoadException(super.message, {this.nativeCode, this.cause});

  /// LiteRT-LM's status code, when a native call failed.
  final int? nativeCode;

  /// What failed underneath, when something did.
  final Object? cause;

  @override
  String toString() => 'EmbedderLoadException: $message';
}

/// A loaded embedder failed a request. Core: `EmbeddingEngineException`.
final class EmbedderEngineException extends LiteRtLmException {
  const EmbedderEngineException(super.message, {this.nativeCode, this.cause});

  /// LiteRT-LM's status code, when a native call failed.
  final int? nativeCode;

  /// What failed underneath, when something did.
  final Object? cause;

  @override
  String toString() => 'EmbedderEngineException: $message';
}

/// An input longer than the embedder takes; never truncated. Core:
/// `EmbeddingInputTooLongException`.
final class EmbedderInputTooLongException extends LiteRtLmException {
  const EmbedderInputTooLongException(
    super.message, {
    required this.maxInputTokens,
    this.actualTokens,
  });

  final int maxInputTokens;
  final int? actualTokens;

  @override
  String toString() => 'EmbedderInputTooLongException: $message';
}

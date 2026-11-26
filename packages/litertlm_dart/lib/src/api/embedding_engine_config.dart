// What an EmbeddingGemma 2 `EmbeddingEngine` loads and takes, shared by both
// arms.

import 'dart:typed_data' show Uint8List;

import 'package:meta/meta.dart' show immutable;

import '../embedder/embedder_types.dart';
import '../runtime/types.dart' show ActivationDataType;
import 'backend.dart';
import 'message.dart';

/// What an `EmbeddingEngine` loads, and on what: LiteRT-LM's Kotlin and
/// Swift `EmbeddingEngineConfig`.
///
/// Kotlin's `modelFd` (an Android file descriptor in place of [modelPath]) is
/// not here: LiteRT-LM's C API creates embedding settings from a path only,
/// and the bundle's NPU stamp and towers are read from the file by path
/// before the engine exists.
@immutable
final class EmbeddingEngineConfig {
  /// Throws [ArgumentError] for a [maxInputLength] below 1.
  EmbeddingEngineConfig({
    required this.modelPath,
    this.cacheDir,
    Backend? backend,
    this.visionBackend,
    this.audioBackend,
    this.visionTokensPerImage,
    this.requireWeightCache = false,
    this.maxInputLength,
    this.activationDataType,
  }) : backend = backend ?? const Backend.cpu() {
    if (maxInputLength case final length? when length < 1) {
      throw ArgumentError.value(length, 'maxInputLength', 'must be 1 or more');
    }
  }

  /// The EmbeddingGemma 2 `.litertlm` bundle. On the web: a URL the page can
  /// fetch (`blob:`, `https:`).
  final String modelPath;

  /// Where the engine keeps one weight-cache directory per bundle copy. Use a
  /// directory that is not backed up; a purged cache is rebuilt at the next
  /// load. Natively it is required: `EmbeddingEngine.create` refuses a null
  /// one with an [ArgumentError]. On the web the runtime keeps no weight
  /// cache, and a given one is refused, as `EngineConfig.cacheDir` is.
  final String? cacheDir;

  /// The text tower's backend. Natively: a per-SoC bundle runs on the NPU
  /// only, a generic one never there; the GPU is taken where it was measured,
  /// for the bundles measured there, and refused elsewhere (never moved to
  /// the CPU). On the web: [Backend.gpu] (WebGPU) only — the CPU
  /// (WebAssembly) path of the pinned `@litert-lm/core` 0.20.0 loads these
  /// bundles but takes 110-225 s to load and 9-12 s per short text, so
  /// `Backend.cpu`, the default, is refused there for speed, as is the
  /// NPU.
  final Backend backend;

  /// Null: images are not taken. Set: they are, and a bundle without a vision
  /// tower is refused. Natively the vision tower runs on the NPU beside an
  /// NPU text tower and on the CPU otherwise; any other backend is refused.
  /// On the web it runs on the text tower's backend, and another is refused.
  final Backend? visionBackend;

  /// Null: audio is not taken. Set: it is, and a bundle without an audio
  /// tower is refused. Natively the audio tower runs on the CPU only; on the
  /// web on [Backend.gpu] (measured some 65 times faster than its WebAssembly
  /// CPU path) or [Backend.cpu].
  final Backend? audioBackend;

  /// Vision tokens per image: 140 (null) or 70.
  final int? visionTokensPerImage;

  /// Refuse a load that leaves no real weight cache behind, instead of
  /// warning. Native only: the web keeps no weight cache, and `true` is
  /// refused there.
  final bool requireWeightCache;

  /// The longest text input the engine must take, in tokens (Kotlin's and
  /// Swift's `maxInputLength`). Null is 1024 (the largest signature when a
  /// bundle has none that long). The engine prepares the bundle's text
  /// signatures up to the smallest one at or above it, and that signature is
  /// its limit (`info.maxInputTokens`): an input over it is refused with an
  /// [EmbedderInputTooLongException], never truncated. Natively a length
  /// above the bundle's largest signature is refused at load (LiteRT-LM
  /// refuses it). Memory grows with the signature: one 8192-token input
  /// peaked at +10.25 GB.
  final int? maxInputLength;

  /// The activation type of the text tower and, when there is one, the
  /// vision tower (Kotlin's `EmbeddingEngineConfig.activationDataType`;
  /// Swift has none). Null keeps the bundle's preferred type. Refused on the
  /// web, whose `EmbeddingEngine` takes none.
  final ActivationDataType? activationDataType;
}

/// [contents] as one embedder request: at most one text part, any image
/// parts and at most one audio part. Throws [ArgumentError] for contents an
/// engine of [modalities] does not take ([checkEmbeddingRequest]).
EmbedderInput embedderInputOfContents(
  List<Content> contents,
  Set<EmbedderModality> modalities,
) {
  String? text;
  final images = <Uint8List>[];
  Uint8List? audio;
  for (final part in contents) {
    switch (part) {
      case TextContent(text: final t):
        if (text != null) {
          throw ArgumentError.value(contents, 'contents', 'has two texts');
        }
        text = t;
      case ImageBytesContent(:final bytes):
        images.add(bytes);
      case AudioBytesContent(:final bytes):
        if (audio != null) {
          throw ArgumentError.value(contents, 'contents', 'has two audios');
        }
        audio = bytes;
      case ImageFileContent() || AudioFileContent() || ToolResponseContent():
        throw ArgumentError.value(
          part,
          'contents',
          'an embedding takes text, image bytes and audio bytes',
        );
    }
  }
  checkEmbeddingRequest(
    contents,
    modalities: modalities,
    hasText: text != null,
    hasImages: images.isNotEmpty,
    hasAudio: audio != null,
  );
  return EmbedderInput(text: text, images: images, audio: audio);
}

/// Refuses, as an [ArgumentError], [contents] with no part, or with images
/// or audio an engine of [modalities] was not loaded for.
void checkEmbeddingRequest(
  List<Content> contents, {
  required Set<EmbedderModality> modalities,
  required bool hasText,
  required bool hasImages,
  required bool hasAudio,
}) {
  if (!hasText && !hasImages && !hasAudio) {
    throw ArgumentError.value(contents, 'contents', 'has nothing to embed');
  }
  if (hasImages && !modalities.contains(EmbedderModality.image)) {
    throw ArgumentError.value(
      contents,
      'contents',
      'has images; load with visionBackend to embed them',
    );
  }
  if (hasAudio && !modalities.contains(EmbedderModality.audio)) {
    throw ArgumentError.value(
      contents,
      'contents',
      'has audio; load with audioBackend to embed it',
    );
  }
}

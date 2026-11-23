// What an EmbeddingGemma 2 `EmbeddingEngine` loads and takes, shared by both
// arms.

import 'dart:typed_data' show Uint8List;

import 'package:meta/meta.dart' show immutable;

import '../embedder/embedder_types.dart';
import 'backend.dart';
import 'message.dart';

/// What an [EmbeddingEngine] loads, and on what: LiteRT-LM's
/// `EmbeddingEngineConfig`.
@immutable
final class EmbeddingEngineConfig {
  EmbeddingEngineConfig({
    required this.modelPath,
    required this.cacheDir,
    Backend? backend,
    this.visionBackend,
    this.audioBackend,
    this.visionTokensPerImage,
    this.requireWeightCache = false,
  }) : backend = backend ?? const Backend.cpu();

  /// The EmbeddingGemma 2 `.litertlm` bundle.
  final String modelPath;

  /// Where the engine keeps one weight-cache directory per bundle copy. Use a
  /// directory that is not backed up; a purged cache is rebuilt at the next
  /// load.
  final String cacheDir;

  /// The text tower's backend. A per-SoC bundle runs on the NPU only, a
  /// generic one never there; the GPU is taken where it was measured, for the
  /// bundles measured there, and refused elsewhere (never moved to the CPU).
  final Backend backend;

  /// Null: images are not taken. Set: they are, and a bundle without a vision
  /// tower is refused. The vision tower runs on the NPU beside an NPU text
  /// tower and on the CPU otherwise; any other backend is refused.
  final Backend? visionBackend;

  /// Null: audio is not taken. Set: it is, and a bundle without an audio
  /// tower is refused. The audio tower runs on the CPU only; any other
  /// backend is refused.
  final Backend? audioBackend;

  /// Vision tokens per image: 140 (null) or 70.
  final int? visionTokensPerImage;

  /// Refuse a load that leaves no real weight cache behind, instead of
  /// warning.
  final bool requireWeightCache;
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

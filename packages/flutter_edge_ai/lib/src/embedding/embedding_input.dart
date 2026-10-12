import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import 'embedding_modality.dart';

/// One thing to embed, shaped like `Message`: optional text plus media.
///
/// Media are ENCODED files (JPEG, WAV, …), not decoded pixels or samples.
/// Which containers an engine accepts is engine-defined — its README says, and
/// the loaded model refuses anything else with
/// `EmbeddingFormatNotSupportedException` before the request is sent.
///
/// Bytes are COPIED at construction: an input is immutable, and a view the
/// caller passes would otherwise drag its whole backing buffer along when the
/// input is sent to the embedding worker.
final class EmbeddingInput {
  EmbeddingInput._({
    this.text,
    List<Uint8List> images = const [],
    Uint8List? audio,
  }) : images = List.unmodifiable([for (final image in images) _copy(image)]),
       audio = audio == null ? null : _copy(audio),
       _modalities = Set.unmodifiable({
         if (text != null) EmbeddingModality.text,
         if (images.isNotEmpty) EmbeddingModality.image,
         if (audio != null) EmbeddingModality.audio,
       });

  /// Text to embed. Empty text is valid: it embeds the task prefix and the
  /// model's terminators only.
  factory EmbeddingInput.text(String text) => EmbeddingInput._(text: text);

  /// One encoded image. Throws [ArgumentError] if [encodedImage] is empty.
  factory EmbeddingInput.image(Uint8List encodedImage) {
    _requireBytes(encodedImage, 'encodedImage');
    return EmbeddingInput._(images: [encodedImage]);
  }

  /// One encoded audio clip. Throws [ArgumentError] if [encodedAudio] is
  /// empty.
  factory EmbeddingInput.audio(Uint8List encodedAudio) {
    _requireBytes(encodedAudio, 'encodedAudio');
    return EmbeddingInput._(audio: encodedAudio);
  }

  /// The text part, or null for a media-only input.
  final String? text;

  /// The encoded images, in order. Unmodifiable; empty unless images were
  /// given.
  final List<Uint8List> images;

  /// The encoded audio clip, or null.
  final Uint8List? audio;

  final Set<EmbeddingModality> _modalities;

  /// The modalities this input carries. Unmodifiable, never empty.
  Set<EmbeddingModality> get modalities => _modalities;

  static Uint8List _copy(Uint8List bytes) =>
      Uint8List.fromList(bytes).asUnmodifiableView();

  static void _requireBytes(Uint8List bytes, String name) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, name, 'must not be empty');
    }
  }

  @override
  String toString() {
    final parts = [
      if (text != null) 'text(${text!.length} chars)',
      if (images.isNotEmpty)
        'images(${[for (final i in images) i.length].join(', ')} bytes)',
      if (audio != null) 'audio(${audio!.length} bytes)',
    ];
    return 'EmbeddingInput(${parts.join(', ')})';
  }
}

/// An input carrying several modalities at once.
///
/// The public constructor for this arrives with core 2.4.0 (R5 §2.1, P3); the
/// 2.3.0 facade already refuses such an input unless the engine declared
/// `combinedInputs` (D17), and this is how that refusal is tested before
/// then. Not exported by any public library. Same rules as the 2.4.0
/// constructor: at least one part, no empty byte array.
@visibleForTesting
EmbeddingInput debugCombinedEmbeddingInput({
  String? text,
  List<Uint8List> images = const [],
  Uint8List? audio,
}) {
  if (text == null && images.isEmpty && audio == null) {
    throw ArgumentError('An EmbeddingInput needs at least one part.');
  }
  for (final image in images) {
    EmbeddingInput._requireBytes(image, 'images');
  }
  if (audio != null) EmbeddingInput._requireBytes(audio, 'audio');
  return EmbeddingInput._(text: text, images: images, audio: audio);
}

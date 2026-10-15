import 'package:meta/meta.dart' show immutable;

import 'package:flutter_edge_ai/src/model.dart' show ModelType;

/// Where a message's media go relative to its text.
enum MediaPosition { beforeText, afterText }

/// The order in which an engine sends a user message's images, audio and text
/// to the model.
///
/// Media on the same side of the text keep a fixed order: images, then audio.
/// Several images keep the order they were given in. A message with no text
/// still carries its empty text part, so an audio-only message is the same in
/// every order.
///
/// The chat template renders the parts in the order they arrive, and a model
/// answers best in the order it was trained on, so this belongs to the model:
/// on LiteRT-LM, Gemma 4 E2B and E4B said they could not hear the audio less
/// often with the audio after the text, as their model card writes it; Gemma
/// 3n showed no difference; VibeVoice-ASR stopped transcribing with its audio
/// after the text.
@immutable
final class MultimodalOrder {
  const MultimodalOrder({
    this.images = MediaPosition.beforeText,
    this.audio = MediaPosition.beforeText,
  });

  final MediaPosition images;
  final MediaPosition audio;

  /// Images, audio, text.
  static const imagesAudioText = MultimodalOrder();

  /// Images, text, audio: the order of the Gemma 4 model card.
  static const imagesTextAudio = MultimodalOrder(
    audio: MediaPosition.afterText,
  );

  /// The order a model of [type] gets when `getActiveModel` is given none:
  /// [imagesTextAudio] for [ModelType.gemma4], [imagesAudioText] for every
  /// other type.
  static MultimodalOrder forModelType(ModelType type) => switch (type) {
    ModelType.gemma4 => imagesTextAudio,
    _ => imagesAudioText,
  };

  @override
  bool operator ==(Object other) =>
      other is MultimodalOrder &&
      other.images == images &&
      other.audio == audio;

  @override
  int get hashCode => Object.hash(images, audio);

  @override
  String toString() =>
      'MultimodalOrder(images: ${images.name}, audio: ${audio.name})';
}

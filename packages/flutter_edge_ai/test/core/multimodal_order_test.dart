import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Gemma 4 sends its audio after the text, every other type before', () {
    for (final type in ModelType.values) {
      expect(
        MultimodalOrder.forModelType(type),
        type == ModelType.gemma4
            ? MultimodalOrder.imagesTextAudio
            : MultimodalOrder.imagesAudioText,
        reason: type.name,
      );
    }
  });

  test('the named orders put images before the text', () {
    expect(MultimodalOrder.imagesAudioText.images, MediaPosition.beforeText);
    expect(MultimodalOrder.imagesAudioText.audio, MediaPosition.beforeText);
    expect(MultimodalOrder.imagesTextAudio.images, MediaPosition.beforeText);
    expect(MultimodalOrder.imagesTextAudio.audio, MediaPosition.afterText);
  });

  test('orders compare by value, so the model cache can compare them', () {
    const built = MultimodalOrder(audio: MediaPosition.afterText);
    expect(built, MultimodalOrder.imagesTextAudio);
    expect(built.hashCode, MultimodalOrder.imagesTextAudio.hashCode);
    expect(built, isNot(MultimodalOrder.imagesAudioText));
    expect(
      const MultimodalOrder(images: MediaPosition.afterText),
      isNot(MultimodalOrder.imagesAudioText),
    );
  });
}

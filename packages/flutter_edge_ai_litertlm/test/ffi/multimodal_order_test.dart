import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'ffi_test_support.dart';

final _image1 = Uint8List.fromList([1, 1]);
final _image2 = Uint8List.fromList([2, 2]);
final _audio = Uint8List.fromList([3, 3]);

/// The message's parts as short labels: `image1`, `image2`, `audio`, and
/// `text:<text>`.
List<String> _parts(
  String text, {
  List<Uint8List>? images,
  Uint8List? audio,
  MultimodalOrder? order,
}) {
  // What a session sends: its user message as litertlm_dart serializes it.
  final message = messageJson(
    liteRtLmUserMessage(
      text,
      images: images ?? const [],
      audio: audio,
      order: order ?? const MultimodalOrder(),
    ),
  );
  expect(message['role'], 'user');
  return [
    for (final part in message['content']! as List<Object?>)
      switch (part! as Map<String, Object?>) {
        {'type': 'text', 'text': final String t} => 'text:$t',
        {'type': 'audio', 'blob': final String b}
            when b == base64Encode(_audio) =>
          'audio',
        {'type': 'image', 'blob': final String b}
            when b == base64Encode(_image1) =>
          'image1',
        {'type': 'image', 'blob': final String b}
            when b == base64Encode(_image2) =>
          'image2',
        final other => 'unexpected $other',
      },
  ];
}

void main() {
  const at = MultimodalOrder.imagesAudioText;
  const ta = MultimodalOrder.imagesTextAudio;

  group('liteRtLmUserMessage', () {
    test('a text message is the text alone, in every order', () {
      for (final order in [at, ta]) {
        expect(_parts('hi', order: order), ['text:hi']);
      }
    });

    test('images stay before the text in both named orders', () {
      for (final order in [at, ta]) {
        expect(_parts('what is this', images: [_image1], order: order), [
          'image1',
          'text:what is this',
        ]);
      }
    });

    test('the audio goes before the text or after it', () {
      expect(_parts('tell me', audio: _audio, order: at), [
        'audio',
        'text:tell me',
      ]);
      expect(_parts('tell me', audio: _audio, order: ta), [
        'text:tell me',
        'audio',
      ]);
    });

    test('images, audio and text', () {
      expect(_parts('q', images: [_image1], audio: _audio, order: at), [
        'image1',
        'audio',
        'text:q',
      ]);
      expect(_parts('q', images: [_image1], audio: _audio, order: ta), [
        'image1',
        'text:q',
        'audio',
      ]);
    });

    test('several images keep the order they were given in', () {
      for (final order in [at, ta]) {
        expect(_parts('q', images: [_image2, _image1], order: order), [
          'image2',
          'image1',
          'text:q',
        ]);
      }
    });

    test('images may go after the text too', () {
      expect(
        _parts(
          'q',
          images: [_image1],
          audio: _audio,
          order: const MultimodalOrder(images: MediaPosition.afterText),
        ),
        ['audio', 'text:q', 'image1'],
      );
    });

    test('on the same side the images come before the audio', () {
      expect(
        _parts(
          'q',
          images: [_image1, _image2],
          audio: _audio,
          order: const MultimodalOrder(
            images: MediaPosition.afterText,
            audio: MediaPosition.afterText,
          ),
        ),
        ['text:q', 'image1', 'image2', 'audio'],
      );
    });

    test('an audio-only message keeps its empty text part', () {
      expect(_parts('', audio: _audio, order: at), ['audio', 'text:']);
      expect(_parts('', audio: _audio, order: ta), ['text:', 'audio']);
    });

    test('without an order it is images, audio, text', () {
      expect(_parts('q', images: [_image1], audio: _audio), [
        'image1',
        'audio',
        'text:q',
      ]);
    });
  });

  group('FfiInferenceModel', () {
    Future<MultimodalOrder> orderOfSession(
      ModelType type, {
      MultimodalOrder? multimodalOrder,
    }) async {
      final model = ffiModelForClient(
        ffiClient: LiteRtLmFfiClient(),
        maxTokens: 1024,
        modelType: type,
        activeBackend: null,
        multimodalOrder: multimodalOrder,
        // A shared conversation: opening it makes no native call.
        ownConversations: 1,
        onClose: () {},
      );
      final session = await model.createSession() as FfiInferenceModelSession;
      final order = session.multimodalOrder;
      await session.close();
      return order;
    }

    test('a conversation gets the order of the model type', () async {
      expect(await orderOfSession(ModelType.gemma4), ta);
      expect(await orderOfSession(ModelType.gemmaIt), at);
    });

    test('an order given to the model wins over its type', () async {
      expect(await orderOfSession(ModelType.gemma4, multimodalOrder: at), at);
      expect(await orderOfSession(ModelType.general, multimodalOrder: ta), ta);
    });
  });
}

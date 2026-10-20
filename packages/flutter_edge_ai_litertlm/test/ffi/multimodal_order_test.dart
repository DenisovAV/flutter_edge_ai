import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

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
  final json = order == null
      ? LiteRtLmFfiClient.buildMessageJson(
          text,
          imagesBytes: images,
          audioBytes: audio,
        )
      : LiteRtLmFfiClient.buildMessageJson(
          text,
          imagesBytes: images,
          audioBytes: audio,
          order: order,
        );
  final message = jsonDecode(json) as Map<String, Object?>;
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

/// Records the order the model asks the conversation for, then stops: no
/// engine is loaded.
class _CapturingClient extends LiteRtLmFfiClient {
  MultimodalOrder? multimodalOrder;

  @override
  SamplingParams get bundleSampler => const SamplingParams();

  @override
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    required ResolvedSampling sampling,
    required bool samplingExplicit,
    int? maxOutputTokens,
    required MultimodalOrder multimodalOrder,
  }) {
    this.multimodalOrder = multimodalOrder;
    throw const _Captured();
  }
}

class _Captured implements Exception {
  const _Captured();
}

void main() {
  const at = MultimodalOrder.imagesAudioText;
  const ta = MultimodalOrder.imagesTextAudio;

  group('buildMessageJson', () {
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
    Future<MultimodalOrder?> orderAskedFor(
      ModelType type, {
      MultimodalOrder? multimodalOrder,
    }) async {
      final client = _CapturingClient();
      final model = FfiInferenceModel(
        ffiClient: client,
        maxTokens: 1024,
        modelType: type,
        activeBackend: null,
        multimodalOrder: multimodalOrder,
        onClose: () {},
      );
      await expectLater(model.createSession(), throwsA(isA<_Captured>()));
      return client.multimodalOrder;
    }

    test('a conversation gets the order of the model type', () async {
      expect(await orderAskedFor(ModelType.gemma4), ta);
      expect(await orderAskedFor(ModelType.gemmaIt), at);
    });

    test('an order given to the model wins over its type', () async {
      expect(await orderAskedFor(ModelType.gemma4, multimodalOrder: at), at);
      expect(await orderAskedFor(ModelType.general, multimodalOrder: ta), ta);
    });
  });
}

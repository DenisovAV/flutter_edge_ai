// LiteRtLmWebSession sends images and audio when its engine loaded that
// encoder (core's supportImage / supportAudio), as natively: the media as
// their bytes, around the text as the model's MultimodalOrder says. Without
// the encoder it refuses the message rather than dropping the bytes, which
// let the model answer about media it never received. The engine side is
// measured in example/integration_test/web_multimodal_test.dart; these tests
// stand a stub Conversation on a plain JS object and pin the session's half.
//
// tool/test_all.sh runs it in Chrome (dart2js and dart2wasm). By hand:
//   flutter test --platform chrome test/web/litert_lm_web_session_media_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/web_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'web_session_fixture.dart';

/// A Conversation whose `sendMessageStreaming` records what it was sent and
/// returns an iterator that is already done.
({JSObject conversation, List<JSAny?> sent}) _stubConversation() {
  final sent = <JSAny?>[];
  final done = JSObject()..['done'] = true.toJS;
  final iterator = JSObject()
    ..['next'] = (() => Future<JSObject>.value(done).toJS).toJS;
  final conversation = JSObject()
    ..['sendMessageStreaming'] = ((JSAny? message) {
      sent.add(message);
      return iterator;
    }).toJS
    ..['cancel'] = (() {}).toJS
    ..['delete'] = (() => Future<void>.value().toJS).toJS;
  return (conversation: conversation, sent: sent);
}

LiteRtLmWebSession _session(
  JSObject conversation, {
  bool image = false,
  bool audio = false,
}) => webSessionOver(
  conversation,
  modelType: ModelType.gemma4,
  supportImage: image,
  supportAudio: audio,
);

/// The content parts of the message [sent] carried, as Dart values.
List<Object?> _parts(JSAny? sent) =>
    ((sent.dartify()! as Map)['content']! as List).cast<Object?>();

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
final _wav = Uint8List.fromList('RIFF'.codeUnits);

Matcher _refused(String flags) => throwsA(
  isA<UnsupportedError>().having(
    (e) => e.message,
    'message',
    allOf(contains('was loaded without'), contains(flags)),
  ),
);

void main() {
  group('LiteRtLmWebSession media', () {
    test(
      'without supportImage an image message throws, in every Message shape',
      () async {
        final session = _session(_stubConversation().conversation);
        for (final message in [
          Message.withImage(
            text: 'What is this?',
            imageBytes: _jpeg,
            isUser: true,
          ),
          Message.withImages(
            text: 'And these?',
            imageBytes: [_jpeg, _jpeg],
            isUser: true,
          ),
          Message.imageOnly(imageBytes: _jpeg, isUser: true),
        ]) {
          await expectLater(
            session.addQueryChunk(message),
            _refused('supportImage: true'),
          );
        }
      },
    );

    test('without supportAudio an audio message throws', () async {
      final session = _session(_stubConversation().conversation);
      await expectLater(
        session.addQueryChunk(
          Message.withAudio(
            text: 'Transcribe.',
            audioBytes: _wav,
            isUser: true,
          ),
        ),
        _refused('supportAudio: true'),
      );
      await expectLater(
        session.addQueryChunk(
          Message.audioOnly(audioBytes: _wav, isUser: true),
        ),
        _refused('supportAudio: true'),
      );
    });

    test('a message with both names both flags', () async {
      final session = _session(_stubConversation().conversation);
      await expectLater(
        session.addQueryChunk(
          Message(
            text: 'Both.',
            imageBytes: _jpeg,
            audioBytes: _wav,
            isUser: true,
          ),
        ),
        _refused('supportImage: true and supportAudio: true'),
      );
    });

    test('a refused message leaves the next turn unchanged', () async {
      final stub = _stubConversation();
      final session = _session(stub.conversation);

      await expectLater(
        session.addQueryChunk(
          Message.withImage(
            text: 'REFUSED-IMAGE-TURN',
            imageBytes: _jpeg,
            isUser: true,
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
      await session.addQueryChunk(
        const Message(text: 'Hello there', isUser: true),
      );
      await session.getResponse();

      expect(stub.sent, hasLength(1));
      final sent = stub.sent.single;
      expect(
        sent.isA<JSString>(),
        isTrue,
        reason: 'a text turn goes to the runtime as a plain string',
      );
      final text = (sent as JSString).toDart;
      expect(text, contains('Hello there'));
      expect(text, isNot(contains('REFUSED-IMAGE-TURN')));
    });

    test('a text message is still sent as a plain string', () async {
      final stub = _stubConversation();
      final session = _session(stub.conversation);

      await session.addQueryChunk(const Message(text: 'Hi.', isUser: true));
      final response = await session.getResponse();

      expect(response, isEmpty, reason: 'the stub iterator is already done');
      expect(stub.sent.single.isA<JSString>(), isTrue);
      expect((stub.sent.single as JSString).toDart, contains('Hi.'));
    });

    test('with supportImage an image goes to the runtime as its bytes, before '
        'the text for Gemma 4', () async {
      final stub = _stubConversation();
      final session = _session(stub.conversation, image: true);

      await session.addQueryChunk(
        Message.withImage(
          text: 'What is this?',
          imageBytes: _jpeg,
          isUser: true,
        ),
      );
      await session.getResponse();

      final parts = _parts(stub.sent.single);
      expect(parts.first, {'type': 'image', 'blob': base64Encode(_jpeg)});
      expect(parts.last, containsPair('type', 'text'));
    });

    test('every image of a message is sent once', () async {
      final stub = _stubConversation();
      final session = _session(stub.conversation, image: true);

      await session.addQueryChunk(
        Message.withImages(
          text: 'And these?',
          imageBytes: [_jpeg, _jpeg],
          isUser: true,
        ),
      );
      await session.getResponse();

      expect(
        _parts(stub.sent.single).where((p) => (p! as Map)['type'] == 'image'),
        hasLength(2),
      );
    });

    test('with supportAudio a clip goes to the runtime as its bytes', () async {
      final stub = _stubConversation();
      final session = _session(stub.conversation, audio: true);

      await session.addQueryChunk(
        Message.withAudio(text: 'Transcribe.', audioBytes: _wav, isUser: true),
      );
      await session.getResponse();

      expect(
        _parts(stub.sent.single),
        contains(equals({'type': 'audio', 'blob': base64Encode(_wav)})),
      );
    });
  });
}

// LiteRtLmWebSession refuses image and audio messages. `@litert-lm/core`
// 0.18.0 creates the LLM engine with no vision or audio executor, so the bytes
// could reach no encoder; the session used to drop them, and the model then
// answered about media it never received. The engine side is measured in
// example/integration_test/web_multimodal_test.dart; these tests stand a stub
// Conversation on a plain JS object and pin the session's half: the refusal,
// its wording, and that nothing of the refused message is staged.
//
// Not run by tool/test_all.sh or CI, which run on the VM. Run:
//   flutter test --platform chrome test/web/litert_lm_web_session_media_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web.dart';
import 'package:flutter_edge_ai_litertlm/src/web/litert_lm_web_inference.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mutex/mutex.dart';

/// A Conversation whose `sendMessageStreaming` records what it was sent and
/// returns an iterator that is already done.
({LiteRtLmConversation conversation, List<JSAny?> sent}) _stubConversation() {
  final sent = <JSAny?>[];
  final done = JSObject()..['done'] = true.toJS;
  final iterator = JSObject()
    ..['next'] = (() => Future<JSObject>.value(done).toJS).toJS;
  final conversation = JSObject()
    ..['sendMessageStreaming'] = ((JSAny? message) {
      sent.add(message);
      return iterator;
    }).toJS
    ..['cancel'] = (() {}).toJS;
  return (conversation: conversation as LiteRtLmConversation, sent: sent);
}

LiteRtLmWebSession _session(LiteRtLmConversation conversation) =>
    LiteRtLmWebSession(
      conversation: conversation,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      generationMutex: Mutex(),
      onClose: () {},
    );

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
final _wav = Uint8List.fromList('RIFF'.codeUnits);

Matcher _refused(String kinds, {required bool namesMediaPipe}) => throwsA(
  isA<UnsupportedError>().having(
    (e) => e.message,
    'message',
    allOf(
      contains('Web LiteRT-LM does not support $kinds input for LLMs yet'),
      namesMediaPipe ? contains('MediaPipe') : isNot(contains('MediaPipe')),
    ),
  ),
);

void main() {
  group('LiteRtLmWebSession media', () {
    test('an image message throws, in every Message shape', () async {
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
          _refused('image', namesMediaPipe: true),
        );
      }
    });

    test('an audio message throws', () async {
      final session = _session(_stubConversation().conversation);
      await expectLater(
        session.addQueryChunk(
          Message.withAudio(
            text: 'Transcribe.',
            audioBytes: _wav,
            isUser: true,
          ),
        ),
        _refused('audio', namesMediaPipe: false),
      );
      await expectLater(
        session.addQueryChunk(
          Message.audioOnly(audioBytes: _wav, isUser: true),
        ),
        _refused('audio', namesMediaPipe: false),
      );
    });

    test('a message with both names both', () async {
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
        _refused('image and audio', namesMediaPipe: true),
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
  });
}

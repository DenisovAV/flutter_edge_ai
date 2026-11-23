// Images and audio in a web conversation, over the stub runtime
// (web_runtime_stub.dart), which does what @litert-lm/core 0.19.0 was
// measured to do with Gemma 4 E2B's GPU export (2026-11-23): a part's bytes
// go as base64 in `blob`, and the runtime's history returns them as
// `blob: {bytes: [...]}`, which a preface aborts the module on.
//
// Run: dart test -p chrome test/web/web_conversation_media_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_conversation_media_browser_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

final _png = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
final _wav = Uint8List.fromList([82, 73, 70, 70, 4, 5]);

Future<web.Engine> _multimodalEngine() => web.createWebEngine(
  EngineConfig(
    modelPath: 'blob:https://example.com/model',
    backend: const Backend.gpu(),
    visionBackend: const Backend.gpu(),
    audioBackend: const Backend.cpu(),
  ),
  pageLock: web.LiteRtLmPageLock(),
);

Message _withImage(String text) => Message(
  role: Role.user,
  contents: [Content.imageBytes(_png), Content.text(text)],
);

void main() {
  setUp(() {
    installRuntime();
    setOnPage('resolvedVisionBackend', 4);
    setOnPage('resolvedAudioBackend', 3);
  });
  tearDown(removeRuntime);

  test('an image goes to the runtime as its bytes in base64', () async {
    final engine = await _multimodalEngine();
    final conversation = await engine.createConversation();

    final reply = conversation.sendMessageStream(_withImage('Which shape?'));
    final done = reply.drain<void>();
    await settle();
    js('__end');
    await done;

    expect(list('sent').single, {
      'role': 'user',
      'content': [
        {'type': 'image', 'blob': base64Encode(_png)},
        {'type': 'text', 'text': 'Which shape?'},
      ],
    });
    await engine.close();
  });

  test('an audio clip goes to the runtime as its bytes in base64', () async {
    final engine = await _multimodalEngine();
    final conversation = await engine.createConversation();

    final done = conversation
        .sendMessageStream(
          Message(
            role: Role.user,
            contents: [Content.audioBytes(_wav), Content.text('Transcribe.')],
          ),
        )
        .drain<void>();
    await settle();
    js('__end');
    await done;

    expect(((list('sent').single! as Map)['content'] as List).first, {
      'type': 'audio',
      'blob': base64Encode(_wav),
    });
    await engine.close();
  });

  test('a rebuild replays an image of the history as base64, not as the '
      'runtime\'s {bytes}', () async {
    final engine = await _multimodalEngine();
    final conversation = await engine.createConversation();
    final first = conversation
        .sendMessageStream(_withImage('Which shape?'))
        .drain<void>();
    await settle();
    js('__step', 'Circle');
    js('__end');
    await first;
    await stoppedExchange(conversation, 'Count to 300.', '1 2');

    await exchange(conversation, 'Which shape was it?', 'Circle');

    expect(prefaceMessages(1)!.first, {
      'role': 'user',
      'content': [
        {'type': 'image', 'blob': base64Encode(_png)},
        {'type': 'text', 'text': 'Which shape?'},
      ],
    });
    await engine.close();
  });

  group('refuses, without sending', () {
    Matcher refused(String message) => emitsError(
      isA<UnsupportedError>().having(
        (e) => e.message,
        'message',
        contains(message),
      ),
    );

    test('an image by file path', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation();

      await expectLater(
        conversation.sendMessageStream(
          Message(
            role: Role.user,
            contents: [Content.imageFile('/photo.png'), Content.text('x')],
          ),
        ),
        refused('cannot read a file path'),
      );

      expect(list('sent'), isEmpty);
      await engine.close();
    });

    test('an image on an engine without a vision encoder', () async {
      setOnPage('resolvedVisionBackend', null);
      setOnPage('resolvedAudioBackend', null);
      final engine = await webEngine();
      final conversation = await engine.createConversation();

      await expectLater(
        conversation.sendMessageStream(_withImage('x')),
        refused('loaded no vision encoder'),
      );

      expect(list('sent'), isEmpty);
      await engine.close();
    });

    test('audio on an engine without an audio encoder', () async {
      setOnPage('resolvedVisionBackend', null);
      setOnPage('resolvedAudioBackend', null);
      final engine = await webEngine();
      final conversation = await engine.createConversation();

      await expectLater(
        conversation.sendMessageStream(
          Message(
            role: Role.user,
            contents: [Content.audioBytes(_wav), Content.text('x')],
          ),
        ),
        refused('loaded no audio encoder'),
      );

      expect(list('sent'), isEmpty);
      await engine.close();
    });
  });
}

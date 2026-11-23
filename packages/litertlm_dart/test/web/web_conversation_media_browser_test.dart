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

Future<web.Engine> _multimodalEngine({int? maxNumImages}) =>
    web.createWebEngine(
      EngineConfig(
        modelPath: 'blob:https://example.com/model',
        backend: const Backend.gpu(),
        visionBackend: const Backend.gpu(),
        audioBackend: const Backend.cpu(),
        maxNumImages: maxNumImages,
      ),
      pageLock: web.LiteRtLmPageLock(),
    );

/// Sends [message] on [conversation] and ends its reply.
Future<void> _answered(Conversation conversation, Message message) async {
  final done = conversation.sendMessageStream(message).drain<void>();
  await settle();
  js('__end');
  await done;
}

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

  group('maxNumImages counts the images of a conversation', () {
    test('an image past it is refused before the send, naming '
        'maxNumImages', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation();
      await _answered(conversation, _withImage('Which shape?'));

      await expectLater(
        conversation.sendMessageStream(_withImage('And this one?')),
        emitsError(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            allOf(contains('maxNumImages: 1'), contains('holds 1 of the 1')),
          ),
        ),
      );

      expect(list('sent'), hasLength(1));
      await engine.close();
    });

    test(
      'a larger maxNumImages takes more images in one conversation',
      () async {
        final engine = await _multimodalEngine(maxNumImages: 2);
        final conversation = await engine.createConversation();

        await _answered(conversation, _withImage('Which shape?'));
        await _answered(conversation, _withImage('And this one?'));

        expect(list('sent'), hasLength(2));
        await engine.close();
      },
    );

    test(
      'an image of a turn the runtime failed is freed by the rebuild',
      () async {
        final engine = await _multimodalEngine(maxNumImages: 2);
        final conversation = await engine.createConversation();
        await _answered(conversation, _withImage('Which shape?'));
        final failed = conversation
            .sendMessageStream(_withImage('And this one?'))
            .drain<void>()
            .catchError((Object _) {});
        await settle();
        js('__fail', 'generation failed');
        await failed;

        await _answered(conversation, _withImage('And now this one?'));

        expect(list('sent'), hasLength(3));
        await engine.close();
      },
    );

    test('an image turn stopped before any output frees its image for one '
        'sent right after the stop', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation();
      final stopped = conversation
          .sendMessageStream(_withImage('Which shape?'))
          .drain<void>();
      await settle();
      conversation.cancel();
      final next = conversation
          .sendMessageStream(_withImage('And this one?'))
          .drain<void>();
      await stopped;
      await settle();
      js('__end');
      await next;

      expect(list('sent'), hasLength(2));
      await engine.close();
    });

    test('an image whose reply stream could not be read is freed by the '
        'rebuild', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation();
      setOnPage('unreadable', true);
      await conversation
          .sendMessageStream(_withImage('Which shape?'))
          .drain<void>()
          .catchError((Object _) {});
      setOnPage('unreadable', false);

      await _answered(conversation, _withImage('And this one?'));

      expect(list('sent'), hasLength(2));
      await engine.close();
    });

    test('of two image turns queued on the handle under a reservation of '
        'one, the second is refused when its turn comes', () async {
      final engine = await _multimodalEngine();
      final handle = web.conversationHandle(await engine.createConversation());
      String image(String text) => jsonEncode({
        'role': 'user',
        'content': [
          {'type': 'image', 'blob': base64Encode(_png)},
          {'type': 'text', 'text': text},
        ],
      });
      final first = handle.chatRawMessage(image('Which shape?')).drain<void>();
      final second = expectLater(
        handle.chatRawMessage(image('And this one?')),
        emitsError(errorWith<UnsupportedError>('maxNumImages: 1')),
      );
      await settle();
      js('__end');
      await first;
      await second;

      expect(list('sent'), hasLength(1));
      await engine.close();
    });

    test('a message with more images than it is refused before it is '
        'queued', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation();

      await expectLater(
        conversation.sendMessageStream(
          Message(
            role: Role.user,
            contents: [
              Content.imageBytes(_png),
              Content.imageBytes(_png),
              Content.text('Both?'),
            ],
          ),
        ),
        emitsError(errorWith<UnsupportedError>('the message has 2')),
      );

      expect(list('sent'), isEmpty);
      await engine.close();
    });

    test('an initial image counts against it', () async {
      final engine = await _multimodalEngine();
      final conversation = await engine.createConversation(
        ConversationConfig(initialMessages: [_withImage('Remember this.')]),
      );

      await expectLater(
        conversation.sendMessageStream(_withImage('And this one?')),
        emitsError(errorWith<UnsupportedError>('maxNumImages: 1')),
      );

      expect(list('sent'), isEmpty);
      await engine.close();
    });
  });

  test('an initial image goes to the preface as its bytes in base64', () async {
    final engine = await _multimodalEngine();

    await engine.createConversation(
      ConversationConfig(initialMessages: [_withImage('Remember this.')]),
    );

    expect(prefaceMessages(0)!.single, {
      'role': 'user',
      'content': [
        {'type': 'image', 'blob': base64Encode(_png)},
        {'type': 'text', 'text': 'Remember this.'},
      ],
    });
    await engine.close();
  });

  test('an initial audio clip without an audio encoder is refused', () async {
    setOnPage('resolvedAudioBackend', null);
    final engine = await webEngine();

    await expectLater(
      engine.createConversation(
        ConversationConfig(
          initialMessages: [
            Message(
              role: Role.user,
              contents: [Content.audioBytes(_wav), Content.text('x')],
            ),
          ],
        ),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('loaded no audio encoder'),
        ),
      ),
    );

    expect(list('conversationOptions'), isEmpty);
    await engine.close();
  });
}

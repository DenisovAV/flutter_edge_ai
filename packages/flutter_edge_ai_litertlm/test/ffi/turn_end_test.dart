import 'dart:async';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal.dart' hide ActivationDataType;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;
import 'ffi_test_support.dart';

/// A conversation whose native side the test plays: each send is a real
/// [NativeTurnStream] on [turns], and the test posts its chunks and its end
/// through [send].
class _Handle implements ConversationHandle {
  final turns = NativeTurns<String>(cancelNative: (_) {}, deleteNative: (_) {});
  late NativeTurnStream<String> send;
  final sent = Completer<void>();

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) {
    send = NativeTurnStream(turns, 'c');
    sent.complete();
    return send.stream;
  }

  @override
  void cancelGeneration() => turns.cancel('c');

  @override
  Future<void> close() async => turns.release('c');

  @override
  Future<int?> tokenCount(String text) async => text.length;

  @override
  BenchmarkInfo getSessionMetrics() => const BenchmarkInfo();

  /// Native's turn-end record, as the test sets it.
  NativeLastTurnEnd? turnEnd;

  @override
  NativeLastTurnEnd? get lastTurnEnd => turnEnd;

  @override
  int? get lastTurnCode => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FfiInferenceModelSession _session(_Handle handle, {int? maxOutputTokens}) =>
    ffiSessionForHandle(
      handle: handle,
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
      supportImage: false,
      supportAudio: false,
      maxOutputTokens: maxOutputTokens,
      onClose: () {},
    );

void main() {
  test('a chat turn the session close cuts short keeps its partial reply in '
      'the history, then fails with a StateError (decision H)', () async {
    final handle = _Handle();
    final session = _session(handle);
    final chat = InferenceChat(
      sessionCreator: () async => session,
      maxTokens: 1024,
    );
    await chat.initSession();
    await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));

    final seen = <String>[];
    final done = chat.generateChatResponseAsync().forEach(
      (r) => seen.add((r as TextResponse).token),
    );
    await handle.sent.future;
    handle.send.chunk('Par');
    await pumpEventQueue();
    await session.close();
    handle.send.cancelled();

    await expectLater(done, throwsStateError);
    expect(seen, ['Par']);
    expect(chat.fullHistory.map((m) => m.text), ['Hi', 'Par']);
  });

  test('a stop keeps the partial reply as the turn\'s answer', () async {
    final handle = _Handle();
    final session = _session(handle);
    final chat = InferenceChat(
      sessionCreator: () async => session,
      maxTokens: 1024,
    );
    await chat.initSession();
    await chat.addQueryChunk(const Message(text: 'Hi', isUser: true));

    final reply = chat.generateChatResponse();
    await handle.sent.future;
    handle.send.chunk('Par');
    await chat.stopGeneration();
    handle.send.cancelled();

    expect(((await reply) as TextResponse).token, 'Par');
    expect(chat.fullHistory.last.text, 'Par');
  });

  test('a stop asked before the close still reads as a stop', () async {
    final handle = _Handle();
    final session = _session(handle);
    final turn = startEngineTurnForTest(session);
    final text = turn.text.toList();
    await handle.sent.future;
    handle.send.chunk('Par');
    await session.stopGeneration();
    await session.close();
    handle.send.cancelled();
    expect(await text, ['Par']);
    expect(await turn.end, TurnEnd.stopped);
  });

  test('a model close (its conversations released, the session object '
      'still open) is TurnEnd.closed too', () async {
    final handle = _Handle();
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;
    handle.send.chunk('Par');
    // What LiteRtLmFfiClient.shutdown does to every handle.
    handle.close();
    handle.send.cancelled();
    expect(await text, ['Par']);
    expect(await turn.end, TurnEnd.closed);
  });

  test('getResponseAsync itself still fails a closed turn (B90)', () async {
    final handle = _Handle();
    final session = _session(handle);
    final text = session.getResponseAsync().toList();
    await handle.sent.future;
    await session.close();
    handle.send.cancelled();
    await expectLater(text, throwsA(isA<LiteRtLmSessionClosedError>()));
  });

  for (final (cap, expected) in [
    (null, TurnEnd.endOfSequence),
    (64, TurnEnd.outputLimit),
  ]) {
    test(
      'a completed turn reports $expected with maxOutputTokens $cap',
      () async {
        final handle = _Handle();
        final turn = startEngineTurnForTest(
          _session(handle, maxOutputTokens: cap),
        );
        final text = turn.text.toList();
        await handle.sent.future;
        handle.send
          ..chunk('ok')
          ..finished();
        expect(await text, ['ok']);
        expect(await turn.end, expected);
      },
    );
  }

  for (final (record, expected) in [
    (NativeLastTurnEnd.completed, TurnEnd.endOfSequence),
    (NativeLastTurnEnd.outputLimit, TurnEnd.outputLimit),
    (NativeLastTurnEnd.contextLimit, TurnEnd.contextLimit),
  ]) {
    test('a completed turn reports $expected when native\'s record is '
        '$record, whatever the cap', () async {
      for (final cap in [null, 64]) {
        final handle = _Handle()..turnEnd = record;
        final turn = startEngineTurnForTest(
          _session(handle, maxOutputTokens: cap),
        );
        final text = turn.text.toList();
        await handle.sent.future;
        handle.send
          ..chunk('ok')
          ..finished();
        expect(await text, ['ok']);
        expect(await turn.end, expected, reason: 'cap $cap');
      }
    });
  }

  test('a turn native ended context_full fails its text with the public '
      'ContextLimitException that keeps native token counts, and its end is '
      'contextLimit; getResponseAsync fails the same way', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.contextFull;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;
    handle.send.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
    await expectLater(
      text,
      throwsA(
        isA<ContextLimitException>().having(
          (e) => '$e',
          'message',
          allOf(contains('token count'), contains('RESOURCE_EXHAUSTED')),
        ),
      ),
    );
    expect(await turn.end, TurnEnd.contextLimit);

    final plain = _Handle()..turnEnd = NativeLastTurnEnd.contextFull;
    final failing = _session(plain).getResponseAsync().toList();
    await plain.sent.future;
    plain.send.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
    await expectLater(failing, throwsA(isA<ContextLimitException>()));
  });

  test('any other failed turn keeps its error on the text', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;
    handle.send.failed(Exception('Stream error: INTERNAL'));
    await expectLater(text, throwsException);
  });

  test('a native failure mid-turn reaches core as the plain Exception a '
      'session open throws, not as the runtime type', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;
    handle.send.failed(
      const lm.LiteRtLmNativeException(
        'Failed to create conversation (INTERNAL)',
      ),
    );
    await expectLater(
      text,
      throwsA(
        allOf(
          isNot(isA<lm.LiteRtLmException>()),
          isA<Exception>().having(
            (e) => '$e',
            'message',
            contains('Failed to create conversation (INTERNAL)'),
          ),
        ),
      ),
    );
  });

  test('a failed GPU turn that names Backend.cpu() reaches core with the '
      'line in core\'s terms', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;

    handle.send.failed(
      const lm.LiteRtLmNativeException(
        'Stream error: INTERNAL. Load it on the CPU (Backend.cpu()).',
      ),
    );

    await expectLater(
      text,
      throwsA(
        isA<Exception>().having(
          (e) => '$e',
          'message',
          allOf(
            contains('(Backend.cpu())'),
            contains(
              'In flutter_edge_ai: preferredBackend: '
              'PreferredBackend.cpu, or none.',
            ),
          ),
        ),
      ),
    );
  });

  test('a failed turn whose cause is a library that failed to load keeps '
      'that type and gets the line in core\'s terms', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;

    handle.send.failed(
      const LibraryLoadFailedException(
        "LiteRT-LM's companion libraries are not in the app: …",
      ),
    );

    await expectLater(
      text,
      throwsA(
        isA<LibraryLoadFailedException>().having(
          (e) => e.loadMessage,
          'message',
          contains("flutter_edge_ai_litertlm's Swift package embeds them"),
        ),
      ),
    );
  });

  test('a runtime exception that fails the turn keeps its '
      'type and gets the line in core\'s terms', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;

    handle.send.failed(
      const lm.LiteRtLmEngineCreateException(
        'The encoder failed. Load it on the CPU (Backend.cpu()).',
      ),
    );

    await expectLater(
      text,
      throwsA(
        isA<lm.LiteRtLmEngineCreateException>().having(
          (e) => e.message,
          'message',
          contains(
            'In flutter_edge_ai: preferredBackend: PreferredBackend.cpu',
          ),
        ),
      ),
    );
  });

  test('an Error that is not native keeps its type and gets the line in '
      'core\'s terms', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.failed;
    final turn = startEngineTurnForTest(_session(handle));
    final text = turn.text.toList();
    await handle.sent.future;

    handle.send.failed(
      UnsupportedError(
        'No GPU sampler here. Load it on the CPU (Backend.cpu()).',
      ),
    );

    await expectLater(
      text,
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('No GPU sampler here.'),
            contains(
              'In flutter_edge_ai: preferredBackend: PreferredBackend.cpu',
            ),
          ),
        ),
      ),
    );
  });

  test('liteRtLmCompletedTurnEnd: each record, and the guess without one', () {
    for (final end in [...NativeLastTurnEnd.values, null]) {
      for (final cap in [null, 64]) {
        final guess = cap == null ? TurnEnd.endOfSequence : TurnEnd.outputLimit;
        expect(liteRtLmCompletedTurnEnd(end, cap), switch (end) {
          NativeLastTurnEnd.completed => TurnEnd.endOfSequence,
          NativeLastTurnEnd.outputLimit => TurnEnd.outputLimit,
          NativeLastTurnEnd.contextLimit ||
          NativeLastTurnEnd.contextFull => TurnEnd.contextLimit,
          _ => guess,
        }, reason: '$end, cap $cap');
      }
    }
  });

  test('npuContextWindowNote: silent when the window is the one asked for', () {
    expect(npuContextWindowNote(asked: 4096, window: 4096), isNull);
    final note = npuContextWindowNote(asked: 4096, window: 1280)!;
    expect(note, contains('1280'));
    expect(note, contains('4096'));
    expect(note, contains('one KV cache'));
  });
}

/// The session's `startTurn`, which is protected: a test may call it.
// ignore: invalid_use_of_protected_member
EngineTurn startEngineTurnForTest(FfiInferenceModelSession s) => s.startTurn();

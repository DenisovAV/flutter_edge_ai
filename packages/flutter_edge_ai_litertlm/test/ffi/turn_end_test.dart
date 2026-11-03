import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_test/flutter_test.dart';

/// A conversation whose native side the test plays: each send is a real
/// [NativeTurnStream] on [turns], and the test posts its chunks and its end
/// through [send].
class _Handle implements ConversationHandle {
  final turns = NativeTurns<String>(cancelNative: (_) {}, deleteNative: (_) {});
  late NativeTurnStream<String> send;
  final sent = Completer<void>();

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    send = NativeTurnStream(turns, 'c');
    sent.complete();
    return send.stream;
  }

  @override
  void cancelGeneration() => turns.cancel('c');

  @override
  void close() => turns.release('c');

  @override
  Future<int?> tokenCount(String text) async => text.length;

  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

FfiInferenceModelSession _session(_Handle handle, {int? maxOutputTokens}) =>
    FfiInferenceModelSession(
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
    await expectLater(text, throwsA(isA<LiteRtLmTurnClosedException>()));
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
}

/// The session's `startTurn`, which is protected: a test may call it.
// ignore: invalid_use_of_protected_member
EngineTurn startEngineTurnForTest(FfiInferenceModelSession s) => s.startTurn();

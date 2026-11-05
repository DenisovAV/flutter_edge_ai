// Virtual open sessions take a failed turn (decision W) and a turn stopped
// before it produced anything (Rule A) back out of their history: the next
// turn rebuilds the shared conversation from a history without it.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late LiteRtLmFfiClient client;
  late List<String?> seeds;
  late List<NativeTurnStream<Pointer<LiteRtLmConversation>>> sends;
  late List<Pointer<LiteRtLmConversation>> sentOn;
  late FfiInferenceModel model;
  late InferenceModelSession session;

  setUp(() async {
    client = LiteRtLmFfiClient();
    seeds = [];
    sends = [];
    sentOn = [];
    client
      ..virtualCreateForTest = (history) async {
        seeds.add(history);
        final c = Pointer<LiteRtLmConversation>.fromAddress(
          0x5000 + 16 * seeds.length,
        );
        client.registerLiveForTest(c);
        return c;
      }
      ..virtualSendForTest = (c) {
        final send = client.newTurnForTest(c);
        sends.add(send);
        sentOn.add(c);
        return send;
      };
    model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      supportImage: true,
      supportAudio: true,
      onClose: () {},
    );
    session = await model.openSession();
  });

  /// Starts a turn of [text]; the test ends it through [sends].last.
  Future<String> turn(String text) async {
    await session.addQueryChunk(Message(text: text, isUser: true));
    final reply = session.getResponseAsync().join()..ignore();
    await pumpEventQueue();
    return reply;
  }

  List<String> users(String? seed) => [
    for (final m in jsonDecode(seed ?? '[]') as List<dynamic>)
      if ((m as Map)['role'] == 'user')
        (((m['content'] as List).single as Map)['text'] as String).trim(),
  ];

  Future<void> completeTurn(String text) async {
    final reply = turn(text);
    await pumpEventQueue();
    sends.last
      ..chunk('{"role":"assistant","content":[{"type":"text","text":"ok"}]}')
      ..finished();
    await reply;
  }

  test('a virtual session replays images and audio after another session '
      'takes the shared conversation', () async {
    await session.addQueryChunk(
      Message(
        text: 'remember this',
        isUser: true,
        imageBytes: Uint8List.fromList([1, 2]),
        audioBytes: Uint8List.fromList([3, 4]),
      ),
    );
    final firstReply = session.getResponseAsync().join();
    await pumpEventQueue();
    sends.last
      ..chunk('{"role":"assistant","content":[{"type":"text","text":"ok"}]}')
      ..finished();
    await firstReply;

    final other = await model.openSession();
    await other.addQueryChunk(const Message(text: 'switch', isUser: true));
    final otherReply = other.getResponseAsync().join();
    await pumpEventQueue();
    sends.last.finished();
    await otherReply;

    await session.addQueryChunk(const Message(text: 'recall it', isUser: true));
    final recalled = session.getResponseAsync().join();
    await pumpEventQueue();
    sends.last.finished();
    await recalled;

    final replay = jsonDecode(seeds.last!) as List<dynamic>;
    expect((replay.first as Map)['content'], [
      {'type': 'image', 'blob': 'AQI='},
      {'type': 'audio', 'blob': 'AwQ='},
      {'type': 'text', 'text': 'remember this'},
    ]);
    await other.close();
  });

  test('a failed turn is not replayed: the next turn rebuilds the shared '
      'conversation without it', () async {
    await completeTurn('one');
    final failing = turn('two');
    await pumpEventQueue();
    client.recordTurnEndForTest(sentOn.last, NativeLastTurnEnd.failed);
    sends.last.failed(Exception('Stream error: INTERNAL'));
    await expectLater(failing, throwsException);
    await completeTurn('three');
    expect(seeds, hasLength(2), reason: 'rebuilt after the failure');
    expect(users(seeds.last), ['one']);
  });

  test('a turn stopped before it produced anything is not replayed (Rule A); '
      'one stopped after text is', () async {
    await completeTurn('one');
    final quiet = turn('two');
    await pumpEventQueue();
    await session.stopGeneration();
    sends.last.cancelled();
    expect(await quiet, isEmpty);
    await completeTurn('three');
    expect(users(seeds.last), ['one']);

    final partial = turn('four');
    await pumpEventQueue();
    sends.last.chunk(
      '{"role":"assistant","content":[{"type":"text","text":"half"}]}',
    );
    await pumpEventQueue();
    await session.stopGeneration();
    sends.last.cancelled();
    await partial;
    await completeTurn('five');
    expect(users(seeds.last), ['one', 'three', 'four']);
  });

  test(
    'a turn that fails after streaming text is not replayed either',
    () async {
      await completeTurn('one');
      final failing = turn('two');
      await pumpEventQueue();
      sends.last.chunk(
        '{"role":"assistant","content":[{"type":"text","text":"partial"}]}',
      );
      await pumpEventQueue();
      client.recordTurnEndForTest(sentOn.last, NativeLastTurnEnd.failed);
      sends.last.failed(Exception('Stream error: INTERNAL'));
      await expectLater(failing, throwsException);
      await completeTurn('three');
      expect(users(seeds.last), ['one']);
    },
  );

  test(
    'closing a virtual session queued behind another turn prevents its '
    'send, ends it closed, and leaves no history or native conversation',
    () async {
      final queuedClient = LiteRtLmFfiClient();
      final convs = <Pointer<LiteRtLmConversation>>[];
      final queuedSends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
      queuedClient
        ..virtualCreateForTest = (_) async {
          final conv = Pointer<LiteRtLmConversation>.fromAddress(
            0x7000 + convs.length * 16,
          );
          queuedClient.registerLiveForTest(conv);
          convs.add(conv);
          return conv;
        }
        ..virtualSendForTest = (conv) {
          final send = queuedClient.newTurnForTest(conv);
          queuedSends.add(send);
          return send;
        };
      final queuedModel = FfiInferenceModel(
        ffiClient: queuedClient,
        maxTokens: 1024,
        modelType: ModelType.gemmaIt,
        activeBackend: PreferredBackend.cpu,
        onClose: () {},
      );
      final a = await queuedModel.openSession() as FfiInferenceModelSession;
      final b = await queuedModel.openSession() as FfiInferenceModelSession;

      await a.addQueryChunk(const Message(text: 'A', isUser: true));
      final aTurn = _startTurn(a);
      final aText = aTurn.text.toList();
      await pumpEventQueue();
      expect(queuedSends, hasLength(1));

      await b.addQueryChunk(const Message(text: 'B', isUser: true));
      final bTurn = _startTurn(b);
      final bText = bTurn.text.toList();
      await pumpEventQueue();
      expect(queuedSends, hasLength(1), reason: 'B is queued behind A');

      await b.close();
      queuedSends.single.finished();
      expect(await aText, isEmpty);
      await pumpEventQueue();
      expect(queuedSends, hasLength(1), reason: 'closed B never sends');
      expect(await bText, isEmpty);
      expect(await bTurn.end, TurnEnd.closed);
      expect(virtualConversationHistoryForTest(b.handle), isEmpty);
      expect(
        convs,
        hasLength(1),
        reason: 'closed B never creates a conversation',
      );

      await a.close();
      expect(
        convs.where(queuedClient.isConversationLiveForTest),
        isEmpty,
        reason: 'the only native conversation belonged to A and was released',
      );
    },
  );

  test('closing a virtual session while its conversation is being created '
      'deletes that conversation and never sends', () async {
    final creatingClient = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x8000);
    final createStarted = Completer<void>();
    final finishCreate = Completer<void>();
    var sends = 0;
    creatingClient
      ..virtualCreateForTest = (_) async {
        createStarted.complete();
        await finishCreate.future;
        creatingClient.registerLiveForTest(conv);
        return conv;
      }
      ..virtualSendForTest = (conversation) {
        sends++;
        return creatingClient.newTurnForTest(conversation);
      };
    final creatingModel = FfiInferenceModel(
      ffiClient: creatingClient,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
      onClose: () {},
    );
    final session =
        await creatingModel.openSession() as FfiInferenceModelSession;
    await session.addQueryChunk(const Message(text: 'queued', isUser: true));
    final turn = _startTurn(session);
    final text = turn.text.toList();
    await createStarted.future;

    await session.close();
    finishCreate.complete();

    expect(await text, isEmpty);
    expect(await turn.end, TurnEnd.closed);
    expect(sends, 0);
    expect(virtualConversationHistoryForTest(session.handle), isEmpty);
    expect(creatingClient.isConversationLiveForTest(conv), isFalse);
  });
}

/// The session's `startTurn`, which is protected: a test may call it.
// ignore: invalid_use_of_protected_member
EngineTurn _startTurn(FfiInferenceModelSession session) => session.startTurn();

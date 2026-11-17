import 'dart:async';
// On the MediaTek NPU a native conversation answers its second message empty
// (LiteRT-LM #4256), so every turn there runs in a fresh conversation that
// replays the history (liteRtLmFreshConversationEachTurn). These hold the
// rule and the virtual openSession path to it; RecoveringConversationHandle's
// side (createSession, native openSession) is in recovering_handle_test.dart.
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/bindings.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

import 'ffi_test_support.dart';

void main() {
  test(
    'only a model on the MediaTek NPU gets a fresh conversation each turn',
    () {
      final fresh = <(BackendKind?, NpuStack?)>{
        for (final backend in [...BackendKind.values, null])
          for (final vendor in [...NpuStack.values, null])
            if (liteRtLmFreshConversationEachTurn(
              backend: backend,
              npuVendor: vendor,
            ))
              (backend, vendor),
      };
      expect(fresh, {(BackendKind.npu, NpuStack.mediatek)});
    },
  );

  group('virtual openSession', () {
    late LiteRtLmFfiClient client;
    late List<String?> seeds;
    late List<NativeTurnStream<Pointer<LiteRtLmConversation>>> sends;
    late List<Pointer<LiteRtLmConversation>> sentOn;

    setUp(() {
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
    });

    // The engine decides from its backend and NPU vendor: MediaTek gets a
    // fresh conversation each turn, Qualcomm does not.
    FfiInferenceModel model({required bool fresh}) => ffiModelForClient(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.npu,
      npuVendor: fresh ? NpuStack.mediatek : NpuStack.qualcomm,
      onClose: () {},
    );

    Future<String> completeTurn(
      InferenceModelSession session,
      String text,
    ) async {
      await session.addQueryChunk(Message(text: text, isUser: true));
      final reply = session.getResponseAsync().join();
      await pumpEventQueue();
      sends.last
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok $text"}]}',
        )
        ..finished();
      return reply;
    }

    List<String> texts(String? seed) => [
      for (final m in jsonDecode(seed ?? '[]') as List<dynamic>)
        (((m as Map)['content'] as List).single as Map)['text'] as String,
    ];

    test('each turn of one session runs on a new conversation that replays '
        'the turns before it', () async {
      final session = await model(fresh: true).openSession();
      expect(await completeTurn(session, 'one'), 'ok one');
      expect(await completeTurn(session, 'two'), 'ok two');
      expect(await completeTurn(session, 'three'), 'ok three');

      expect(sentOn.toSet(), hasLength(3), reason: 'one message each');
      expect(seeds, hasLength(3));
      expect(seeds.first, isNull);
      expect(texts(seeds[1]).map((t) => t.trim()), ['one', 'ok one']);
      expect(texts(seeds[2]).map((t) => t.trim()), [
        'one',
        'ok one',
        'two',
        'ok two',
      ]);
    });

    test('a follow-up started while the turn before it still streams '
        'replays that turn', () async {
      final session = await model(fresh: true).openSession();
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      final first = session.getResponseAsync().join();
      await pumpEventQueue();
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      final second = session.getResponseAsync().join();
      await pumpEventQueue();
      expect(sends, hasLength(1), reason: 'the follow-up waits');
      sends.single
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok one"}]}',
        )
        ..finished();
      expect(await first, 'ok one');
      await pumpEventQueue();
      sends.last
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok two"}]}',
        )
        ..finished();
      expect(await second, 'ok two');
      expect(texts(seeds.last).map((t) => t.trim()), ['one', 'ok one']);
    });

    test('without it too, a turn asked for while the one before it streams '
        'waits for it instead of failing', () async {
      final session = await model(fresh: false).openSession();
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      final first = session.getResponseAsync().join();
      await pumpEventQueue();
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      final second = session.getResponseAsync().join();
      await pumpEventQueue();
      expect(sends, hasLength(1), reason: 'the follow-up waits');
      sends.single
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok one"}]}',
        )
        ..finished();
      expect(await first, 'ok one');
      await pumpEventQueue();
      expect(sends, hasLength(2));
      sends.last
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok two"}]}',
        )
        ..finished();
      expect(await second, 'ok two');
    });

    test('a queued turn dropped by a stop reports stopped, even when a later '
        'turn starts before it settles', () async {
      final session = await model(fresh: false).openSession();
      final engineSession = session as FfiInferenceModelSession;
      await session.addQueryChunk(const Message(text: 'a', isUser: true));
      final a = engineSession.startTurn();
      final aText = a.text.join();
      await pumpEventQueue();
      await session.addQueryChunk(const Message(text: 'b', isUser: true));
      final b = engineSession.startTurn();
      final bText = b.text.join();
      await pumpEventQueue();
      await session.stopGeneration();
      await session.addQueryChunk(const Message(text: 'c', isUser: true));
      final c = engineSession.startTurn();
      final cText = c.text.join();
      await pumpEventQueue();
      sends.first.cancelled();
      await aText;
      expect(await bText, '');
      expect(await b.end, TurnEnd.stopped);
      expect(await a.end, TurnEnd.stopped);
      await pumpEventQueue();
      sends.last
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok c"}]}',
        )
        ..finished();
      expect(await cText, 'ok c');
      expect(await c.end, isNot(TurnEnd.stopped));
    });

    test('a stopped turn whose stream is paused does not block the next '
        'turn', () async {
      final session = await model(fresh: false).openSession();
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      final first = session.getResponseAsync().listen((_) {});
      await pumpEventQueue();
      sends.single.chunk(
        '{"role":"assistant","content":[{"type":"text","text":"o"}]}',
      );
      first.pause();
      await session.stopGeneration();
      // Native ends the stopped turn; its consumer stays paused.
      sends.single.cancelled();
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      final second = session.getResponseAsync().join();
      // The conversation gives the stopped turn its bounded wind-down
      // (5 s), then sends the next one.
      for (var i = 0; sends.length < 2 && i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(sends, hasLength(2), reason: 'the next turn is sent');
      sends.last
        ..chunk(
          '{"role":"assistant","content":[{"type":"text","text":"ok two"}]}',
        )
        ..finished();
      expect(await second.timeout(const Duration(seconds: 10)), 'ok two');
      await first.cancel();
    });

    test(
      'closing the session releases a turn waiting behind a paused one',
      () async {
        final session = await model(fresh: false).openSession();
        await session.addQueryChunk(const Message(text: 'one', isUser: true));
        final first = session.getResponseAsync().listen((_) {});
        await pumpEventQueue();
        sends.single.chunk(
          '{"role":"assistant","content":[{"type":"text","text":"o"}]}',
        );
        await pumpEventQueue();
        first.pause();
        await pumpEventQueue();
        sends.single.chunk(
          '{"role":"assistant","content":[{"type":"text","text":"n"}]}',
        );
        await session.addQueryChunk(const Message(text: 'two', isUser: true));
        final second = session.getResponseAsync().toList().then<Object?>(
          (_) => null,
          onError: (Object e) => e,
        );
        await pumpEventQueue();
        await session.close();
        sends.single.cancelled();
        expect(
          await second.timeout(const Duration(seconds: 10)),
          isA<StateError>(),
        );
        expect(sends, hasLength(1), reason: 'the waiting turn is not sent');
        await first.cancel();
      },
    );

    test('a stop drops a turn still waiting for the one before it', () async {
      final session = await model(fresh: false).openSession();
      await session.addQueryChunk(const Message(text: 'one', isUser: true));
      final first = session.getResponseAsync().join();
      await pumpEventQueue();
      await session.addQueryChunk(const Message(text: 'two', isUser: true));
      final second = session.getResponseAsync().join();
      await pumpEventQueue();
      await session.stopGeneration();
      sends.single.cancelled();
      await first;
      expect(await second, '');
      await pumpEventQueue();
      expect(sends, hasLength(1), reason: 'the waiting turn is not sent');
    });

    test(
      'without it, a session\'s follow-ups reuse its conversation',
      () async {
        final session = await model(fresh: false).openSession();
        await completeTurn(session, 'one');
        await completeTurn(session, 'two');
        expect(sentOn.toSet(), hasLength(1));
        expect(seeds, [null]);
      },
    );
  });
}

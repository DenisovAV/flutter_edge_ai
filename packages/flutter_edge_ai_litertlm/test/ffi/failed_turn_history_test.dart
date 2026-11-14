import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'dart:ffi';
import 'dart:async';
// Virtual sessions' turn ends, read when native ends each turn, and the
// rebuild of the shared conversation after a failed turn (decision W: a
// failed turn is taken back on both sides).

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('virtual turn ends', () {
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x1000);

    test('a session keeps its own turn end when another session deletes the '
        'shared conversation as soon as the lock goes, and a context_full '
        'turn marks the conversation for a rebuild', () async {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      final turns = NativeTurns<Pointer<LiteRtLmConversation>>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, conv);
      final a = Object();
      client.recordTurnEndForTest(conv, NativeLastTurnEnd.contextFull);
      // The watcher first, then the release, which hands the lock to a
      // queued session that deletes the conversation and its record.
      client.watchVirtualTurnEnd(a, conv, send.turn.ended);
      unawaited(
        send.turn.ended.whenComplete(
          () => client.deleteConversationForTest(conv),
        ),
      );
      final text = send.stream.toList();
      send.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
      await expectLater(text, throwsException);
      expect(client.isConversationLiveForTest(conv), isFalse);
      expect(client.virtualLastTurnEnd(a), NativeLastTurnEnd.contextFull);
      expect(client.virtualConversationNeedsRebuildForTest, isTrue);
    });

    test('another end keeps the shared conversation', () async {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      final turns = NativeTurns<Pointer<LiteRtLmConversation>>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, conv);
      final a = Object();
      client
        ..recordTurnEndForTest(conv, NativeLastTurnEnd.completed)
        ..watchVirtualTurnEnd(a, conv, send.turn.ended);
      final text = send.stream.toList();
      send.finished();
      await text;
      await pumpEventQueue();
      expect(client.virtualLastTurnEnd(a), NativeLastTurnEnd.completed);
      expect(client.virtualConversationNeedsRebuildForTest, isFalse);
    });

    test('a turn that fails before its send forgets the session\'s previous '
        'end', () async {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      final turns = NativeTurns<Pointer<LiteRtLmConversation>>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, conv);
      final a = Object();
      client
        ..recordTurnEndForTest(conv, NativeLastTurnEnd.contextFull)
        ..watchVirtualTurnEnd(a, conv, send.turn.ended);
      final first = send.stream.toList();
      send.failed(Exception('x'));
      await expectLater(first, throwsException);
      await pumpEventQueue();
      expect(client.virtualLastTurnEnd(a), NativeLastTurnEnd.contextFull);
      // The next turn of the session fails at its create (no engine here).
      await expectLater(
        client
            .startVirtualTurn(
              conversationToken: a,
              messageJson: '{}',
              history: const [],
              sampling: SamplingParams.resolve(
                const SamplingParams(),
                modelType: ModelType.gemmaIt,
              ),
              samplingExplicit: false,
              thinking: false,
              filterChannelContent: true,
            )
            .toList(),
        throwsStateError,
      );
      expect(client.virtualLastTurnEnd(a), isNull);
    });

    test('any failed turn (here one that ran out of resources) marks the '
        'shared conversation for a rebuild', () async {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      final turns = NativeTurns<Pointer<LiteRtLmConversation>>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, conv);
      final a = Object();
      client
        ..recordTurnEndForTest(conv, NativeLastTurnEnd.failed, code: 8)
        ..watchVirtualTurnEnd(a, conv, send.turn.ended);
      final text = send.stream.toList();
      send.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
      await expectLater(text, throwsException);
      await pumpEventQueue();
      expect(client.virtualLastTurnCode(a), 8);
      expect(client.virtualLastTurnEnd(a), NativeLastTurnEnd.failed);
      expect(client.virtualConversationNeedsRebuildForTest, isTrue);
    });

    test('through startVirtualTurn: a context_full turn keeps its end for its '
        'session although the next session, queued on the lock, deletes the '
        'shared conversation as soon as the lock goes', () async {
      final client = LiteRtLmFfiClient();
      final convs = <Pointer<LiteRtLmConversation>>[];
      final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
      client
        ..virtualCreateForTest = (_) async {
          final c = Pointer<LiteRtLmConversation>.fromAddress(
            0x3000 + 16 * convs.length,
          );
          client.registerLiveForTest(c);
          convs.add(c);
          return c;
        }
        ..virtualSendForTest = (c) {
          final send = client.newTurnForTest(c);
          sends.add(send);
          return send;
        };
      final sampling = SamplingParams.resolve(
        const SamplingParams(),
        modelType: ModelType.gemmaIt,
      );
      Stream<String> turn(Object token) => client.startVirtualTurn(
        conversationToken: token,
        messageJson: '{}',
        history: const [],
        sampling: sampling,
        samplingExplicit: false,
        thinking: false,
        filterChannelContent: true,
      );
      final a = Object();
      final b = Object();
      final aText = turn(a).toList();
      await pumpEventQueue();
      // B's turn waits on the lock A holds.
      final bText = turn(b).toList();
      await pumpEventQueue();
      expect(sends, hasLength(1));
      client.recordTurnEndForTest(convs.single, NativeLastTurnEnd.contextFull);
      sends.single.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
      await expectLater(aText, throwsException);
      await pumpEventQueue();
      // B took the lock, deleted A's conversation and made its own.
      expect(convs, hasLength(2));
      expect(client.isConversationLiveForTest(convs.first), isFalse);
      expect(client.virtualLastTurnEnd(a), NativeLastTurnEnd.contextFull);
      sends.last.finished();
      await bText;
    });
  });
}

import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'dart:ffi';
import 'dart:async';
// A failed turn stays in a session's history (a rebuild replays it) unless
// native ended it context_full (section 23): that input was refused before
// the model saw it. Both conversation handles follow one rule.
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only a context_full turn and a refused send did not reach the model',
    () {
      for (final end in NativeLastTurnEnd.values) {
        expect(
          failedTurnReachedModel(end),
          end != NativeLastTurnEnd.contextFull &&
              end != NativeLastTurnEnd.refused,
          reason: '$end',
        );
      }
      expect(failedTurnReachedModel(null), isTrue);
      expect(
        failedTurnReachedModel(NativeLastTurnEnd.failed, absResourceExhausted),
        isFalse,
        reason: 'a resource ran out: the prefill failed',
      );
      expect(failedTurnReachedModel(NativeLastTurnEnd.failed, 13), isTrue);
    },
  );

  test('the recovering handle and the virtual sessions both follow it', () {
    final source = File(
      'lib/src/ffi/ffi_inference_model.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('failedTurnReachedModel(_live.lastTurnEnd, _live.lastTurnCode)'),
      reason: 'RecoveringConversationHandle',
    );
    expect(
      source,
      contains(
        'if (!failedTurnReachedModel(lastTurnEnd, lastTurnCode)) recorded = true;',
      ),
      reason: '_VirtualConversationHandle',
    );
  });

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
            )
            .toList(),
        throwsStateError,
      );
      expect(client.virtualLastTurnEnd(a), isNull);
    });

    test('a turn that ran out of resources also marks the shared conversation '
        'for a rebuild', () async {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      final turns = NativeTurns<Pointer<LiteRtLmConversation>>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, conv);
      final a = Object();
      client
        ..recordTurnEndForTest(
          conv,
          NativeLastTurnEnd.failed,
          code: absResourceExhausted,
        )
        ..watchVirtualTurnEnd(a, conv, send.turn.ended);
      final text = send.stream.toList();
      send.failed(Exception('Stream error: RESOURCE_EXHAUSTED'));
      await expectLater(text, throwsException);
      await pumpEventQueue();
      expect(client.virtualLastTurnCode(a), absResourceExhausted);
      expect(client.virtualConversationNeedsRebuildForTest, isTrue);
    });

    test('through startVirtualTurn: a context_full turn keeps its end for its '
        'session although the next session, queued on the lock, deletes the '
        'shared conversation as soon as the lock goes', () async {
      final client = LiteRtLmFfiClient();
      final convs = <Pointer<LiteRtLmConversation>>[];
      final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
      client
        ..virtualCreateForTest = () async {
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

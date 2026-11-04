// A send to another conversation than the one LiteRT-LM's executor ran last
// runs its native call on a spawned isolate (doc/research/
// litertlm-l3-switch-send.md). Which sends switch (ExecutorConversation),
// and what may happen while such a call is still inside native
// (SendCallGate): nothing that ends the turn — the engine lock, a deferred
// delete, a shutdown — and no free of the strings the call reads.
import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ExecutorConversation', () {
    test('a send switches unless the same conversation ran last', () {
      final executor = ExecutorConversation<String>();
      expect(executor.send('a'), isTrue, reason: 'nothing known yet');
      expect(executor.send('a'), isFalse);
      expect(executor.send('b'), isTrue);
      expect(executor.send('b'), isFalse);
    });

    test('anything else on the executor makes the next send a switch; a '
        'rewind makes its conversation the last', () {
      final executor = ExecutorConversation<String>()..send('a');
      executor.unknown();
      expect(executor.send('a'), isTrue);
      executor.ranOn('b');
      expect(executor.send('b'), isFalse);
    });

    test('forgetting the last conversation forgets it; another is kept', () {
      final executor = ExecutorConversation<String>()..send('a');
      executor.forget('b');
      expect(executor.last, 'a');
      executor.forget('a');
      expect(executor.last, isNull);
    });
  });

  group('SendCallGate', () {
    test('an end native calls back with while the call is inside native is '
        'held: the turn, the deferred delete of a close and the strings all '
        'wait for the call to return', () async {
      final deleted = <String>[];
      final turns = NativeTurns<String>(
        cancelNative: (_) {},
        deleteNative: deleted.add,
      );
      final send = NativeTurnStream(turns, 'c');
      var freed = 0;
      final gate = SendCallGate(freeStrings: () => freed++)..callStarted();
      final text = send.stream.toList();

      // The final callback arrives before the call has returned.
      send.chunk('Hi');
      gate
        ..end(send.finished)
        ..release();
      // A close meanwhile.
      turns.release('c');
      await pumpEventQueue();
      expect(send.turn.hasEnded, isFalse);
      expect(deleted, isEmpty, reason: 'the call still uses the conversation');
      expect(freed, 0, reason: 'the call still reads the strings');

      gate.callReturned();
      expect(freed, 1);
      expect(send.turn.hasEnded, isFalse, reason: 'the result comes first');
      gate.flushEnd();
      expect(await text, ['Hi']);
      await pumpEventQueue();
      expect(send.turn.hasEnded, isTrue);
      expect(deleted, ['c']);
      expect(freed, 1, reason: 'once');
    });

    test('without a call in flight an end applies at once and the strings '
        'go when the stream is done with them', () async {
      final turns = NativeTurns<String>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, 'c');
      var freed = 0;
      final gate = SendCallGate(freeStrings: () => freed++);
      final text = send.stream.toList();
      gate
        ..end(send.finished)
        ..release();
      await text;
      expect(send.turn.hasEnded, isTrue);
      expect(freed, 1);
    });

    test('the first end wins', () async {
      final turns = NativeTurns<String>(
        cancelNative: (_) {},
        deleteNative: (_) {},
      );
      final send = NativeTurnStream(turns, 'c');
      final gate = SendCallGate(freeStrings: () {})..callStarted();
      final text = send.stream.toList();
      gate
        ..end(() => send.failed(StateError('first')))
        ..end(send.finished)
        ..callReturned()
        ..flushEnd();
      await expectLater(text, throwsStateError);
    });
  });

  group('the client', () {
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x4000);

    test('deleting the conversation the executor ran last forgets it', () {
      final client = LiteRtLmFfiClient()..registerLiveForTest(conv);
      client.executorForTest.ranOn(conv);
      client.deleteConversationForTest(conv);
      expect(client.executorForTest.last, isNull);
    });

    test('a rewind runs on its conversation, which is then the executor\'s '
        'last: the next send to it does not switch', () async {
      final saved = rewindOffMainIsolate;
      addTearDown(() => rewindOffMainIsolate = saved);
      rewindOffMainIsolate =
          ({
            required int conversationAddr,
            required String? exchangeJson,
            String? extraContext,
          }) async => (
            code: 0,
            lastTurnEnd: NativeLastTurnEnd.cancelled.index,
            message: null,
          );
      final client = LiteRtLmFfiClient()
        ..registerLiveForTest(conv)
        ..hasTurnRewindForTest = true;
      client.executorForTest.unknown();
      expect(await client.rewindForTest(conv), StoppedTurnRewind.rewound);
      expect(client.executorForTest.last, conv);
    });

    test('through the send path: the final chunk arrives while the spawned '
        'call is still inside native, and a close comes before it returns; '
        'the turn ends, the conversation is deleted and the strings are '
        'freed only after the call has returned', () async {
      final deletes = <int>[];
      final optionalArgs = calloc<Int64>();
      addTearDown(() => calloc.free(optionalArgs));
      final callables = <NativeCallable<Function>>[];
      Pointer<NativeFunction<T>> keep<T extends Function>(NativeCallable<T> c) {
        callables.add(c);
        return c.nativeFunction;
      }

      addTearDown(() {
        for (final c in callables) {
          c.close();
        }
      });
      final symbols = <String, Pointer<NativeType>>{
        'litert_lm_conversation_optional_args_create': keep(
          NativeCallable<
            UnsignedInt Function(
              Pointer<Pointer<LiteRtLmConversationOptionalArgs>>,
            )
          >.isolateLocal((
            Pointer<Pointer<LiteRtLmConversationOptionalArgs>> out,
          ) {
            out.value = optionalArgs.cast();
            return 0;
          }, exceptionalReturn: 1),
        ),
        'litert_lm_conversation_optional_args_delete': keep(
          NativeCallable<
            Void Function(Pointer<LiteRtLmConversationOptionalArgs>)
          >.isolateLocal((Pointer<LiteRtLmConversationOptionalArgs> _) {}),
        ),
        'litert_lm_conversation_delete': keep(
          NativeCallable<
            Void Function(Pointer<LiteRtLmConversation>)
          >.isolateLocal(
            (Pointer<LiteRtLmConversation> c) => deletes.add(c.address),
          ),
        ),
        'litert_lm_conversation_cancel_process': keep(
          NativeCallable<
            UnsignedInt Function(Pointer<LiteRtLmConversation>)
          >.isolateLocal(
            (Pointer<LiteRtLmConversation> _) => 0,
            exceptionalReturn: 1,
          ),
        ),
      };
      final client = LiteRtLmFfiClient()
        ..bindingsForTest = LiteRtLmBindings.fromLookup(
          <T extends NativeType>(String name) =>
              (symbols[name] ?? (throw ArgumentError('no fake for $name')))
                  .cast<T>(),
        );
      Pointer<
        NativeFunction<
          Void Function(Pointer<Void>, Pointer<Char>, Uint8, Pointer<Char>)
        >
      >?
      callback;
      client.streamForTest(
        createProxy: (dartCallback, _, _, _, _, outProxyFn) {
          callback = dartCallback;
          outProxyFn.value = dartCallback;
          return Pointer.fromAddress(0x20);
        },
        freeString: calloc.free,
        destroyProxy: (_) {},
      );
      client.registerLiveForTest(conv);

      final saved = sendOffMainIsolate;
      addTearDown(() => sendOffMainIsolate = saved);
      final callReturns = Completer<void>();
      var callStarted = false;
      sendOffMainIsolate = (_) async {
        callStarted = true;
        // Native calls back with the whole reply before the call returns.
        callback!
            .asFunction<
              void Function(Pointer<Void>, Pointer<Char>, int, Pointer<Char>)
            >()(nullptr, 'Hi'.toNativeUtf8().cast(), 1, nullptr);
        await callReturns.future;
        return (code: 0, message: null, micros: 0);
      };

      final text = client.sendForTest(conv, '{}').toList();
      await pumpEventQueue();
      expect(callStarted, isTrue, reason: 'a first send switches');
      client.releaseConversationForTest(conv);
      await pumpEventQueue();
      expect(deletes, isEmpty, reason: 'the call still runs on it');
      var done = false;
      unawaited(text.then((_) => done = true));
      await pumpEventQueue();
      expect(done, isFalse, reason: 'the turn has not ended');

      callReturns.complete();
      expect(await text, ['Hi']);
      await pumpEventQueue();
      expect(deletes, [conv.address]);
      // The call's result came before the turn's end, so it could not mark a
      // conversation already deleted as sent.
      expect(client.hasSentForTest(conv), isFalse);
    });
  });
}

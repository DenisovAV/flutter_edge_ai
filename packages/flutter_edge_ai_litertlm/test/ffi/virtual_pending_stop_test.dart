import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a plain virtual session stopped during slow prefill cancels native '
      'and takes an empty turn back', () async {
    final client = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x6f00);
    final optionalArgs = calloc<Int64>();
    final callables = <NativeCallable<Function>>[];
    Pointer<NativeFunction<T>> keep<T extends Function>(NativeCallable<T> c) {
      callables.add(c);
      return c.nativeFunction;
    }

    var nativeCancels = 0;
    final cancelObserved = Completer<void>();
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
      'litert_lm_conversation_cancel_process': keep(
        NativeCallable<
          UnsignedInt Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal((Pointer<LiteRtLmConversation> _) {
          nativeCancels++;
          if (!cancelObserved.isCompleted) cancelObserved.complete();
          return 0;
        }, exceptionalReturn: 1),
      ),
      'litert_lm_conversation_delete': keep(
        NativeCallable<
          Void Function(Pointer<LiteRtLmConversation>)
        >.isolateLocal((Pointer<LiteRtLmConversation> _) {}),
      ),
      'litert_lm_engine_delete': keep(
        NativeCallable<Void Function(Pointer<LiteRtLmEngine>)>.isolateLocal(
          (Pointer<LiteRtLmEngine> _) {},
        ),
      ),
    };
    addTearDown(() {
      for (final callable in callables) {
        callable.close();
      }
      calloc.free(optionalArgs);
    });

    Pointer<
      NativeFunction<
        Void Function(Pointer<Void>, Pointer<Char>, Uint8, Pointer<Char>)
      >
    >?
    callback;
    client
      ..bindingsForTest = LiteRtLmBindings.fromLookup(
        <T extends NativeType>(String name) =>
            (symbols[name] ?? (throw ArgumentError('no fake for $name')))
                .cast<T>(),
      )
      ..virtualCreateForTest = (_) async {
        client.registerLiveForTest(conv);
        return conv;
      }
      ..virtualRewindForTest = ((_, _, _) async =>
          StoppedTurnRewind.unsupported)
      ..metricsForTest = ((_) => SessionMetrics())
      ..spawnedSendPrefillDelayForTest = const Duration(milliseconds: 600);
    client.streamForTest(
      createProxy: (dartCallback, _, _, _, _, outProxyFn) {
        callback = dartCallback;
        outProxyFn.value = dartCallback;
        return Pointer.fromAddress(0x20);
      },
      freeString: calloc.free,
      destroyProxy: (_) {},
    );
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      openSessionBacking: OpenSessionBacking.virtual,
      onClose: () {},
    );
    final session = await model.openSession() as FfiInferenceModelSession;

    await session.addQueryChunk(const Message(text: 'slow', isUser: true));
    final stopwatch = Stopwatch()..start();
    final response = session.getResponse();
    // The iPhone regression stopped 300 ms into a 570--690 ms prefill, before
    // native emitted its first token.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await session.stopGeneration();

    expect(
      stopwatch.elapsedMilliseconds,
      lessThan(500),
      reason: 'the fake synchronous prefill must not block stopGeneration',
    );
    await cancelObserved.future.timeout(const Duration(seconds: 2));
    expect(nativeCancels, 1, reason: 'stop must reach the running native turn');
    callback!
        .asFunction<
          void Function(Pointer<Void>, Pointer<Char>, int, Pointer<Char>)
        >()(nullptr, nullptr, 0, 'CANCELLED'.toNativeUtf8().cast());
    expect(await response, isEmpty);
    expect(
      virtualConversationHistoryForTest(session.handle),
      isEmpty,
      reason: 'Rule A takes back a stopped turn that produced no text',
    );
    await pumpEventQueue();

    await session.close();
    await model.close();
  });

  test('a plain virtual session honours a stop during conversation creation, '
      'then sends its next turn and reports that turn metrics', () async {
    final client = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7000);
    final createStarted = Completer<void>();
    final finishCreate = Completer<void>();
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    var stoppedTurnSettled = false;
    client
      ..virtualCreateForTest = (_) async {
        createStarted.complete();
        await finishCreate.future;
        client.registerLiveForTest(conv);
        return conv;
      }
      ..virtualSendForTest = (conversation) {
        final send = client.newTurnForTest(conversation);
        sends.add(send);
        if (!stoppedTurnSettled) {
          client.recordTurnEndForTest(
            conversation,
            NativeLastTurnEnd.contextFull,
          );
          scheduleMicrotask(
            () => send.failed(Exception('injected context limit')),
          );
        }
        return send;
      }
      ..metricsForTest = (_) => SessionMetrics(tokensPerSecond: 42);
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      openSessionBacking: OpenSessionBacking.virtual,
      onClose: () {},
    );
    final session = await model.openSession();

    await session.addQueryChunk(const Message(text: 'first', isUser: true));
    final stopped = session.getResponse();
    await createStarted.future;
    await session.stopGeneration();
    finishCreate.complete();

    expect(await stopped, isEmpty);
    stoppedTurnSettled = true;
    expect(sends, isEmpty, reason: 'the pending stop must prevent native send');

    await session.addQueryChunk(const Message(text: 'second', isUser: true));
    final answered = session.getResponse();
    await pumpEventQueue();
    sends.single
      ..chunk(
        '{"role":"assistant","content":['
        '{"type":"text","text":"OK"}]}',
      )
      ..finished();
    expect(await answered, 'OK');
    await pumpEventQueue();
    expect(session.getSessionMetrics().tokensPerSecond, 42);

    await session.close();
    await model.close();
  });

  test('a plain virtual follow-up stopped behind another native operation '
      'never sends and clears the previous turn metrics', () async {
    final client = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7100);
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    client
      ..virtualCreateForTest = (_) async {
        client.registerLiveForTest(conv);
        return conv;
      }
      ..virtualSendForTest = (conversation) {
        final send = client.newTurnForTest(conversation);
        final isFollowUp = sends.isNotEmpty;
        sends.add(send);
        if (isFollowUp) scheduleMicrotask(send.finished);
        return send;
      }
      ..metricsForTest = (_) => SessionMetrics(tokensPerSecond: 42);
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.gpu,
      openSessionBacking: OpenSessionBacking.virtual,
      onClose: () {},
    );
    final session = await model.openSession();

    await session.addQueryChunk(const Message(text: 'first', isUser: true));
    final first = session.getResponse();
    await pumpEventQueue();
    sends.single
      ..chunk(
        '{"role":"assistant","content":['
        '{"type":"text","text":"OK"}]}',
      )
      ..finished();
    expect(await first, 'OK');
    await pumpEventQueue();
    expect(session.getSessionMetrics().tokensPerSecond, 42);

    final operationStarted = Completer<void>();
    final releaseOperation = Completer<void>();
    final operation = client.holdNativeMutexForTest(() async {
      operationStarted.complete();
      await releaseOperation.future;
    });
    await operationStarted.future;

    await session.addQueryChunk(const Message(text: 'second', isUser: true));
    final stopped = session.getResponse();
    await pumpEventQueue();
    await session.stopGeneration();
    expect(
      session.getSessionMetrics().tokensPerSecond,
      isNull,
      reason: 'a turn that never reaches native has no benchmark snapshot',
    );
    releaseOperation.complete();
    await operation;

    expect(await stopped, isEmpty);
    expect(sends, hasLength(1), reason: 'the stopped follow-up must not send');
    expect(session.getSessionMetrics().tokensPerSecond, isNull);

    await session.close();
    await model.close();
  });
}

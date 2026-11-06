import 'dart:async';
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

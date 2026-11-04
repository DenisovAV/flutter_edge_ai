// Virtual open sessions take a failed turn (decision W) and a turn stopped
// before it produced anything (Rule A) back out of their history: the next
// turn rebuilds the shared conversation from a history without it.
import 'dart:convert';
import 'dart:ffi';

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
    final model = FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.cpu,
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
}

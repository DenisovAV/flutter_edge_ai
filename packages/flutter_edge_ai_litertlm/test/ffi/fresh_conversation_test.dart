// On the MediaTek NPU a native conversation answers its second message empty
// (LiteRT-LM #4256), so every turn there runs in a fresh conversation that
// replays the history (liteRtLmFreshConversationEachTurn). These hold the
// rule and the virtual openSession path to it; RecoveringConversationHandle's
// side (createSession, native openSession) is in recovering_handle_test.dart.
import 'dart:convert';
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only a model on the MediaTek NPU gets a fresh conversation each turn',
    () {
      final fresh = <(PreferredBackend?, NpuStack?)>{
        for (final backend in [...PreferredBackend.values, null])
          for (final vendor in [...NpuStack.values, null])
            if (liteRtLmFreshConversationEachTurn(
              backend: backend,
              npuVendor: vendor,
            ))
              (backend, vendor),
      };
      expect(fresh, {(PreferredBackend.npu, NpuStack.mediatek)});
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

    FfiInferenceModel model({required bool fresh}) => FfiInferenceModel(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemmaIt,
      activeBackend: PreferredBackend.npu,
      freshConversationEachTurn: fresh,
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

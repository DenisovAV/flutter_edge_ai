// Under core the model's tool calls are core's to run: a reply with a call
// reaches the session as native wrote it, and nothing is sent back for it
// (litertlm_dart's automatic tool calling stays off for the adapter).
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/bindings.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

import 'ffi_test_support.dart';

void main() {
  test('a tool call reaches the session unchanged and nothing is sent for '
      'it', () async {
    final client = LiteRtLmFfiClient();
    final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7400);
    final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
    client
      ..virtualCreateForTest = (_) async {
        client.registerLiveForTest(conv);
        return conv;
      }
      ..virtualSendForTest = (conversation) {
        final send = client.newTurnForTest(conversation);
        sends.add(send);
        return send;
      };
    final model = ffiModelForClient(
      ffiClient: client,
      maxTokens: 1024,
      modelType: ModelType.gemma4,
      activeBackend: PreferredBackend.cpu,
      openSessionBacking: OpenSessionBacking.virtual,
      onClose: () {},
    );
    final session =
        await model.openSession(
              tools: const [
                Tool(
                  name: 'get_weather',
                  description: 'The weather',
                  parameters: {'type': 'object'},
                ),
              ],
            )
            as FfiInferenceModelSession;
    // Core runs the calls: the conversation the adapter built does not.
    expect(
      conversationConfig(session.conversation).automaticToolCalling,
      isFalse,
    );
    expect(
      conversationConfig(session.conversation).tools.single.name,
      'get_weather',
    );
    await session.addQueryChunk(
      const Message(text: 'Weather in Paris?', isUser: true),
    );
    final reply = session.getResponse();
    await pumpEventQueue();
    const call =
        '{"role":"assistant","tool_calls":[{"type":"function",'
        '"function":{"name":"get_weather","arguments":{"city":"Paris"}}}]}';
    sends.single
      ..chunk(call)
      ..finished();
    await reply;
    await pumpEventQueue();
    expect(session.lastRawResponse, call);
    expect(sends, hasLength(1), reason: 'no tool response was sent');
    await session.close();
    await model.close();
  });
}

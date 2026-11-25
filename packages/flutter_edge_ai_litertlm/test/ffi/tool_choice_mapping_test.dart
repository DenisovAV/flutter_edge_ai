// Core's tool choice on a model whose tool calls LiteRT-LM runs: none opens
// the conversation without the tools; required goes with each user turn
// (litertlm_dart's per-message ToolChoice), and only where the conversation
// has those tools and no response format.
import 'dart:ffi';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/bindings.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import 'ffi_test_support.dart';

const _tools = [
  Tool(
    name: 'get_weather',
    description: 'The weather',
    parameters: {'type': 'object'},
  ),
];

Future<FfiInferenceModelSession> _open(
  ModelType modelType,
  ToolChoice choice,
) async {
  final client = LiteRtLmFfiClient();
  final conv = Pointer<LiteRtLmConversation>.fromAddress(0x7400);
  client.virtualCreateForTest = (_) async {
    client.registerLiveForTest(conv);
    return conv;
  };
  final model = ffiModelForClient(
    ffiClient: client,
    maxTokens: 1024,
    modelType: modelType,
    activeBackend: PreferredBackend.cpu,
    openSessionBacking: OpenSessionBacking.virtual,
    onClose: () {},
  );
  addTearDown(model.close);
  return await model.openEngineSession(
        SessionRequest(tools: _tools, toolChoice: choice),
      )
      as FfiInferenceModelSession;
}

void main() {
  test('auto: the tools, no choice on the turns', () async {
    final session = await _open(ModelType.gemma4, ToolChoice.auto);
    expect(conversationConfig(session.conversation).tools, hasLength(1));
    expect(session.userTurnToolChoice, isNull);
  });

  test(
    'required: the tools, and ToolChoice.required on each user turn',
    () async {
      final session = await _open(ModelType.gemma4, ToolChoice.required);
      expect(conversationConfig(session.conversation).tools, hasLength(1));
      expect(session.userTurnToolChoice, same(lm.ToolChoice.required));
    },
  );

  test('none: the conversation gets no tools at all', () async {
    final session = await _open(ModelType.gemma4, ToolChoice.none);
    expect(conversationConfig(session.conversation).tools, isEmpty);
    expect(session.userTurnToolChoice, isNull);
  });

  test(
    'a model whose tools core prompts for itself: no native choice',
    () async {
      final session = await _open(ModelType.gemmaIt, ToolChoice.required);
      expect(conversationConfig(session.conversation).tools, isEmpty);
      expect(session.userTurnToolChoice, isNull);
    },
  );
}

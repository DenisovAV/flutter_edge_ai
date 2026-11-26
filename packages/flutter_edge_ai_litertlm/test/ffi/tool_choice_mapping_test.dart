// Core's tool choice on a model whose tools LiteRT-LM renders (Gemma 4,
// FunctionGemma): none opens the conversation without the tools; required
// goes with each user turn as litertlm_dart's per-message ToolChoice, never
// with the turn answering tool results.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/adapter/ffi_inference_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;
import 'package:litertlm_dart/litertlm_dart.dart' as lm;

import 'ffi_test_support.dart';

const _tools = [
  Tool(
    name: 'get_weather',
    description: 'The weather',
    parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string'},
      },
    },
  ),
];

/// A client whose conversations are fakes.
class _Client extends LiteRtLmFfiClient {
  @override
  BundleSampler get bundleSampler => const BundleSampler();

  @override
  Future<LiteRtLmConversationHandle> createConversationHandle({
    String? systemMessage,
    String? toolsJson,
    String? messagesJson,
    required Sampler sampling,
    required bool samplingExplicit,
    int? maxOutputTokens,
    required MediaOrder multimodalOrder,
    Constraint? constraint,
    required bool filterChannelContent,
    ConversationExtras extras = ConversationExtras.none,
  }) async => LiteRtLmConversationHandle.forTest(this);
}

FfiInferenceModel _model(ModelType modelType, {String? toolChoiceRefusal}) {
  final model = ffiModelForClient(
    ffiClient: _Client(),
    maxTokens: 1024,
    modelType: modelType,
    activeBackend: PreferredBackend.cpu,
    openSessionBacking: OpenSessionBacking.native,
    toolChoiceRefusal: toolChoiceRefusal,
    onClose: () {},
  );
  addTearDown(model.close);
  return model;
}

Future<FfiInferenceModelSession> _open(
  ModelType modelType,
  ToolChoice choice,
) async {
  final session =
      await _model(
            modelType,
          ).openEngineSession(SessionRequest(tools: _tools, toolChoice: choice))
          as FfiInferenceModelSession;
  addTearDown(session.close);
  return session;
}

/// Records the role and the tool choice of each send; no native code.
class _ChoiceRecordingHandle implements ConversationHandle {
  _ChoiceRecordingHandle({this.failWith});

  /// Every send fails with this, when set, before anything streams.
  final Object? failWith;

  final sends = <({String role, String? choice})>[];

  @override
  Future<int?> tokenCount(String text) async => null;

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => throw UnimplementedError();

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => throw UnimplementedError();

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) async* {
    sends.add((
      role: sentMessage(messageJson).role,
      choice: options.toolChoiceJson,
    ));
    if (failWith case final error?) throw error;
    yield '{"role":"assistant","content":[{"type":"text","text":"ok"}]}';
  }

  @override
  void cancelGeneration() {}

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  BenchmarkInfo getSessionMetrics() => const BenchmarkInfo();

  @override
  NativeBenchmark? getNativeBenchmark() => null;

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;

  @override
  Future<void> close() async {}
}

void main() {
  test('auto: the tools, no choice on the turns', () async {
    final session = await _open(ModelType.gemma4, ToolChoice.auto);
    expect(conversationConfig(session.conversation).tools, hasLength(1));
    expect(session.declaresTools, isTrue);
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

  test('required on FunctionGemma: the same native choice', () async {
    final session = await _open(ModelType.functionGemma, ToolChoice.required);
    expect(session.userTurnToolChoice, same(lm.ToolChoice.required));
  });

  test('none: the conversation gets no tools at all, and a tool response '
      'goes as user text', () async {
    final opened = await _open(ModelType.gemma4, ToolChoice.none);
    final tools = conversationConfig(opened.conversation).tools;
    expect(tools, isEmpty);
    expect(opened.declaresTools, isFalse);
    expect(opened.userTurnToolChoice, isNull);
    // The same session over a handle that records what it sends.
    final handle = _ChoiceRecordingHandle();
    final session = ffiSessionForHandle(
      handle: handle,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      supportImage: false,
      supportAudio: false,
      tools: tools,
      userTurnToolChoice: opened.userTurnToolChoice,
      onClose: () {},
    );
    addTearDown(session.close);
    await session.addQueryChunk(
      Message.toolResponse(toolName: 'get_weather', response: {'sky': 'x'}),
    );
    await session.getResponse();
    expect(handle.sends.single.role, 'user');
    expect(handle.sends.single.choice, isNull);
  });

  test('a model whose tools core prompts for itself: no native tools, no '
      'native choice', () async {
    final session = await _open(ModelType.gemmaIt, ToolChoice.required);
    expect(conversationConfig(session.conversation).tools, isEmpty);
    expect(session.userTurnToolChoice, isNull);
  });

  test('the session sends required with a user turn, and no choice with the '
      'turn answering tool results', () async {
    final handle = _ChoiceRecordingHandle();
    final session = ffiSessionForHandle(
      handle: handle,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      supportImage: false,
      supportAudio: false,
      tools: [lm.Tool(name: 'get_weather', description: 'The weather')],
      userTurnToolChoice: lm.ToolChoice.required,
      onClose: () {},
    );
    addTearDown(session.close);
    await session.addQueryChunk(
      const Message(text: 'Weather in Paris?', isUser: true),
    );
    await session.getResponse();
    await session.addQueryChunk(
      Message.toolResponse(
        toolName: 'get_weather',
        response: const {'sky': 'clear'},
      ),
    );
    await session.getResponse();
    expect(handle.sends, hasLength(2));
    expect(handle.sends[0].role, 'user');
    expect(handle.sends[0].choice, isNotNull);
    expect(jsonDecode(handle.sends[0].choice!), 'required');
    expect(handle.sends[1].role, 'tool');
    expect(handle.sends[1].choice, isNull);
  });

  FfiInferenceModelSession recording(_ChoiceRecordingHandle handle) {
    final session = ffiSessionForHandle(
      handle: handle,
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
      supportImage: false,
      supportAudio: false,
      tools: [lm.Tool(name: 'get_weather', description: 'The weather')],
      userTurnToolChoice: lm.ToolChoice.required,
      onClose: () {},
    );
    addTearDown(session.close);
    return session;
  }

  test('a turn mixing user text with a tool response (a history replay) '
      'goes without the choice', () async {
    final handle = _ChoiceRecordingHandle();
    final session = recording(handle);
    await session.addQueryChunk(
      const Message(text: 'Weather in Paris?', isUser: true),
    );
    await session.addQueryChunk(
      Message.toolResponse(toolName: 'get_weather', response: {'sky': 'x'}),
    );
    await session.getResponse();
    expect(handle.sends.single.role, 'user');
    expect(handle.sends.single.choice, isNull);
  });

  test('a constraint refusal on a turn sent with a tool choice does not '
      'close the session', () async {
    final handle = _ChoiceRecordingHandle(
      failWith: const lm.ConstraintUnsupportedException('refused'),
    );
    final session = recording(handle);
    await session.addQueryChunk(const Message(text: 'Hi', isUser: true));
    await expectLater(session.getResponse(), throwsA(anything));
    await pumpEventQueue();
    await session.addQueryChunk(const Message(text: 'Again', isUser: true));
    await expectLater(session.getResponse(), throwsA(anything));
    expect(handle.sends, hasLength(2));
  });

  test('required where LiteRT-LM refuses constrained decoding is refused '
      'at open, naming the tool choice', () async {
    await expectLater(
      _model(
        ModelType.gemma4,
        toolChoiceRefusal: 'refused on linux_arm64 CPU',
      ).openEngineSession(
        SessionRequest(tools: _tools, toolChoice: ToolChoice.required),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          allOf(contains('ToolChoice.required'), contains('linux_arm64')),
        ),
      ),
    );
    // auto and none send no choice, so they open there.
    final model = _model(ModelType.gemma4, toolChoiceRefusal: 'refused');
    for (final choice in [ToolChoice.auto, ToolChoice.none]) {
      final s = await model.openEngineSession(
        SessionRequest(tools: _tools, toolChoice: choice),
      );
      await s.close();
    }
  });

  test('required without tools is an ArgumentError', () async {
    await expectLater(
      _model(
        ModelType.gemma4,
      ).openEngineSession(SessionRequest(toolChoice: ToolChoice.required)),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('the legacy createChat maps the choice too', () async {
    final model = _model(ModelType.gemma4);
    // ignore: deprecated_member_use
    await model.createChat(
      tools: _tools,
      modelType: ModelType.gemma4,
      toolChoice: ToolChoice.required,
    );
    // ignore: deprecated_member_use
    var session = model.session! as FfiInferenceModelSession;
    expect(session.userTurnToolChoice, same(lm.ToolChoice.required));
    // ignore: deprecated_member_use
    await model.createChat(
      tools: _tools,
      modelType: ModelType.gemma4,
      toolChoice: ToolChoice.none,
    );
    // ignore: deprecated_member_use
    session = model.session! as FfiInferenceModelSession;
    expect(conversationConfig(session.conversation).tools, isEmpty);
    expect(session.declaresTools, isFalse);
    expect(session.userTurnToolChoice, isNull);
  });
}

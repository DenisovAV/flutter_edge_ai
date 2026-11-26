// Engine.createConversation over a fake client: which conversations get a
// native conversation of their own, and what each is created with.
import 'dart:convert';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

typedef _Create = ({
  String? systemMessage,
  String? toolsJson,
  String? messagesJson,
  Sampler sampling,
  bool samplingExplicit,
  int? maxOutputTokens,
  Constraint? constraint,
  bool filterChannelContent,
  ConversationExtras extras,
});

class _Client extends LiteRtLmFfiClient {
  final creates = <_Create>[];

  @override
  BundleSampler get bundleSampler => const BundleSampler(topK: 20);

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
    ConversationExtras extras = ConversationExtras.none,
    required bool filterChannelContent,
  }) async {
    creates.add((
      systemMessage: systemMessage,
      toolsJson: toolsJson,
      messagesJson: messagesJson,
      sampling: sampling,
      samplingExplicit: samplingExplicit,
      maxOutputTokens: maxOutputTokens,
      constraint: constraint,
      filterChannelContent: filterChannelContent,
      extras: extras,
    ));
    return LiteRtLmConversationHandle.forTest(this);
  }
}

void main() {
  test('on a virtual-backed engine conversations share one native '
      "conversation; createOwnConversation gets one of its own", () async {
    final client = _Client();
    final engine = engineForTest(client);
    final a = await engine.createConversation();
    final b = await engine.createConversation();
    expect(conversationHandle(a), isA<VirtualConversationHandle>());
    expect(conversationHandle(b), isA<VirtualConversationHandle>());
    expect(client.creates, isEmpty);
    final own = await createOwnConversation(engine);
    expect(conversationHandle(own), isA<RecoveringConversationHandle>());
    expect(client.creates, hasLength(1));
  });

  test('on a native-backed engine every conversation has its own', () async {
    final client = _Client();
    final engine = engineForTest(client, backing: OpenSessionBacking.native);
    final a = await engine.createConversation();
    final b = await engine.createConversation();
    expect(conversationHandle(a), isA<RecoveringConversationHandle>());
    expect(conversationHandle(b), isA<RecoveringConversationHandle>());
    expect(client.creates, hasLength(2));
  });

  test("the caller's sampler is the caller's; a default is not", () async {
    final client = _Client();
    final engine = engineForTest(client, backing: OpenSessionBacking.native);
    final mine = SamplerConfig(topK: 1, topP: 1, temperature: 0, seed: 3);
    await engine.createConversation(ConversationConfig(samplerConfig: mine));
    await createConversationWithDefault(engine, ConversationConfig(), mine);
    await engine.createConversation();
    expect(client.creates.map((c) => c.samplingExplicit), [true, false, false]);
    expect(client.creates.map((c) => c.sampling.topK), [
      1,
      1,
      20,
    ], reason: "the last takes the file's sampler");
  });

  test('what a conversation is created with: system, tools, history, cap, '
      'constraint and extras', () async {
    final client = _Client();
    final engine = engineForTest(
      client,
      backing: OpenSessionBacking.native,
      speculates: true,
    );
    await engine.createConversation(
      ConversationConfig(
        systemInstruction: 'be brief',
        tools: [Tool(name: 'f')],
        initialMessages: [Message.user('a'), Message.model('b')],
        maxOutputTokens: 64,
        responseFormat: ResponseFormat.regex('[0-9]+'),
        extraContext: const {'k': 'v'},
        speculativeDecoding: SpeculativeDecodingConfig(
          mode: SpeculativeDecodingMode.adaptive,
        ),
      ),
    );
    await engine.createConversation(
      ConversationConfig(
        responseFormat: ResponseFormat.json(const {'type': 'string'}),
      ),
    );
    final first = client.creates.first;
    expect(first.systemMessage, 'be brief');
    expect(jsonDecode(first.toolsJson!), hasLength(1));
    expect(jsonDecode(first.messagesJson!), [
      {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'a'},
        ],
      },
      {
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': 'b'},
        ],
      },
    ]);
    expect(first.maxOutputTokens, 64);
    expect(first.constraint, const Constraint.regex('[0-9]+'));
    expect(first.extras.extraContext, {'k': 'v'});
    expect(
      first.extras.speculativeDecoding,
      SpeculativeDecodingConfig(mode: SpeculativeDecodingMode.adaptive),
    );
    expect(
      client.creates.last.constraint,
      const Constraint.jsonSchema('{"type":"string"}'),
    );
  });

  test('the channel filter follows the engine: off on the NPU and on a model '
      'whose linear attention state is set or unread', () async {
    for (final (backend, linear, filters) in [
      (const Backend.cpu(), false, true),
      (const Backend.npu(), false, false),
      (const Backend.cpu(), true, false),
      (const Backend.cpu(), null, false),
    ]) {
      final client = _Client();
      final engine = engineForTest(
        client,
        backend: backend,
        backing: OpenSessionBacking.native,
        linearAttentionState: linear,
      );
      await engine.createConversation();
      expect(client.creates.single.filterChannelContent, filters);
      expect(engineFiltersChannelContent(engine), filters);
    }
  });

  test('a send after the engine closed is a StateError at the call, on '
      'either backing', () async {
    for (final backing in OpenSessionBacking.values) {
      final engine = engineForTest(_Client(), backing: backing);
      final conversation = await engine.createConversation();
      await engine.close();
      expect(
        () => conversation.sendMessageStream(Message.user('x')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'The engine is closed.',
          ),
        ),
        reason: '$backing',
      );
    }
  });

  test('a response format is refused where constrained decoding was not '
      'qualified, before any conversation exists', () async {
    final client = _Client();
    final engine = engineForTest(
      client,
      constraintRefusal: 'refused on linux_arm64 CPU',
    );
    await expectLater(
      engine.createConversation(
        ConversationConfig(responseFormat: ResponseFormat.regex('[0-9]+')),
      ),
      throwsA(
        isA<ConstraintUnsupportedException>().having(
          (e) => e.message,
          'message',
          'refused on linux_arm64 CPU',
        ),
      ),
    );
    expect(client.creates, isEmpty);
    await engine.createConversation();
  });

  test(
    'a tool choice other than auto is refused on the stream where '
    'constrained decoding was not qualified, as a response format is',
    () async {
      final engine = engineForTest(
        _Client(),
        constraintRefusal: 'refused on linux_arm64 CPU',
      );
      final conversation = await engine.createConversation(
        ConversationConfig(tools: [Tool(name: 't')]),
      );
      for (final choice in [
        ToolChoice.none,
        ToolChoice.required,
        const ToolChoice.forcedFunction('t'),
        const ToolChoice.allowedTools(['t']),
      ]) {
        await expectLater(
          conversation
              .sendMessageStream(Message.user('x'), toolChoice: choice)
              .toList(),
          throwsA(
            isA<ConstraintUnsupportedException>().having(
              (e) => e.message,
              'message',
              'refused on linux_arm64 CPU',
            ),
          ),
          reason: '$choice',
        );
      }
    },
  );

  test('the qualified rows: the CPU and GPU of macOS, iOS, Linux x64, '
      'Windows x64 and Android (Adreno, Mali, PowerVR); never an NPU', () {
    String? refusal(String abi, BackendKind backend, {AndroidGpuFamily? gpu}) =>
        liteRtLmConstrainedDecodingRefusal(
          abi: abi,
          backend: backend,
          androidGpu: gpu,
        );
    expect(refusal('macos_arm64', BackendKind.gpu), isNull);
    expect(refusal('linux_x64', BackendKind.cpu), isNull);
    expect(
      refusal('linux_arm64', BackendKind.cpu),
      contains('linux_arm64 CPU'),
    );
    expect(
      refusal('android_arm64', BackendKind.gpu, gpu: AndroidGpuFamily.adreno),
      isNull,
    );
    for (final vendor in NpuStack.values) {
      for (final abi in vendor.abis) {
        expect(
          liteRtLmConstrainedDecodingRefusal(
            abi: abi,
            backend: BackendKind.npu,
            npuVendor: vendor,
          ),
          contains('NPU'),
        );
      }
    }
  });

  test('option scoring is refused on the NPU, before anything native', () {
    final engine = engineForTest(_Client(), backend: const Backend.npu());
    expect(
      () => engine.scoreTargets('p', ['a']),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('does not run on the NPU'),
        ),
      ),
    );
  });

  test('a closed engine opens no conversation and tokenizes nothing', () async {
    final engine = engineForTest(_Client());
    await engine.close();
    expect(engine.createConversation, throwsStateError);
    expect(() => engine.tokenize('x'), throwsStateError);
  });

  test("a conversation's chat template and tool call streaming reach its "
      'native conversation', () async {
    final client = _Client();
    final engine = engineForTest(client, backing: OpenSessionBacking.native);
    await engine.createConversation(
      ConversationConfig(
        chatTemplate: '{{ messages }}',
        enableToolCallStreaming: true,
      ),
    );
    final extras = client.creates.single.extras;
    expect(extras.chatTemplate, '{{ messages }}');
    expect(extras.streamToolCalls, isTrue);
    await engine.createConversation();
    expect(client.creates.last.extras.chatTemplate, isNull);
    expect(client.creates.last.extras.streamToolCalls, isFalse);
  });

  test("a conversation's visual token budget is checked against the engine "
      'before anything native', () async {
    final client = _Client();
    final engine = engineForTest(
      client,
      backing: OpenSessionBacking.native,
      visionBackend: const Backend.cpu(),
      visionBudgets: const [70, 140, 280],
      visualTokenBudget: 140,
    );
    await engine.createConversation(ConversationConfig(visualTokenBudget: 70));
    expect(client.creates, hasLength(1));
    for (final budget in [280, 100]) {
      await expectLater(
        engine.createConversation(
          ConversationConfig(visualTokenBudget: budget),
        ),
        throwsArgumentError,
        reason: '$budget',
      );
    }
    final noVision = engineForTest(client, backing: OpenSessionBacking.native);
    await expectLater(
      noVision.createConversation(ConversationConfig(visualTokenBudget: 70)),
      throwsArgumentError,
    );
    expect(client.creates, hasLength(1));
  });
}

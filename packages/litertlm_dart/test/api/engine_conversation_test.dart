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
    final engine = engineForTest(client, backing: OpenSessionBacking.native);
    await engine.createConversation(
      ConversationConfig(
        systemInstruction: 'be brief',
        tools: [Tool(name: 'f')],
        initialMessages: [Message.user('a'), Message.model('b')],
        maxOutputTokens: 64,
        responseFormat: ResponseFormat.regex('[0-9]+'),
        extraContext: const {'k': 'v'},
        speculativeDecoding: SpeculativeDecodingMode.adaptive,
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
    expect(first.extras.speculativeDecoding, SpeculativeDecodingMode.adaptive);
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

  test('a closed engine opens no conversation and tokenizes nothing', () async {
    final engine = engineForTest(_Client());
    await engine.close();
    expect(engine.createConversation, throwsStateError);
    expect(() => engine.tokenize('x'), throwsStateError);
  });
}

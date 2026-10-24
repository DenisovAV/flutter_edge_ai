import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every path through which `InferenceChat` records a tool call stores the
/// calls it returned, beside the text it has always stored.
class _Session implements InferenceModelSession, RawSdkResponseSession {
  _Session(this.tokens, this.raw);

  final List<String> tokens;
  final String? raw;

  @override
  String? get lastRawResponse => raw;
  @override
  Future<void> addQueryChunk(Message message) async {}
  @override
  Future<String> getResponse() async => tokens.join();
  @override
  Stream<String> getResponseAsync() => Stream.fromIterable(tokens);
  @override
  Future<int> sizeInTokens(String text) async => text.length ~/ 4;
  @override
  Future<void> stopGeneration() async {}
  @override
  SessionMetrics getSessionMetrics() => SessionMetrics();
  @override
  Future<void> close() async {}
}

const _tool = Tool(
  name: 'runIntent',
  description: 'run an intent',
  parameters: {
    'type': 'object',
    'properties': {
      'intent': {'type': 'string'},
    },
  },
);

const _call = FunctionCallResponse(name: 'runIntent', args: {'intent': 'x'});

Future<InferenceChat> _chat(
  ModelType type,
  List<String> tokens, {
  String? raw,
}) async {
  final chat = InferenceChat(
    sessionCreator: () async => _Session(tokens, raw),
    maxTokens: 1024,
    modelType: type,
    supportsFunctionCalls: true,
    tools: const [_tool],
  );
  await chat.initSession();
  await chat.addQuery(const Message(text: 'hi', isUser: true));
  return chat;
}

Message _recorded(InferenceChat chat) =>
    chat.fullHistory.singleWhere((m) => m.type == MessageType.toolCall);

void main() {
  const raw =
      '{"role":"assistant","tool_calls":[{"type":"function","function":'
      '{"name":"runIntent","arguments":{"intent":"x"}}}]}';
  const json = '{"name":"runIntent","parameters":{"intent":"x"}}';

  test(
    'an SDK call with an id keeps it, in the response and the history',
    () async {
      const withId =
          '{"role":"assistant","tool_calls":[{"id":"c1","type":"function",'
          '"function":{"name":"runIntent","arguments":{"intent":"x"}}}]}';
      const expected = FunctionCallResponse(
        name: 'runIntent',
        args: {'intent': 'x'},
        id: 'c1',
      );
      final chat = await _chat(ModelType.gemma4, const [withId], raw: withId);

      expect(await chat.generateChatResponse(), expected);
      expect(_recorded(chat).toolCalls, [expected]);
    },
  );

  test('SDK response, generateChatResponse', () async {
    final chat = await _chat(ModelType.gemma4, const [raw], raw: raw);

    expect(await chat.generateChatResponse(), _call);
    expect(_recorded(chat).text, raw);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('SDK response, end of stream', () async {
    final chat = await _chat(ModelType.gemma4, const [raw], raw: raw);

    expect(await chat.generateChatResponseAsync().toList(), [_call]);
    expect(_recorded(chat).text, raw);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('a model answering in the canonical text a history replays', () async {
    final canonical = Message.toolCall(calls: const [_call]).text;
    final chat = await _chat(ModelType.general, [canonical]);

    expect(await chat.generateChatResponse(), _call);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('text call, generateChatResponse', () async {
    final chat = await _chat(ModelType.general, const [json]);

    expect(await chat.generateChatResponse(), _call);
    expect(_recorded(chat).text, json);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('text call completed mid-stream', () async {
    final chat = await _chat(ModelType.general, const [
      '{"name":"runIntent",',
      '"parameters":{"intent":"x"}}',
    ]);

    expect(await chat.generateChatResponseAsync().toList(), [_call]);
    expect(_recorded(chat).text, json);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('text call found at end of stream', () async {
    final chat = await _chat(ModelType.general, const [json]);

    expect(await chat.generateChatResponseAsync().toList(), [_call]);
    expect(_recorded(chat).text, json);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('a tagged call in one chunk, at end of stream, is a call', () async {
    // The whole `<tool_call>` block in the last chunk: nothing after it makes
    // the mid-stream check run, and the block itself is not JSON.
    const tagged =
        '<tool_call>{"name":"runIntent","arguments":{"intent":"x"}}'
        '</tool_call>';
    final chat = await _chat(ModelType.qwen, const [tagged]);

    expect(await chat.generateChatResponseAsync().toList(), [_call]);
    expect(_recorded(chat).text, tagged);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('a fenced call in one chunk, at end of stream, is a call', () async {
    const fenced =
        '```json\n{"name":"runIntent","parameters":{"intent":"x"}}\n```';
    final chat = await _chat(ModelType.general, const [fenced]);

    expect(await chat.generateChatResponseAsync().toList(), [_call]);
    expect(_recorded(chat).toolCalls, [_call]);
  });

  test('parallel calls are all stored, and toolCallsOf reads them', () async {
    const parallel =
        '{"role":"assistant","tool_calls":['
        '{"type":"function","function":{"name":"runIntent","arguments":{"intent":"x"}}},'
        '{"type":"function","function":{"name":"runIntent","arguments":{"intent":"y"}}}]}';
    final chat = await _chat(ModelType.gemma4, const [parallel], raw: parallel);

    final response = await chat.generateChatResponse();

    expect(response, isA<ParallelFunctionCallResponse>());
    final calls = (response as ParallelFunctionCallResponse).calls;
    expect(_recorded(chat).toolCalls, calls);
    expect(toolCallsOf(_recorded(chat)), calls);
  });
}

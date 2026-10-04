import 'package:flutter_edge_ai/core/chat.dart';
import 'package:flutter_edge_ai/core/message.dart';
import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/model_response.dart';
import 'package:flutter_edge_ai/core/tool.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// #366, exercised through the streaming loop rather than through `parse()`.
///
/// `chat.dart` appends one token at a time and parses the first buffer that
/// `isFunctionCallComplete` accepts. Handing `parse()` a whole call — as the
/// parser unit tests do — never touches that gate, which is precisely how the
/// truncate-at-the-first-`}` bug stayed hidden behind green tests. These drive
/// `generateChatResponseAsync()` end to end.
class _ScriptedSession implements InferenceModelSession {
  _ScriptedSession(this.tokens);

  final List<String> tokens;

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

Future<List<ModelResponse>> streamTokens(List<String> tokens) async {
  final chat = InferenceChat(
    sessionCreator: () async => _ScriptedSession(tokens),
    maxTokens: 1024,
    modelType: ModelType.functionGemma,
    supportsFunctionCalls: true,
    tools: [
      const Tool(
        name: 'f',
        description: 'd',
        parameters: {
          'type': 'object',
          'properties': {
            'b': {'type': 'number', 'description': 'b'},
          },
        },
      ),
    ],
  );
  await chat.initSession();
  await chat.addQuery(const Message(text: 'hi', isUser: true));
  return chat.generateChatResponseAsync().toList();
}

void main() {
  test('nested-object call survives the per-token gate intact', () async {
    // `{x:1}` ends a token with `}` — the old gate called the call finished
    // there, dropping `b` and leaking the tail as text.
    final responses = await streamTokens([
      '<start_function_call>',
      'call:',
      'f',
      '{a:',
      '{x:1}',
      ',b:2}',
      '<end_function_call>',
    ]);

    final calls = responses.whereType<FunctionCallResponse>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.name, equals('f'));
    expect(calls.single.args['a'], equals({'x': 1}));
    expect(calls.single.args['b'], equals(2), reason: 'b must not be dropped');

    expect(
      responses.whereType<TextResponse>(),
      isEmpty,
      reason: 'no part of the call may reach the user as text',
    );
  });

  test('call with a brace inside a string value survives intact', () async {
    final responses = await streamTokens([
      '<start_function_call>',
      'call:f{msg:',
      '<escape>a}',
      'b<escape>',
      ',x:1}',
      '<end_function_call>',
    ]);

    final calls = responses.whereType<FunctionCallResponse>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.args['msg'], equals('a}b'));
    expect(calls.single.args['x'], equals(1), reason: 'x must not be dropped');

    expect(responses.whereType<TextResponse>(), isEmpty);
  });

  test('a call cut off mid-body degrades to text, never to a bogus call', () {
    // The brace never closes, so the gate never fires and the end-of-stream
    // handler must surface what the model produced rather than swallow it.
    return streamTokens(['<start_function_call>', 'call:f{a:1,b:']).then((
      responses,
    ) {
      expect(responses.whereType<FunctionCallResponse>(), isEmpty);
      expect(
        responses.whereType<TextResponse>().map((r) => r.token).join(),
        equals('<start_function_call>call:f{a:1,b:'),
      );
    });
  });

  test('call whose end tag a stop token ate is still parsed', () async {
    final responses = await streamTokens([
      '<start_function_call>',
      'call:f{a:1,b:',
      '[1,2]}',
    ]);

    final calls = responses.whereType<FunctionCallResponse>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.args['a'], equals(1));
    expect(calls.single.args['b'], equals([1, 2]));
  });
}

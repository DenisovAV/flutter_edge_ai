// Automatic tool calling on the web arm, over the stub runtime
// (web_runtime_stub.dart): the shared Conversation runs the calls and sends
// their results to the runtime conversation as a tool message, and a stop
// during the round after them is rebuilt with the whole exchange.
//
// Run: dart test -p chrome test/web/web_conversation_tools_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_conversation_tools_browser_test.dart
@TestOn('browser')
library;

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

const _weatherCall =
    '{"role":"assistant","tool_calls":[{"type":"function",'
    '"function":{"name":"weather","arguments":{"city":"London"}}}]}';

final _weatherCalls = [
  {
    'type': 'function',
    'function': {
      'name': 'weather',
      'arguments': {'city': 'London'},
    },
  },
];

Tool _weather(List<Map<String, Object?>> seen) => Tool(
  name: 'weather',
  parameters: {'type': 'object'},
  execute: (arguments) {
    seen.add(arguments);
    return {'temp': 25};
  },
);

Map<String, Object?> get _toolMessage => {
  'role': 'tool',
  'content': [
    {
      'type': 'tool_response',
      'name': 'weather',
      'response': {'temp': 25},
    },
  ],
};

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  late web.Engine engine;
  setUp(() async => engine = await webEngine());
  tearDown(() => engine.close());

  test('a call is run and its result sent as a tool message; the answer '
      'streams as the same reply', () async {
    final seen = <Map<String, Object?>>[];
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [_weather(seen)]),
    );
    final reply = conversation.sendMessageStream(Message.user('hi')).toList();
    await settle();
    js('__chunk', _weatherCall);
    js('__end');
    await settle();
    expect(seen, [
      {'city': 'London'},
    ]);
    expect(list('sent'), ['hi', _toolMessage]);
    js('__step', 'Sunny');
    js('__end');
    final pieces = await reply;
    expect(pieces.map((m) => m.text), ['Sunny']);
    expect(pieces.expand((m) => m.toolCalls), isEmpty);
  });

  test('a call of a tool without execute reaches the caller unrun', () async {
    final seen = <Map<String, Object?>>[];
    final conversation = await engine.createConversation(
      ConversationConfig(
        tools: [
          _weather(seen),
          Tool(name: 'manual'),
        ],
      ),
    );
    final reply = conversation.sendMessage(Message.user('hi'));
    await settle();
    js(
      '__chunk',
      '{"role":"assistant","tool_calls":[{"type":"function",'
          '"function":{"name":"manual","arguments":{}}}]}',
    );
    js('__end');
    final message = await reply;
    expect(message.toolCalls.single.name, 'manual');
    expect(seen, isEmpty);
    expect(list('sent'), ['hi']);
  });

  test('automaticToolCalling false returns the call unrun', () async {
    final seen = <Map<String, Object?>>[];
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [_weather(seen)], automaticToolCalling: false),
    );
    final reply = conversation.sendMessage(Message.user('hi'));
    await settle();
    js('__chunk', _weatherCall);
    js('__end');
    expect((await reply).toolCalls.single.name, 'weather');
    expect(seen, isEmpty);
    expect(list('sent'), ['hi']);
  });

  test('a stop during round 2 keeps the call, its result and the partial '
      'answer in the rebuilt conversation', () async {
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [_weather([])]),
    );
    final stopped = conversation.sendMessageStream(Message.user('hi')).toList();
    await settle();
    js('__chunk', _weatherCall);
    js('__end');
    await settle();
    js('__step', 'It is');
    await settle();
    conversation.cancel();
    expect((await stopped).map((m) => m.text), ['It is']);

    await exchange(conversation, 'Thanks', 'Welcome');

    expect(list('conversationOptions'), hasLength(2));
    expect(prefaceMessages(1), [
      {'role': 'user', 'content': 'hi'},
      {...assistantPart(''), 'tool_calls': _weatherCalls},
      _toolMessage,
      assistantPart('It is'),
    ]);
  });
}

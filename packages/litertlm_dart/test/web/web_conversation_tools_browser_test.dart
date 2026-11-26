// Automatic tool calling on the web arm, over the stub runtime
// (web_runtime_stub.dart): the shared Conversation runs the calls and sends
// their results to the runtime conversation as user text ("Tool <name>
// returned: <JSON>"), and a stop during the round after them is rebuilt
// with the whole exchange. @litert-lm/core answers a tool message with
// nothing on most sampler seeds (measured 2026-11-26, web_tool_responses.dart).
//
// Run: dart test -p chrome test/web/web_conversation_tools_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_conversation_tools_browser_test.dart
@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

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

/// [_weather]'s result as the user text it is sent as.
Map<String, Object?> get _toolText =>
    userPart('Tool weather returned: {"temp":25}');

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  late web.Engine engine;
  setUp(() async => engine = await webEngine());
  tearDown(() => engine.close());

  test('an image beside a result goes in the same user message, after its '
      'line; an empty reply to it is an empty reply', () async {
    setOnPage('resolvedVisionBackend', backendId('GPU'));
    final vision = await web.createWebEngine(
      EngineConfig(
        modelPath: 'blob:https://example.com/model',
        backend: const Backend.gpu(),
        visionBackend: const Backend.gpu(),
      ),
      pageLock: web.LiteRtLmPageLock(),
    );
    addTearDown(vision.close);
    final conversation = await vision.createConversation(
      ConversationConfig(tools: [Tool(name: 'weather')]),
    );
    final reply = conversation.sendMessage(
      Message.tool([
        Content.toolResponse('weather', {'temp': 25}),
        Content.imageBytes(Uint8List.fromList([137, 80, 78, 71])),
      ]),
    );
    await settle();
    expect(list('sent').single, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Tool weather returned: {"temp":25}'},
        {
          'type': 'image',
          'blob': base64Encode([137, 80, 78, 71]),
        },
      ],
    });
    js('__emptyReply');
    expect((await reply).text, '');
    await exchange(conversation, 'Thanks', 'Welcome');
    expect(list('conversationOptions'), hasLength(1));
  });

  test('a result in a user message goes as user text', () async {
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [Tool(name: 'weather')]),
    );
    final reply = conversation.sendMessage(
      Message(
        role: Role.user,
        contents: [
          Content.toolResponse('weather', {'temp': 25}),
        ],
      ),
    );
    await settle();
    expect(list('sent').single, _toolText);
    js('__step', 'Sunny');
    js('__end');
    expect((await reply).text, 'Sunny');
  });

  test('a call id goes with its result as text', () async {
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [_weather([])]),
    );
    final reply = conversation.sendMessage(Message.user('hi'));
    await settle();
    js(
      '__chunk',
      '{"role":"assistant","tool_calls":[{"id":"call_7","type":"function",'
          '"function":{"name":"weather","arguments":{"city":"London"}}}]}',
    );
    js('__end');
    await settle();
    expect(
      list('sent').last,
      userPart('Tool weather (call call_7) returned: {"temp":25}'),
    );
    js('__step', 'Sunny');
    js('__end');
    expect((await reply).text, 'Sunny');
  });

  test('an empty reply to the results as text is an empty reply, not a '
      'refused send', () async {
    final conversation = await engine.createConversation(
      ConversationConfig(tools: [_weather([])]),
    );
    final reply = conversation.sendMessage(Message.user('hi'));
    await settle();
    js('__chunk', _weatherCall);
    js('__end');
    await settle();
    js('__emptyReply');
    expect((await reply).text, '');
    // Nothing to rebuild: the next message goes to the same conversation.
    await exchange(conversation, 'Thanks', 'Welcome');
    expect(list('conversationOptions'), hasLength(1));
  });

  test(
    'results as text the runtime refuses are left out of the rebuild',
    () async {
      final conversation = await engine.createConversation(
        ConversationConfig(tools: [_weather([])]),
      );
      final reply = conversation.sendMessage(Message.user('hi'));
      final failed = expectLater(reply, throwsA(isA<TurnFailedException>()));
      await settle();
      js('__chunk', _weatherCall);
      setOnPage('refuseNextSend', true);
      js('__end');
      await failed;

      await exchange(conversation, 'Thanks', 'Welcome');
      expect(prefaceMessages(1), [
        {'role': 'user', 'content': 'hi'},
        {...assistantPart(''), 'tool_calls': _weatherCalls},
      ]);
    },
  );

  test('a call is run and its result sent; the answer streams as the same '
      'reply', () async {
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
    expect(list('sent'), ['hi', _toolText]);
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

  test(
    'an execute that throws answers the model with the error as text',
    () async {
      final conversation = await engine.createConversation(
        ConversationConfig(
          tools: [
            Tool(name: 'weather', execute: (_) => throw StateError('offline')),
          ],
        ),
      );
      final reply = conversation.sendMessage(Message.user('hi'));
      await settle();
      js('__chunk', _weatherCall);
      js('__end');
      await settle();
      expect(
        list('sent').last,
        userPart('Tool weather returned: "Error: Bad state: offline"'),
      );
      js('__step', 'Sorry');
      js('__end');
      expect((await reply).text, 'Sorry');
    },
  );

  test(
    'after 25 rounds a reply that still calls tools fails the send',
    () async {
      final seen = <Map<String, Object?>>[];
      final conversation = await engine.createConversation(
        ConversationConfig(tools: [_weather(seen)]),
      );
      final reply = conversation.sendMessage(Message.user('hi'));
      final failed = expectLater(reply, throwsWith<TurnFailedException>('25'));
      for (var i = 0; i < 26; i++) {
        await settle();
        js('__chunk', _weatherCall);
        js('__end');
      }
      await failed;
      expect(seen, hasLength(25));
      expect(list('sent'), hasLength(26));
    },
  );

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
      _toolText,
      assistantPart('It is'),
    ]);
  });

  test(
    'on a clone, a stop during round 2 replays the results as text',
    () async {
      final original = await engine.createConversation(
        ConversationConfig(tools: [_weather([])]),
      );
      await exchange(original, 'Hello', 'Hi');
      final conversation = await original.clone();
      final stopped = conversation
          .sendMessageStream(Message.user('hi'))
          .toList();
      await settle();
      js('__chunk', _weatherCall);
      js('__end');
      await settle();
      js('__step', 'It is');
      await settle();
      conversation.cancel();
      await stopped;

      await exchange(conversation, 'Thanks', 'Welcome');
      expect(prefaceMessages(1), [
        {'role': 'user', 'content': 'Hello'},
        assistantPart('Hi'),
        {'role': 'user', 'content': 'hi'},
        {...assistantPart(''), 'tool_calls': _weatherCalls},
        _toolText,
        assistantPart('It is'),
      ]);
    },
  );
}

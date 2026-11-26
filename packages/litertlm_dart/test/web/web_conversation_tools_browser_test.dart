// Automatic tool calling on the web arm, over the stub runtime
// (web_runtime_stub.dart): the shared Conversation runs the calls and sends
// their results to the runtime conversation, and a stop during the round
// after them is rebuilt with the whole exchange. The results go as a tool
// message on a page that fetched @litert-lm/core 0.19.0, and as user text
// ("Tool <name> returned: <JSON>") on 0.20.0, the pinned version, which a
// page with no versioned URL is taken to run, and on
// 0.21.0-nightly.20261125: those answer a tool message with nothing under
// greedy decoding and on most sampler seeds (measured 2026-11-26, web_tool_responses.dart).
//
// Run: dart test -p chrome test/web/web_conversation_tools_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_conversation_tools_browser_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

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

/// The tool message holding [_weather]'s result, as 0.19.0 takes it.
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

/// The same result as user text, as 0.20.0 and later take it.
Map<String, Object?> get _toolText =>
    userPart('Tool weather returned: {"temp":25}');

/// The page's resources: one fetched from @litert-lm/core [version]'s URL,
/// or none of the runtime (a self-hosted one) when null.
void _pageFetched(String? version) => globalContext.callMethod(
  'eval'.toJS,
  '''window.__realEntries = window.__realEntries || performance.getEntriesByType;
    Object.defineProperty(performance, 'getEntriesByType', {
      configurable: true,
      value: (type) => type !== 'resource' ? [] : [
        ${version == null ? '' : "{name: 'https://cdn.jsdelivr.net/npm/@litert-lm/core@$version/+esm'},"}
        {name: 'https://example.com/app.js'},
      ],
    });'''
      .toJS,
);

void _pageEntriesRestored() => globalContext.callMethod(
  'eval'.toJS,
  '''if (window.__realEntries) {
      Object.defineProperty(performance, 'getEntriesByType', {
        configurable: true, value: window.__realEntries});
      delete window.__realEntries;
    }'''
      .toJS,
);

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);
  tearDown(_pageEntriesRestored);

  late web.Engine engine;
  setUp(() async {
    _pageFetched(null);
    engine = await webEngine();
  });
  tearDown(() => engine.close());

  group('a result goes as', () {
    for (final (version, toolMessage) in [
      ('0.19.0', true),
      ('0.20.0', false),
      ('0.21.0-nightly.20261125', false),
      (null, false),
    ]) {
      test('${toolMessage ? 'a tool message' : 'user text'} on '
          '${version ?? 'a page that fetched no versioned runtime'}', () async {
        _pageFetched(version);
        final onPage = await webEngine();
        addTearDown(onPage.close);
        final conversation = await onPage.createConversation(
          ConversationConfig(tools: [_weather([])]),
        );
        final reply = conversation.sendMessage(Message.user('hi'));
        await settle();
        js('__chunk', _weatherCall);
        js('__end');
        await settle();
        expect(list('sent'), ['hi', toolMessage ? _toolMessage : _toolText]);
        js('__step', 'Sunny');
        js('__end');
        expect((await reply).text, 'Sunny');
      });
    }
  });

  test('a nightly is read with its prerelease', () {
    _pageFetched('0.21.0-nightly.20261125');
    expect(web.liteRtLmWebFetchedVersions(), {'0.21.0-nightly.20261125'});
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

  test('on 0.19.0 a stop during round 2 replays the tool message', () async {
    _pageFetched('0.19.0');
    final onPage = await webEngine();
    addTearDown(onPage.close);
    final conversation = await onPage.createConversation(
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
    await stopped;

    await exchange(conversation, 'Thanks', 'Welcome');
    expect(prefaceMessages(1), [
      {'role': 'user', 'content': 'hi'},
      {...assistantPart(''), 'tool_calls': _weatherCalls},
      _toolMessage,
      assistantPart('It is'),
    ]);
  });
}

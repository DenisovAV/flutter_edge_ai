// Automatic tool calling over a fake handle: which replies the conversation
// runs itself, what it sends back, what the caller sees, the round limit, and
// a stop in each phase of a round. The last group drives a real virtual
// handle, whose history a rebuild replays.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_bindings.dart';
import 'package:test/test.dart';

/// A handle whose native side the test plays: each send is a real
/// [NativeTurnStream], and the test posts its chunks and its end.
class _Handle implements ConversationHandle {
  final turns = NativeTurns<String>(cancelNative: (_) {}, deleteNative: (_) {});
  final sends = <NativeTurnStream<String>>[];
  final messages = <Map<String, Object?>>[];
  final options = <SendOptions>[];
  int cancels = 0;

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) {
    messages.add(jsonDecode(messageJson) as Map<String, Object?>);
    this.options.add(options);
    final send = NativeTurnStream(turns, 'c${sends.length}');
    sends.add(send);
    return send.stream;
  }

  @override
  void cancelGeneration() {
    cancels++;
    if (sends.isNotEmpty) turns.cancel('c${sends.length - 1}');
  }

  @override
  Future<void> close() async {
    for (var i = 0; i < sends.length; i++) {
      turns.release('c$i');
    }
  }

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

String _text(String t) => jsonEncode({
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': t},
  ],
});

String _calls(List<(String, Map<String, Object?>)> calls) => jsonEncode({
  'role': 'assistant',
  'tool_calls': [
    for (final (name, arguments) in calls)
      {
        'type': 'function',
        'function': {'name': name, 'arguments': arguments},
      },
  ],
});

String _call(String name, [Map<String, Object?> arguments = const {}]) =>
    _calls([(name, arguments)]);

/// The tool responses of the tool message the [index]th send carried.
List<Object?> _responses(_Handle handle, int index) {
  final message = handle.messages[index];
  expect(message['role'], 'tool');
  return message['content']! as List<Object?>;
}

Map<String, Object?> _response(String name, Object? response) => {
  'type': 'tool_response',
  'name': name,
  'response': response,
};

/// A tool that records each call's arguments and answers with [result].
Tool _tool(
  String name,
  List<Map<String, Object?>> seen, {
  FutureOr<Object?> Function(Map<String, Object?> arguments)? result,
}) => Tool(
  name: name,
  execute: (arguments) {
    seen.add(arguments);
    return result == null ? {'ok': name} : result(arguments);
  },
);

Conversation _conversation(
  _Handle handle,
  List<Tool> tools, {
  bool automatic = true,
  ResponseFormat? responseFormat,
  bool Function()? engineClosed,
}) => conversationForTest(
  handle,
  config: ConversationConfig(
    tools: tools,
    automaticToolCalling: automatic,
    responseFormat: responseFormat,
  ),
  engineClosed: engineClosed,
);

void main() {
  test('one round: the call is run, its result sent as a tool message, and '
      "the model's answer streams as the same reply", () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [
      _tool('weather', seen, result: (a) => {'city': a['city'], 'temp': 25}),
    ]);
    final reply = conversation.sendMessageStream(Message.user('hi')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('weather', {'city': 'London'}))
      ..finished();
    await pumpEventQueue();
    expect(seen, [
      {'city': 'London'},
    ]);
    expect(handle.sends, hasLength(2));
    expect(_responses(handle, 1), [
      _response('weather', {'city': 'London', 'temp': 25}),
    ]);
    handle.sends.last
      ..chunk(_text('Sunny'))
      ..finished();
    final pieces = await reply;
    expect(pieces.map((m) => m.text), ['Sunny']);
    expect(pieces.expand((m) => m.toolCalls), isEmpty);
    // The conversation is free again.
    conversation.sendMessageStream(Message.user('next')).listen((_) {});
    await pumpEventQueue();
    expect(handle.messages.last['role'], 'user');
  });

  test(
    'several rounds, each one more send, until a reply calls no tool',
    () async {
      final handle = _Handle();
      final seen = <Map<String, Object?>>[];
      final conversation = _conversation(handle, [_tool('step', seen)]);
      final reply = conversation.sendMessage(Message.user('go'));
      for (var i = 0; i < 3; i++) {
        await pumpEventQueue();
        handle.sends.last
          ..chunk(_call('step', {'i': i}))
          ..finished();
      }
      await pumpEventQueue();
      handle.sends.last
        ..chunk(_text('done'))
        ..finished();
      expect((await reply).text, 'done');
      expect(seen, [
        {'i': 0},
        {'i': 1},
        {'i': 2},
      ]);
      expect(handle.messages.map((m) => m['role']), [
        'user',
        'tool',
        'tool',
        'tool',
      ]);
    },
  );

  test('parallel calls in one reply run in order and are answered by one '
      'tool message', () async {
    final handle = _Handle();
    final order = <String>[];
    final gate = Completer<void>();
    final conversation = _conversation(handle, [
      Tool(
        name: 'a',
        execute: (_) async {
          order.add('a start');
          await gate.future;
          order.add('a end');
          return 1;
        },
      ),
      Tool(
        name: 'b',
        execute: (_) {
          order.add('b');
          return [2];
        },
      ),
    ]);
    final reply = conversation.sendMessage(Message.user('x'));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_calls([('a', {}), ('b', {})]))
      ..finished();
    await pumpEventQueue();
    expect(order, ['a start'], reason: 'b waits for a');
    gate.complete();
    await pumpEventQueue();
    expect(order, ['a start', 'a end', 'b']);
    expect(_responses(handle, 1), [
      _response('a', 1),
      _response('b', [2]),
    ]);
    handle.sends.last
      ..chunk(_text('ok'))
      ..finished();
    expect((await reply).text, 'ok');
  });

  test('a reply calling a declared tool without execute is returned to the '
      'caller, nothing run, even beside a runnable call', () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [
      _tool('auto', seen),
      Tool(name: 'manual'),
    ]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    final chunk = _calls([
      ('auto', {}),
      ('manual', {'q': 1}),
    ]);
    handle.sends.single
      ..chunk(chunk)
      ..finished();
    final pieces = await reply;
    expect(seen, isEmpty);
    expect(handle.sends, hasLength(1));
    expect(pieces, hasLength(1));
    expect(pieces.single.toolCalls.map((c) => c.name), ['auto', 'manual']);
    expect(
      messageRawJson(pieces.single),
      chunk,
      reason: 'the piece native wrote, as without automatic calling',
    );
  });

  test('a call to a name no tool declares is answered with "Tool not found" '
      'and the reply continues', () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [_tool('real', seen)]);
    final reply = conversation.sendMessage(Message.user('x'));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_calls([('ghost', {}), ('real', {})]))
      ..finished();
    await pumpEventQueue();
    expect(_responses(handle, 1), [
      _response('ghost', 'Error: Tool not found: ghost'),
      _response('real', {'ok': 'real'}),
    ]);
    handle.sends.last
      ..chunk(_text('sorry'))
      ..finished();
    expect((await reply).text, 'sorry');
  });

  test(
    'an execute that throws answers the model with the error as text',
    () async {
      final handle = _Handle();
      final conversation = _conversation(handle, [
        Tool(name: 'boom', execute: (_) => throw StateError('no network')),
      ]);
      final reply = conversation.sendMessage(Message.user('x'));
      await pumpEventQueue();
      handle.sends.single
        ..chunk(_call('boom'))
        ..finished();
      await pumpEventQueue();
      expect(_responses(handle, 1), [
        _response('boom', 'Error: Bad state: no network'),
      ]);
      handle.sends.last
        ..chunk(_text('failed'))
        ..finished();
      expect((await reply).text, 'failed');
    },
  );

  test('an async execute that fails is answered the same way', () async {
    final handle = _Handle();
    final conversation = _conversation(handle, [
      Tool(
        name: 'boom',
        execute: (_) async => throw const FormatException('x'),
      ),
    ]);
    unawaited(conversation.sendMessage(Message.user('x')));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('boom'))
      ..finished();
    await pumpEventQueue();
    expect(_responses(handle, 1), [
      _response('boom', 'Error: FormatException: x'),
    ]);
  });

  test('a result that is not JSON is an error for the model', () async {
    final handle = _Handle();
    final conversation = _conversation(handle, [
      Tool(name: 'odd', execute: (_) => {'when': DateTime(2026)}),
    ]);
    unawaited(conversation.sendMessage(Message.user('x')));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('odd'))
      ..finished();
    await pumpEventQueue();
    expect(handle.sends, hasLength(2));
    expect(_responses(handle, 1), [
      _response('odd', 'Error: the result of odd is not JSON (DateTime).'),
    ]);
  });

  test('after 25 rounds a reply that still calls tools fails the send with '
      'TurnFailedException naming the limit', () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [_tool('loop', seen)]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    for (var i = 0; i < 26; i++) {
      await pumpEventQueue();
      handle.sends.last
        ..chunk(_call('loop'))
        ..finished();
    }
    await expectLater(
      reply,
      throwsA(
        isA<TurnFailedException>().having(
          (e) => '$e',
          'message',
          contains('25'),
        ),
      ),
    );
    expect(seen, hasLength(25));
    expect(handle.sends, hasLength(26));
    // The failed turn let the conversation go.
    conversation.sendMessageStream(Message.user('again')).listen((_) {});
    await pumpEventQueue();
    expect(handle.sends, hasLength(27));
  });

  test(
    'automaticToolCalling false: the reply is returned, nothing run',
    () async {
      final handle = _Handle();
      final seen = <Map<String, Object?>>[];
      final conversation = _conversation(handle, [
        _tool('t', seen),
      ], automatic: false);
      final reply = conversation.sendMessage(Message.user('x'));
      await pumpEventQueue();
      handle.sends.single
        ..chunk(_text('Calling.'))
        ..chunk(_call('t', {'a': 1}))
        ..finished();
      final message = await reply;
      expect(message.text, 'Calling.');
      expect(message.toolCalls.single.arguments, {'a': 1});
      expect(seen, isEmpty);
      expect(handle.sends, hasLength(1));
    },
  );

  test('the stream yields the text and thought of every round and none of '
      'the calls it ran; sendMessage returns the last answer', () async {
    final handle = _Handle();
    final conversation = _conversation(handle, [_tool('t', [])]);
    final pieces = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'channels': {'thought': 'need t'},
        }),
      )
      ..chunk(_text('Checking. '))
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': 'With text. '},
          ],
          'tool_calls': [
            {
              'function': {'name': 't', 'arguments': <String, Object?>{}},
            },
          ],
        }),
      )
      ..finished();
    await pumpEventQueue();
    handle.sends.last
      ..chunk(_text('Answer'))
      ..finished();
    final got = await pieces;
    expect(got.expand((m) => m.toolCalls), isEmpty);
    expect(got.map((m) => m.text).join(), 'Checking. With text. Answer');
    expect(got.first.channels, {'thought': 'need t'});

    final reply = conversation.sendMessage(Message.user('y'));
    await pumpEventQueue();
    handle.sends.last
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'channels': {'thought': 'first'},
        }),
      )
      ..chunk(_text('Checking.'))
      ..chunk(_call('t'))
      ..finished();
    await pumpEventQueue();
    handle.sends.last
      ..chunk(_text('Final'))
      ..finished();
    final message = await reply;
    expect(message.text, 'Final');
    expect(message.channels, isEmpty);
    expect(message.toolCalls, isEmpty);
  });

  test('cancel() during round 2 keeps what round 2 generated; no further '
      'round, and the conversation answers the next message', () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [_tool('t', seen)]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('t'))
      ..finished();
    await pumpEventQueue();
    handle.sends.last.chunk(_text('Par'));
    conversation.cancel();
    expect(handle.cancels, 1);
    handle.sends.last.cancelled();
    expect((await reply).map((m) => m.text), ['Par']);
    expect(handle.sends, hasLength(2));
    final next = conversation.sendMessageStream(Message.user('next')).toList();
    await pumpEventQueue();
    expect(handle.messages.map((m) => m['role']), ['user', 'tool', 'user']);
    handle.sends.last
      ..chunk(_text('ok'))
      ..finished();
    expect((await next).map((m) => m.text), ['ok']);
  });

  test('cancel() as round 2 ends with more calls starts no round 3: the '
      'calls are returned unrun', () async {
    final handle = _Handle();
    final seen = <Map<String, Object?>>[];
    final conversation = _conversation(handle, [_tool('t', seen)]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('t', {'n': 1}))
      ..finished();
    await pumpEventQueue();
    handle.sends.last.chunk(_call('t', {'n': 2}));
    conversation.cancel();
    // Native had already ended it: the stop changes nothing there.
    handle.sends.last.finished();
    final pieces = await reply;
    expect(seen, [
      {'n': 1},
    ]);
    expect(handle.sends, hasLength(2));
    expect(pieces.single.toolCalls.single.arguments, {'n': 2});
  });

  test('cancelling the subscription during round 2 stops native; its future '
      'completes once native has ended the round', () async {
    final handle = _Handle();
    final conversation = _conversation(handle, [_tool('t', [])]);
    final seen = <String>[];
    final subscription = conversation
        .sendMessageStream(Message.user('x'))
        .listen((m) => seen.add(m.text));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('t'))
      ..finished();
    await pumpEventQueue();
    handle.sends.last.chunk(_text('Par'));
    await pumpEventQueue();
    var done = false;
    final cancelled = subscription.cancel().then((_) => done = true);
    await pumpEventQueue();
    expect(handle.cancels, 1);
    expect(done, isFalse);
    handle.sends.last.cancelled();
    await cancelled;
    expect(seen, ['Par']);
    expect(handle.sends, hasLength(2));
    conversation.sendMessageStream(Message.user('next')).listen((_) {});
    await pumpEventQueue();
    expect(handle.sends, hasLength(3));
  });

  test('cancel() while the tools run sends no results: the reply ends with '
      'the calls', () async {
    final handle = _Handle();
    final gate = Completer<Object?>();
    final conversation = _conversation(handle, [
      Tool(name: 'slow', execute: (_) => gate.future),
    ]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('slow', {'a': 1}))
      ..finished();
    await pumpEventQueue();
    conversation.cancel();
    // The next message may be sent at once; the late tool result must not
    // start a round under it.
    final next = conversation.sendMessageStream(Message.user('next')).toList();
    await pumpEventQueue();
    gate.complete('late');
    final pieces = await reply;
    expect(pieces.single.toolCalls.single.name, 'slow');
    expect(handle.messages.map((m) => m['role']), ['user', 'user']);
    handle.sends.last
      ..chunk(_text('ok'))
      ..finished();
    expect((await next).map((m) => m.text), ['ok']);
  });

  test('cancelling the subscription while the tools run sends nothing more '
      'and frees the conversation', () async {
    final handle = _Handle();
    final gate = Completer<Object?>();
    final conversation = _conversation(handle, [
      Tool(name: 'slow', execute: (_) => gate.future),
    ]);
    final subscription = conversation
        .sendMessageStream(Message.user('x'))
        .listen((_) {});
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('slow'))
      ..finished();
    await pumpEventQueue();
    await subscription.cancel();
    gate.complete('late');
    await pumpEventQueue();
    expect(handle.sends, hasLength(1));
    conversation.sendMessageStream(Message.user('next')).listen((_) {});
    await pumpEventQueue();
    expect(handle.sends, hasLength(2));
  });

  test('closing the conversation while the tools run ends the reply with '
      'ConversationClosedException', () async {
    final handle = _Handle();
    final gate = Completer<Object?>();
    final conversation = _conversation(handle, [
      Tool(name: 'slow', execute: (_) => gate.future),
    ]);
    final reply = conversation.sendMessageStream(Message.user('x')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('slow'))
      ..finished();
    await pumpEventQueue();
    await conversation.close();
    gate.complete(1);
    await expectLater(reply, throwsA(isA<ConversationClosedException>()));
    expect(handle.sends, hasLength(1));
  });

  test('with a response format, a message goes without it while some tool '
      'has execute; tool responses keep it', () async {
    final handle = _Handle();
    final conversation = _conversation(handle, [
      _tool('t', []),
    ], responseFormat: ResponseFormat.json(const {'type': 'object'}));
    unawaited(conversation.sendMessage(Message.user('x')));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_call('t'))
      ..finished();
    await pumpEventQueue();
    expect(handle.options.map((o) => o.unconstrained), [true, false]);
  });

  test('the response format stays on every message without automatic tools, '
      'and on a tool response the caller sends', () async {
    for (final (tools, automatic, message) in [
      ([Tool(name: 'manual')], true, Message.user('x')),
      ([_tool('t', [])], false, Message.user('x')),
      (
        [_tool('t', [])],
        true,
        Message.tool([const Content.toolResponse('t', 1)]),
      ),
    ]) {
      final handle = _Handle();
      final conversation = _conversation(
        handle,
        tools,
        automatic: automatic,
        responseFormat: ResponseFormat.json(const {'type': 'object'}),
      );
      conversation.sendMessageStream(message).listen((_) {});
      await pumpEventQueue();
      expect(handle.options.single.unconstrained, isFalse);
    }
  });

  test(
    'without a tool with execute every reply reaches the caller as today',
    () async {
      final handle = _Handle();
      final conversation = _conversation(handle, [Tool(name: 'manual')]);
      final reply = conversation.sendMessageStream(Message.user('x')).toList();
      await pumpEventQueue();
      handle.sends.single
        ..chunk(_call('ghost'))
        ..chunk(_text('after'))
        ..finished();
      final pieces = await reply;
      expect(pieces.first.toolCalls.single.name, 'ghost');
      expect(pieces.last.text, 'after');
      expect(handle.sends, hasLength(1));
    },
  );

  group('over a virtual handle', () {
    test(
      'a stop during round 2 keeps the round-1 exchange, the tool results '
      'and the partial answer in the history the next message replays',
      () async {
        final client = LiteRtLmFfiClient();
        final seeds = <String?>[];
        final sends = <NativeTurnStream<Pointer<LiteRtLmConversation>>>[];
        client
          ..virtualCreateForTest = (history) async {
            seeds.add(history);
            final c = Pointer<LiteRtLmConversation>.fromAddress(
              0x7000 + 16 * seeds.length,
            );
            client.registerLiveForTest(c);
            return c;
          }
          ..virtualSendForTest = (c) {
            final send = client.newTurnForTest(c);
            sends.add(send);
            return send;
          };
        final handle = VirtualConversationHandle(
          client: client,
          systemMessage: null,
          toolsJson: null,
          sampling: const Sampler(
            temperature: 1,
            topK: 40,
            topP: 0.95,
            randomSeed: 1,
          ),
          samplingExplicit: false,
          multimodalOrder: MediaOrder.imagesAudioText,
          filterChannelContent: false,
          toolCallsOf: nativeToolCalls,
          freshConversationEachTurn: true,
        );
        final conversation = conversationForTest(
          handle,
          config: ConversationConfig(
            tools: [
              Tool(name: 'weather', execute: (_) => {'temp': 25}),
            ],
          ),
        );
        Future<void> waitForSends(int n) async {
          for (var i = 0; sends.length < n && i < 200; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(sends, hasLength(n));
        }

        final reply = conversation
            .sendMessageStream(Message.user('hi'))
            .toList();
        await waitForSends(1);
        sends.last
          ..chunk(_call('weather', {'city': 'London'}))
          ..finished();
        await waitForSends(2);
        sends.last.chunk(_text('It is'));
        await Future<void>.delayed(Duration.zero);
        conversation.cancel();
        sends.last.cancelled();
        expect((await reply).map((m) => m.text), ['It is']);

        final next = conversation.sendMessage(Message.user('thanks'));
        await waitForSends(3);
        sends.last
          ..chunk(_text('ok'))
          ..finished();
        expect((await next).text, 'ok');
        final replayed = jsonDecode(seeds.last!) as List<Object?>;
        expect(
          [for (final m in replayed) (m as Map)['role']],
          ['user', 'assistant', 'tool', 'assistant'],
          reason: '$replayed',
        );
        final call = (replayed[1] as Map)['tool_calls'] as List<Object?>;
        expect(jsonEncode(call), contains('London'));
        expect(jsonEncode(replayed[2]), contains('"temp":25'));
        expect(jsonEncode(replayed[3]), contains('It is'));
        await conversation.close();
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });
}

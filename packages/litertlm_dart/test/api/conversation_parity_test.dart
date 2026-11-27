// The Kotlin/Swift Conversation members litertlm_dart 0.20.0 maps one to
// one, over a fake handle: what each send hands the native layer (an
// explicit ToolChoice.auto, a tool choice beside a response format, a
// message's own output cap, the conversation's visual token budget), tool
// call ids both ways, and the calls that read a conversation's own state
// (token count, rendering, clone).
import 'dart:async';
import 'dart:convert';

import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

/// A handle whose native side the test plays: each send is a real
/// [NativeTurnStream], and the test posts its chunks and its end.
class _Handle implements ConversationHandle {
  final turns = NativeTurns<String>(cancelNative: (_) {}, deleteNative: (_) {});
  final sends = <NativeTurnStream<String>>[];
  final messages = <Map<String, Object?>>[];
  final options = <SendOptions>[];

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
  void cancelGeneration() {}

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

/// A handle that can read its own state: what it was asked, and what it
/// answers.
class _StateHandle extends _Handle implements ConversationStateAccess {
  final rendered = <String>[];
  final clones = <_StateHandle>[];

  @override
  Future<int> kvTokenCount() async => 42;

  @override
  Future<String> renderMessage(String messageJson) async {
    rendered.add(messageJson);
    return '<user>$messageJson';
  }

  @override
  Future<String> renderPreface() async => '<preface>';

  @override
  Future<ConversationHandle> cloneHandle() async {
    final clone = _StateHandle();
    clones.add(clone);
    return clone;
  }
}

String _text(String t) => jsonEncode({
  'role': 'assistant',
  'content': [
    {'type': 'text', 'text': t},
  ],
});

/// Sends [message] and plays one reply of [text].
Future<void> _reply(
  _Handle handle,
  Conversation conversation,
  Stream<Message> Function() send, [
  String text = 'ok',
]) async {
  final reply = send().toList();
  await pumpEventQueue();
  handle.sends.last
    ..chunk(_text(text))
    ..finished();
  await reply;
}

void main() {
  group('ToolChoice', () {
    test('auto is sent as an explicit "auto"; no choice sends none', () async {
      final handle = _Handle();
      final conversation = conversationForTest(
        handle,
        config: ConversationConfig(tools: [Tool(name: 'weather')]),
      );
      await _reply(
        handle,
        conversation,
        () => conversation.sendMessageStream(
          Message.user('hi'),
          toolChoice: ToolChoice.auto,
        ),
      );
      await _reply(
        handle,
        conversation,
        () => conversation.sendMessageStream(Message.user('again')),
      );
      expect(handle.options[0].toolChoiceJson, '"auto"');
      expect(jsonDecode(handle.options[0].toolChoiceJson!), 'auto');
      expect(handle.options[1].toolChoiceJson, isNull);
    });

    test('beside a response format, a choice goes with a send that carries '
        'no format (automatic tools pending) and is refused on one that '
        'does', () async {
      final format = ResponseFormat.json(const {'type': 'object'});
      // Automatic tools: the user message goes without the format, so the
      // choice applies, as in Kotlin and Swift.
      final handle = _Handle();
      final automatic = conversationForTest(
        handle,
        config: ConversationConfig(
          tools: [Tool(name: 'weather', execute: (_) => 'sunny')],
          responseFormat: format,
        ),
      );
      await _reply(
        handle,
        automatic,
        () => automatic.sendMessageStream(
          Message.user('hi'),
          toolChoice: ToolChoice.required,
        ),
      );
      expect(handle.options.single.unconstrained, isTrue);
      expect(handle.options.single.toolChoiceJson, '"required"');

      // No automatic tools: the send carries the format, and native would
      // ignore the choice beside it.
      final manual = conversationForTest(
        _Handle(),
        config: ConversationConfig(
          tools: [Tool(name: 'weather')],
          responseFormat: format,
        ),
      );
      await expectLater(
        manual.sendMessageStream(
          Message.user('hi'),
          toolChoice: ToolChoice.required,
        ),
        emitsError(isA<ArgumentError>()),
      );
    });
  });

  test("a message's maxOutputTokens goes with each of its sends, tool "
      'rounds included; below 1 is an ArgumentError', () async {
    final handle = _Handle();
    final conversation = conversationForTest(
      handle,
      config: ConversationConfig(
        maxOutputTokens: 500,
        tools: [Tool(name: 'step', execute: (_) => 1)],
      ),
    );
    final reply = conversation.sendMessage(
      Message.user('go'),
      maxOutputTokens: 12,
    );
    await pumpEventQueue();
    handle.sends.last
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {'name': 'step', 'arguments': <String, Object?>{}},
            },
          ],
        }),
      )
      ..finished();
    await pumpEventQueue();
    handle.sends.last
      ..chunk(_text('done'))
      ..finished();
    await reply;
    expect(handle.options.map((o) => o.maxOutputTokens), [12, 12]);
    await _reply(
      handle,
      conversation,
      () => conversation.sendMessageStream(Message.user('plain')),
    );
    expect(handle.options.last.maxOutputTokens, isNull);
    expect(
      () =>
          conversation.sendMessageStream(Message.user('x'), maxOutputTokens: 0),
      throwsArgumentError,
    );
  });

  test("the conversation's visual token budget goes with every send", () async {
    final handle = _Handle();
    final conversation = conversationForTest(
      handle,
      config: ConversationConfig(visualTokenBudget: 70),
    );
    await _reply(
      handle,
      conversation,
      () => conversation.sendMessageStream(Message.user('look')),
    );
    expect(handle.options.single.visualTokenBudget, 70);
    expect(() => ConversationConfig(visualTokenBudget: 0), throwsArgumentError);
    expect(
      () => EngineConfig(modelPath: 'm', visualTokenBudget: -1),
      throwsArgumentError,
    );
    expect(() => ConversationConfig(chatTemplate: ''), throwsArgumentError);
  });

  group('tool call ids', () {
    test("a reply's call id is read, and the automatic response carries "
        'it', () async {
      final handle = _Handle();
      final seen = <ToolCall>[];
      final conversation = conversationForTest(
        handle,
        config: ConversationConfig(
          tools: [Tool(name: 'weather', execute: (_) => 'sunny')],
          automaticToolCalling: false,
        ),
      );
      final reply = conversation.sendMessageStream(Message.user('hi')).toList();
      await pumpEventQueue();
      handle.sends.last
        ..chunk(
          jsonEncode({
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'call_7',
                'type': 'function',
                'function': {
                  'name': 'weather',
                  'arguments': {'city': 'Oslo'},
                },
              },
            ],
          }),
        )
        ..finished();
      for (final piece in await reply) {
        seen.addAll(piece.toolCalls);
      }
      expect(seen.single.id, 'call_7');

      final automatic = _Handle();
      final auto = conversationForTest(
        automatic,
        config: ConversationConfig(
          tools: [Tool(name: 'weather', execute: (_) => 'sunny')],
        ),
      );
      final done = auto.sendMessage(Message.user('hi'));
      await pumpEventQueue();
      automatic.sends.last
        ..chunk(
          jsonEncode({
            'role': 'assistant',
            'tool_calls': [
              {
                'id': 'call_8',
                'type': 'function',
                'function': {'name': 'weather', 'arguments': '{}'},
              },
            ],
          }),
        )
        ..finished();
      await pumpEventQueue();
      expect(automatic.messages.last, {
        'role': 'tool',
        'content': [
          {
            'type': 'tool_response',
            'name': 'weather',
            'response': 'sunny',
            'id': 'call_8',
          },
        ],
      });
      automatic.sends.last
        ..chunk(_text('Sunny'))
        ..finished();
      await done;
    });

    test('an id is written back as Swift writes it; none is left out', () {
      final json = messageJson(
        Message(
          role: Role.model,
          toolCalls: [
            ToolCall('a', const {}, id: 'x1'),
            ToolCall('b', const {}),
          ],
        ),
      );
      final calls = json['tool_calls']! as List<Object?>;
      expect((calls[0]! as Map)['id'], 'x1');
      expect((calls[1]! as Map).containsKey('id'), isFalse);
      expect(
        messageJson(
          Message.tool([
            const Content.toolResponse('a', 1, id: 'x1'),
            const Content.toolResponse('b', 2),
          ]),
        )['content'],
        [
          {'type': 'tool_response', 'name': 'a', 'response': 1, 'id': 'x1'},
          {'type': 'tool_response', 'name': 'b', 'response': 2},
        ],
      );
    });
  });

  group("the conversation's own state", () {
    test('token count, rendering and clone go to the handle', () async {
      final handle = _StateHandle();
      final conversation = conversationForTest(handle);
      expect(await conversation.getTokenCount(), 42);
      expect(await conversation.renderPrefaceIntoString(), '<preface>');
      final rendered = await conversation.renderMessageIntoString(
        Message.user('hi'),
      );
      expect(jsonDecode(handle.rendered.single), {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'hi'},
        ],
      });
      expect(rendered, startsWith('<user>'));
      final clone = await conversation.clone();
      expect(handle.clones, hasLength(1));
      // The clone sends on its own handle.
      await _reply(
        handle.clones.single,
        clone,
        () => clone.sendMessageStream(Message.user('to the clone')),
      );
      expect(handle.clones.single.messages, hasLength(1));
      expect(handle.messages, isEmpty);
    });

    test('a handle without state is an UnsupportedError; a closed '
        'conversation a StateError', () async {
      final plain = conversationForTest(_Handle());
      expect(plain.getTokenCount(), throwsUnsupportedError);
      expect(plain.clone(), throwsUnsupportedError);
      final closed = conversationForTest(_StateHandle());
      await closed.close();
      expect(closed.getTokenCount(), throwsStateError);
    });
  });

  test("Backend.googleTensor, Kotlin's GOOGLE_TENSOR, is refused by name", () {
    expect(
      Backend.googleTensor,
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('Unsupported backend: 4'),
        ),
      ),
    );
  });
}

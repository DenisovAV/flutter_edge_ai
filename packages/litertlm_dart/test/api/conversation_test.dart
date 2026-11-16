// Conversation over a fake handle: what it sends, how a reply streams and
// ends, the two ways to stop it, and the errors it ends with.
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
  final thinking = <bool>[];
  final options = <SendOptions>[];
  int cancels = 0;
  bool closed = false;
  NativeLastTurnEnd? turnEnd;

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) {
    messages.add(jsonDecode(messageJson) as Map<String, Object?>);
    thinking.add(enableThinking);
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
  void close() {
    closed = true;
    for (var i = 0; i < sends.length; i++) {
      turns.release('c$i');
    }
  }

  @override
  Future<int?> tokenCount(String text) async => text.length;

  @override
  BenchmarkInfo getSessionMetrics() => const BenchmarkInfo(outputTokens: 3);

  @override
  NativeLastTurnEnd? get lastTurnEnd => turnEnd;

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

void main() {
  test('a reply streams as messages and ends when native ends it', () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(handle);
    final reply = conversation.sendMessageStream(Message.user('hi')).toList();
    await pumpEventQueue();
    handle.sends.single
      ..chunk(_text('Hel'))
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'channels': {'thought': 'think'},
        }),
      )
      ..chunk(_text('lo'))
      ..finished();
    final pieces = await reply;
    expect(pieces.map((m) => m.text).join(), 'Hello');
    expect(pieces[1].channels, {'thought': 'think'});
    expect(handle.messages.single, {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'hi'},
      ],
    });
    expect(handle.cancels, 0, reason: 'a turn that ended is not stopped');
  });

  test('sendMessage gathers the reply into one message', () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(handle);
    final reply = conversation.sendMessage(Message.user('hi'));
    await pumpEventQueue();
    handle.sends.single
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'channels': {'thought': 'a'},
        }),
      )
      ..chunk(_text('ok'))
      ..chunk(
        jsonEncode({
          'role': 'assistant',
          'tool_calls': [
            {
              'function': {'name': 'f', 'arguments': <String, Object?>{}},
            },
          ],
        }),
      )
      ..finished();
    final message = await reply;
    expect(message.text, 'ok');
    expect(message.channels, {'thought': 'a'});
    expect(message.toolCalls.single.name, 'f');
  });

  test('cancel() stops native and keeps what was generated', () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(handle);
    final reply = conversation.sendMessageStream(Message.user('hi')).toList();
    await pumpEventQueue();
    handle.sends.single.chunk(_text('Par'));
    conversation.cancel();
    handle.sends.single.cancelled();
    expect((await reply).map((m) => m.text), ['Par']);
    expect(handle.cancels, 1);
  });

  test('cancelling the subscription stops native, and its future completes '
      'once native has ended the turn', () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(handle);
    final seen = <String>[];
    final subscription = conversation
        .sendMessageStream(Message.user('hi'))
        .listen((m) => seen.add(m.text));
    await pumpEventQueue();
    handle.sends.single.chunk(_text('Par'));
    await pumpEventQueue();
    var cancelDone = false;
    final cancelled = subscription.cancel().then((_) => cancelDone = true);
    await pumpEventQueue();
    expect(handle.cancels, 1);
    expect(cancelDone, isFalse, reason: 'native has not ended the turn yet');
    handle.sends.single.cancelled();
    await cancelled;
    expect(seen, ['Par']);
  });

  test('one reply at a time; a cancelled one does not hold the next', () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(handle);
    final first = conversation
        .sendMessageStream(Message.user('a'))
        .listen((_) {});
    await pumpEventQueue();
    expect(
      () => conversation.sendMessageStream(Message.user('b')),
      throwsStateError,
    );
    unawaited(first.cancel());
    // Allowed at once: the handle makes it wait for the stopped turn.
    conversation.sendMessageStream(Message.user('b')).listen((_) {});
    handle.sends.first.cancelled();
    await pumpEventQueue();
    expect(handle.messages, hasLength(2));
  });

  test("the message's options reach the send; extraContext merges over the "
      "conversation's", () async {
    final handle = _Handle();
    final conversation = Conversation.forTest(
      handle,
      config: ConversationConfig(
        extraContext: const {'a': 1, 'b': 1},
        thinkingConfig: ThinkingConfig(thinkingTokenBudget: 64),
      ),
    );
    final penalty = RepetitionPenaltyConfig(repetitionPenalty: 1.3);
    final ngram = NoRepeatNgramConfig(noRepeatNgramSize: 3);
    conversation
        .sendMessageStream(
          Message.user('x'),
          extraContext: const {'b': 2},
          repetitionPenaltyConfig: penalty,
          noRepeatNgramConfig: ngram,
          suppressTokens: const [5, 6],
        )
        .listen((_) {});
    await pumpEventQueue();
    final sent = handle.options.single;
    expect(sent.extraContext, {'a': 1, 'b': 2});
    expect(sent.repetitionPenalty, same(penalty));
    expect(sent.noRepeatNgram, same(ngram));
    expect(sent.suppressTokens, [5, 6]);
    expect(sent.thinkingTokenBudget, 64);
    expect(handle.thinking.single, isTrue);
  });

  test(
    'a message overrides the thinking config; off sends no budget',
    () async {
      final handle = _Handle();
      final conversation = Conversation.forTest(
        handle,
        config: ConversationConfig(
          thinkingConfig: ThinkingConfig(thinkingTokenBudget: 64),
        ),
      );
      conversation
          .sendMessageStream(
            Message.user('x'),
            thinkingConfig: ThinkingConfig(enableThinking: false),
          )
          .listen((_) {});
      await pumpEventQueue();
      expect(handle.thinking.single, isFalse);
      expect(handle.options.single.thinkingTokenBudget, isNull);
    },
  );

  test('a response format with a thinking budget is refused before a send', () {
    final handle = _Handle();
    final conversation = Conversation.forTest(
      handle,
      config: ConversationConfig(
        responseFormat: ResponseFormat.json(const {'type': 'string'}),
        thinkingConfig: ThinkingConfig(thinkingTokenBudget: 64),
      ),
    );
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsA(isA<ConstraintUnsupportedException>()),
    );
    expect(handle.messages, isEmpty);
  });

  group('how a send ends', () {
    Future<Object?> errorOf(
      void Function(_Handle handle, NativeTurnStream<String> send) end,
    ) async {
      final handle = _Handle();
      final conversation = Conversation.forTest(handle);
      final reply = conversation.sendMessageStream(Message.user('x')).toList();
      await pumpEventQueue();
      end(handle, handle.sends.single);
      try {
        await reply;
        return null;
      } catch (e) {
        return e;
      }
    }

    test('closed while streaming: ConversationClosedException', () async {
      expect(
        await errorOf((handle, send) {
          handle.close();
          send.cancelled();
        }),
        isA<ConversationClosedException>(),
      );
    });

    test('cancelled by nobody: TurnFailedException', () async {
      expect(
        await errorOf((_, send) => send.cancelled()),
        isA<TurnFailedException>(),
      );
    });

    test('a message that did not fit: ContextFullException', () async {
      expect(
        await errorOf((handle, send) {
          handle.turnEnd = NativeLastTurnEnd.contextFull;
          send.failed(Exception('native token counts'));
        }),
        isA<ContextFullException>().having(
          (e) => e.message,
          'message',
          contains('native token counts'),
        ),
      );
    });

    test('any other failure as it came', () async {
      expect(
        await errorOf((_, send) => send.failed(const FormatException('x'))),
        isA<FormatException>(),
      );
    });
  });

  test('the last turn end, metrics, token count and close', () async {
    final handle = _Handle()..turnEnd = NativeLastTurnEnd.outputLimit;
    final conversation = Conversation.forTest(handle);
    expect(conversation.lastTurnEnd, TurnEnd.outputLimit);
    handle.turnEnd = NativeLastTurnEnd.none;
    expect(conversation.lastTurnEnd, isNull);
    expect(conversation.getBenchmarkInfo().outputTokens, 3);
    expect(await conversation.countTokens('four'), 4);
    await conversation.close();
    expect(handle.closed, isTrue);
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsStateError,
    );
  });
}

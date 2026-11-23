// How a web conversation stops and recovers, over the stub runtime
// (web_runtime_stub.dart), which does what @litert-lm/core 0.18.0 and 0.19.0 were
// measured to do: a stop mid-reply rejects the stream and leaves the runtime
// conversation refusing every later send, so the next message goes to one
// rebuilt from the preface, the exchanges so far and `getHistory()` (which
// holds no preface); a stop with nothing in flight or after the last chunk
// changes nothing.
//
// Run: dart test -p chrome test/web/web_conversation_stop_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_conversation_stop_browser_test.dart
@TestOn('browser')
library;

import 'dart:convert';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

final _tool = Tool(name: 'f', description: 'd', parameters: {'type': 'object'});

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  group('the rebuilt conversation', () {
    late web.Engine engine;
    setUp(() async => engine = await webEngine());
    tearDown(() => engine.close());

    test('keeps the system instruction, the initial messages and the tools, '
        'each once, then the exchanges and the stopped one', () async {
      final conversation = await engine.createConversation(
        ConversationConfig(
          systemInstruction: 'Be brief.',
          initialMessages: [Message.user('Earlier'), Message.model('Yes')],
          tools: [_tool],
        ),
      );
      await exchange(conversation, 'One', 'Uno');
      await stoppedExchange(conversation, 'Two', 'Do');

      await exchange(conversation, 'Three', 'Tres');

      expect(prefaceMessages(1), [
        {'role': 'system', 'content': 'Be brief.'},
        userPart('Earlier'),
        assistantPart('Yes'),
        {'role': 'user', 'content': 'One'},
        assistantPart('Uno'),
        userPart('Two'),
        assistantPart('Do'),
      ]);
      final options = asMap(list('conversationOptions')[1]);
      expect(asMap(options['preface'])['tools'], hasLength(1));
    });

    test('after a second stop holds every exchange exactly once', () async {
      final conversation = await engine.createConversation(
        ConversationConfig(systemInstruction: 'Be brief.'),
      );
      await exchange(conversation, 'One', 'Uno');
      await stoppedExchange(conversation, 'Two', 'Do');
      await exchange(conversation, 'Three', 'Tres');
      await stoppedExchange(conversation, 'Four', 'Cua');

      await exchange(conversation, 'Five', 'Cinco');

      expect(list('conversationOptions'), hasLength(3));
      expect(prefaceMessages(2), [
        {'role': 'system', 'content': 'Be brief.'},
        {'role': 'user', 'content': 'One'},
        assistantPart('Uno'),
        userPart('Two'),
        assistantPart('Do'),
        {'role': 'user', 'content': 'Three'},
        assistantPart('Tres'),
        userPart('Four'),
        assistantPart('Cua'),
      ]);
    });

    test(
      'an exchange that repeats one replayed earlier is replayed again',
      () async {
        final conversation = await engine.createConversation();
        await exchange(conversation, 'One', 'Uno');
        await stoppedExchange(conversation, 'Gone', '');
        await exchange(conversation, 'One', 'Uno');
        await stoppedExchange(conversation, 'Gone again', '');

        await exchange(conversation, 'Two', 'Dos');

        expect(prefaceMessages(2), [
          {'role': 'user', 'content': 'One'},
          assistantPart('Uno'),
          {'role': 'user', 'content': 'One'},
          assistantPart('Uno'),
        ]);
      },
    );

    test('a stop mid tool call, with no text yet, keeps the message and '
        'the call, as natively', () async {
      final conversation = await engine.createConversation(
        ConversationConfig(tools: [_tool]),
      );
      final stopped = conversation
          .sendMessageStream(Message.user('Call f'))
          .drain<void>();
      await settle();
      js(
        '__chunk',
        '{"role":"assistant","tool_calls":[{"type":"function",'
            '"function":{"name":"f","arguments":{}}}]}',
      );
      await settle();
      conversation.cancel();
      await stopped;

      await exchange(conversation, 'Next', 'Ok');

      expect(prefaceMessages(1), [
        userPart('Call f'),
        {
          'role': 'assistant',
          'tool_calls': [
            {
              'type': 'function',
              'function': {'name': 'f', 'arguments': <String, Object?>{}},
            },
          ],
        },
      ]);
    });

    test('a stop keeps a call the engine\'s toolCallsOf reads in the reply\'s '
        'text', () async {
      final reading = await web.createWebEngine(
        webConfig(),
        pageLock: web.LiteRtLmPageLock(),
        toolCallsOf: (raw) => [
          if (raw.contains('<call g>')) (name: 'g', arguments: {'n': 1}),
        ],
      );
      final conversation = await reading.createConversation(
        ConversationConfig(tools: [_tool]),
      );
      await stoppedExchange(conversation, 'Call g', '<call g>');

      await exchange(conversation, 'Next', 'Ok');

      expect(prefaceMessages(1)!.last, {
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {
              'name': 'g',
              'arguments': {'n': 1},
            },
          },
        ],
      });
      await reading.close();
    });

    test('a tool-call reader that throws keeps the stopped turn\'s text, and '
        'the turn after it is answered', () async {
      final throwing = await web.createWebEngine(
        webConfig(),
        pageLock: web.LiteRtLmPageLock(),
        toolCallsOf: (_) => throw StateError('bad reader'),
      );
      final conversation = await throwing.createConversation(
        ConversationConfig(tools: [_tool]),
      );
      final stopped = conversation
          .sendMessageStream(Message.user('Call f'))
          .drain<void>();
      await settle();
      js(
        '__chunk',
        '{"role":"assistant","tool_calls":[{"type":"function",'
            '"function":{"name":"f","arguments":{}}}]}',
      );
      await settle();
      conversation.cancel();
      await stopped;

      await exchange(conversation, 'Next', 'Ok');

      expect(prefaceMessages(1), [userPart('Call f'), assistantPart('')]);
      await throwing.close();
    });

    test('a stop after text and a tool call keeps the call, not the text, '
        'as natively', () async {
      final conversation = await engine.createConversation(
        ConversationConfig(tools: [_tool]),
      );
      final stopped = conversation
          .sendMessageStream(Message.user('Call f'))
          .drain<void>();
      await settle();
      js('__step', 'Let me check.');
      js(
        '__chunk',
        '{"role":"assistant","tool_calls":[{"type":"function",'
            '"function":{"name":"f","arguments":{}}}]}',
      );
      await settle();
      conversation.cancel();
      await stopped;

      await exchange(conversation, 'Next', 'Ok');

      expect(prefaceMessages(1)!.last, {
        'role': 'assistant',
        'tool_calls': [
          {
            'type': 'function',
            'function': {'name': 'f', 'arguments': <String, Object?>{}},
          },
        ],
      });
    });

    test('a stop before any chunk keeps nothing of the stopped turn', () async {
      final conversation = await engine.createConversation();
      final stopped = conversation
          .sendMessageStream(Message.user('Gone'))
          .drain<void>();
      await settle();
      conversation.cancel();
      await stopped;

      await exchange(conversation, 'Next', 'Ok');

      expect(prefaceMessages(1), isNull);
    });
  });

  test('a stop after thoughts only keeps the message with an empty reply, '
      'as natively', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation(
      ConversationConfig(thinkingConfig: ThinkingConfig()),
    );
    final stopped = conversation
        .sendMessageStream(
          Message.user('Why?'),
          thinkingConfig: ThinkingConfig(),
        )
        .drain<void>();
    await settle();
    js('__chunk', '{"role":"assistant","channels":{"thought":"Hmm"}}');
    await settle();
    conversation.cancel();
    await stopped;

    final next = conversation
        .sendMessageStream(Message.user('Ok'), thinkingConfig: ThinkingConfig())
        .drain<void>();
    await settle();
    js('__end');
    await next;

    expect(prefaceMessages(1), [userPart('Why?'), assistantPart('')]);
    await engine.close();
  });

  test(
    'a stop during thinking keeps the reply\'s text, not its thoughts',
    () async {
      final engine = await webEngine();
      final conversation = await engine.createConversation(
        ConversationConfig(thinkingConfig: ThinkingConfig()),
      );
      final stopped = conversation
          .sendMessageStream(
            Message.user('Why?'),
            thinkingConfig: ThinkingConfig(),
          )
          .drain<void>();
      await settle();
      js('__chunk', '{"role":"assistant","channels":{"thought":"Hmm"}}');
      js('__step', 'Because');
      await settle();
      conversation.cancel();
      await stopped;

      final next = conversation
          .sendMessageStream(
            Message.user('Ok'),
            thinkingConfig: ThinkingConfig(),
          )
          .drain<void>();
      await settle();
      js('__end');
      await next;

      expect(prefaceMessages(1), [userPart('Why?'), assistantPart('Because')]);
      await engine.close();
    },
  );

  group('after a turn the runtime failed', () {
    late web.Engine engine;
    late Conversation conversation;
    setUp(() async {
      engine = await webEngine();
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    Future<void> failedTurn(String text) async {
      final failed = conversation
          .sendMessageStream(Message.user(text))
          .drain<void>()
          .catchError((Object _) {});
      await settle();
      js('__fail', 'generation failed');
      await failed;
    }

    test('the next message goes to a conversation rebuilt without the '
        'failed message, and is answered', () async {
      await exchange(conversation, 'One', 'Uno');
      await failedTurn('Broken');

      await exchange(conversation, 'Two', 'Dos');

      expect(prefaceMessages(1), [
        {'role': 'user', 'content': 'One'},
        assistantPart('Uno'),
      ]);
      expect(list('sent').last, 'Two');
    });

    test('a rebuild after it names the failed turn when it fails', () async {
      await failedTurn('Broken');
      setOnPage('conversationErrorAfter', 1);

      await expectLater(
        conversation.sendMessageStream(Message.user('Two')),
        emitsError(
          isA<TurnFailedException>().having(
            (e) => '${web.turnFailureCause(e)}',
            'cause',
            contains('Could not rebuild the conversation after a failed turn'),
          ),
        ),
      );
    });

    test('a failed message already left out is not left out of a later '
        'rebuild', () async {
      await failedTurn('Note');
      await exchange(conversation, 'Two', 'Dos');
      setOnPage('historyTail', [
        {'role': 'user', 'content': 'Note'},
      ]);
      await stoppedExchange(conversation, 'Three', 'Tr');

      await exchange(conversation, 'Four', 'Cuatro');

      expect(
        prefaceMessages(2),
        contains(equals({'role': 'user', 'content': 'Note'})),
      );
    });

    test('a rebuild after a stop before any chunk names the stop when it '
        'fails, also after an earlier failed turn', () async {
      await failedTurn('Broken');
      await exchange(conversation, 'Two', 'Dos');
      final stopped = conversation
          .sendMessageStream(Message.user('Three'))
          .drain<void>();
      await settle();
      conversation.cancel();
      await stopped;
      setOnPage('conversationErrorAfter', 2);

      await expectLater(
        conversation.sendMessageStream(Message.user('Four')),
        emitsError(
          isA<TurnFailedException>().having(
            (e) => '${web.turnFailureCause(e)}',
            'cause',
            contains(
              'Could not rebuild the conversation after a stopped reply',
            ),
          ),
        ),
      );
    });

    test('only the failed message is left out of the rebuild, not another '
        'message at the end of the history', () async {
      await exchange(conversation, 'One', 'Uno');
      setOnPage('historyTail', [
        {'role': 'user', 'content': 'Note'},
      ]);
      await stoppedExchange(conversation, 'Two', 'Do');

      await exchange(conversation, 'Three', 'Tres');

      expect(
        prefaceMessages(1),
        contains(equals({'role': 'user', 'content': 'Note'})),
      );
    });

    test('a stop after the last chunk records no stopped exchange: a failed '
        'turn after it rebuilds with that exchange once', () async {
      final stopped = conversation
          .sendMessageStream(Message.user('One'))
          .drain<void>();
      await settle();
      js('__step', 'Uno');
      js('__generated');
      await settle();
      conversation.cancel();
      await stopped;
      await failedTurn('Broken');

      await exchange(conversation, 'Two', 'Dos');

      expect(prefaceMessages(1), [
        {'role': 'user', 'content': 'One'},
        assistantPart('Uno'),
      ]);
    });
  });

  group('a stop that changes nothing in the runtime', () {
    late web.Engine engine;
    late Conversation conversation;
    setUp(() async {
      engine = await webEngine();
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    test('with nothing in flight: the runtime is not asked, and the next '
        'message goes to the same conversation', () async {
      conversation.cancel();

      await exchange(conversation, 'One', 'Uno');

      expect(count('cancels'), 0);
      expect(list('conversationOptions'), hasLength(1));
      expect(list('sent'), ['One']);
    });

    test('after the last chunk: the reply ends, and the next message goes '
        'to the same conversation with no exchange added twice', () async {
      final pieces = <Message>[];
      final reply = conversation
          .sendMessageStream(Message.user('One'))
          .forEach(pieces.add);
      await settle();
      js('__step', 'Uno');
      js('__generated');
      await settle();
      conversation.cancel();
      await reply;

      await exchange(conversation, 'Two', 'Dos');

      expect(pieces.single.text, 'Uno');
      expect(count('cancels'), 1);
      expect(list('conversationOptions'), hasLength(1));
      expect(list('sent'), ['One', 'Two']);
    });
  });

  group('a stream that rejects', () {
    test('keeps the page until a call on the executor mutex has run', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final conversation = await engine.createConversation();
      setOnPage('holdFence', true);
      final reply = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();
      var entered = false;
      final other = lock.acquire().then((lease) {
        entered = true;
        lease.release();
      });

      js('__fail', 'generation failed');
      await settle();

      expect(count('tokenCounts'), 1);
      expect(entered, isFalse, reason: 'let go before the module did');
      js('__releaseFences');
      await other;
      expect(await reply, errorWith<TurnFailedException>('generation failed'));
      setOnPage('holdFence', false);
      await engine.close();
    });

    test('makes the next message rebuild the conversation', () async {
      final engine = await webEngine();
      final conversation = await engine.createConversation();
      final failed = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .catchError((Object _) {});
      await settle();
      js('__fail', 'generation failed');
      await failed;

      await exchange(conversation, 'Again', 'Ok');

      expect(list('conversationOptions'), hasLength(2));
      await engine.close();
    });
  });

  group('a full context window', () {
    late web.Engine engine;
    late Conversation conversation;
    setUp(() async {
      engine = await webEngine();
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    web.NativeLastTurnEnd? lastEnd() =>
        web.conversationHandle(conversation).lastTurnEnd;

    /// Sends [text] and has the runtime refuse it for its size, as [how]
    /// (`__tooLong` or `__contextFull`).
    Future<Object?> refused(String text, String how) async {
      final reply = conversation
          .sendMessageStream(Message.user(text))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();
      js(how);
      return reply;
    }

    test('a message too long for the room left is a ContextFullException, '
        'and the turn ends at the context limit', () async {
      expect(
        await refused('Long', '__tooLong'),
        errorWith<ContextFullException>('Send a shorter message'),
      );
      expect(lastEnd(), web.NativeLastTurnEnd.contextFull);
    });

    test('the next, shorter message goes to a conversation rebuilt without '
        'the refused one, and is answered', () async {
      await exchange(conversation, 'One', 'Uno');
      await refused('Long', '__tooLong');

      await exchange(conversation, 'Short', 'Ok');

      expect(prefaceMessages(1), [
        {'role': 'user', 'content': 'One'},
        assistantPart('Uno'),
      ]);
      expect(list('sent').last, 'Short');
      expect(lastEnd(), isNull);
    });

    test('a message refused while the history fills the window ends the '
        'conversation: every later message fails without being sent', () async {
      setOnPage('tokenCount', 4096);
      expect(
        await refused('Long', '__contextFull'),
        errorWith<ContextFullException>(
          'The context window of this conversation is full',
        ),
      );

      await expectLater(
        conversation.sendMessageStream(Message.user('Short')),
        emitsError(errorWith<ContextFullException>('Open a new conversation')),
      );
      expect(lastEnd(), web.NativeLastTurnEnd.contextFull);
      expect(list('sent'), ['Long']);
      expect(list('conversationOptions'), hasLength(1));
    });

    test('a rebuilt conversation whose replayed history fills the window '
        'ends at its first refusal, though it counts nothing yet', () async {
      await stoppedExchange(conversation, 'One', 'Un');
      setOnPage('tokenCount', 4096);
      final reply = conversation
          .sendMessageStream(Message.user('Two'))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();
      // The runtime prefills a preface only at the first send (N5).
      setOnPage('tokenCount', 0);
      js('__tooLong');

      expect(await reply, errorWith<ContextFullException>('is full'));
      await expectLater(
        conversation.sendMessageStream(Message.user('Three')),
        emitsError(errorWith<ContextFullException>('is full')),
      );
      expect(list('sent'), ['One', 'Two']);
    });

    test('a rebuild the runtime refuses for it is a ContextFullException, '
        'and so is every later message', () async {
      await stoppedExchange(conversation, 'One', 'Un');
      setOnPage(
        'conversationError',
        'Max number of tokens reached, the context window is full.',
      );

      await expectLater(
        conversation.sendMessageStream(Message.user('Two')),
        emitsError(
          errorWith<ContextFullException>('Max number of tokens reached'),
        ),
      );
      setOnPage('conversationError', null);
      await expectLater(
        conversation.sendMessageStream(Message.user('Three')),
        emitsError(
          errorWith<ContextFullException>(
            'The context window of this conversation is full',
          ),
        ),
      );
      expect(list('conversationOptions'), hasLength(2));
    });

    test('a turn queued on the handle while the window filled fails without '
        'being sent', () async {
      setOnPage('tokenCount', 4096);
      final handle = web.conversationHandle(conversation);
      final first = handle
          .chatRawMessage(jsonEncode(userPart('Long')))
          .drain<void>()
          .catchError((Object _) {});
      final second = expectLater(
        handle.chatRawMessage(jsonEncode(userPart('Short'))),
        emitsError(errorWith<ContextFullException>('is full')),
      );
      await settle();
      js('__contextFull');
      await first;
      await second;

      expect(list('sent'), hasLength(1));
    });

    test('a turn that ends normally records no end', () async {
      await exchange(conversation, 'One', 'Uno');

      expect(lastEnd(), isNull);
    });
  });

  group('a rebuild that fails', () {
    late web.Engine engine;
    late Conversation conversation;
    setUp(() async {
      engine = await webEngine();
      conversation = await engine.createConversation();
      await stoppedExchange(conversation, 'One', 'Un');
    });
    tearDown(() => engine.close());

    Matcher failsRebuild(String cause) => emitsError(
      isA<TurnFailedException>().having(
        (e) => '${web.turnFailureCause(e)}',
        'cause',
        allOf(
          contains(cause),
          contains('cannot be used until a rebuild succeeds'),
        ),
      ),
    );

    test('on a history the runtime refuses is a LiteRtLmNativeException '
        'saying the next message tries again', () async {
      setOnPage('historyError', 'History unavailable');

      await expectLater(
        conversation.sendMessageStream(Message.user('Two')),
        failsRebuild('History unavailable'),
      );

      expect(
        web.turnFailureCause(
          await conversation
                  .sendMessageStream(Message.user('Three'))
                  .drain<void>()
                  .then<Object?>((_) => null, onError: (Object e) => e)
              as TurnFailedException,
        ),
        errorWith<LiteRtLmNativeException>('History unavailable'),
      );
    });

    test('on a conversation the runtime refuses to create is a '
        'LiteRtLmNativeException naming its refusal', () async {
      setOnPage('conversationErrorAfter', 1);

      await expectLater(
        conversation.sendMessageStream(Message.user('Two')),
        failsRebuild('Rebuild refused'),
      );
    });

    test('on a history media part of an unknown shape ends the '
        'conversation, naming the part', () async {
      setOnPage('oddMediaInHistory', true);

      await expectLater(
        conversation.sendMessageStream(Message.user('Two')),
        emitsError(
          isA<TurnFailedException>().having(
            (e) => '${web.turnFailureCause(e)}',
            'cause',
            allOf(
              contains('This conversation cannot continue'),
              contains('a blob of an unknown shape'),
              contains('Open a new conversation'),
            ),
          ),
        ),
      );
      setOnPage('oddMediaInHistory', false);
    });

    test('that cannot replay the history fails every later message the '
        'same way, without trying again', () async {
      setOnPage('oddMediaInHistory', true);
      await conversation
          .sendMessageStream(Message.user('Two'))
          .drain<void>()
          .catchError((Object _) {});
      setOnPage('oddMediaInHistory', false);

      await expectLater(
        conversation.sendMessageStream(Message.user('Three')),
        emitsError(
          errorWith<TurnFailedException>('This conversation cannot continue'),
        ),
      );
      expect(list('conversationOptions'), hasLength(1));
      expect(list('sent'), ['One']);
    });

    test('is tried again by the next message, which then goes to the '
        'rebuilt conversation', () async {
      setOnPage('historyError', 'History unavailable');
      await conversation
          .sendMessageStream(Message.user('Two'))
          .drain<void>()
          .catchError((Object _) {});
      setOnPage('historyError', null);

      await exchange(conversation, 'Three', 'Trois');

      expect(list('conversationOptions'), hasLength(2));
      expect(list('sent').last, 'Three');
    });
  });

  test('a close while the conversation is being rebuilt ends the turn as '
      'closed, and deletes the old and the rebuilt conversation', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    await stoppedExchange(conversation, 'One', 'Un');
    setOnPage('holdHistory', true);
    final reply = conversation.sendMessageStream(Message.user('Two'));
    final ended = expectLater(
      reply,
      emitsError(errorWith<ConversationClosedException>('closed')),
    );
    await settle();

    final closing = conversation.close();
    js('__releaseHistories');
    await closing;

    await ended;
    expect(list('sent'), ['One'], reason: 'the turn was sent after the close');
    expect(count('conversationDeletes'), 2);
    await engine.close();
  });

  test('a stop while a rebuild fails ends the turn as stopped and logs the '
      'rebuild\'s failure', () async {
    final logged = <String>[];
    final saved = web.runtimeLogSink;
    web.runtimeLogSink = (message, {verbose = false}) => logged.add(message);
    addTearDown(() => web.runtimeLogSink = saved);
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    await stoppedExchange(conversation, 'One', 'Un');
    setOnPage('holdHistory', true);
    setOnPage('conversationErrorAfter', 1);
    final reply = conversation
        .sendMessageStream(Message.user('Two'))
        .drain<void>();
    await settle();

    conversation.cancel();
    js('__releaseHistories');
    await reply;

    expect(
      logged,
      contains(
        contains('Could not rebuild the conversation after a stopped reply'),
      ),
    );
    await engine.close();
  });

  group('a stopped generation that never ends', () {
    late Duration saved;
    setUp(() {
      saved = web.WebConversationHandle.drainTimeout;
      web.WebConversationHandle.drainTimeout = const Duration(
        milliseconds: 100,
      );
      setOnPage('stuckOnCancel', true);
    });
    tearDown(() => web.WebConversationHandle.drainTimeout = saved);

    test('poisons the page after the drain timeout, without a close', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final conversation = await engine.createConversation();
      final reply = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();

      late Object? error;
      final printed = await printsOf(() async {
        conversation.cancel();
        error = await reply; // ends when the drain timer gives up on it
      });

      expect(lock.poison?.message, contains('after it was stopped'));
      expect(printed.single, contains('ERROR'));
      expect(
        error,
        isA<web.LiteRtLmPagePoisonedError>().having(
          (e) => e.message,
          'message',
          contains('after it was stopped'),
        ),
      );
    });

    test('a stream that failed and never leaves the module poisons the page '
        'too', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final conversation = await engine.createConversation();
      setOnPage('holdFence', true);
      final reply = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();

      late Object? error;
      await printsOf(() async {
        js('__fail', 'generation failed');
        error = await reply;
      });

      expect(lock.poison?.message, contains('after its stream failed'));
      expect(
        error,
        errorWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
      );
      setOnPage('holdFence', false);
    });

    test('a close during a rebuild that never ends poisons the page', () async {
      setOnPage('stuckOnCancel', false);
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final conversation = await engine.createConversation();
      await stoppedExchange(conversation, 'One', 'Un');
      setOnPage('holdHistory', true);
      final reply = conversation
          .sendMessageStream(Message.user('Two'))
          .drain<void>()
          .then<Object?>((_) => null, onError: (Object e) => e);
      await settle();

      await printsOf(
        () => expectLater(
          conversation.close(),
          throwsA(
            isA<web.LiteRtLmPagePoisonedError>().having(
              (e) => e.message,
              'message',
              contains('during a rebuild'),
            ),
          ),
        ),
      );

      expect(
        await reply,
        errorWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
      );
    });

    test(
      'ends the reply a caller awaits with the poisoned page, on close',
      () async {
        final lock = web.LiteRtLmPageLock();
        final engine = await webEngine(lock: lock);
        final conversation = await engine.createConversation();
        final reply = conversation
            .sendMessageStream(Message.user('Hello'))
            .drain<void>()
            .then<Object?>((_) => null, onError: (Object e) => e);
        await settle();

        await expectLater(
          conversation.close(),
          throwsA(errorWith<web.LiteRtLmPagePoisonedError>('Reload the page')),
        );

        expect(
          await reply,
          errorWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
        );
      },
    );
  });

  test('a fault while reading a chunk stops the generation, holds the page '
      'until its stream ended, then fails the turn with that fault', () async {
    final lock = web.LiteRtLmPageLock();
    final engine = await webEngine(lock: lock);
    final conversation = await engine.createConversation();
    final reply = conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .then<Object?>((_) => null, onError: (Object e) => e);
    await settle();

    js('__unwritable');
    await settle();

    expect(count('cancels'), 1, reason: 'the generation was not stopped');
    final error = await reply;
    expect(
      error,
      errorWith<TurnFailedException>('litertlm_dart could not read'),
    );
    expect(
      '${web.turnFailureCause(error! as TurnFailedException)}',
      contains('BigInt'),
    );
    expect(lock.poison, isNull);
    await engine.close();
  });

  test('a rebuild after a chunk it could not read names that cause when it '
      'fails', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    final faulted = conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .catchError((Object _) {});
    await settle();
    js('__unwritable');
    await faulted;
    setOnPage('conversationErrorAfter', 1);

    await expectLater(
      conversation.sendMessageStream(Message.user('Again')),
      emitsError(
        isA<TurnFailedException>().having(
          (e) => '${web.turnFailureCause(e)}',
          'cause',
          contains('after a reply litertlm_dart could not read'),
        ),
      ),
    );
    await engine.close();
  });

  test('the message after a stream that could not be read goes to a rebuilt '
      'conversation', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    setOnPage('unreadable', true);
    await conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .catchError((Object _) {});
    setOnPage('unreadable', false);

    await exchange(conversation, 'Again', 'Ok');

    expect(list('conversationOptions'), hasLength(2));
    expect(list('sent').last, 'Again');
    await engine.close();
  });

  test('a stream that cannot be read after the send stops the generation, '
      'waits for it to leave the module, then fails the turn', () async {
    final lock = web.LiteRtLmPageLock();
    final engine = await webEngine(lock: lock);
    final conversation = await engine.createConversation();
    setOnPage('unreadable', true);
    setOnPage('holdFence', true);

    final reply = conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .then<Object?>((_) => null, onError: (Object e) => e);
    await settle();
    var entered = false;
    final other = lock.acquire().then((lease) {
      entered = true;
      lease.release();
    });
    await settle();

    expect(count('cancels'), 1, reason: 'the generation was not stopped');
    expect(entered, isFalse, reason: 'let go before the module did');
    js('__releaseFences');
    await other;
    final error = await reply;
    expect(
      error,
      errorWith<TurnFailedException>('litertlm_dart could not read'),
    );
    expect(
      '${web.turnFailureCause(error! as TurnFailedException)}',
      contains('unreadable stream'),
    );
    setOnPage('unreadable', false);
    setOnPage('holdFence', false);
    await engine.close();
  });

  test('Engine.close with a reply streaming and a create queued behind it '
      'returns once the reply has stopped', () async {
    final lock = web.LiteRtLmPageLock();
    final engine = await webEngine(lock: lock);
    final conversation = await engine.createConversation();
    final reply = conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .catchError((Object _) {});
    await settle();
    final queued = engine.createConversation().then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );

    await engine.close().timeout(const Duration(seconds: 2));

    await reply;
    expect(
      await queued,
      errorWith<StateError>('closed while a conversation opened'),
    );
    expect(count('cancels'), 1);
    expect(count('engineDeletes'), 1);
  });

  test('Conversation.close called twice: the second completes when the '
      'first has', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    setOnPage('holdFence', true);
    final reply = conversation
        .sendMessageStream(Message.user('Hello'))
        .drain<void>()
        .catchError((Object _) {});
    await settle();
    final first = conversation.close();
    var secondDone = false;
    final second = conversation.close().then((_) => secondDone = true);
    await settle();

    expect(secondDone, isFalse, reason: 'returned before the first close');
    js('__releaseFences');
    await first;
    await second;
    await reply;
    await engine.close();
  });
}

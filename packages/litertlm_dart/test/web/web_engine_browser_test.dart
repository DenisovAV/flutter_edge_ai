// The web arm of the public API in a browser, over a stub `@litert-lm/core`
// defined on the page in plain JS: `window.Engine` (with the prototype members
// the release calls) and conversations whose `sendMessageStreaming` returns a
// real `ReadableStream` the test feeds chunk by chunk. The stub does what
// 0.18.0 was measured to do (2026-11-23, web_litertlm_runtime_probe_test.dart):
// `cancel()` rejects the stream with "Task cancelled", and every later send on
// that conversation fails the same way; `getHistory()` holds the completed
// exchanges only; an engine's `delete()` is a Promise, a conversation's
// returns nothing (the typings say Promise, nothing here relies on it).
//
// What it holds: the refusals before the runtime is touched, the settings and
// conversation options handed over, the runtime's errors as typed
// exceptions, how a message is sent, the per-turn stop (a stopped turn ends
// normally however the runtime ends it, a queued one is never sent), the
// rebuild of a stopped conversation from its history, a pump that meets a
// malformed step, close against a create waiting for the page, and a stopped
// generation that never ends poisoning the page.
//
// Run: dart test -p chrome test/web/web_engine_browser_test.dart
//      dart test -p chrome -c dart2wasm test/web/web_engine_browser_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

import 'web_runtime_stub.dart';

void main() {
  setUp(installRuntime);
  tearDown(removeRuntime);

  group('Engine.create', () {
    test('refuses what the web does not run, before touching the runtime', () {
      for (final config in [
        webConfig(backend: const Backend.npu()),
        EngineConfig(modelPath: 'blob:x', visionBackend: const Backend.npu()),
        EngineConfig(modelPath: 'blob:x', audioBackend: const Backend.npu()),
        EngineConfig(modelPath: 'blob:x', cacheDir: '/tmp'),
        EngineConfig(
          modelPath: 'blob:x',
          activationDataType: ActivationDataType.float32,
        ),
        EngineConfig(
          modelPath: 'blob:x',
          speculativeDecoding: SpeculativeDecodingMode.on,
        ),
      ]) {
        expect(
          () => Engine.create(config),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains(web.liteRtLmWebRuntime),
            ),
          ),
        );
      }
      expect(list('createSettings'), isEmpty);
    });

    test('a vision encoder goes to the runtime with one image reserved per '
        'conversation by default, which a GPU_ARTISAN model needs', () async {
      setOnPage('resolvedVisionBackend', 4);
      setOnPage('resolvedAudioBackend', 3);
      final engine = await Engine.create(
        EngineConfig(
          modelPath: 'blob:x',
          backend: const Backend.gpu(),
          visionBackend: const Backend.gpu(),
          audioBackend: const Backend.cpu(),
        ),
      );

      final settings = asMap(list('createSettings').single);
      expect(settings['visionBackend'], 4);
      expect(settings['audioBackend'], 3);
      expect(asMap(settings['mainExecutorSettings'])['maxNumImages'], 1);
      await engine.close();
    });

    test(
      'maxNumImages, when set, is the images a conversation reserves',
      () async {
        setOnPage('resolvedVisionBackend', 4);
        final engine = await Engine.create(
          EngineConfig(
            modelPath: 'blob:x',
            backend: const Backend.gpu(),
            visionBackend: const Backend.gpu(),
            maxNumImages: 3,
          ),
        );

        expect(
          asMap(
            asMap(list('createSettings').single)['mainExecutorSettings'],
          )['maxNumImages'],
          3,
        );
        await engine.close();
      },
    );

    test('an encoder asked for that the runtime does not report is a '
        'LiteRtLmEngineCreateException, and the engine is deleted', () async {
      await expectLater(
        Engine.create(
          EngineConfig(
            modelPath: 'blob:x',
            backend: const Backend.gpu(),
            visionBackend: const Backend.gpu(),
          ),
        ),
        throwsA(
          isA<LiteRtLmEngineCreateException>().having(
            (e) => e.message,
            'message',
            contains('without its vision encoder'),
          ),
        ),
      );

      expect(count('engineDeletes'), 1);
    });

    test('the encoders the runtime resolved are read back', () async {
      setOnPage('resolvedVisionBackend', 4);
      setOnPage('resolvedAudioBackend', 3);

      final engine = await Engine.create(
        EngineConfig(
          modelPath: 'blob:x',
          backend: const Backend.gpu(),
          visionBackend: const Backend.gpu(),
          audioBackend: const Backend.cpu(),
        ),
      );

      expect(engine.visionBackend, const Backend.gpu());
      expect(engine.audioBackend, const Backend.cpu());
      await engine.close();
    });

    test(
      'a page without the loader, without window.Engine or with a runtime '
      'lacking what the release calls is a StateError saying which',
      () async {
        removeRuntime();
        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('litertLmReady'),
                contains(web.liteRtLmWebModuleUrl),
              ),
            ),
          ),
        );
        globalContext['litertLmReady'] = Future<void>.value().toJS;
        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('window.Engine = m.Engine;'),
            ),
          ),
        );
        installRuntime();
        ((globalContext['Engine']! as JSObject)['prototype']! as JSObject)
            .delete('createConversation'.toJS);
        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('createConversation'),
                contains(web.liteRtLmWebRuntimeVersion),
              ),
            ),
          ),
        );
        expect(list('createSettings'), isEmpty);
      },
    );

    test('hands Engine.create the model, the backend, the context and the '
        'thread count; reads back what the runtime resolved', () async {
      setOnPage('resolvedBackend', 2); // GPU_ARTISAN: a web export on the GPU
      setOnPage('maxNumTokens', 2048);
      final engine = await Engine.create(webConfig(tokens: 2048));
      expect(asMap(list('createSettings').single), {
        'model': 'blob:https://example.com/model',
        'backend': 4,
        'mainExecutorSettings': {'maxNumTokens': 2048},
      });
      expect(engine.backend, const Backend.gpu());
      expect(engine.maxNumTokens, 2048);
      expect(engine.bundleInfo, isNull);
      await engine.close();

      installRuntime();
      setOnPage('resolvedBackend', 3);
      final cpu = await Engine.create(
        webConfig(backend: const Backend.cpu(threadCount: 2)),
      );
      final cpuSettings = asMap(list('createSettings').single);
      expect(cpuSettings['backend'], 3);
      expect(cpuSettings['mainExecutorSettings'], {
        'backendConfig': {'number_of_threads': 2},
      });
      expect(cpu.backend, const Backend.cpu());
      await cpu.close();
    });

    test('a backend the release does not know is a StateError', () async {
      setOnPage('resolvedBackend', 6);
      await expectLater(Engine.create(webConfig()), throwsStateError);
    });

    test('the runtime refusing the model is a LiteRtLmEngineCreateException '
        'carrying its message', () async {
      setOnPage('createError', 'Failed to load the model');
      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          isA<LiteRtLmEngineCreateException>().having(
            (e) => e.nativeMessage,
            'nativeMessage',
            contains('Failed to load the model'),
          ),
        ),
      );
    });

    test('a model stream goes in place of the URL', () async {
      final stream = JSObject()..['kind'] = 'stream'.toJS;
      final engine = await web.createWebEngine(webConfig(), model: stream);
      final model =
          (page['createSettings']! as JSArray<JSObject>).toDart.single['model'];
      expect(model.strictEquals(stream).toDart, isTrue);
      await engine.close();
    });
  });

  group('createConversation', () {
    late web.Engine engine;
    setUp(() async => engine = await webEngine());
    tearDown(() => engine.close());

    test('the sampler as TOP_P, the preface: system, history, tools and the '
        'thinking switch; channel filtering only with thinking', () async {
      await engine.createConversation(
        ConversationConfig(
          systemInstruction: 'Be brief.',
          initialMessages: [Message.user('Earlier'), Message.model('Yes')],
          tools: [
            Tool(name: 'f', description: 'd', parameters: {'type': 'object'}),
          ],
          samplerConfig: SamplerConfig(topK: 3, topP: 0.5, temperature: 0.2),
          maxOutputTokens: 64,
          thinkingConfig: ThinkingConfig(),
          extraContext: {'x': 1},
        ),
      );
      final options = asMap(list('conversationOptions').single);
      expect(options['sessionConfig'], {
        'samplerParams': {
          'type': 2,
          'temperature': 0.2,
          'k': 3,
          'p': 0.5,
          'seed': 0,
        },
        'maxOutputTokens': 64,
      });
      expect(options['preface'], {
        'messages': [
          {'role': 'system', 'content': 'Be brief.'},
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Earlier'},
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Yes'},
            ],
          },
        ],
        'tools': [
          {
            'type': 'function',
            'function': {
              'name': 'f',
              'description': 'd',
              'parameters': {'type': 'object'},
            },
          },
        ],
        'extra_context': {'x': 1, 'enable_thinking': true},
      });
      expect(options['filterChannelContentFromKvCache'], isTrue);
      expect(options.containsKey('enableConstrainedDecoding'), isFalse);
    });

    test(
      'without a sampler: 0.8 / 40 / 0.95 / 1, said once per engine',
      () async {
        final printed = <String>[];
        await runZoned(
          () async {
            await engine.createConversation();
            await engine.createConversation();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, line) => printed.add(line),
          ),
        );
        expect(
          asMap(
            asMap(list('conversationOptions').first)['sessionConfig'],
          )['samplerParams'],
          {'type': 2, 'temperature': 0.8, 'k': 40, 'p': 0.95, 'seed': 1},
        );
        expect(
          printed.where((l) => l.contains('sampler cannot be read')),
          hasLength(1),
        );
      },
    );

    group('refuses, without creating a conversation', () {
      Matcher refusal(String message) => throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains(message),
        ),
      );

      test('a response format', () async {
        await expectLater(
          engine.createConversation(
            ConversationConfig(responseFormat: ResponseFormat.regex('a+')),
          ),
          throwsA(
            isA<ConstraintUnsupportedException>().having(
              (e) => e.message,
              'message',
              contains('no constrained-decoding option'),
            ),
          ),
        );
        expect(list('conversationOptions'), isEmpty);
      });

      test('speculative decoding', () async {
        await expectLater(
          engine.createConversation(
            ConversationConfig(speculativeDecoding: SpeculativeDecodingMode.on),
          ),
          refusal('no speculative decoding'),
        );
        expect(list('conversationOptions'), isEmpty);
      });

      test('a thinking token budget', () async {
        await expectLater(
          engine.createConversation(
            ConversationConfig(
              thinkingConfig: ThinkingConfig(thinkingTokenBudget: 10),
            ),
          ),
          refusal('no thinking token budget'),
        );
        expect(list('conversationOptions'), isEmpty);
      });

      test('an initial image on an engine without a vision encoder', () async {
        await expectLater(
          engine.createConversation(
            ConversationConfig(
              initialMessages: [
                Message(
                  role: Role.user,
                  contents: [Content.imageBytes(Uint8List(4))],
                ),
              ],
            ),
          ),
          refusal('loaded no vision encoder'),
        );
        expect(list('conversationOptions'), isEmpty);
      });

      test('an initial image by file path', () async {
        await expectLater(
          engine.createConversation(
            ConversationConfig(
              initialMessages: [
                Message(
                  role: Role.user,
                  contents: [Content.imageFile('/photo.png')],
                ),
              ],
            ),
          ),
          refusal('cannot read a file path'),
        );
        expect(list('conversationOptions'), isEmpty);
      });
    });

    test('the runtime refusing the conversation is a '
        'LiteRtLmNativeException', () async {
      setOnPage('conversationError', 'Preface too long');
      await expectLater(
        engine.createConversation(),
        throwsA(
          isA<LiteRtLmNativeException>().having(
            (e) => e.message,
            'message',
            contains('Preface too long'),
          ),
        ),
      );
    });

    test('the tokenizer and option scoring refuse, as futures', () async {
      await expectLater(engine.tokenize('x'), throwsUnsupportedError);
      await expectLater(engine.detokenize([1]), throwsUnsupportedError);
      await expectLater(
        engine.scoreTargets('p', ['t']),
        throwsUnsupportedError,
      );
    });
  });

  group('a conversation', () {
    late web.Engine engine;
    late Conversation conversation;
    setUp(() async {
      engine = await webEngine();
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    test('a one-part text message goes as its string, through the real '
        'ReadableStream; the reply streams as Messages', () async {
      final pieces = <Message>[];
      final done = conversation
          .sendMessageStream(Message.user('Hello'))
          .forEach(pieces.add);
      await settle();
      expect(list('sent').single, 'Hello');
      js('__step', 'Hi');
      await settle();
      js('__end');
      await done;
      expect(pieces.single.text, 'Hi');
    });

    test('a tool result goes as the role-tool object', () async {
      final done = conversation
          .sendMessageStream(
            Message.tool([
              Content.toolResponse('f', {'ok': true}),
            ]),
          )
          .drain<void>();
      await settle();
      expect(list('sent').single, {
        'role': 'tool',
        'content': [
          {
            'type': 'tool_response',
            'name': 'f',
            'response': {'ok': true},
          },
        ],
      });
      js('__end');
      await done;
    });

    test('refuses media, per-message thinking, other template variables and '
        'decoding options, without sending; the same variables in another '
        'key order are accepted', () async {
      final c = await engine.createConversation(
        ConversationConfig(extraContext: {'a': 1, 'b': 2}),
      );
      Future<void> refused(Stream<Message> reply) =>
          expectLater(reply, emitsError(isA<UnsupportedError>()));
      await refused(
        c.sendMessageStream(
          Message(
            role: Role.user,
            contents: [Content.imageBytes(Uint8List(4))],
          ),
        ),
      );
      await refused(
        c.sendMessageStream(
          Message.user('x'),
          thinkingConfig: ThinkingConfig(),
        ),
      );
      await refused(
        c.sendMessageStream(Message.user('x'), extraContext: {'a': 2}),
      );
      await refused(
        c.sendMessageStream(Message.user('x'), suppressTokens: [1]),
      );
      expect(list('sent'), isEmpty);
      final sent = c
          .sendMessageStream(Message.user('x'), extraContext: {'b': 2, 'a': 1})
          .drain<void>();
      await settle();
      expect(list('sent'), hasLength(1));
      js('__end');
      await sent;
    });

    test('cancel(): the runtime rejects the stopped stream and the reply ends '
        'normally with what arrived; the next message goes to a conversation '
        'rebuilt from the history, the stopped exchange put back', () async {
      final first = conversation
          .sendMessageStream(Message.user('One'))
          .drain<void>();
      await settle();
      js('__step', 'Uno');
      js('__end');
      await first;

      final pieces = <Message>[];
      final stopped = conversation
          .sendMessageStream(Message.user('Two'))
          .forEach(pieces.add);
      await settle();
      js('__step', 'Do');
      await settle();
      conversation.cancel();
      await stopped; // no TurnFailedException
      expect(pieces.single.text, 'Do');
      expect(count('cancels'), 1);

      final reply = conversation
          .sendMessageStream(Message.user('Three'))
          .drain<void>();
      await settle();
      expect(list('conversationOptions'), hasLength(2));
      expect(
        asMap(asMap(list('conversationOptions').last)['preface'])['messages'],
        [
          {'role': 'user', 'content': 'One'},
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Uno'},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Two'},
            ],
          },
          {
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'Do'},
            ],
          },
        ],
      );
      expect(count('conversationDeletes'), 1, reason: 'the stopped one');
      expect(list('sent').last, 'Three');
      js('__step', 'Tres');
      js('__end');
      await reply;
    });

    test('a stop before anything was generated takes the turn back: the '
        'rebuilt preface has no trace of it', () async {
      final stopped = conversation
          .sendMessageStream(Message.user('Gone'))
          .drain<void>();
      await settle();
      conversation.cancel();
      await stopped;
      final next = conversation
          .sendMessageStream(Message.user('Next'))
          .drain<void>();
      await settle();
      expect(
        asMap(
          asMap(list('conversationOptions').last)['preface'],
        ).containsKey('messages'),
        isFalse,
      );
      js('__end');
      await next;
    });

    test('the benchmark record refuses on the web', () {
      expect(conversation.getBenchmarkInfo, throwsUnsupportedError);
    });

    test('a failed generation is a TurnFailedException carrying the '
        "runtime's error", () async {
      final reply = conversation.sendMessageStream(Message.user('Hello'));
      final expectation = expectLater(
        reply,
        emitsError(
          isA<TurnFailedException>().having(
            (e) => '${web.turnFailureCause(e)}',
            'cause',
            contains('generation failed'),
          ),
        ),
      );
      await settle();
      js('__fail', 'generation failed');
      await expectation;
    });

    test('a close mid-reply ends it with ConversationClosedException; the '
        'conversation is deleted after the stream ended', () async {
      final reply = conversation.sendMessageStream(Message.user('Hello'));
      final expectation = expectLater(
        reply,
        emitsError(isA<ConversationClosedException>()),
      );
      await settle();
      await conversation.close();
      expect(count('cancels'), 1);
      await expectation;
      expect(count('conversationDeletes'), 1);
    });
  });

  group('on its own page lock', () {
    test('a subscription cancel stops the runtime too; the page stays held '
        'until the stream ended, and the next message is rebuilt', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final c = await engine.createConversation();
      final sub = c.sendMessageStream(Message.user('Hello')).listen((_) {});
      await settle();
      js('__step', 'Par');
      await settle();
      setOnPage('stuckOnCancel', true); // the stream ends later, on its own
      final cancelled = sub.cancel();
      await settle();
      expect(count('cancels'), 1);
      var other = false;
      unawaited(
        lock.acquire().then((l) {
          other = true;
          l.release();
        }),
      );
      await settle();
      expect(other, isFalse, reason: 'let go of the page before the end');
      js('__fail', 'Task cancelled');
      await cancelled;
      await settle();
      expect(other, isTrue);
      final next = c.sendMessageStream(Message.user('Again')).drain<void>();
      await settle();
      expect(list('sent').last, 'Again');
      expect(list('conversationOptions'), hasLength(2));
      js('__end');
      await next;
      await engine.close();
    });

    test('a turn waiting for the page that is stopped is never sent, and '
        'ends normally', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final c = await engine.createConversation();
      final held = await lock.acquire();
      final reply = c.sendMessageStream(Message.user('Queued')).drain<void>();
      await settle();
      c.cancel();
      held.release();
      await reply;
      expect(list('sent'), isEmpty);
      await engine.close();
    });

    test('a step that is not an object with `done` fails the reply and '
        'poisons the page: where the generation is cannot be known', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final c = await engine.createConversation();
      setOnPage('malformed', true);

      final printed = await printsOf(
        () => expectLater(
          c.sendMessageStream(Message.user('Hello')),
          emitsError(
            isA<TurnFailedException>().having(
              (e) => '$e',
              'message',
              contains('without a boolean `done`'),
            ),
          ),
        ),
      );

      expect(lock.poison?.message, contains('without a boolean `done`'));
      expect(printed.single, contains('ERROR'));
      await expectLater(
        lock.acquire(),
        throwsA(isA<web.LiteRtLmPagePoisonedError>()),
      );
    });

    test('Engine.close waits for a conversation create waiting for the page: '
        'the create refuses, the runtime never sees it, then the engine is '
        'deleted', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final held = await lock.acquire();
      final create = engine.createConversation();
      final closing = engine.close();
      await settle();
      expect(count('engineDeletes'), 0, reason: 'deleted under a create');
      held.release();
      await expectLater(create, throwsStateError);
      await closing;
      expect(list('conversationOptions'), isEmpty);
      expect(count('engineDeletes'), 1);
    });

    test('a stopped generation that never ends: close fails with the '
        'poisoned page after the drain timeout, every later call on the page '
        'fails, and the engine is left to the page', () async {
      final saved = web.WebConversationHandle.drainTimeout;
      web.WebConversationHandle.drainTimeout = const Duration(
        milliseconds: 200,
      );
      addTearDown(() => web.WebConversationHandle.drainTimeout = saved);
      final lock = web.LiteRtLmPageLock();
      final engine = await webEngine(lock: lock);
      final conversation = await engine.createConversation();
      setOnPage('stuckOnCancel', true);
      final reply = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .catchError((Object _) {});
      await settle();
      await expectLater(
        conversation.close(),
        throwsA(isA<web.LiteRtLmPagePoisonedError>()),
      );
      await expectLater(
        lock.acquire(),
        throwsA(isA<web.LiteRtLmPagePoisonedError>()),
      );
      await expectLater(
        engine.close(),
        throwsA(isA<web.LiteRtLmPagePoisonedError>()),
      );
      expect(count('engineDeletes'), 0);
      unawaited(reply);
    });
  });

  test('Engine.close closes every conversation, then deletes the engine; '
      'later calls are StateErrors', () async {
    final engine = await webEngine();
    final conversation = await engine.createConversation();
    await engine.createConversation();
    await engine.close();
    expect(count('conversationDeletes'), 2);
    expect(count('engineDeletes'), 1);
    expect(engine.createConversation, throwsStateError);
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsStateError,
    );
  });

  test('LiteRT-LM#2080: a second conversation with another sampler set by '
      'the caller is warned about once', () async {
    final engine = await webEngine();
    final printed = <String>[];
    await runZoned(
      () async {
        for (final topK in [1, 2, 3]) {
          final conversation = await engine.createConversation(
            ConversationConfig(
              samplerConfig: SamplerConfig(topK: topK, topP: 1, temperature: 1),
            ),
          );
          final done = conversation
              .sendMessageStream(Message.user('x'))
              .drain<void>();
          await settle();
          js('__end');
          await done;
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => printed.add(line),
      ),
    );
    expect(
      printed.where((line) => line.contains('LiteRT-LM#2080')),
      hasLength(1),
    );
    await engine.close();
  });

  test(
    'the file reads and the benchmark refuse on the web, as futures',
    () async {
      await expectLater(readBundleInfo('m.litertlm'), throwsUnsupportedError);
      await expectLater(
        readBundleGenericData('m.litertlm', 'x'),
        throwsUnsupportedError,
      );
      await expectLater(
        benchmark(modelPath: 'm', backend: const Backend.gpu()),
        throwsUnsupportedError,
      );
    },
  );
}

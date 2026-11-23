// The web arm of the public API in a browser, over a stub `@litert-lm/core`
// defined on the page in plain JS: `window.Engine` (with 0.19.0's
// `createExclusive`) and conversations whose `sendMessageStreaming` returns a
// real `ReadableStream` the test feeds chunk by chunk. The stub does what
// 0.19.0 was measured to do (2026-11-23, web_litertlm_runtime_probe_test.dart):
// `cancel()` rejects the stream with "Task cancelled", and every later send on
// that conversation fails the same way; `getHistory()` holds the completed
// exchanges only.
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

const _stub = r'''
(() => {
  const p = window.__page = {
    createSettings: [], conversationOptions: [], sent: [],
    cancels: 0, conversationDeletes: 0, engineDeletes: 0, streams: [],
    resolvedBackend: 4, maxNumTokens: 4096,
    createError: null, conversationError: null, rejectOnCancel: true,
  };
  const open = () => p.streams.find((s) => !s.closed);
  const conversation = () => {
    const c = {dead: false, history: []};
    c.sendMessageStreaming = (message) => {
      p.sent.push(message);
      // A bare iterator (no Symbol.asyncIterator) whose step has no `done`.
      if (p.malformed) return {next: async () => ({value: 1})};
      let controller;
      const stream = new ReadableStream({start(ctl) { controller = ctl; }});
      const entry = {controller, conversation: c, message, closed: false, text: ''};
      p.streams.push(entry);
      if (c.dead) {
        entry.closed = true;
        queueMicrotask(() => controller.error(new Error('Task cancelled')));
      }
      return stream;
    };
    c.cancel = () => {
      p.cancels++;
      c.dead = true;
      if (!p.rejectOnCancel) return;
      for (const s of p.streams) {
        if (s.conversation === c && !s.closed) {
          s.closed = true;
          s.controller.error(new Error('Task cancelled'));
        }
      }
    };
    c.getHistory = async () => c.history;
    c.delete = async () => { p.conversationDeletes++; };
    return c;
  };
  window.__step = (text) => {
    const s = open();
    s.text += text;
    s.controller.enqueue({role: 'assistant', content: [{type: 'text', text}]});
  };
  window.__end = () => {
    const s = open();
    s.closed = true;
    s.controller.close();
    s.conversation.history.push(
      {role: 'user', content: s.message},
      {role: 'assistant', content: [{type: 'text', text: s.text}]});
  };
  window.__fail = (message) => {
    const s = open();
    s.closed = true;
    s.controller.error(new Error(message));
  };
  window.Engine = function Engine() {};
  window.Engine.createExclusive = function () {};
  window.Engine.create = async (settings) => {
    p.createSettings.push(settings);
    if (p.createError) throw new Error(p.createError);
    return {
      settings: {backend: p.resolvedBackend,
                 mainExecutorSettings: {maxNumTokens: p.maxNumTokens}},
      createConversation: async (options) => {
        p.conversationOptions.push(options);
        if (p.conversationError) throw new Error(p.conversationError);
        return conversation();
      },
      delete: async () => { p.engineDeletes++; },
    };
  };
  window.litertLmReady = Promise.resolve(window.Engine);
})();
''';

JSObject get _page => globalContext['__page']! as JSObject;
int _count(String key) => (_page[key]! as JSNumber).toDartInt;
List<Object?> _list(String key) =>
    (_page[key]! as JSArray<JSAny?>).toDart.map((v) => v.dartify()).toList();
void _set(String key, Object? value) => _page[key] = value.jsify();
void _js(String name, [String? arg]) => arg == null
    ? globalContext.callMethod(name.toJS)
    : globalContext.callMethod(name.toJS, arg.toJS);

void _installRuntime() => globalContext.callMethod('eval'.toJS, _stub.toJS);

void _removeRuntime() {
  for (final key in ['litertLmReady', 'Engine', '__page']) {
    globalContext.delete(key.toJS);
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

EngineConfig _config({Backend backend = const Backend.gpu(), int? tokens}) =>
    EngineConfig(
      modelPath: 'blob:https://example.com/model',
      backend: backend,
      maxNumTokens: tokens,
    );

/// An engine on a page lock of its own, so a poisoned lock stays in its test.
Future<web.Engine> _engine({web.LiteRtLmPageLock? lock}) =>
    web.createWebEngine(_config(), pageLock: lock ?? web.LiteRtLmPageLock());

Map<String, Object?> _map(Object? value) =>
    (value! as Map).cast<String, Object?>();

void main() {
  setUp(_installRuntime);
  tearDown(_removeRuntime);

  group('Engine.create', () {
    test('refuses what the web does not run, before touching the runtime', () {
      for (final config in [
        _config(backend: const Backend.npu()),
        EngineConfig(modelPath: 'blob:x', visionBackend: const Backend.gpu()),
        EngineConfig(modelPath: 'blob:x', audioBackend: const Backend.cpu()),
        EngineConfig(modelPath: 'blob:x', maxNumImages: 1),
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
      expect(_list('createSettings'), isEmpty);
    });

    test(
      'vision and audio are refused with what 0.19.0 was measured doing',
      () {
        expect(
          () => Engine.create(
            EngineConfig(
              modelPath: 'blob:x',
              visionBackend: const Backend.gpu(),
            ),
          ),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Vision executor should not be null'),
                contains('measured'),
              ),
            ),
          ),
        );
      },
    );

    test('a page without the loader, without window.Engine or with another '
        'runtime version is a StateError saying which', () async {
      _removeRuntime();
      await expectLater(
        Engine.create(_config()),
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
        Engine.create(_config()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('window.Engine = m.Engine;'),
          ),
        ),
      );
      _installRuntime();
      (globalContext['Engine']! as JSObject).delete('createExclusive'.toJS);
      await expectLater(
        Engine.create(_config()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains(web.liteRtLmWebRuntimeVersion),
          ),
        ),
      );
    });

    test('hands Engine.create the model, the backend, the context and the '
        'thread count; reads back what the runtime resolved', () async {
      _set('resolvedBackend', 2); // GPU_ARTISAN: a web export on the GPU
      _set('maxNumTokens', 2048);
      final engine = await Engine.create(_config(tokens: 2048));
      expect(_map(_list('createSettings').single), {
        'model': 'blob:https://example.com/model',
        'backend': 4,
        'mainExecutorSettings': {'maxNumTokens': 2048},
      });
      expect(engine.backend, const Backend.gpu());
      expect(engine.maxNumTokens, 2048);
      expect(engine.bundleInfo, isNull);
      await engine.close();

      _installRuntime();
      _set('resolvedBackend', 3);
      final cpu = await Engine.create(
        _config(backend: const Backend.cpu(threadCount: 2)),
      );
      expect(_map(_list('createSettings').single)['mainExecutorSettings'], {
        'backendConfig': {'number_of_threads': 2},
      });
      expect(cpu.backend, const Backend.cpu());
      await cpu.close();
    });

    test('a backend the release does not know is a StateError', () async {
      _set('resolvedBackend', 6);
      await expectLater(Engine.create(_config()), throwsStateError);
    });

    test('the runtime refusing the model is a LiteRtLmEngineCreateException '
        'carrying its message', () async {
      _set('createError', 'Failed to load the model');
      await expectLater(
        Engine.create(_config()),
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
      final engine = await web.createWebEngine(_config(), model: stream);
      final model = (_page['createSettings']! as JSArray<JSObject>)
          .toDart
          .single['model'];
      expect(model.strictEquals(stream).toDart, isTrue);
      await engine.close();
    });
  });

  group('createConversation', () {
    late web.Engine engine;
    setUp(() async => engine = await _engine());
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
      final options = _map(_list('conversationOptions').single);
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
          _map(
            _map(_list('conversationOptions').first)['sessionConfig'],
          )['samplerParams'],
          {'type': 2, 'temperature': 0.8, 'k': 40, 'p': 0.95, 'seed': 1},
        );
        expect(
          printed.where((l) => l.contains('sampler cannot be read')),
          hasLength(1),
        );
      },
    );

    test('refuses a response format, speculative decoding, a thinking budget '
        'and an initial message with an image', () async {
      await expectLater(
        engine.createConversation(
          ConversationConfig(responseFormat: ResponseFormat.regex('a+')),
        ),
        throwsA(isA<ConstraintUnsupportedException>()),
      );
      await expectLater(
        engine.createConversation(
          ConversationConfig(speculativeDecoding: SpeculativeDecodingMode.on),
        ),
        throwsUnsupportedError,
      );
      await expectLater(
        engine.createConversation(
          ConversationConfig(
            thinkingConfig: ThinkingConfig(thinkingTokenBudget: 10),
          ),
        ),
        throwsUnsupportedError,
      );
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
        throwsUnsupportedError,
      );
      expect(_list('conversationOptions'), isEmpty);
    });

    test('the runtime refusing the conversation is a '
        'LiteRtLmNativeException', () async {
      _set('conversationError', 'Preface too long');
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
      engine = await _engine();
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    test('a one-part text message goes as its string, through the real '
        'ReadableStream; the reply streams as Messages', () async {
      final pieces = <Message>[];
      final done = conversation
          .sendMessageStream(Message.user('Hello'))
          .forEach(pieces.add);
      await _settle();
      expect(_list('sent').single, 'Hello');
      _js('__step', 'Hi');
      await _settle();
      _js('__end');
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
      await _settle();
      expect(_list('sent').single, {
        'role': 'tool',
        'content': [
          {
            'type': 'tool_response',
            'name': 'f',
            'response': {'ok': true},
          },
        ],
      });
      _js('__end');
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
      expect(_list('sent'), isEmpty);
      final sent = c
          .sendMessageStream(Message.user('x'), extraContext: {'b': 2, 'a': 1})
          .drain<void>();
      await _settle();
      expect(_list('sent'), hasLength(1));
      _js('__end');
      await sent;
    });

    test('cancel(): the runtime rejects the stopped stream and the reply ends '
        'normally with what arrived; the next message goes to a conversation '
        'rebuilt from the history, the stopped exchange put back', () async {
      final first = conversation
          .sendMessageStream(Message.user('One'))
          .drain<void>();
      await _settle();
      _js('__step', 'Uno');
      _js('__end');
      await first;

      final pieces = <Message>[];
      final stopped = conversation
          .sendMessageStream(Message.user('Two'))
          .forEach(pieces.add);
      await _settle();
      _js('__step', 'Do');
      await _settle();
      conversation.cancel();
      await stopped; // no TurnFailedException
      expect(pieces.single.text, 'Do');
      expect(_count('cancels'), 1);

      final reply = conversation
          .sendMessageStream(Message.user('Three'))
          .drain<void>();
      await _settle();
      expect(_list('conversationOptions'), hasLength(2));
      expect(
        _map(_map(_list('conversationOptions').last)['preface'])['messages'],
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
      expect(_count('conversationDeletes'), 1, reason: 'the stopped one');
      expect(_list('sent').last, 'Three');
      _js('__step', 'Tres');
      _js('__end');
      await reply;
    });

    test('a stop before anything was generated takes the turn back: the '
        'rebuilt preface has no trace of it', () async {
      final stopped = conversation
          .sendMessageStream(Message.user('Gone'))
          .drain<void>();
      await _settle();
      conversation.cancel();
      await stopped;
      final next = conversation
          .sendMessageStream(Message.user('Next'))
          .drain<void>();
      await _settle();
      expect(
        _map(
          _map(_list('conversationOptions').last)['preface'],
        ).containsKey('messages'),
        isFalse,
      );
      _js('__end');
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
      await _settle();
      _js('__fail', 'generation failed');
      await expectation;
    });

    test('a close mid-reply ends it with ConversationClosedException; the '
        'conversation is deleted after the stream ended', () async {
      final reply = conversation.sendMessageStream(Message.user('Hello'));
      final expectation = expectLater(
        reply,
        emitsError(isA<ConversationClosedException>()),
      );
      await _settle();
      await conversation.close();
      expect(_count('cancels'), 1);
      await expectation;
      expect(_count('conversationDeletes'), 1);
    });
  });

  group('on its own page lock', () {
    test('a subscription cancel stops the runtime too; the page stays held '
        'until the stream ended, and the next message is rebuilt', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await _engine(lock: lock);
      final c = await engine.createConversation();
      final sub = c.sendMessageStream(Message.user('Hello')).listen((_) {});
      await _settle();
      _js('__step', 'Par');
      await _settle();
      _set('rejectOnCancel', false); // the stream ends later, on its own
      final cancelled = sub.cancel();
      await _settle();
      expect(_count('cancels'), 1);
      var other = false;
      unawaited(
        lock.acquire().then((l) {
          other = true;
          l.release();
        }),
      );
      await _settle();
      expect(other, isFalse, reason: 'let go of the page before the end');
      _js('__fail', 'Task cancelled');
      await cancelled;
      await _settle();
      expect(other, isTrue);
      final next = c.sendMessageStream(Message.user('Again')).drain<void>();
      await _settle();
      expect(_list('sent').last, 'Again');
      expect(_list('conversationOptions'), hasLength(2));
      _js('__end');
      await next;
      await engine.close();
    });

    test('a turn waiting for the page that is stopped is never sent, and '
        'ends normally', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await _engine(lock: lock);
      final c = await engine.createConversation();
      final held = await lock.acquire();
      final reply = c.sendMessageStream(Message.user('Queued')).drain<void>();
      await _settle();
      c.cancel();
      held.release();
      await reply;
      expect(_list('sent'), isEmpty);
      await engine.close();
    });

    test('a step that is not an object with `done` fails the reply and lets '
        'go of the page', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await _engine(lock: lock);
      final c = await engine.createConversation();
      _set('malformed', true);
      await expectLater(
        c.sendMessageStream(Message.user('Hello')),
        emitsError(
          isA<TurnFailedException>().having(
            (e) => '$e',
            'message',
            contains('without a boolean `done`'),
          ),
        ),
      );
      await lock.run(() async {}).timeout(const Duration(seconds: 2));
      await engine.close();
    });

    test('Engine.close waits for a conversation create waiting for the page: '
        'the create refuses, the runtime never sees it, then the engine is '
        'deleted', () async {
      final lock = web.LiteRtLmPageLock();
      final engine = await _engine(lock: lock);
      final held = await lock.acquire();
      final create = engine.createConversation();
      final closing = engine.close();
      await _settle();
      expect(_count('engineDeletes'), 0, reason: 'deleted under a create');
      held.release();
      await expectLater(create, throwsStateError);
      await closing;
      expect(_list('conversationOptions'), isEmpty);
      expect(_count('engineDeletes'), 1);
    });

    test('a stopped generation that never ends: close fails with the '
        'poisoned page after the drain timeout, every later call on the page '
        'fails, and the engine is left to the page', () async {
      final saved = web.WebConversationHandle.closeDrainTimeout;
      web.WebConversationHandle.closeDrainTimeout = const Duration(
        milliseconds: 200,
      );
      addTearDown(() => web.WebConversationHandle.closeDrainTimeout = saved);
      final lock = web.LiteRtLmPageLock();
      final engine = await _engine(lock: lock);
      final conversation = await engine.createConversation();
      _set('rejectOnCancel', false);
      final reply = conversation
          .sendMessageStream(Message.user('Hello'))
          .drain<void>()
          .catchError((Object _) {});
      await _settle();
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
      expect(_count('engineDeletes'), 0);
      unawaited(reply);
    });
  });

  test('Engine.close closes every conversation, then deletes the engine; '
      'later calls are StateErrors', () async {
    final engine = await _engine();
    final conversation = await engine.createConversation();
    await engine.createConversation();
    await engine.close();
    expect(_count('conversationDeletes'), 2);
    expect(_count('engineDeletes'), 1);
    expect(engine.createConversation, throwsStateError);
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsStateError,
    );
  });

  test('LiteRT-LM#2080: a second conversation with another sampler set by '
      'the caller is warned about once', () async {
    final engine = await _engine();
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
          await _settle();
          _js('__end');
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

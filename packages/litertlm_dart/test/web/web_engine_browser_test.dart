// The web arm of the public API in a browser, over a stub `@litert-lm/core`
// defined on the page (`window.Engine`, `window.litertLmReady`): what
// `Engine.create` refuses before the runtime is touched, the settings it hands
// `Engine.create`, what it reads back, the conversation options a
// `ConversationConfig` becomes, how a message reaches `sendMessageStreaming`
// (a bare string for one text part, the object for a tool result), what a
// send refuses, how a stop and a close end a turn, and that `close` drains,
// deletes every conversation and then the engine. The calls that need the
// file system or native benchmark mode refuse. The real runtime is
// example/integration_test/litertlm_web_test.dart (flutter drive).
//
// Run: dart test -p chrome test/web/web_engine_browser_test.dart
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:litertlm_dart/internal_web.dart' as web;
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

/// What the stub runtime saw.
final class _Page {
  final createSettings = <JSObject>[];
  final conversationOptions = <JSObject>[];
  final sent = <JSAny?>[];
  int engineDeletes = 0;
  int conversationDeletes = 0;
  int cancels = 0;

  /// Each `next()` of the current stream: answered by [step] / [fail].
  final pending = <Completer<JSObject>>[];

  void step(Map<String, Object?>? value, {bool done = false}) => pending
      .removeAt(0)
      .complete(
        JSObject()
          ..['done'] = done.toJS
          ..['value'] = value?.jsify(),
      );

  void fail(Object error) => pending.removeAt(0).completeError(error);
}

late _Page _page;

/// Installs the stub runtime: `window.litertLmReady` and `window.Engine`,
/// whose engines report [backend] and [maxNumTokens] as resolved.
void _installRuntime({int backend = 4, int maxNumTokens = 4096}) {
  final page = _page = _Page();
  JSObject conversation() {
    final iterator = JSObject()
      ..['next'] = (() {
        final step = Completer<JSObject>();
        page.pending.add(step);
        return step.future.toJS;
      }).toJS;
    return JSObject()
      ..['sendMessageStreaming'] = ((JSAny? message) {
        page.sent.add(message);
        return iterator;
      }).toJS
      ..['cancel'] = (() {
        page.cancels++;
      }).toJS
      ..['delete'] = (() {
        page.conversationDeletes++;
        return Future<void>.value().toJS;
      }).toJS;
  }

  final engine = JSObject()
    ..['settings'] = {
      'backend': backend,
      'mainExecutorSettings': {'maxNumTokens': maxNumTokens},
    }.jsify()
    ..['createConversation'] = ((JSObject options) {
      page.conversationOptions.add(options);
      return Future<JSObject>.value(conversation()).toJS;
    }).toJS
    ..['delete'] = (() {
      page.engineDeletes++;
      return Future<void>.value().toJS;
    }).toJS;
  globalContext['litertLmReady'] = Future<void>.value().toJS;
  globalContext['Engine'] = JSObject()
    ..['create'] = ((JSObject settings) {
      page.createSettings.add(settings);
      return Future<JSObject>.value(engine).toJS;
    }).toJS;
}

void _removeRuntime() {
  globalContext.delete('litertLmReady'.toJS);
  globalContext.delete('Engine'.toJS);
}

Map<String, Object?> _dart(JSAny? value) =>
    (value.dartify()! as Map).cast<String, Object?>();

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

EngineConfig _config({Backend backend = const Backend.gpu(), int? tokens}) =>
    EngineConfig(
      modelPath: 'blob:https://example.com/model',
      backend: backend,
      maxNumTokens: tokens,
    );

void main() {
  tearDown(_removeRuntime);

  group('Engine.create', () {
    test('refuses what the web runtime does not have, before touching it', () {
      for (final config in [
        _config(backend: const Backend.npu()),
        _config(backend: const Backend.cpu(threadCount: 2)),
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
    });

    test('a page without the module script is a StateError naming the '
        'loader', () async {
      await expectLater(
        Engine.create(_config()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('window.litertLmReady is not set'),
          ),
        ),
      );
    });

    test('hands Engine.create the model URL and the backend, the context only '
        'when set, and reads back what the runtime resolved', () async {
      _installRuntime(backend: 4, maxNumTokens: 2048);
      final engine = await Engine.create(_config());
      expect(_dart(_page.createSettings.single), {
        'model': 'blob:https://example.com/model',
        'backend': 4,
      });
      expect(engine.backend, const Backend.gpu());
      expect(engine.maxNumTokens, 2048);
      expect(engine.bundleInfo, isNull);
      expect(engine.visionBackend, isNull);
      expect(engine.audioBackend, isNull);
      await engine.close();

      _installRuntime(backend: 3, maxNumTokens: 1024);
      final cpu = await Engine.create(
        _config(backend: const Backend.cpu(), tokens: 1024),
      );
      expect(_dart(_page.createSettings.single), {
        'model': 'blob:https://example.com/model',
        'backend': 3,
        'mainExecutorSettings': {'maxNumTokens': 1024},
      });
      expect(cpu.backend, const Backend.cpu());
      await cpu.close();
    });

    test('a model stream goes in place of the URL', () async {
      _installRuntime();
      final stream = JSObject()..['kind'] = 'stream'.toJS;
      final engine = await web.createWebEngine(_config(), model: stream);
      final model = _page.createSettings.single['model'];
      expect(identical(model, stream), isTrue);
      await engine.close();
    });
  });

  group('createConversation', () {
    late Engine engine;
    setUp(() async {
      _installRuntime();
      engine = await Engine.create(_config());
    });
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
      final options = _dart(_page.conversationOptions.single);
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

    test('without a config: the default sampler, thinking off, no channel '
        'filter, no messages or tools', () async {
      await engine.createConversation();
      final options = _dart(_page.conversationOptions.single);
      expect((options['sessionConfig']! as Map)['samplerParams'], {
        'type': 2,
        'temperature': 0.8,
        'k': 40,
        'p': 0.95,
        'seed': 1,
      });
      expect(options['preface'], {
        'extra_context': {'enable_thinking': false},
      });
      expect(options.containsKey('filterChannelContentFromKvCache'), isFalse);
    });

    test('refuses a response format, speculative decoding and a thinking '
        'budget', () async {
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
      expect(_page.conversationOptions, isEmpty);
    });

    test('the tokenizer and option scoring refuse', () {
      expect(() => engine.tokenize('x'), throwsUnsupportedError);
      expect(() => engine.detokenize([1]), throwsUnsupportedError);
      expect(() => engine.scoreTargets('p', ['t']), throwsUnsupportedError);
    });
  });

  group('a conversation', () {
    late Engine engine;
    late Conversation conversation;
    setUp(() async {
      _installRuntime();
      engine = await Engine.create(_config());
      conversation = await engine.createConversation();
    });
    tearDown(() => engine.close());

    test('a one-part text message goes as its string; the reply streams as '
        'Messages and ends with the stream', () async {
      final pieces = <Message>[];
      final done = conversation
          .sendMessageStream(Message.user('Hello'))
          .forEach(pieces.add);
      await _settle();
      expect((_page.sent.single! as JSString).toDart, 'Hello');
      _page.step({
        'role': 'model',
        'content': [
          {'type': 'text', 'text': 'Hi'},
        ],
      });
      await _settle();
      _page.step(null, done: true);
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
      expect(_dart(_page.sent.single), {
        'role': 'tool',
        'content': [
          {
            'type': 'tool_response',
            'name': 'f',
            'response': {'ok': true},
          },
        ],
      });
      _page.step(null, done: true);
      await done;
    });

    test('refuses media, per-message thinking, template variables and '
        'decoding options, without sending', () async {
      Future<void> refused(Stream<Message> reply) =>
          expectLater(reply, emitsError(isA<UnsupportedError>()));
      await refused(
        conversation.sendMessageStream(
          Message(
            role: Role.user,
            contents: [Content.imageBytes(Uint8List(4))],
          ),
        ),
      );
      await refused(
        conversation.sendMessageStream(
          Message.user('x'),
          thinkingConfig: ThinkingConfig(),
        ),
      );
      await refused(
        conversation.sendMessageStream(
          Message.user('x'),
          extraContext: {'a': 1},
        ),
      );
      await refused(
        conversation.sendMessageStream(Message.user('x'), suppressTokens: [1]),
      );
      expect(_page.sent, isEmpty);
    });

    test('cancel() stops the runtime and the reply ends normally, whatever '
        'the stream ends with', () async {
      final pieces = <Message>[];
      final done = conversation
          .sendMessageStream(Message.user('Hello'))
          .forEach(pieces.add);
      await _settle();
      _page.step({'role': 'model', 'content': 'Par'});
      await _settle();
      conversation.cancel();
      expect(_page.cancels, 1);
      _page.fail(StateError('CANCELLED'));
      await done;
      expect(pieces.single.text, 'Par');
    });

    test('a failed generation is a TurnFailedException carrying the '
        "runtime's error", () async {
      final reply = conversation.sendMessageStream(Message.user('Hello'));
      final failure = StateError('generation failed');
      final expectation = expectLater(
        reply,
        emitsError(
          // The runtime's rejection, as JS carried it.
          isA<TurnFailedException>().having(
            (e) => '${web.turnFailureCause(e)}',
            'cause',
            contains('generation failed'),
          ),
        ),
      );
      await _settle();
      _page.fail(failure);
      await expectation;
    });

    test('a close mid-reply ends it with ConversationClosedException, after '
        'the stream drained; the conversation is deleted', () async {
      final reply = conversation.sendMessageStream(Message.user('Hello'));
      final expectation = expectLater(
        reply,
        emitsError(isA<ConversationClosedException>()),
      );
      await _settle();
      await conversation.close();
      expect(_page.cancels, 1);
      _page.step(null, done: true);
      await expectation;
      await (web.conversationHandle(conversation) as web.WebConversationHandle)
          .closed;
      expect(_page.conversationDeletes, 1);
    });
  });

  test('Engine.close closes every conversation, then deletes the engine; '
      'later calls are StateErrors', () async {
    _installRuntime();
    final engine = await Engine.create(_config());
    final conversation = await engine.createConversation();
    await engine.createConversation();
    await engine.close();
    expect(_page.conversationDeletes, 2);
    expect(_page.engineDeletes, 1);
    expect(engine.createConversation, throwsStateError);
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsStateError,
    );
  });

  test('LiteRT-LM#2080: a second conversation with another sampler set by '
      'the caller is warned about once', () async {
    _installRuntime();
    final engine = await Engine.create(_config());
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
          _page.step(null, done: true);
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

  test('the file reads and the benchmark refuse on the web', () {
    expect(() => readBundleInfo('m.litertlm'), throwsUnsupportedError);
    expect(
      () => readBundleGenericData('m.litertlm', 'x'),
      throwsUnsupportedError,
    );
    expect(
      () => benchmark(modelPath: 'm', backend: const Backend.gpu()),
      throwsUnsupportedError,
    );
    expect(
      () => EmbeddingEngine.create(
        EmbeddingEngineConfig(
          modelPath: 'blob:x',
          cacheDir: '',
          backend: const Backend.npu(),
        ),
      ),
      throwsUnsupportedError,
    );
  });
}

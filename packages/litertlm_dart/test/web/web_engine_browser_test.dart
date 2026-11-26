// The web arm of the public API in a browser, over a stub `@litert-lm/core`
// defined on the page in plain JS: `window.litertLm`, whose `Engine` has the
// prototype members the release calls, and conversations whose `sendMessageStreaming` returns a
// real `ReadableStream` the test feeds chunk by chunk. The stub does what
// 0.19.0 was measured to do (2026-11-23, web_litertlm_runtime_probe_test.dart):
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
    group('refuses what the web does not run, before touching the runtime', () {
      for (final (what, config, message) in [
        ('the NPU', webConfig(backend: const Backend.npu()), 'the NPU'),
        (
          'an NPU vision encoder',
          EngineConfig(modelPath: 'blob:x', visionBackend: const Backend.npu()),
          'an NPU vision encoder',
        ),
        (
          'an NPU audio encoder',
          EngineConfig(modelPath: 'blob:x', audioBackend: const Backend.npu()),
          'an NPU audio encoder',
        ),
        (
          'a cache directory',
          EngineConfig(modelPath: 'blob:x', cacheDir: '/tmp'),
          'a cache directory (cacheDir)',
        ),
        (
          'an activation type',
          EngineConfig(
            modelPath: 'blob:x',
            activationDataType: ActivationDataType.float32,
          ),
          'refuses an activationDataType: 0.20.0 takes one',
        ),
        (
          'speculative decoding',
          EngineConfig(
            modelPath: 'blob:x',
            speculativeDecoding: SpeculativeDecodingConfig(
              mode: SpeculativeDecodingMode.on,
            ),
          ),
          'the web export has no drafter',
        ),
      ]) {
        test(what, () async {
          await expectLater(
            Engine.create(config),
            throwsWith<UnsupportedError>(message),
          );
          expect(list('createSettings'), isEmpty);
        });
      }
    });

    test('a vision encoder goes to the runtime with one image reserved per '
        'conversation by default, which a GPU_ARTISAN model needs', () async {
      setOnPage('resolvedVisionBackend', backendId('GPU'));
      setOnPage('resolvedAudioBackend', backendId('CPU'));
      final engine = await Engine.create(
        EngineConfig(
          modelPath: 'blob:x',
          backend: const Backend.gpu(),
          visionBackend: const Backend.gpu(),
          audioBackend: const Backend.cpu(),
        ),
      );

      final settings = asMap(list('createSettings').single);
      expect(settings['visionBackend'], backendId('GPU'));
      expect(settings['audioBackend'], backendId('CPU'));
      expect(asMap(settings['mainExecutorSettings'])['maxNumImages'], 1);
      await engine.close();
    });

    test(
      'maxNumImages, when set, is the images a conversation reserves',
      () async {
        setOnPage('resolvedVisionBackend', backendId('GPU'));
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

    test('an audio encoder asked for that the runtime does not report is '
        'refused, naming audio', () async {
      await expectLater(
        Engine.create(
          EngineConfig(
            modelPath: 'blob:x',
            backend: const Backend.gpu(),
            audioBackend: const Backend.cpu(),
          ),
        ),
        throwsWith<LiteRtLmEngineCreateException>(
          'without its audio encoder (settings.audioBackend not reported)',
        ),
      );
    });

    test('an encoder the runtime put on a backend this release does not '
        'know is refused, naming that backend', () async {
      setOnPage('resolvedVisionBackend', 7);

      await expectLater(
        Engine.create(
          EngineConfig(
            modelPath: 'blob:x',
            backend: const Backend.gpu(),
            visionBackend: const Backend.gpu(),
          ),
        ),
        throwsWith<LiteRtLmEngineCreateException>(
          'with its vision encoder on backend 7, which this release does not '
          'know',
        ),
      );

      expect(count('engineDeletes'), 1);
    });

    test('the encoders the runtime resolved are read back', () async {
      setOnPage('resolvedVisionBackend', backendId('GPU'));
      setOnPage('resolvedAudioBackend', backendId('CPU'));

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

    test('a page without the loader is a StateError naming the module and the '
        'shim line', () async {
      removeRuntime();

      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          errorWith<web.LiteRtLmWebModuleError>('window.litertLm is not set')
              .having(
                (e) => e.message,
                'message',
                contains(web.liteRtLmWebModuleUrl),
              )
              .having(
                (e) => e.message,
                'message',
                contains(web.liteRtLmWebModuleShimLine),
              ),
        ),
      );
    });

    test(
      'a loader that sets no window.litertLm is a StateError naming the shim '
      'line',
      () async {
        removeRuntime();
        globalContext['litertLmReady'] = Future<void>.value().toJS;

        await expectLater(
          Engine.create(webConfig()),
          throwsA(
            errorWith<web.LiteRtLmWebModuleError>(
              'window.litertLm is not set',
            ).having(
              (e) => e.message,
              'message',
              allOf(
                contains(web.liteRtLmWebModuleShimLine),
                isNot(contains('replace')),
              ),
            ),
          ),
        );
      },
    );

    test('a page with the old shim (window.Engine, no window.litertLm) is a '
        'StateError naming the lines to replace', () async {
      final engine = stubModule['Engine'];
      removeRuntime();
      globalContext['Engine'] = engine;
      globalContext['litertLmReady'] = Future<JSAny?>.value(engine).toJS;
      addTearDown(() => globalContext.delete('Engine'.toJS));

      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          errorWith<web.LiteRtLmWebModuleError>('but window.Engine or').having(
            (e) => e.message,
            'message',
            allOf(
              contains('window.Engine = m.Engine;'),
              contains('window.EmbeddingEngine = m.EmbeddingEngine;'),
              contains(web.liteRtLmWebModuleShimLine),
            ),
          ),
        ),
      );
    });

    test('a window.litertLm that is not an object is a StateError', () async {
      globalContext['litertLm'] = 'module'.toJS;

      await expectLater(
        Engine.create(webConfig()),
        throwsWith<web.LiteRtLmWebModuleError>(
          'window.litertLm is a value of type string',
        ),
      );
    });

    test('a module without Engine is a StateError naming it, while the '
        'module is otherwise whole', () async {
      stubModule.delete('Engine'.toJS);

      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          errorWith<web.LiteRtLmWebModuleError>(
            'window.litertLm has no Engine (a value of type undefined)',
          ).having(
            (e) => e.message,
            'message',
            contains(web.liteRtLmWebModuleUrl),
          ),
        ),
      );
      expect(list('createSettings'), isEmpty);
    });

    test('a runtime lacking a member the release calls is a StateError '
        'naming it and the pinned version', () async {
      ((stubModule['Engine']! as JSObject)['prototype']! as JSObject).delete(
        'createConversation'.toJS,
      );

      await expectLater(
        Engine.create(webConfig()),
        throwsA(
          errorWith<StateError>('createConversation').having(
            (e) => e.message,
            'message',
            contains(web.liteRtLmWebRuntimeVersion),
          ),
        ),
      );
      expect(list('createSettings'), isEmpty);
    });

    test('hands Engine.create the model, the backend, the context and the '
        'thread count; reads back what the runtime resolved', () async {
      setOnPage(
        'resolvedBackend',
        backendId('GPU_ARTISAN'),
      ); // a web export on the GPU
      setOnPage('maxNumTokens', 2048);
      final engine = await Engine.create(webConfig(tokens: 2048));
      expect(asMap(list('createSettings').single), {
        'model': 'blob:https://example.com/model',
        'backend': backendId('GPU'),
        'mainExecutorSettings': {'maxNumTokens': 2048},
      });
      expect(engine.backend, const Backend.gpu());
      expect(engine.maxNumTokens, 2048);
      expect(engine.bundleInfo, isNull);
      await engine.close();

      installRuntime();
      setOnPage('resolvedBackend', backendId('CPU'));
      final cpu = await Engine.create(
        webConfig(backend: const Backend.cpu(threadCount: 2)),
      );
      final cpuSettings = asMap(list('createSettings').single);
      expect(cpuSettings['backend'], backendId('CPU'));
      expect(cpuSettings['mainExecutorSettings'], {
        'backendConfig': {'number_of_threads': 2},
      });
      expect(cpu.backend, const Backend.cpu());
      await cpu.close();
    });

    test('a backend the release does not know is a StateError', () async {
      setOnPage('resolvedBackend', 6);
      await expectLater(
        Engine.create(webConfig()),
        throwsWith<StateError>('backend 6'),
      );
    });

    group('the Backend ids are the module\'s own (window.litertLm.Backend)', () {
      for (final (version, backends) in [
        ('0.19.0', backends019),
        ('0.20.0', backends020),
      ]) {
        group(version, () {
          final cpu = backends['CPU']!;
          final gpu = backends['GPU']!;
          final artisan = backends['GPU_ARTISAN']!;
          setUp(() {
            removeRuntime();
            installRuntime(backends: backends);
          });

          test('the backend and the encoders are sent as its CPU ($cpu) and '
              'GPU ($gpu), and read back as they resolved', () async {
            setOnPage('resolvedVisionBackend', gpu);
            setOnPage('resolvedAudioBackend', cpu);
            final engine = await Engine.create(
              EngineConfig(
                modelPath: 'blob:x',
                backend: const Backend.gpu(),
                visionBackend: const Backend.gpu(),
                audioBackend: const Backend.cpu(),
              ),
            );
            final settings = asMap(list('createSettings').single);
            expect(settings['backend'], gpu);
            expect(settings['visionBackend'], gpu);
            expect(settings['audioBackend'], cpu);
            expect(engine.backend, const Backend.gpu());
            expect(engine.visionBackend, const Backend.gpu());
            expect(engine.audioBackend, const Backend.cpu());
            await engine.close();
          });

          test('GPU_ARTISAN ($artisan) reads back as the GPU, CPU ($cpu) as '
              'the CPU', () async {
            setOnPage('resolvedBackend', artisan);
            final engine = await Engine.create(webConfig());
            expect(engine.backend, const Backend.gpu());
            await engine.close();

            setOnPage('resolvedBackend', cpu);
            final onCpu = await Engine.create(
              webConfig(backend: const Backend.cpu()),
            );
            expect(asMap(list('createSettings').last)['backend'], cpu);
            expect(onCpu.backend, const Backend.cpu());
            await onCpu.close();
          });

          test('an id it reports that is not CPU, GPU or GPU_ARTISAN is '
              'refused naming the id and the enum\'s name for it, and the '
              'engine is deleted', () async {
            setOnPage('resolvedBackend', backends['NPU']);
            await expectLater(
              Engine.create(webConfig()),
              throwsWith<StateError>(
                'backend ${backends['NPU']}, which this release does not know '
                '(NPU in the page\'s Backend)',
              ),
            );
            expect(count('engineDeletes'), 1);

            setOnPage('resolvedBackend', 42);
            await expectLater(
              Engine.create(webConfig()),
              throwsWith<StateError>(
                'backend 42, which this release does not know (not in the '
                'page\'s Backend',
              ),
            );
          });

          test(
            'an encoder on an id it does not know is refused naming it',
            () async {
              setOnPage('resolvedAudioBackend', backends['NPU']);
              await expectLater(
                Engine.create(
                  EngineConfig(
                    modelPath: 'blob:x',
                    backend: const Backend.gpu(),
                    audioBackend: const Backend.cpu(),
                  ),
                ),
                throwsWith<LiteRtLmEngineCreateException>(
                  'with its audio encoder on backend ${backends['NPU']}, which '
                  'this release does not know (NPU in the page\'s Backend)',
                ),
              );
              expect(count('engineDeletes'), 1);
            },
          );
        });
      }

      for (final (what, backends, reason) in <(String, Object?, String)>[
        (
          'missing',
          null,
          'window.litertLm has no Backend (a value of type undefined)',
        ),
        (
          'not an object',
          'GPU',
          'window.litertLm.Backend is a value of type string',
        ),
        ('without CPU', {'GPU': 3, 'GPU_ARTISAN': 1}, 'it has no CPU'),
        (
          'with a GPU that is not an integer',
          {'CPU': 2, 'GPU': 3.5, 'GPU_ARTISAN': 1},
          'its GPU is 3.5, not an integer',
        ),
      ]) {
        test('a module whose enum is $what is a StateError naming the '
            'runtime to import, before Engine.create', () async {
          if (backends == null) {
            stubModule.delete('Backend'.toJS);
          } else {
            stubModule['Backend'] = backends.jsify();
          }
          await expectLater(
            Engine.create(webConfig()),
            throwsA(
              errorWith<web.LiteRtLmWebBackendEnumError>(reason).having(
                (e) => e.message,
                'message',
                contains(web.liteRtLmWebModuleUrl),
              ),
            ),
          );
          expect(list('createSettings'), isEmpty);
        });
      }
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
            ConversationConfig(
              speculativeDecoding: SpeculativeDecodingConfig(
                mode: SpeculativeDecodingMode.on,
              ),
            ),
          ),
          refusal('the web export has no drafter'),
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
      await expectLater(
        engine.tokenize('x'),
        throwsWith<UnsupportedError>('no tokenizer'),
      );
      await expectLater(
        engine.detokenize([1]),
        throwsWith<UnsupportedError>('no tokenizer'),
      );
      await expectLater(
        engine.scoreTargets('p', ['t']),
        throwsWith<UnsupportedError>('Option scoring does not run on the web'),
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

    // On 0.20.0 and later as user text: they mostly answer a tool message
    // with nothing (web_conversation_tools_browser_test.dart has 0.19.0's tool
    // message).
    test('a tool result goes as user text on the pinned runtime', () async {
      // A conversation that declares the tool: a tool result on one that
      // declares none is refused before anything is sent.
      await conversation.close();
      conversation = await engine.createConversation(
        ConversationConfig(tools: [Tool(name: 'f')]),
      );
      final done = conversation
          .sendMessageStream(
            Message.tool([
              Content.toolResponse('f', {'ok': true}),
            ]),
          )
          .drain<void>();
      await settle();
      expect(list('sent').single, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Tool f returned: {"ok":true}'},
        ],
      });
      js('__end');
      await done;
    });

    group('refuses, without sending', () {
      late Conversation c;
      setUp(
        () async => c = await engine.createConversation(
          ConversationConfig(extraContext: {'a': 1, 'b': 2}),
        ),
      );

      test('an image on an engine without a vision encoder', () async {
        await expectLater(
          c.sendMessageStream(
            Message(
              role: Role.user,
              contents: [Content.imageBytes(Uint8List(4))],
            ),
          ),
          emitsError(errorWith<UnsupportedError>('loaded no vision encoder')),
        );
        expect(list('sent'), isEmpty);
      });

      test('thinking asked per message', () async {
        await expectLater(
          c.sendMessageStream(
            Message.user('x'),
            thinkingConfig: ThinkingConfig(),
          ),
          emitsError(
            errorWith<UnsupportedError>('thinking is set per conversation'),
          ),
        );
        expect(list('sent'), isEmpty);
      });

      test('other template variables', () async {
        await expectLater(
          c.sendMessageStream(Message.user('x'), extraContext: {'a': 2}),
          emitsError(errorWith<UnsupportedError>('template variables')),
        );
        expect(list('sent'), isEmpty);
      });

      test('a per-message decoding option', () async {
        await expectLater(
          c.sendMessageStream(Message.user('x'), suppressTokens: [1]),
          emitsError(errorWith<UnsupportedError>('suppressTokens')),
        );
        expect(list('sent'), isEmpty);
      });
    });

    test(
      'the same template variables in another key order are accepted',
      () async {
        final c = await engine.createConversation(
          ConversationConfig(extraContext: {'a': 1, 'b': 2}),
        );

        final sent = c
            .sendMessageStream(
              Message.user('x'),
              extraContext: {'b': 2, 'a': 1},
            )
            .drain<void>();
        await settle();
        js('__end');
        await sent;

        expect(list('sent'), hasLength(1));
      },
    );

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
      expect(
        conversation.getBenchmarkInfo,
        throwsWith<UnsupportedError>('benchmark mode'),
      );
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
        emitsError(errorWith<ConversationClosedException>('closed')),
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
        throwsWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
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
      await expectLater(
        create,
        throwsWith<StateError>('closed while a conversation opened'),
      );
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
        throwsWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
      );
      await expectLater(
        lock.acquire(),
        throwsWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
      );
      await expectLater(
        engine.close(),
        throwsWith<web.LiteRtLmPagePoisonedError>('Reload the page'),
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
    expect(
      engine.createConversation,
      throwsWith<StateError>('The engine is closed.'),
    );
    expect(
      () => conversation.sendMessageStream(Message.user('x')),
      throwsWith<StateError>('closed'),
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
      await expectLater(
        readBundleInfo('m.litertlm'),
        throwsWith<UnsupportedError>('which the web cannot'),
      );
      await expectLater(
        readBundleGenericData('m.litertlm', 'x'),
        throwsWith<UnsupportedError>('which the web'),
      );
      await expectLater(
        benchmark(modelPath: 'm', backend: const Backend.gpu()),
        throwsWith<UnsupportedError>('benchmark mode'),
      );
    },
  );
}

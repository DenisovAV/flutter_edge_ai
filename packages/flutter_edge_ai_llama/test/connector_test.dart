import 'dart:async';

import 'package:flutter/foundation.dart';
// ignore: implementation_imports — verifies actual provider selection for the declared GGUF routing contract.
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;
  late LlamaInferenceModel model;
  setUp(() {
    engine = _FakeEngine();
    model = LlamaInferenceModel(
      engine: engine,
      maxTokens: 2048,
      activeBackend: edge.PreferredBackend.cpu,
    );
  });
  tearDown(() async {
    await model.close();
    EngineRegistry.instance.reset();
  });

  test('registry claims declared GGUF regardless of filename', () {
    const provider = LlamaEngineProvider();
    EngineRegistry.instance.registerAll([provider]);
    for (final filename in [
      'model.gguf',
      'model.GGUF',
      'weights',
      'weights.bin',
    ]) {
      expect(EngineRegistry.instance.findFor(_spec(filename)), same(provider));
    }
    for (final type in edge.ModelFileType.values) {
      if (type == edge.ModelFileType.gguf) continue;
      expect(
        EngineRegistry.instance.findFor(_spec('model.gguf', type)),
        isNull,
      );
    }
    expect(model.fileType, edge.ModelFileType.gguf);
  });

  test('provider refuses binary GGUF before loading', () async {
    final provider = LlamaEngineProvider(
      loader: (_, _) async => fail('Binary files must not reach llama'),
    );
    await expectLater(
      provider.createModel(
        _spec('model.gguf', edge.ModelFileType.binary),
        const RuntimeConfig(modelPath: '/models/model.gguf', maxTokens: 2048),
      ),
      throwsA(isA<llama.LlamaUnsupportedException>()),
    );
  });

  test('installed LoRA path becomes the default for generation', () async {
    final spec = edge.InferenceModelSpec(
      name: 'model',
      modelSource: _source('/models/model.gguf'),
      loraSource: _source('/models/adapter.gguf'),
      modelType: edge.ModelType.general,
      fileType: edge.ModelFileType.gguf,
    );
    final provider = LlamaEngineProvider(loader: (_, _) async => engine);
    final config = RuntimeConfig(
      modelPath: '/models/model.gguf',
      maxTokens: 2048,
      artifactPaths: {
        spec.files[0].prefsKey: '/models/model.gguf',
        spec.files[1].prefsKey: '/models/adapter.gguf',
      },
    );
    expect(spec.files[1].filename, 'model__adapter.gguf');
    if (kIsWeb) {
      await expectLater(
        provider.createModel(spec, config),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
      expect(engine.requests, isEmpty);
      return;
    }
    final loaded =
        await provider.createModel(spec, config) as LlamaInferenceModel;
    addTearDown(loaded.close);
    expect(loaded.defaultLoraPath, '/models/adapter.gguf');
    final session = await loaded.openSession();
    await session.addQueryChunk(
      edge.Message.text(text: 'adapted', isUser: true),
    );
    await session.getResponse();
    expect(engine.adaptersAtGeneration, ['/models/adapter.gguf']);
    expect(engine.activeAdapter, isNull);
  });

  test(
    'closed state starts before teardown and close shares its future',
    () async {
      final gate = Completer<void>();
      engine.disposeGate = gate;
      var notifications = 0;
      model.addCloseListener(() => notifications++);
      expect(model.isClosed, isFalse);
      final closing = model.close();
      try {
        expect(model.isClosed, isTrue);
        expect(model.close(), same(closing));
        await engine.disposeStarted.future.timeout(const Duration(seconds: 2));
        expect(notifications, 0);
        expect(engine.disposals, 0);
        expect(
          () => model.createSession(),
          throwsA(isA<llama.LlamaStateException>()),
        );
      } finally {
        gate.complete();
        await closing;
      }
      expect(model.isClosed, isTrue);
      expect(notifications, 1);
      expect(engine.disposals, 1);
    },
  );

  test('provider forwards context and CPU selection through load', () async {
    final provider = LlamaEngineProvider(
      loader: (path, params) async {
        expect(path, '/models/test.gguf');
        expect(params.contextSize, 2048);
        expect(params.device, llama.ComputeDevice.cpu);
        expect(params.gpuLayers, 0);
        return engine;
      },
    );
    final loaded = await provider.createModel(
      _spec('test.gguf'),
      const RuntimeConfig(
        modelPath: '/models/test.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.cpu,
      ),
    );
    expect(loaded.activeBackend, edge.PreferredBackend.cpu);
    await loaded.close();
    expect(engine.disposals, 1);
  });

  test(
    'explicit GPU selection rejects CPU fallback and disposes runtime',
    () async {
      final provider = LlamaEngineProvider(loader: (_, _) async => engine);
      await expectLater(
        provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: 'model.gguf',
            maxTokens: 2048,
            preferredBackend: edge.PreferredBackend.gpu,
          ),
        ),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
      expect(engine.disposals, 1);
    },
  );

  test(
    'GPU reporting preserves verified offload and unknown runtime identity',
    () async {
      final provider = LlamaEngineProvider(loader: (_, _) async => engine);
      for (final layers in <int?>[12, null]) {
        engine.gpuLayers = layers;
        final loaded = await provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: 'model.gguf',
            maxTokens: 2048,
            preferredBackend: edge.PreferredBackend.gpu,
          ),
        );
        expect(
          loaded.activeBackend,
          layers == null ? isNull : edge.PreferredBackend.gpu,
        );
        await loaded.close();
      }
    },
  );

  test('provider rejects unsupported configuration before loading', () async {
    final provider = LlamaEngineProvider(
      loader: (_, _) async => fail('Unsupported configurations must not load'),
    );
    for (final config in [
      const RuntimeConfig(
        modelPath: 'test.gguf',
        maxTokens: 2048,
        supportImage: true,
      ),
      const RuntimeConfig(
        modelPath: 'test.gguf',
        maxTokens: 2048,
        supportAudio: true,
      ),
      const RuntimeConfig(
        modelPath: 'test.gguf',
        maxTokens: 2048,
        preferredBackend: edge.PreferredBackend.npu,
      ),
      const RuntimeConfig(
        modelPath: 'test.gguf',
        maxTokens: 2048,
        enableSpeculativeDecoding: true,
      ),
    ]) {
      await expectLater(
        provider.createModel(_spec('test.gguf'), config),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
    }
  });

  test('load cleanup disposes an unexpected runtime', () async {
    engine.fakeRuntime = llama.LlamaRuntime.liteRtLm;
    final provider = LlamaEngineProvider(loader: (_, _) async => engine);
    await expectLater(
      provider.createModel(
        _spec('test.gguf'),
        const RuntimeConfig(modelPath: 'test.gguf', maxTokens: 2048),
      ),
      throwsA(isA<llama.LlamaUnsupportedException>()),
    );
    expect(engine.disposals, 1);
  });

  test('public Edge AI chat streams raw input, history and sampling', () async {
    final chat = await model.createChat(
      systemInstruction: 'Be concise.',
      temperature: .25,
      randomSeed: 42,
      topK: 12,
      topP: .8,
      maxOutputTokens: 64,
    );
    await chat.addQueryChunk(
      edge.Message.text(text: 'Remember the word orchid.', isUser: true),
    );
    final first = await chat.generateChatResponseAsync().toList();
    expect(
      first.whereType<edge.TextResponse>().map((r) => r.token).join(),
      'Hello world',
    );
    await chat.addQueryChunk(
      edge.Message.text(text: 'What word?', isUser: true),
    );
    await chat.generateChatResponseAsync().drain<void>();
    expect(engine.requests.last.map((m) => m.role), [
      llama.LlamaChatRole.system,
      llama.LlamaChatRole.user,
      llama.LlamaChatRole.assistant,
      llama.LlamaChatRole.user,
    ]);
    expect(engine.requests.last.map((m) => m.content), [
      'Be concise.',
      'Remember the word orchid.',
      'Hello world',
      'What word?',
    ]);
    expect(engine.lastParams!.temp, .25);
    expect(engine.lastParams!.seed, 42);
    expect(engine.lastParams!.topK, 12);
    expect(engine.lastParams!.topP, .8);
    expect(engine.lastParams!.maxTokens, 64);
    expect(engine.lastThinking, isFalse);
    expect(engine.lastToolChoice, llama.ToolChoice.auto);
    final metrics = chat.session.getSessionMetrics();
    expect(metrics.inputTokens, 10);
    expect(metrics.outputTokens, 2);
    expect(metrics.totalTokens, 12);
    expect(metrics.timeToFirstTokenMs, 5);
  });

  test(
    'new legacy session closes old history without unloading weights',
    () async {
      final first = await model.createSession(maxOutputTokens: 64);
      await first.addQueryChunk(edge.Message.text(text: 'old', isUser: true));
      await first.getResponse();
      final second = await model.createSession(maxOutputTokens: 64);
      expect(
        first.addQueryChunk(edge.Message.text(text: 'invalid', isUser: true)),
        throwsA(isA<llama.LlamaStateException>()),
      );
      await second.addQueryChunk(edge.Message.text(text: 'new', isUser: true));
      await second.getResponse();
      expect(engine.requests.last.map((m) => m.content), ['new']);
      expect(engine.disposals, 0);
      expect(model.sessions, [second]);
    },
  );

  test('disabled modalities and orphan tool results fail loudly', () async {
    await expectLater(
      model.createChat(toolChoice: edge.ToolChoice.required),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
    expect(
      () => model.createSession(enableVisionModality: true),
      throwsA(isA<llama.LlamaUnsupportedException>()),
    );
    final session = await model.createSession();
    for (final message in [
      edge.Message.withImage(
        text: 'image',
        imageBytes: Uint8List(1),
        isUser: true,
      ),
      edge.Message.audioOnly(audioBytes: Uint8List(1), isUser: true),
    ]) {
      await expectLater(
        session.addQueryChunk(message),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
    }
    await expectLater(
      session.addQueryChunk(
        edge.Message.toolResponse(toolName: 'search', response: {'ok': true}),
      ),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
  });

  test('rendered template overhead is checked before inference', () async {
    engine.promptTokens = 2000;
    final session = await model.createSession(maxOutputTokens: 64);
    await session.addQueryChunk(
      edge.Message.text(text: 'short raw text', isUser: true),
    );
    await expectLater(
      session.getResponse(),
      throwsA(isA<llama.LlamaContextException>()),
    );
    expect(engine.requests, isEmpty);
  });

  test('invalid sampling and output budgets are rejected', () {
    for (final limit in [0, -1, 2048]) {
      expect(
        () => model.createSession(maxOutputTokens: limit),
        throwsA(isA<llama.LlamaArgumentException>()),
      );
    }
    expect(
      () => model.createSession(temperature: double.nan),
      throwsArgumentError,
    );
    expect(() => model.createSession(topP: 0), throwsArgumentError);
  });

  for (final operation in [
    'createSession',
    'openSession',
    'createChat',
    'openChat',
  ]) {
    test(
      '$operation accepts nullable values and forwards general defaults',
      () async {
        final edge.InferenceModel facade = model;
        final session = switch (operation) {
          'createSession' => await facade.createSession(
            temperature: null,
            topK: null,
            topP: null,
            randomSeed: null,
          ),
          'openSession' => await facade.openSession(
            temperature: null,
            topK: null,
            topP: null,
            randomSeed: null,
          ),
          'createChat' => (await facade.createChat(
            temperature: null,
            topK: null,
            topP: null,
            randomSeed: null,
          )).session,
          _ => (await facade.openChat(
            temperature: null,
            topK: null,
            topP: null,
            randomSeed: null,
          )).session,
        };
        await session.addQueryChunk(
          edge.Message.text(text: 'hello', isUser: true),
        );
        await session.getResponse();
        expect(engine.lastParams!.temp, .8);
        expect(engine.lastParams!.topK, 40);
        expect(engine.lastParams!.topP, .95);
        expect(engine.lastParams!.seed, 1);
      },
    );
  }

  test(
    'provider retains installed family for sessions and both chat paths',
    () async {
      final provider = LlamaEngineProvider(loader: (_, _) async => engine);
      final loaded = await provider.createModel(
        _spec('gemma.gguf', edge.ModelFileType.gguf, edge.ModelType.gemma4),
        const RuntimeConfig(modelPath: 'gemma.gguf', maxTokens: 2048),
      );
      try {
        for (final operation in [
          'createSession',
          'openSession',
          'createChat',
          'openChat',
        ]) {
          final session = switch (operation) {
            'createSession' => await loaded.createSession(),
            'openSession' => await loaded.openSession(),
            'createChat' => (await loaded.createChat()).session,
            _ => (await loaded.openChat()).session,
          };
          await session.addQueryChunk(
            edge.Message.text(text: 'hi', isUser: true),
          );
          await session.getResponse();
          expect(engine.lastParams!.temp, 1);
          expect(engine.lastParams!.topK, 64);
          expect(engine.lastParams!.topP, .95);
        }
        expect(
          (loaded as LlamaInferenceModel).modelType,
          edge.ModelType.gemma4,
        );
      } finally {
        await loaded.close();
      }
    },
  );

  for (final detached in [false, true]) {
    test(
      'chat family override and thinking defaults reach runtime (detached: $detached)',
      () async {
        for (final thinking in [false, true]) {
          final chat = detached
              ? await model.openChat(
                  modelType: edge.ModelType.qwen3,
                  enableThinking: thinking,
                )
              : await model.createChat(
                  modelType: edge.ModelType.qwen3,
                  enableThinking: thinking,
                );
          await chat.addQuery(edge.Message.text(text: 'hi', isUser: true));
          await chat.generateChatResponse();
          expect(engine.lastParams!.temp, thinking ? .6 : .7);
          expect(engine.lastParams!.topK, 20);
          expect(engine.lastParams!.topP, thinking ? .95 : .8);
          await chat.close();
        }
      },
    );
  }

  test('session thinking uses installed family and partial overrides keep defaults', () async {
    final provider = LlamaEngineProvider(loader: (_, _) async => engine);
    final loaded = await provider.createModel(
      _spec('qwen.gguf', edge.ModelFileType.gguf, edge.ModelType.qwen3),
      const RuntimeConfig(modelPath: 'qwen.gguf', maxTokens: 2048),
    );
    try {
      for (final session in [
        await loaded.createSession(enableThinking: true, randomSeed: 42),
        await loaded.openSession(enableThinking: true, topP: .9),
      ]) {
        await session.addQueryChunk(
          edge.Message.text(text: 'hi', isUser: true),
        );
        await session.getResponse();
        expect(engine.lastParams!.temp, .6);
        expect(engine.lastParams!.topK, 20);
        expect(
          engine.lastParams!.seed,
          identical(session, loaded.session) ? 42 : 1,
        );
        expect(
          engine.lastParams!.topP,
          identical(session, loaded.session) ? .95 : .9,
        );
      }
      final explicit = await loaded.openSession(
        temperature: .2,
        topK: 12,
        topP: .75,
        randomSeed: 7,
      );
      await explicit.addQueryChunk(edge.Message.text(text: 'hi', isUser: true));
      await explicit.getResponse();
      expect(engine.lastParams!.temp, .2);
      expect(engine.lastParams!.topK, 12);
      expect(engine.lastParams!.topP, .75);
      expect(engine.lastParams!.seed, 7);
    } finally {
      await loaded.close();
    }
  });

  test(
    'explicit sampling skips greedy family; explicit greedy remains greedy',
    () async {
      for (final create in [model.createChat, model.openChat]) {
        final chat = await create(
          modelType: edge.ModelType.phi,
          temperature: .5,
        );
        await chat.addQuery(edge.Message.text(text: 'hi', isUser: true));
        await chat.generateChatResponse();
        expect(engine.lastParams!.temp, .5);
        expect(engine.lastParams!.topK, 40);
        await chat.close();
        final topPChat = await create(modelType: edge.ModelType.phi, topP: .7);
        await topPChat.addQuery(edge.Message.text(text: 'hi', isUser: true));
        await topPChat.generateChatResponse();
        expect(engine.lastParams!.temp, .8);
        expect(engine.lastParams!.topK, 40);
        expect(engine.lastParams!.topP, .7);
        await topPChat.close();
        final greedy = await create(temperature: 0, topK: 64);
        await greedy.addQuery(edge.Message.text(text: 'hi', isUser: true));
        await greedy.generateChatResponse();
        expect(engine.lastParams!.topK, 1);
        await greedy.close();
      }
      for (final create in [model.createSession, model.openSession]) {
        for (final temperature in [0.0, .5]) {
          final session = await create(
            temperature: temperature,
            topK: temperature == 0 ? 64 : 1,
          );
          await session.addQueryChunk(
            edge.Message.text(text: 'hi', isUser: true),
          );
          await session.getResponse();
          expect(engine.lastParams!.topK, 1);
          await session.close();
        }
      }
    },
  );

  test(
    'invalid sampling on all entry points preserves a usable legacy session',
    () async {
      final original = await model.createSession();
      for (final create in [model.createSession, model.openSession]) {
        for (final topK in [0, -1]) {
          expect(() => create(topK: topK), throwsArgumentError);
        }
        for (final temperature in [-1.0, double.infinity, double.nan]) {
          expect(() => create(temperature: temperature), throwsArgumentError);
        }
        for (final topP in [0.0, 1.1, double.infinity, double.nan]) {
          expect(() => create(topP: topP), throwsArgumentError);
        }
      }
      for (final create in [model.createChat, model.openChat]) {
        await expectLater(create(topK: 0), throwsArgumentError);
        await expectLater(create(temperature: double.nan), throwsArgumentError);
        await expectLater(create(topP: 0), throwsArgumentError);
      }
      expect(model.session, same(original));
      await original.addQueryChunk(
        edge.Message.text(text: 'still usable', isUser: true),
      );
      await original.getResponse();
      expect(engine.requests.single.single.content, 'still usable');
      expect(model.sessions, [original]);
    },
  );

  test('Edge AI family heuristics do not alter GGUF user text', () async {
    final chat = await model.createChat(modelType: edge.ModelType.qwen3);
    await chat.addQueryChunk(
      edge.Message.text(text: 'plain input', isUser: true),
    );
    await chat.generateChatResponseAsync().drain<void>();
    expect(engine.requests.single.single.content, 'plain input');
  });

  test('generation errors discard partial output before retry', () async {
    engine.failAfterFirstToken = true;
    final session = await model.createSession();
    await session.addQueryChunk(
      edge.Message.text(text: 'failed', isUser: true),
    );
    await expectLater(
      session.getResponse(),
      throwsA(isA<llama.LlamaInferenceException>()),
    );
    engine.failAfterFirstToken = false;
    await session.addQueryChunk(edge.Message.text(text: 'retry', isUser: true));
    await session.getResponse();
    expect(engine.requests.last.map((m) => m.content), ['retry']);
  });

  test('stop cancels the engine and rolls back the interrupted turn', () async {
    final session = await model.createSession(maxOutputTokens: 64);
    await session.addQueryChunk(edge.Message.text(text: 'keep', isUser: true));
    await session.getResponse();
    engine.blockGeneration = true;
    await session.addQueryChunk(
      edge.Message.text(text: 'abandoned', isUser: true),
    );
    final firstToken = Completer<void>();
    final subscription = session.getResponseAsync().listen((_) {
      if (!firstToken.isCompleted) firstToken.complete();
    });
    await firstToken.future;
    await session.stopGeneration().timeout(const Duration(seconds: 2));
    await subscription.cancel();
    expect(engine.cancels, greaterThan(0));
    engine.blockGeneration = false;
    await session.addQueryChunk(edge.Message.text(text: 'next', isUser: true));
    await session.getResponse();
    expect(engine.requests.last.map((m) => m.content), [
      'keep',
      'Hello world',
      'next',
    ]);
  });

  test(
    'subscription cancellation stops native work before the next turn',
    () async {
      engine.blockGeneration = true;
      final session = await model.createSession(maxOutputTokens: 64);
      await session.addQueryChunk(
        edge.Message.text(text: 'abandoned', isUser: true),
      );
      final firstToken = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => firstToken.complete(),
      );
      await firstToken.future;
      await subscription.cancel().timeout(const Duration(seconds: 2));
      expect(engine.cancels, greaterThan(0));
      engine.blockGeneration = false;
      await session.addQueryChunk(
        edge.Message.text(text: 'next', isUser: true),
      );
      await session.getResponse();
      expect(engine.requests.last.map((m) => m.content), ['next']);
    },
  );

  test('rejecting overlapping generation does not cancel its owner', () async {
    engine.blockGeneration = true;
    final session = await model.createSession(maxOutputTokens: 64);
    await session.addQueryChunk(edge.Message.text(text: 'one', isUser: true));
    final firstToken = Completer<void>();
    final subscription = session.getResponseAsync().listen(
      (_) => firstToken.complete(),
    );
    await firstToken.future;
    final cancels = engine.cancels;
    await expectLater(
      session.getResponse(),
      throwsA(isA<llama.LlamaStateException>()),
    );
    expect(engine.cancels, cancels);
    await subscription.cancel();
  });

  test(
    'closing drains generation, fires once, and rejects later use',
    () async {
      var closed = 0;
      model.addCloseListener(() => closed++);
      engine.blockGeneration = true;
      final session = await model.createSession(maxOutputTokens: 64);
      await session.addQueryChunk(edge.Message.text(text: 'one', isUser: true));
      final firstToken = Completer<void>();
      final subscription = session.getResponseAsync().listen(
        (_) => firstToken.complete(),
      );
      await firstToken.future;
      await Future.wait([model.close(), model.close()])
          .timeout(const Duration(seconds: 2));
      await subscription.cancel();
      expect(engine.disposals, 1);
      expect(closed, 1);
      expect(
        () => model.createSession(),
        throwsA(isA<llama.LlamaStateException>()),
      );
      expect(model.sessions, isEmpty);
    },
  );
  test('typed thinking reaches chat only when enabled', () async {
    engine.script = [_thinking('reason'), _chunk('answer')];
    final chat = await model.createChat(enableThinking: true);
    await chat.addQuery(edge.Message.text(text: 'why', isUser: true));
    final responses = await chat.generateChatResponseAsync().toList();
    expect(
      responses.whereType<edge.ThinkingResponse>().single.content,
      'reason',
    );
    expect(engine.lastThinking, isTrue);
    expect(chat.fullHistory.map((m) => m.type), [
      edge.MessageType.text,
      edge.MessageType.thinking,
      edge.MessageType.text,
    ]);
    final hidden = await model.createChat(enableThinking: false);
    await hidden.addQuery(edge.Message.text(text: 'why', isUser: true));
    expect(
      (await hidden.generateChatResponseAsync().toList())
          .whereType<edge.ThinkingResponse>(),
      isEmpty,
    );
  });

  const tool = edge.Tool(
    name: 'search',
    description: 'Search',
    parameters: {
      'type': 'object',
      'properties': {
        'q': {'type': 'string'},
      },
      'required': ['q'],
      'additionalProperties': false,
    },
  );
  test(
    'fragmented tool calls preserve schemas and call IDs through results',
    () async {
      engine.script = [
        _toolChunk(0, 'search', '{"q":', id: 'call_1'),
        _toolChunk(0, null, '"flower"}'),
      ];
      final chat = await model.createChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.required,
      );
      await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
      final response = await chat.generateChatResponse();
      final call = response as LlamaFunctionCallResponse;
      expect(call.id, 'call_1');
      expect(call.args, {'q': 'flower'});
      expect(engine.lastTools.single.toJsonSchema(), tool.parameters);
      expect(engine.lastTemplateTools.single.toJsonSchema(), tool.parameters);
      expect(engine.lastToolChoice, llama.ToolChoice.required);
      await expectLater(
        chat.addQuery(edge.Message.text(text: 'next', isUser: true)),
        throwsA(isA<llama.LlamaStateException>()),
      );
      await chat.addQuery(
        LlamaToolResponseMessage(
          callId: call.id,
          toolName: call.name,
          response: {'found': true},
        ),
      );
      await chat.generateChatResponseAsync().drain<void>();
      final result =
          engine.requests.last.last.parts.single
              as llama.LlamaToolResultContent;
      expect(result.id, call.id);
      expect(result.result, {'found': true});
    },
  );

  test(
    'parallel calls with same name accept explicit IDs out of order',
    () async {
      engine.script = [
        _toolChunk(0, 'search', '{"q":"a"}', id: 'a'),
        _toolChunk(1, 'search', '{"q":"b"}', id: 'b'),
      ];
      final chat = await model.createChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'both', isUser: true));
      final response =
          await chat.generateChatResponse()
              as edge.ParallelFunctionCallResponse;
      expect(response.calls.map((c) => (c as LlamaFunctionCallResponse).id), [
        'a',
        'b',
      ]);
      await chat.addQuery(
        LlamaToolResponseMessage(
          callId: 'b',
          toolName: 'search',
          response: {'b': true},
        ),
      );
      await chat.addQuery(
        edge.Message.toolResponse(toolName: 'search', response: {'a': true}),
      );
      engine.script = [_chunk('done')];
      await chat.generateChatResponseAsync().drain<void>();
      expect(
        engine.requests.last
            .where((m) => m.role == llama.LlamaChatRole.tool)
            .map((m) => (m.parts.single as llama.LlamaToolResultContent).id),
        ['b', 'a'],
      );
    },
  );

  test(
    'inherited bounded tool loop uses typed calls and stages real results',
    () async {
      engine.scripts = [
        [_toolChunk(0, 'search', '{"q":"a"}', id: 'a')],
        [_chunk('found')],
      ];
      final chat = await model.createChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
      var calls = 0;
      final responses = await chat
          .generateChatResponseWithTools(
            onToolCall: (call) async {
              calls++;
              return {'ok': true};
            },
          )
          .toList();
      expect(calls, 1);
      expect(responses.whereType<edge.TextResponse>().single.token, 'found');
      expect(engine.requests.last.last.role, llama.LlamaChatRole.tool);
    },
  );

  test('none tool choice does not forward declarations', () async {
    final chat = await model.createChat(
      tools: [tool],
      toolChoice: edge.ToolChoice.none,
    );
    await chat.addQuery(edge.Message.text(text: 'hello', isUser: true));
    await chat.generateChatResponse();
    expect(engine.lastTools, isEmpty);
    expect(engine.lastToolChoice, llama.ToolChoice.none);
  });

  test('malformed, undeclared and missing required calls roll back', () async {
    for (final script in [
      [_toolChunk(0, 'search', '{')],
      [_toolChunk(0, 'unknown', '{}')],
      [_chunk('no call')],
    ]) {
      engine.script = script;
      final chat = await model.createChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.required,
      );
      await chat.addQuery(edge.Message.text(text: 'failed', isUser: true));
      await expectLater(
        chat.generateChatResponseAsync().toList(),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      expect(chat.fullHistory, isEmpty);
    }
  });

  test('replayed tool payloads fail atomically with typed errors', () async {
    final chat = await model.openChat(tools: [tool]);
    for (final payload in [
      '{',
      '{}',
      '{"tool_calls":[]}',
      '{"tool_calls":[{"function":{"name":"unknown","arguments":{}}}]}',
      '{"tool_calls":[{"function":{"name":"search","arguments":[]}}]}',
      '{"tool_calls":[{"id":"same","function":{"name":"search","arguments":{}}},{"id":"same","function":{"name":"search","arguments":{}}}]}',
    ]) {
      await expectLater(
        chat.addQuery(edge.Message.toolCall(text: payload)),
        throwsA(isA<llama.LlamaArgumentException>()),
      );
      expect(chat.fullHistory, isEmpty);
    }
    await expectLater(
      chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'partially staged', isUser: true),
          edge.Message.toolCall(text: '{'),
        ],
      ),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
    expect(chat.fullHistory, isEmpty);
    await chat.addQuery(edge.Message.text(text: 'retry', isUser: true));
    await chat.generateChatResponse();
    expect(engine.requests.last.single.content, 'retry');
  });

  test(
    'tool IDs remain unique when the runtime reuses IDs across turns',
    () async {
      engine.script = [_toolChunk(0, 'search', '{}', id: 'reused')];
      final chat = await model.openChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'find', isUser: true));
      final first =
          await chat.generateChatResponse() as LlamaFunctionCallResponse;
      await expectLater(
        chat.addQuery(
          edge.Message(
            text: '{',
            type: edge.MessageType.toolResponse,
            toolName: 'search',
          ),
        ),
        throwsA(isA<llama.LlamaArgumentException>()),
      );
      await chat.addQuery(
        LlamaToolResponseMessage(
          callId: first.id,
          toolName: first.name,
          response: {'ok': true},
        ),
      );
      final second =
          await chat.generateChatResponse() as LlamaFunctionCallResponse;
      expect(second.id, isNot(first.id));
      await chat.addQuery(
        LlamaToolResponseMessage(
          callId: second.id,
          toolName: second.name,
          response: {'ok': true},
        ),
      );
      engine.script = [_chunk('done')];
      await chat.generateChatResponse();
      expect(
        engine.requests.last.last.parts.single,
        isA<llama.LlamaToolResultContent>(),
      );
    },
  );

  test('invalid legacy replacement preserves the existing dialogue', () async {
    final existing = await model.createChat();
    await expectLater(
      model.createChat(tools: [tool, tool]),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
    expect(model.session, same(existing.session));
    await existing.addQuery(
      edge.Message.text(text: 'still usable', isUser: true),
    );
    await existing.generateChatResponse();
    expect(existing.fullHistory.length, 2);
  });

  test('empty inputs fail before entering history', () async {
    final session = await model.openSession();
    await expectLater(
      session.addQueryChunk(edge.Message.text(text: '', isUser: true)),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
    expect(session.messages, isEmpty);
  });

  test(
    'repeated session creation and concurrent shutdown stay serialized',
    () async {
      for (var cycle = 0; cycle < 30; cycle++) {
        final a = await model.openSession();
        final b = await model.openSession();
        await a.addQueryChunk(edge.Message.text(text: 'a', isUser: true));
        await b.addQueryChunk(edge.Message.text(text: 'b', isUser: true));
        await Future.wait([a.getResponse(), b.getResponse()]);
        await Future.wait([a.close(), b.close()]);
        expect(model.sessions, isEmpty);
      }
      engine.blockGeneration = true;
      final owner = await model.openSession();
      final peer = await model.openSession();
      await owner.addQueryChunk(edge.Message.text(text: 'owner', isUser: true));
      final first = Completer<void>();
      final running = owner.getResponseAsync().listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await peer.addQueryChunk(edge.Message.text(text: 'queued', isUser: true));
      final queued = peer.getResponseAsync().listen((_) {});
      await model.close().timeout(const Duration(seconds: 2));
      await Future.wait([running.cancel(), queued.cancel()]);
      expect(engine.maxActive, 1);
      expect(engine.disposals, 1);
      expect(model.sessions, isEmpty);
    },
  );

  test('tool support is capability probed', () async {
    engine.toolSupport = false;
    await expectLater(
      model.createChat(tools: [tool]),
      throwsA(isA<llama.LlamaUnsupportedException>()),
    );
    expect(engine.requests, isEmpty);
  });

  test(
    'independent chats retain histories while generation is serialized',
    () async {
      final a = await model.openChat(systemInstruction: 'A');
      final b = await model.openChat(systemInstruction: 'B');
      await a.addQuery(edge.Message.text(text: 'one', isUser: true));
      await b.addQuery(edge.Message.text(text: 'two', isUser: true));
      await Future.wait([a.generateChatResponse(), b.generateChatResponse()]);
      expect(engine.maxActive, 1);
      expect(engine.requests.map((r) => r.first.content), ['A', 'B']);
      await a.addQuery(edge.Message.text(text: 'three', isUser: true));
      await a.generateChatResponse();
      expect(engine.requests.last.map((m) => m.content), [
        'A',
        'one',
        'Hello world',
        'three',
      ]);
      expect(model.session, isNull);
      expect(model.sessions.length, 2);
      await a.close();
      expect(model.sessions.length, 1);
    },
  );

  test('cancelling a queued peer never cancels the active owner', () async {
    engine.blockGeneration = true;
    final a = await model.openSession();
    final b = await model.openSession();
    await a.addQueryChunk(edge.Message.text(text: 'owner', isUser: true));
    final first = Completer<void>();
    final owner = a.getResponseAsync().listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    await b.addQueryChunk(edge.Message.text(text: 'queued', isUser: true));
    final queued = b.getResponseAsync().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await b.stopGeneration().timeout(const Duration(seconds: 1));
    await queued.cancel();
    expect(engine.cancels, 0);
    expect(engine.requests.length, 1);
    await a.stopGeneration();
    await owner.cancel();
    engine.blockGeneration = false;
    await b.addQueryChunk(edge.Message.text(text: 'retry', isUser: true));
    await b.getResponse();
    expect(engine.requests.last.single.content, 'retry');
  });

  test('session cap and model close cover all detached sessions', () async {
    await model.close();
    model = LlamaInferenceModel(
      engine: engine,
      maxTokens: 2048,
      activeBackend: edge.PreferredBackend.cpu,
      maxConcurrentSessions: 1,
    );
    final a = await model.openSession();
    await expectLater(
      model.openSession(),
      throwsA(isA<llama.LlamaStateException>()),
    );
    await a.close();
    final b = await model.openSession();
    await model.close();
    await expectLater(
      b.addQueryChunk(edge.Message.text(text: 'closed')),
      throwsA(isA<llama.LlamaStateException>()),
    );
    expect(model.sessions, isEmpty);
  });

  test(
    'chat error and cancellation roll back the same visible transcript',
    () async {
      final chat = await model.createChat();
      engine.failAfterFirstToken = true;
      await chat.addQuery(edge.Message.text(text: 'failed', isUser: true));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      expect(chat.fullHistory, isEmpty);
      engine.failAfterFirstToken = false;
      engine.blockGeneration = true;
      await chat.addQuery(edge.Message.text(text: 'stopped', isUser: true));
      final first = Completer<void>();
      final subscription = chat.generateChatResponseAsync().listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await chat.stopGeneration();
      await subscription.cancel();
      expect(chat.fullHistory, isEmpty);
      engine.blockGeneration = false;
      await chat.addQuery(edge.Message.text(text: 'retry', isUser: true));
      await chat.generateChatResponse();
      expect(engine.requests.last.single.content, 'retry');
    },
  );

  test(
    'clearHistory replays typed calls and results without family mutation',
    () async {
      engine.script = [_toolChunk(0, 'search', '{"q":"a"}', id: 'a')];
      final chat = await model.openChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'find', isUser: true));
      await chat.generateChatResponse();
      await chat.addQuery(
        edge.Message.toolResponse(toolName: 'search', response: {'ok': true}),
      );
      final history = chat.fullHistory;
      await chat.clearHistory(replayHistory: history);
      engine.script = [_chunk('done')];
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.role), [
        llama.LlamaChatRole.user,
        llama.LlamaChatRole.assistant,
        llama.LlamaChatRole.tool,
      ]);
      expect(model.sessions.length, 1);
    },
  );

  test(
    'projector pairing and capabilities are validated before serving media',
    () async {
      final provider = LlamaEngineProvider(
        loader: (_, _) async => engine,
        projectorResolver: (_, _) async =>
            llama.ModelSource.path('projector.gguf'),
      );
      final loaded = await provider.createModel(
        _spec('model.gguf'),
        const RuntimeConfig(
          modelPath: 'model.gguf',
          maxTokens: 2048,
          supportImage: true,
          supportAudio: true,
          maxNumImages: 1,
        ),
      );
      final chat = await loaded.createChat(
        supportImage: true,
        supportAudio: true,
      );
      await chat.addQuery(
        edge.Message(
          text: 'media',
          isUser: true,
          imageBytes: Uint8List.fromList([1, 2]),
          audioBytes: Uint8List.fromList([3, 4]),
        ),
      );
      await chat.generateChatResponse();
      expect(engine.projector, 'projector.gguf');
      expect(
        engine.requests.last.single.parts
            .whereType<llama.LlamaImageContent>()
            .single
            .bytes,
        [1, 2],
      );
      expect(
        engine.requests.last.single.parts
            .whereType<llama.LlamaAudioContent>()
            .single
            .bytes,
        [3, 4],
      );
      await expectLater(
        chat.addQuery(
          edge.Message.withImages(
            text: '',
            isUser: true,
            imageBytes: [Uint8List(1), Uint8List(1)],
          ),
        ),
        throwsA(isA<llama.LlamaArgumentException>()),
      );
      await loaded.close();
      engine.visionSupport = false;
      await expectLater(
        provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: 'model.gguf',
            maxTokens: 2048,
            supportImage: true,
          ),
        ),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
    },
  );

  test('per-session LoRA is applied and removed before a peer runs', () async {
    final a = await model.openSession(loraPath: 'adapter.gguf');
    final b = await model.openSession();
    await a.addQueryChunk(edge.Message.text(text: 'adapted', isUser: true));
    await b.addQueryChunk(edge.Message.text(text: 'base', isUser: true));
    await Future.wait([a.getResponse(), b.getResponse()]);
    expect(engine.adaptersAtGeneration, ['adapter.gguf', null]);
    expect(engine.loraEvents, ['set:adapter.gguf', 'remove:adapter.gguf']);
    engine.failAfterFirstToken = true;
    await a.addQueryChunk(edge.Message.text(text: 'fail', isUser: true));
    await expectLater(
      a.getResponse(),
      throwsA(isA<llama.LlamaInferenceException>()),
    );
    expect(engine.activeAdapter, isNull);
  }, skip: kIsWeb);

  test(
    'failed LoRA cleanup rolls back and prevents contaminated peer inference',
    () async {
      engine.failLoraCleanup = true;
      final adapted = await model.openChat(loraPath: 'adapter.gguf');
      final peer = await model.openSession();
      await adapted.addQuery(edge.Message.text(text: 'adapted', isUser: true));
      await expectLater(
        adapted.generateChatResponse(),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      expect(adapted.fullHistory, isEmpty);
      await peer.addQueryChunk(edge.Message.text(text: 'peer', isUser: true));
      await expectLater(
        peer.getResponse(),
        throwsA(isA<llama.LlamaStateException>()),
      );
      expect(engine.requests.length, 1);
    },
    skip: kIsWeb,
  );
}

edge.InferenceModelSpec _spec(
  String filename, [
  edge.ModelFileType fileType = edge.ModelFileType.gguf,
  edge.ModelType modelType = edge.ModelType.general,
]) => edge.InferenceModelSpec(
  name: filename,
  modelSource: _source('/models/$filename'),
  modelType: modelType,
  fileType: fileType,
);

class _Backend implements llama.LlamaBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeEngine extends llama.LlamaEngine {
  _FakeEngine() : super(_Backend());

  llama.LlamaRuntime fakeRuntime = llama.LlamaRuntime.llamaCpp;
  int promptTokens = 10;
  int? gpuLayers = 0;
  int cancels = 0;
  int disposals = 0;
  Completer<void>? disposeGate;
  final Completer<void> disposeStarted = Completer<void>();
  bool blockGeneration = false;
  bool failAfterFirstToken = false;
  List<llama.LlamaCompletionChunk>? script;
  List<List<llama.LlamaCompletionChunk>> scripts = [];
  bool failLoraCleanup = false;
  bool toolSupport = true;
  bool visionSupport = true;
  String? projector;
  String? activeAdapter;
  final List<String?> adaptersAtGeneration = [];
  final List<String> loraEvents = [];
  List<llama.ToolDefinition> lastTools = [];
  List<llama.ToolDefinition> lastTemplateTools = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<llama.LlamaEngineCapabilities> get capabilities async =>
      llama.LlamaEngineCapabilities(
        isSupported: true,
        supportsToolCalling: toolSupport,
        supportsVision: visionSupport,
        supportsAudio: true,
      );
  @override
  Future<void> loadMultimodalProjectorSource(
    llama.ModelSource source, {
    llama.ModelLoadOptions? download,
    llama.ModelLoadOptions? options,
    llama.ModelDownloadProgressCallback? onProgress,
  }) async {
    projector = source.path;
  }

  @override
  Future<void> setLoraSource(
    llama.ModelSource source, {
    double scale = 1.0,
    llama.ModelLoadOptions download = llama.ModelLoadOptions.defaults,
    llama.ModelDownloadProgressCallback? onProgress,
    llama.ModelFileStore? store,
  }) async {
    activeAdapter = source.path;
    loraEvents.add('set:$activeAdapter');
  }

  @override
  Future<void> removeLoraSource(llama.ModelSource source) async {
    if (failLoraCleanup) throw llama.LlamaInferenceException('cleanup failed');
    loraEvents.add('remove:${source.path}');
    activeAdapter = null;
  }

  Completer<void>? _release;
  final List<List<llama.LlamaChatMessage>> requests = [];
  llama.GenerationParams? lastParams;
  bool? lastThinking;
  llama.ToolChoice? lastToolChoice;

  @override
  llama.LlamaRuntime? get runtime => fakeRuntime;

  @override
  Future<int?> getResolvedGpuLayers() async => gpuLayers;

  @override
  Future<int> getContextSize() async => 2048;

  @override
  Future<int> getTokenCount(String text) async => text.length;

  @override
  Future<llama.LlamaChatTemplateResult> chatTemplate(
    List<llama.LlamaChatMessage> messages, {
    bool addAssistant = true,
    Map<String, dynamic>? jsonSchema,
    List<llama.ToolDefinition>? tools,
    llama.ToolChoice toolChoice = llama.ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? customTemplate,
    String? sourceLangCode,
    String? targetLangCode,
    bool includeTokenCount = true,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async {
    lastTemplateTools = tools ?? [];
    return llama.LlamaChatTemplateResult(
      prompt: 'rendered',
      tokenCount: promptTokens,
    );
  }

  @override
  Stream<llama.LlamaCompletionChunk> create(
    List<llama.LlamaChatMessage> messages, {
    llama.GenerationParams? params,
    List<llama.ToolDefinition>? tools,
    llama.ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    active++;
    if (active > maxActive) maxActive = active;
    try {
      requests.add(List.of(messages));
      lastTools = tools ?? [];
      adaptersAtGeneration.add(activeAdapter);
      lastParams = params;
      lastThinking = enableThinking;
      lastToolChoice = toolChoice;
      final custom = scripts.isNotEmpty ? scripts.removeAt(0) : script;
      if (custom != null) {
        yield* Stream.fromIterable(custom);
        return;
      }
      if (blockGeneration) _release = Completer<void>();
      yield _chunk('Hello');
      if (failAfterFirstToken) {
        throw llama.LlamaInferenceException('test failure');
      }
      if (blockGeneration) {
        await _release!.future;
        return;
      }
      yield _chunk(' world');
      yield _chunk(
        null,
        finishReason: 'stop',
        usage: const llama.LlamaGenerationUsage(
          promptTokens: 10,
          completionTokens: 2,
          timeToFirstToken: Duration(milliseconds: 5),
          duration: Duration(milliseconds: 20),
        ),
      );
    } finally {
      active--;
    }
  }

  @override
  void cancelGeneration() {
    cancels++;
    if (_release != null && !_release!.isCompleted) _release!.complete();
  }

  @override
  Future<void> dispose() async {
    if (!disposeStarted.isCompleted) disposeStarted.complete();
    await disposeGate?.future;
    if (disposals == 0) disposals++;
  }
}

llama.LlamaCompletionChunk _chunk(
  String? text, {
  String? finishReason,
  llama.LlamaGenerationUsage? usage,
}) => llama.LlamaCompletionChunk(
  id: 'test',
  object: 'chat.completion.chunk',
  created: 0,
  model: 'test.gguf',
  usage: usage,
  choices: [
    llama.LlamaCompletionChunkChoice(
      index: 0,
      delta: llama.LlamaCompletionChunkDelta(content: text),
      finishReason: finishReason,
    ),
  ],
);

llama.LlamaCompletionChunk _thinking(String text) => llama.LlamaCompletionChunk(
  id: 'test',
  object: 'chat.completion.chunk',
  created: 0,
  model: 'test',
  choices: [
    llama.LlamaCompletionChunkChoice(
      index: 0,
      delta: llama.LlamaCompletionChunkDelta(thinking: text),
    ),
  ],
);
llama.LlamaCompletionChunk _toolChunk(
  int index,
  String? name,
  String arguments, {
  String? id,
}) => llama.LlamaCompletionChunk(
  id: 'test',
  object: 'chat.completion.chunk',
  created: 0,
  model: 'test',
  choices: [
    llama.LlamaCompletionChunkChoice(
      index: 0,
      delta: llama.LlamaCompletionChunkDelta(
        toolCalls: [
          llama.LlamaCompletionChunkToolCall(
            index: index,
            id: id,
            function: llama.LlamaCompletionChunkFunction(
              name: name,
              arguments: arguments,
            ),
          ),
        ],
      ),
    ),
  ],
);

edge.ModelSource _source(String path) => kIsWeb
    ? edge.ModelSource.network('https://models.invalid/${path.split('/').last}')
    : edge.ModelSource.file(path);

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
// ignore: implementation_imports — verifies actual provider selection for the declared GGUF routing contract.
import 'package:flutter_edge_ai/src/registry/engine_registry.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_edge_ai_llama/src/llama_inference_model.dart';
import 'package:flutter_edge_ai_llama/src/llama_inference_session.dart';
import 'package:flutter_edge_ai_llama/src/runtime_error.dart';
import 'package:flutter_edge_ai_llama/src/llama_engine_provider.dart'
    show createLlamaProviderForTest;
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

import 'package:flutter_edge_ai_llama/src/llama_tool.dart'
    show SchemaToolDefinition;
// ignore: implementation_imports — verifies the pinned SDK grammar used in production.
import 'package:llamadart/src/core/template/handlers/glm45_handler.dart';
// ignore: implementation_imports — verifies the pinned shared XML grammar.
import 'package:llamadart/src/core/template/handlers/qwen3_coder_xml_handler.dart';

import 'host_abi_stub.dart' if (dart.library.ffi) 'host_abi_native.dart';
import 'lora_fixture_stub.dart' if (dart.library.io) 'lora_fixture_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String adapterPath;
  late _FakeEngine engine;
  late LlamaInferenceModel model;
  setUp(() async {
    adapterPath = await createLoraFixture();
    engine = _FakeEngine();
    model = LlamaInferenceModel(
      engine: engine,
      maxTokens: 2048,
      activeBackend: edge.PreferredBackend.cpu,
    );
  });
  tearDown(() async {
    await model.close();
    await removeLoraFixture(adapterPath);
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
    final provider = createLlamaProviderForTest(
      loader: (_, _) async => fail('Binary files must not reach llama'),
    );
    await expectLater(
      provider.createModel(
        _spec('model.gguf', edge.ModelFileType.binary),
        const RuntimeConfig(modelPath: '/models/model.gguf', maxTokens: 2048),
      ),
      throwsA(isA<UnsupportedError>()),
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
    final provider = createLlamaProviderForTest(
      loader: (_, params) async {
        expect(params.loras.single.source!.path, '/models/adapter.gguf');
        engine.activeAdapter = params.loras.single.source!.path;
        return engine;
      },
    );
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
        throwsA(isA<UnsupportedError>()),
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
    expect(engine.activeAdapter, '/models/adapter.gguf');
    expect(engine.loraEvents, isEmpty);
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
        await expectLater(model.createSession(), throwsA(isA<StateError>()));
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
    final provider = createLlamaProviderForTest(
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
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
      );
      await expectLater(
        provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: 'model.gguf',
            maxTokens: 2048,
            preferredBackend: edge.PreferredBackend.gpu,
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(engine.disposals, 1);
    },
  );

  test(
    'GPU reporting preserves verified offload and unknown runtime identity',
    () async {
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
      );
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

  for (final backend in [
    'OpenCL',
    'HIP',
    'BLAS',
    'Vulkan, CPU',
    'WebGPU, CPU',
  ]) {
    test(
      'backend identity distinguishes active selection from device lists: $backend',
      () async {
        engine.backendName = backend;
        engine.gpuLayers = 12;
        final provider = createLlamaProviderForTest(
          loader: (_, _) async => engine,
        );
        final loaded = await provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(modelPath: 'model.gguf', maxTokens: 2048),
        );
        final expected = backend == 'BLAS'
            ? edge.PreferredBackend.cpu
            : backend.contains(',') && !(kIsWeb && backend.startsWith('WebGPU'))
            ? null
            : edge.PreferredBackend.gpu;
        expect(loaded.activeBackend, expected);
        await loaded.close();
      },
    );
  }

  test('provider rejects unsupported configuration before loading', () async {
    final provider = createLlamaProviderForTest(
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
        throwsA(isA<UnsupportedError>()),
      );
    }
  });

  test('load cleanup disposes an unexpected runtime', () async {
    engine.fakeRuntime = llama.LlamaRuntime.liteRtLm;
    final provider = createLlamaProviderForTest(loader: (_, _) async => engine);
    await expectLater(
      provider.createModel(
        _spec('test.gguf'),
        const RuntimeConfig(modelPath: 'test.gguf', maxTokens: 2048),
      ),
      throwsA(isA<UnsupportedError>()),
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
        throwsA(isA<StateError>()),
      );
      await second.addQueryChunk(edge.Message.text(text: 'new', isUser: true));
      await second.getResponse();
      expect(engine.requests.last.map((m) => m.content), ['new']);
      expect(engine.disposals, 0);
      expect(model.sessions, [second]);
    },
  );

  test(
    'openChat and createChat apply the GGUF chat rules the same way',
    () async {
      const tool = edge.Tool(name: 'get_time', description: 'Time.');
      for (final create in [model.createChat, model.openChat]) {
        for (final tokenBuffer in [-1, 2048]) {
          await expectLater(
            create(tokenBuffer: tokenBuffer),
            throwsA(isA<ArgumentError>()),
            reason: 'tokenBuffer $tokenBuffer',
          );
        }
        await expectLater(
          create(
            tools: const [tool],
            supportsFunctionCalls: false,
            toolChoice: edge.ToolChoice.required,
          ),
          throwsA(isA<ArgumentError>()),
        );
        final off = await create(
          tools: const [tool],
          supportsFunctionCalls: false,
        );
        expect(off.tools, isEmpty);
        expect(off.supportsFunctionCalls, isFalse);
        await off.close();
        // 0 is a valid buffer: the whole context is the chat's.
        await (await create(tokenBuffer: 0)).close();
        final on = await create(tools: const [tool]);
        expect(on.tools.single.name, 'get_time');
        expect(on.supportsFunctionCalls, isTrue);
        // The GGUF template renders the declarations; the chat must not.
        expect(on.runtimeInjectsToolDeclarations, isTrue);
        expect(on.maxFunctionBufferLength, 1024);
        await on.close();
      }
    },
  );

  test('disabled modalities and orphan tool results fail loudly', () async {
    await expectLater(
      model.createChat(toolChoice: edge.ToolChoice.required),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => model.createSession(enableVisionModality: true),
      throwsA(isA<UnsupportedError>()),
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
        throwsA(isA<UnsupportedError>()),
      );
    }
    await expectLater(
      session.addQueryChunk(
        edge.Message.toolResponse(toolName: 'search', response: {'ok': true}),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('rendered template overhead is checked before inference', () async {
    engine.promptTokens = 2048;
    final session = await model.createSession(maxOutputTokens: 64);
    await session.addQueryChunk(
      edge.Message.text(text: 'short raw text', isUser: true),
    );
    await expectLater(session.getResponse(), throwsA(isA<StateError>()));
    expect(engine.requests, isEmpty);
  });

  test('invalid sampling and output budgets are rejected', () async {
    for (final limit in [0, -1]) {
      await expectLater(
        model.createSession(maxOutputTokens: limit),
        throwsA(isA<ArgumentError>()),
      );
    }
    await expectLater(
      model.createSession(temperature: double.nan),
      throwsArgumentError,
    );
    await expectLater(model.createSession(topP: 0), throwsArgumentError);
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
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
      );
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

  test(
    'session thinking uses installed family and partial overrides keep defaults',
    () async {
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
      );
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
        await explicit.addQueryChunk(
          edge.Message.text(text: 'hi', isUser: true),
        );
        await explicit.getResponse();
        expect(engine.lastParams!.temp, .2);
        expect(engine.lastParams!.topK, 12);
        expect(engine.lastParams!.topP, .75);
        expect(engine.lastParams!.seed, 7);
      } finally {
        await loaded.close();
      }
    },
  );

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
      throwsA(
        isA<RuntimeStateError>().having(
          (e) => e.cause,
          'SDK cause',
          isA<llama.LlamaInferenceException>(),
        ),
      ),
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
    await expectLater(session.getResponse(), throwsA(isA<StateError>()));
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
        onError: (Object error) => expect(error, isA<StateError>()),
      );
      await firstToken.future;
      await Future.wait([
        model.close(),
        model.close(),
      ]).timeout(const Duration(seconds: 2));
      await subscription.cancel();
      expect(engine.disposals, 1);
      expect(closed, 1);
      await expectLater(model.createSession(), throwsA(isA<StateError>()));
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

  for (final streaming in [false, true]) {
    test(
      'content-only templates preserve literal tags in ${streaming ? "streamed" : "collected"} sessions',
      () async {
        engine.script = [
          _thinking('hidden channel'),
          _chunk('<thi'),
          _chunk('nk>literal content</think>answer'),
        ];
        final session = await model.openSession(enableThinking: false);
        await session.addQueryChunk(
          edge.Message.text(text: 'hello', isUser: true),
        );
        final response = streaming
            ? (await session.getResponseAsync().toList()).join()
            : await session.getResponse();
        expect(response, '<think>literal content</think>answer');
        expect(engine.lastThinking, isFalse);
      },
    );
  }

  test('content-only templates preserve literal tags in typed chat', () async {
    engine.script = [
      _thinking('hidden channel'),
      _chunk('<think>literal content</think>answer'),
    ];
    final chat = await model.openChat(enableThinking: false);
    await chat.addQuery(edge.Message.text(text: 'hello', isUser: true));
    final responses = await chat.generateChatResponseAsync().toList();
    expect(responses.whereType<edge.ThinkingResponse>(), isEmpty);
    expect(
      responses.whereType<edge.TextResponse>().map((r) => r.token).join(),
      '<think>literal content</think>answer',
    );
    expect(engine.lastThinking, isFalse);
  });

  for (final format in [
    llama.ChatFormat.hermes,
    llama.ChatFormat.deepseekV3,
    llama.ChatFormat.qwen3CoderXml,
  ]) {
    for (final api in [
      'session',
      'streamed session',
      'chat',
      'streamed chat',
    ]) {
      test('closed ${format.name} thought is hidden in $api', () async {
        engine.templateFormat = format.index;
        engine.templatePrompt = 'assistant\n<think>\n\n</think>\n';
        const raw =
            ' \n<think>reason</think>\t<think>more</think>answer <think>literal</think>';
        const visible = 'answer <think>literal</think>';
        final chunkings = [
          [raw],
          raw.split(''),
          for (var split = 1; split < raw.length; split++)
            [raw.substring(0, split), raw.substring(split)],
        ];
        for (final tokens in chunkings) {
          engine.script = [
            ...tokens.map(_chunk),
            _chunk(
              null,
              finishReason: 'stop',
              usage: const llama.LlamaGenerationUsage(
                promptTokens: 10,
                completionTokens: 30,
              ),
            ),
          ];
          final chat = api.contains('chat') ? await model.openChat() : null;
          final session =
              (chat?.session ?? await model.openSession())
                  as LlamaInferenceSession;
          if (chat != null) {
            await chat.addQuery(edge.Message.text(text: 'first', isUser: true));
          } else {
            await session.addQueryChunk(
              edge.Message.text(text: 'first', isUser: true),
            );
          }
          final String answer;
          if (chat != null) {
            answer = api.startsWith('streamed')
                ? (await chat.generateChatResponseAsync().toList())
                      .whereType<edge.TextResponse>()
                      .map((r) => r.token)
                      .join()
                : (await chat.generateChatResponse() as edge.TextResponse)
                      .token;
          } else {
            answer = api.startsWith('streamed')
                ? (await session.getResponseAsync().toList()).join()
                : await session.getResponse();
          }
          expect(answer, visible, reason: '${tokens.length} chunks');
          expect(session.hiddenThinkingCharacters, 10);
          expect(session.messages.last.text, visible);
          expect(session.getSessionMetrics().outputTokens, 30);
          engine.script = [_chunk('next answer')];
          await session.addQueryChunk(
            edge.Message.text(text: 'next', isUser: true),
          );
          await session.getResponse();
          final assistant = engine.requests.last.firstWhere(
            (m) => m.role == llama.LlamaChatRole.assistant,
          );
          expect(assistant.content, visible);
          expect(session.hiddenThinkingCharacters, 0);
          await session.close();
        }
      });
    }
  }

  test(
    'closed-thought compatibility leaves other literal text unchanged',
    () async {
      const raw = '<think>literal</think>answer';
      for (final (format, prompt, enabled, forcedOpen) in [
        (llama.ChatFormat.contentOnly, '<think></think>', false, false),
        (llama.ChatFormat.hermes, 'assistant', false, false),
        (llama.ChatFormat.hermes, '<think>not empty</think>', false, false),
        (llama.ChatFormat.hermes, '<think></think>', true, false),
        (llama.ChatFormat.hermes, '<think></think>', false, true),
      ]) {
        engine.templateFormat = format.index;
        engine.templatePrompt = prompt;
        engine.templateThinkingForcedOpen = forcedOpen;
        engine.script = raw.split('').map(_chunk).toList();
        final session = await model.openSession(enableThinking: enabled);
        await session.addQueryChunk(
          edge.Message.text(text: 'literal', isUser: true),
        );
        expect(await session.getResponse(), raw);
        await session.close();
      }
      engine.templateThinkingForcedOpen = false;
      engine.templatePrompt = '<think></think>';
      for (final text in [
        'answer <think>literal</think>',
        '{"literal":"<think>keep</think>"}',
        '<thinking>literal</thinking>',
      ]) {
        engine.script = text.split('').map(_chunk).toList();
        final session = await model.openSession();
        await session.addQueryChunk(
          edge.Message.text(text: 'literal', isUser: true),
        );
        expect(await session.getResponse(), text);
        await session.close();
      }
    },
  );

  test(
    'hidden and truncated leading thoughts fail and do not commit',
    () async {
      engine.templateFormat = llama.ChatFormat.hermes.index;
      engine.templatePrompt = '<think></think>';
      for (final raw in [
        '<think>secret</think>',
        '<think>secret</thi',
        '<thi',
      ]) {
        for (final finish in ['stop', 'length']) {
          engine.script = [
            ...raw.split('').map(_chunk),
            _chunk(null, finishReason: finish),
          ];
          final chat = await model.openChat();
          await chat.addQuery(
            edge.Message.text(text: 'abandoned', isUser: true),
          );
          final shown = <edge.ModelResponse>[];
          await expectLater(
            chat.generateChatResponseAsync().map((r) {
              shown.add(r);
              return r;
            }).toList(),
            throwsA(isA<StateError>()),
          );
          expect(shown, isEmpty);
          expect(chat.fullHistory, isEmpty);
          engine.script = [_chunk('<think>again</think>answer')];
          await chat.addQuery(edge.Message.text(text: 'retry', isUser: true));
          expect(
            (await chat.generateChatResponse() as edge.TextResponse).token,
            'answer',
          );
          expect(engine.requests.last.map((m) => m.content), ['retry']);
          await chat.close();
        }
      }
    },
  );

  test(
    'cancelling inside a hidden thought resets the next turn filter',
    () async {
      engine.templateFormat = llama.ChatFormat.hermes.index;
      engine.templatePrompt = '<think></think>';
      engine.firstText = '<think>secret';
      engine.blockGeneration = true;
      final session = await model.openSession() as LlamaInferenceSession;
      await session.addQueryChunk(
        edge.Message.text(text: 'abandoned', isUser: true),
      );
      final shown = <String>[];
      final subscription = session.getResponseAsync().listen(shown.add);
      await Future<void>(() async {
        while (engine.active == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }).timeout(const Duration(seconds: 2));
      await session.stopGeneration().timeout(const Duration(seconds: 2));
      await subscription.cancel();
      expect(shown, isEmpty);
      expect(session.messages, isEmpty);
      engine.blockGeneration = false;
      engine.script = [_chunk('<think>new</think>answer')];
      await session.addQueryChunk(
        edge.Message.text(text: 'retry', isUser: true),
      );
      expect(await session.getResponse(), 'answer');
      expect(session.hiddenThinkingCharacters, 3);
      expect(engine.requests.last.map((m) => m.content), ['retry']);
    },
  );

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
  for (final closesThought in [false, true]) {
    test(
      'hidden leading text preserves structured calls and replay (closed: $closesThought)',
      () async {
        engine.templateFormat = llama.ChatFormat.qwen3CoderXml.index;
        engine.templatePrompt = '<think>\n</think>';
        engine.script = [
          _chunk('<think>secret${closesThought ? '</think>' : ''}'),
          _toolChunk(
            0,
            'search',
            '{"q":"<think>literal</think>"}',
            id: 'call00001',
          ),
          _chunk(
            null,
            finishReason: 'tool_calls',
            usage: const llama.LlamaGenerationUsage(
              promptTokens: 10,
              completionTokens: 20,
            ),
          ),
        ];
        final chat = await model.openChat(tools: [tool]);
        await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
        final responses = await chat.generateChatResponseAsync().toList();
        expect(responses.whereType<edge.TextResponse>(), isEmpty);
        expect(responses.whereType<edge.ThinkingResponse>(), isEmpty);
        final response = responses
            .whereType<edge.FunctionCallResponse>()
            .single;
        expect(response.args, {'q': '<think>literal</think>'});
        expect(
          chat.fullHistory.where(
            (m) => !m.isUser && m.type == edge.MessageType.text,
          ),
          isEmpty,
        );
        expect(chat.fullHistory.any((m) => m.text.contains('secret')), isFalse);
        expect(chat.session.getSessionMetrics().outputTokens, 20);
        await chat.addQuery(
          edge.Message.toolResponse(
            toolCallId: response.id,
            toolName: response.name,
            response: {'found': true},
          ),
        );
        engine.script = [_chunk('done')];
        expect(
          (await chat.generateChatResponse() as edge.TextResponse).token,
          'done',
        );
        final assistant = engine.requests.last.firstWhere(
          (m) => m.role == llama.LlamaChatRole.assistant,
        );
        expect(assistant.parts.whereType<llama.LlamaTextContent>(), isEmpty);
        expect(
          assistant.parts.whereType<llama.LlamaThinkingContent>(),
          isEmpty,
        );
        expect(
          assistant.parts
              .whereType<llama.LlamaToolCallContent>()
              .single
              .arguments,
          {'q': '<think>literal</think>'},
        );
      },
    );
  }
  for (final stopped in [false, true]) {
    test(
      'tool results survive ${stopped ? "stop" : "error"} and remain replayable',
      () async {
        engine.script = [_toolChunk(0, 'search', '{"q":"a"}', id: 'a')];
        final chat = await model.openChat(tools: [tool]);
        await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
        final call =
            await chat.generateChatResponse() as edge.FunctionCallResponse;
        await chat.addQuery(
          edge.Message.toolResponse(
            toolCallId: call.id,
            toolName: call.name,
            response: {'ok': true},
          ),
        );
        engine.script = null;
        if (stopped) {
          engine.blockGeneration = true;
          final first = Completer<void>();
          final stream = chat.generateChatResponseAsync().listen((_) {
            if (!first.isCompleted) first.complete();
          });
          await first.future.timeout(const Duration(seconds: 2));
          await chat.session.stopGeneration();
          await stream.cancel();
          engine.blockGeneration = false;
        } else {
          engine.failAfterFirstToken = true;
          await expectLater(
            chat.generateChatResponseAsync().toList(),
            throwsA(
              isA<RuntimeStateError>().having(
                (e) => e.cause,
                'SDK cause',
                isA<llama.LlamaInferenceException>(),
              ),
            ),
          );
          engine.failAfterFirstToken = false;
        }
        expect(
          chat.fullHistory.where(
            (m) => m.type == edge.MessageType.toolResponse,
          ),
          hasLength(1),
        );
        final history = List<edge.Message>.of(chat.fullHistory);
        await chat.clearHistory(replayHistory: history);
        await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
        await chat.generateChatResponse();
        expect(engine.requests.last.map((m) => m.role), [
          llama.LlamaChatRole.user,
          llama.LlamaChatRole.assistant,
          llama.LlamaChatRole.tool,
          llama.LlamaChatRole.user,
        ]);
      },
    );
  }

  for (final failure in ['stop', 'runtime', 'context']) {
    test('restored conversation survives $failure on the next turn', () async {
      final chat = await model.openChat();
      final restored = [
        edge.Message.text(text: 'remember me', isUser: true),
        edge.Message.text(text: 'remembered'),
      ];
      await chat.clearHistory(replayHistory: restored);
      await chat.addQuery(edge.Message.text(text: 'failed next', isUser: true));
      if (failure == 'stop') {
        engine.blockGeneration = true;
        final first = Completer<void>();
        final subscription = chat.generateChatResponseAsync().listen((_) {
          if (!first.isCompleted) first.complete();
        });
        await first.future.timeout(const Duration(seconds: 2));
        await chat.stopGeneration();
        await subscription.cancel();
        engine.blockGeneration = false;
      } else {
        engine.failAfterFirstToken = failure == 'runtime';
        if (failure == 'context') engine.promptTokens = 2048;
        await expectLater(
          chat.generateChatResponse(),
          throwsA(
            failure == 'runtime'
                ? isA<RuntimeStateError>().having(
                    (e) => e.cause,
                    'SDK cause',
                    isA<llama.LlamaInferenceException>(),
                  )
                : isA<StateError>(),
          ),
        );
        engine.failAfterFirstToken = false;
        engine.promptTokens = 10;
      }
      expect(chat.fullHistory.map((m) => m.text), [
        'remember me',
        'remembered',
      ]);
      await chat.addQuery(edge.Message.text(text: 'retry', isUser: true));
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.content), [
        'remember me',
        'remembered',
        'retry',
      ]);
    });
  }

  test('restore accepts a pending user or unanswered tool call', () async {
    final chat = await model.openChat(tools: [tool]);
    await chat.clearHistory(
      replayHistory: [edge.Message.text(text: 'restored input', isUser: true)],
    );
    await chat.generateChatResponse();
    expect(engine.requests.last.single.content, 'restored input');
    await chat.clearHistory(
      replayHistory: [
        edge.Message.text(text: 'find', isUser: true),
        edge.Message.toolCall(text: '{"name":"search","parameters":{"q":"a"}}'),
      ],
    );
    await expectLater(chat.generateChatResponse(), throwsA(isA<StateError>()));
    expect(chat.fullHistory, hasLength(2));
    await chat.addQuery(
      edge.Message.toolResponse(toolName: 'search', response: {'ok': true}),
    );
    await chat.generateChatResponse();
    expect(
      chat.fullHistory.where((m) => m.type == edge.MessageType.toolResponse),
      hasLength(1),
    );
  });

  test('an output cap above context size remains a cap', () async {
    engine.promptTokens = 1950;
    final session = await model.openSession(maxOutputTokens: 4096);
    await session.addQueryChunk(
      edge.Message.text(text: 'latest', isUser: true),
    );
    await session.getResponse();
    expect(engine.lastParams!.maxTokens, 98);
  });

  test('output is capped by the remaining rendered context', () async {
    engine.promptTokens = 1950;
    final chat = await model.openChat(maxOutputTokens: 128);
    await chat.addQuery(edge.Message.text(text: 'latest', isUser: true));
    await chat.generateChatResponse();
    expect(engine.lastParams!.maxTokens, 98);
  });

  test(
    'context trimming removes whole tool turns and retains system/latest input',
    () async {
      final chat = await model.openChat(
        tools: [tool],
        systemInstruction: 'system',
        tokenBuffer: 256,
      );
      await chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'old tool turn', isUser: true),
          edge.Message.toolCall(
            text:
                '[{"name":"search","parameters":{"q":"a"}},{"name":"search","parameters":{"q":"b"}}]',
          ),
          edge.Message.toolResponse(
            toolName: 'search',
            response: {'first': true},
          ),
          edge.Message.toolResponse(
            toolName: 'search',
            response: {'second': true},
          ),
          edge.Message.text(text: 'old answer'),
          edge.Message.text(text: 'recent turn', isUser: true),
          edge.Message.text(text: 'recent answer'),
        ],
      );
      engine.promptCounter = (messages) =>
          messages.any((m) => m.content == 'old tool turn') ? 1900 : 1000;
      await chat.addQuery(edge.Message.text(text: 'latest', isUser: true));
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.content), [
        'system',
        'recent turn',
        'recent answer',
        'latest',
      ]);
      expect(chat.fullHistory.take(6).map((m) => m.type), [
        edge.MessageType.text,
        edge.MessageType.toolCall,
        edge.MessageType.toolResponse,
        edge.MessageType.toolResponse,
        edge.MessageType.text,
        edge.MessageType.text,
      ]);
      expect(chat.fullHistory.map((m) => m.text).skip(5), [
        'recent turn',
        'recent answer',
        'latest',
        'Hello world',
      ]);
    },
  );

  test('failed generation does not commit context trimming', () async {
    final chat = await model.openChat(tokenBuffer: 256);
    final restored = [
      edge.Message.text(text: 'old', isUser: true),
      edge.Message.text(text: 'answer'),
    ];
    await chat.clearHistory(replayHistory: restored);
    engine.promptCounter = (messages) =>
        messages.any((m) => m.content == 'old') ? 1900 : 100;
    engine.failAfterFirstToken = true;
    await chat.addQuery(edge.Message.text(text: 'latest', isUser: true));
    await expectLater(
      chat.generateChatResponse(),
      throwsA(
        isA<RuntimeStateError>().having(
          (e) => e.cause,
          'SDK cause',
          isA<llama.LlamaInferenceException>(),
        ),
      ),
    );
    expect(chat.fullHistory.map((m) => m.text), ['old', 'answer']);
  });

  test('queued stop preserves answers to committed tool calls', () async {
    engine.script = [_toolChunk(0, 'search', '{"q":"a"}', id: 'a')];
    final chat = await model.openChat(tools: [tool]);
    await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
    final call = await chat.generateChatResponse() as edge.FunctionCallResponse;
    await chat.addQuery(
      edge.Message.toolResponse(
        toolCallId: call.id,
        toolName: call.name,
        response: {'ok': true},
      ),
    );
    engine.script = null;
    engine.blockGeneration = true;
    final owner = await model.openSession();
    await owner.addQueryChunk(edge.Message.text(text: 'owner', isUser: true));
    final first = Completer<void>();
    final running = owner.getResponseAsync().listen((_) {
      if (!first.isCompleted) first.complete();
    });
    await first.future;
    final queued = chat.generateChatResponseAsync().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await chat.session.stopGeneration();
    await queued.cancel();
    await owner.stopGeneration();
    await running.cancel();
    engine.blockGeneration = false;
    await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
    await chat.generateChatResponse();
    expect(
      chat.fullHistory.where((m) => m.type == edge.MessageType.toolResponse),
      hasLength(1),
    );
  });

  test(
    'unset output cap uses the remaining rendered context each turn',
    () async {
      final chat = await model.openChat();
      engine.promptTokens = 200;
      await chat.addQuery(edge.Message.text(text: 'first', isUser: true));
      await chat.generateChatResponse();
      expect(engine.lastParams!.maxTokens, 1848);
      engine.promptTokens = 800;
      await chat.addQuery(edge.Message.text(text: 'second', isUser: true));
      await chat.generateChatResponse();
      expect(engine.lastParams!.maxTokens, 1248);
    },
  );

  test(
    'truncated tools and empty thinking turns fail without committing',
    () async {
      for (final script in [
        [
          _chunk('<tool_call>{"name":"search","arguments":{"q":"fl'),
          _chunk(null, finishReason: 'length'),
        ],
        [_thinking('hidden'), _chunk(null, finishReason: 'length')],
      ]) {
        engine.script = script;
        final chat = await model.openChat(tools: [tool], enableThinking: true);
        await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
        await expectLater(
          chat.generateChatResponseAsync().toList(),
          throwsA(isA<StateError>()),
        );
        expect(chat.fullHistory, isEmpty);
      }
      engine.script = [
        _chunk('plain truncated answer'),
        _chunk(null, finishReason: 'length'),
      ];
      final plain = await model.openChat();
      await plain.addQuery(edge.Message.text(text: 'plain', isUser: true));
      expect(
        (await plain.generateChatResponse() as edge.TextResponse).token,
        'plain truncated answer',
      );
    },
  );

  test(
    'replay groups thinking, text and calls into one assistant turn',
    () async {
      engine.script = [
        _thinking('reason'),
        _chunk('searching'),
        _toolChunk(0, 'search', '{"q":"a"}', id: 'a'),
      ];
      final chat = await model.openChat(tools: [tool], enableThinking: true);
      await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
      final call =
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: call.id,
          toolName: call.name,
          response: {'ok': true},
        ),
      );
      await chat.clearHistory(
        replayHistory: List<edge.Message>.of(chat.fullHistory),
      );
      engine.script = [_chunk('done')];
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.role), [
        llama.LlamaChatRole.user,
        llama.LlamaChatRole.assistant,
        llama.LlamaChatRole.tool,
      ]);
      expect(engine.requests.last[1].parts, hasLength(3));
    },
  );

  test(
    'missing session adapter does not invalidate an unaffected peer',
    () async {
      final bad = await model.openSession(loraPath: '$adapterPath.missing');
      await bad.addQueryChunk(edge.Message.text(text: 'bad', isUser: true));
      await expectLater(bad.getResponse(), throwsA(isA<ArgumentError>()));
      final peer = await model.openSession();
      await peer.addQueryChunk(edge.Message.text(text: 'good', isUser: true));
      expect(await peer.getResponse(), 'Hello world');
      expect(engine.loraEvents, isEmpty);
    },
    skip: kIsWeb,
  );

  test(
    'session override restores the installed adapter before a peer runs',
    () async {
      final installed = LlamaInferenceModel(
        engine: engine,
        maxTokens: 2048,
        activeBackend: edge.PreferredBackend.cpu,
        defaultLoraPath: 'installed.gguf',
      );
      engine.activeAdapter = 'installed.gguf';
      final custom = await installed.openSession(loraPath: adapterPath);
      final base = await installed.openSession();
      await custom.addQueryChunk(
        edge.Message.text(text: 'custom', isUser: true),
      );
      await base.addQueryChunk(
        edge.Message.text(text: 'installed', isUser: true),
      );
      await Future.wait([custom.getResponse(), base.getResponse()]);
      expect(engine.adaptersAtGeneration, [adapterPath, 'installed.gguf']);
      expect(engine.activeAdapter, 'installed.gguf');
      await installed.close();
    },
    skip: kIsWeb,
  );

  test('backend identity overrides an auto GPU-layer request', () async {
    engine.gpuLayers = 999;
    engine.backendName = 'CPU';
    final provider = createLlamaProviderForTest(loader: (_, _) async => engine);
    final loaded = await provider.createModel(
      _spec('cpu.gguf'),
      const RuntimeConfig(modelPath: 'cpu.gguf', maxTokens: 2048),
    );
    expect(loaded.activeBackend, edge.PreferredBackend.cpu);
    await loaded.close();
  });

  test(
    'fragmented tool calls preserve schemas and call IDs through results',
    () async {
      engine.script = [
        _toolChunk(0, 'search', '{"q":', id: 'call00001'),
        _toolChunk(0, null, '"flower"}'),
      ];
      final chat = await model.createChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.required,
      );
      await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
      final response = await chat.generateChatResponse();
      final call = response as edge.FunctionCallResponse;
      expect(call.id, 'call00001');
      expect(call.args, {'q': 'flower'});
      expect(engine.lastTools.single.toJsonSchema(), tool.parameters);
      expect(engine.lastTemplateTools.single.toJsonSchema(), tool.parameters);
      expect(engine.lastToolChoice, llama.ToolChoice.required);
      await expectLater(
        chat.addQuery(edge.Message.text(text: 'next', isUser: true)),
        throwsA(isA<StateError>()),
      );
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: call.id,
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
        _toolChunk(0, 'search', '{"q":"a"}', id: 'call00001'),
        _toolChunk(1, 'search', '{"q":"b"}', id: 'call00002'),
      ];
      final chat = await model.createChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'both', isUser: true));
      final response =
          await chat.generateChatResponse()
              as edge.ParallelFunctionCallResponse;
      expect(response.calls.map((c) => c.id), ['call00001', 'call00002']);
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: 'call00002',
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
        ['call00001', 'call00002'],
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

  test(
    'none tool choice keeps declarations for replay and forbids calls',
    () async {
      final chat = await model.createChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.none,
      );
      await chat.addQuery(edge.Message.text(text: 'hello', isUser: true));
      await chat.generateChatResponse();
      expect(engine.lastTools.single.name, 'search');
      expect(engine.lastToolChoice, llama.ToolChoice.none);
    },
  );

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
        throwsA(isA<StateError>()),
      );
      expect(chat.fullHistory, isEmpty);
    }
  });

  for (final payload in [
    '{"name":"search","parameters":{"q":"a"}}',
    '[{"name":"search","parameters":{"q":"a"}},{"name":"search","parameters":{"q":"b"}}]',
    '{"tool_calls":[{"id":"replay_0","function":{"name":"search","arguments":{"q":"a"}}},{"function":{"name":"search","arguments":{"q":"b"}}}]}',
    '{"tool_calls":[{"function":{"name":"search","arguments":{"q":"a"}}},{"id":"replay_0","function":{"name":"search","arguments":{"q":"b"}}}]}',
  ]) {
    test(
      'core and wrapper tool replay pairs repeated names: $payload',
      () async {
        final chat = await model.openChat(tools: [tool]);
        await chat.addQuery(edge.Message.text(text: 'find', isUser: true));
        await chat.addQuery(edge.Message.toolCall(text: payload));
        final count = payload.startsWith('{"name"') ? 1 : 2;
        for (var i = 0; i < count; i++) {
          await chat.addQuery(
            edge.Message.toolResponse(
              toolName: 'search',
              response: {'index': i},
            ),
          );
        }
        await chat.generateChatResponse();
        final calls = engine.requests.last
            .expand((m) => m.parts)
            .whereType<llama.LlamaToolCallContent>()
            .toList();
        final results = engine.requests.last
            .expand((m) => m.parts)
            .whereType<llama.LlamaToolResultContent>()
            .toList();
        expect(calls.map((c) => c.id).toSet(), hasLength(count));
        expect(results.map((r) => r.id), calls.map((c) => c.id));
        expect(results.map((r) => r.result), [
          for (var i = 0; i < count; i++) {'index': i},
        ]);
        expect(
          chat.fullHistory.where(
            (m) => m.type == edge.MessageType.toolResponse,
          ),
          hasLength(count),
        );
        await chat.clearHistory(replayHistory: List.of(chat.fullHistory));
        await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
        await chat.generateChatResponse();
      },
    );
  }

  test(
    'blank arguments on a no-argument tool decode to an empty object',
    () async {
      engine.script = [_toolChunk(0, 'ping', '')];
      final chat = await model.openChat(
        tools: [
          const edge.Tool(
            name: 'ping',
            description: 'Ping',
            parameters: {'type': 'object', 'properties': {}},
          ),
        ],
      );
      await chat.addQuery(edge.Message.text(text: 'ping', isUser: true));
      final call =
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      expect(call.args, isEmpty);
    },
  );

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
        throwsA(isA<ArgumentError>()),
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
      throwsA(isA<ArgumentError>()),
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
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      await expectLater(
        chat.addQuery(
          edge.Message(
            text: '{',
            type: edge.MessageType.toolResponse,
            toolName: 'search',
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: first.id,
          toolName: first.name,
          response: {'ok': true},
        ),
      );
      final second =
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      expect(second.id, isNot(first.id));
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: second.id,
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
      throwsA(isA<ArgumentError>()),
    );
    expect(model.session, same(existing.session));
    await existing.addQuery(
      edge.Message.text(text: 'still usable', isUser: true),
    );
    await existing.generateChatResponse();
    expect(existing.fullHistory.length, 2);
  });

  test('empty inputs fail before entering history', () async {
    final session = await model.openSession() as LlamaInferenceSession;
    await expectLater(
      session.addQueryChunk(edge.Message.text(text: '', isUser: true)),
      throwsA(isA<ArgumentError>()),
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
      }, onError: (Object _) {});
      await first.future;
      await peer.addQueryChunk(edge.Message.text(text: 'queued', isUser: true));
      final queued = peer.getResponseAsync().listen(
        (_) {},
        onError: (Object _) {},
      );
      await model.close().timeout(const Duration(seconds: 2));
      await Future.wait([running.cancel(), queued.cancel()]);
      expect(engine.maxActive, 1);
      expect(engine.disposals, 1);
      expect(model.sessions, isEmpty);
    },
  );

  test(
    'llama.cpp tools preflight without a runtime capability probe',
    () async {
      engine.capabilityError = StateError('Must not probe capabilities');
      final chat = await model.createChat(tools: [tool]);
      expect(chat, isNotNull);
      expect(engine.lastTemplateTools.single.name, tool.name);
    },
  );

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
    await expectLater(model.openSession(), throwsA(isA<StateError>()));
    await a.close();
    final b = await model.openSession();
    await model.close();
    await expectLater(
      b.addQueryChunk(edge.Message.text(text: 'closed')),
      throwsA(isA<StateError>()),
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
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'SDK cause',
            isA<llama.LlamaInferenceException>(),
          ),
        ),
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
      expect(chat.fullHistory.map((m) => m.type), [
        edge.MessageType.text,
        edge.MessageType.toolCall,
        edge.MessageType.toolResponse,
        edge.MessageType.text,
      ]);
      await chat.clearHistory(replayHistory: List.of(chat.fullHistory));
      await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.role), [
        llama.LlamaChatRole.user,
        llama.LlamaChatRole.assistant,
        llama.LlamaChatRole.tool,
        llama.LlamaChatRole.assistant,
        llama.LlamaChatRole.user,
      ]);
      expect(model.sessions.length, 1);
    },
  );

  test(
    'projector pairing and capabilities are validated before serving media',
    () async {
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
        projectorResolver: (_, _) async =>
            kIsWeb ? 'https://models.invalid/projector.gguf' : 'projector.gguf',
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
      expect(
        engine.projector,
        kIsWeb ? 'https://models.invalid/projector.gguf' : 'projector.gguf',
      );
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
        throwsA(isA<ArgumentError>()),
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
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('per-session LoRA is applied and removed before a peer runs', () async {
    final a = await model.openSession(loraPath: adapterPath);
    final b = await model.openSession();
    await a.addQueryChunk(edge.Message.text(text: 'adapted', isUser: true));
    await b.addQueryChunk(edge.Message.text(text: 'base', isUser: true));
    await Future.wait([a.getResponse(), b.getResponse()]);
    expect(engine.adaptersAtGeneration, [adapterPath, null]);
    expect(engine.loraEvents, ['set:$adapterPath', 'remove:$adapterPath']);
    engine.failAfterFirstToken = true;
    await a.addQueryChunk(edge.Message.text(text: 'fail', isUser: true));
    await expectLater(
      a.getResponse(),
      throwsA(
        isA<RuntimeStateError>().having(
          (e) => e.cause,
          'SDK cause',
          isA<llama.LlamaInferenceException>(),
        ),
      ),
    );
    expect(engine.activeAdapter, isNull);
  }, skip: kIsWeb);

  test(
    'a rejected LoRA override restores the baseline and leaves peers usable',
    () async {
      await model.close();
      engine = _FakeEngine()
        ..activeAdapter = 'installed.gguf'
        ..failLoraSetPath = adapterPath;
      model = LlamaInferenceModel(
        engine: engine,
        maxTokens: 2048,
        activeBackend: edge.PreferredBackend.cpu,
        defaultLoraPath: 'installed.gguf',
      );
      final adapted = await model.openSession(loraPath: adapterPath);
      await adapted.addQueryChunk(
        edge.Message.text(text: 'rejected', isUser: true),
      );
      await expectLater(
        adapted.getResponse(),
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'SDK cause',
            isA<llama.LlamaInferenceException>(),
          ),
        ),
      );
      expect(model.isClosed, isFalse);
      expect(engine.activeAdapter, 'installed.gguf');
      final peer = await model.openSession();
      await peer.addQueryChunk(
        edge.Message.text(text: 'baseline', isUser: true),
      );
      await peer.getResponse();
      expect(engine.adaptersAtGeneration, ['installed.gguf']);
    },
    skip: kIsWeb,
  );

  test(
    'a recovered temporary cleanup failure leaves the shared runtime usable',
    () async {
      engine.failLoraCleanupCount = 1;
      final adapted = await model.openSession(loraPath: adapterPath);
      await adapted.addQueryChunk(
        edge.Message.text(text: 'adapted', isUser: true),
      );
      await expectLater(
        adapted.getResponse(),
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'SDK cause',
            isA<llama.LlamaInferenceException>(),
          ),
        ),
      );
      expect(model.isClosed, isFalse);
      expect(engine.activeAdapter, isNull);
      final peer = await model.openSession();
      await peer.addQueryChunk(edge.Message.text(text: 'peer', isUser: true));
      await peer.getResponse();
      expect(engine.adaptersAtGeneration, [adapterPath, null]);
    },
    skip: kIsWeb,
  );

  test(
    'cleanup failure during stop closes the model and retains its cause',
    () async {
      engine.blockGeneration = true;
      engine.failLoraCleanup = true;
      final adapted = await model.openSession(loraPath: adapterPath);
      await adapted.addQueryChunk(
        edge.Message.text(text: 'stopped', isUser: true),
      );
      final first = Completer<void>();
      final errors = <Object>[];
      final subscription = adapted.getResponseAsync().listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: errors.add);
      await first.future.timeout(const Duration(seconds: 2));
      await adapted.stopGeneration();
      await model.close().timeout(const Duration(seconds: 2));
      await subscription.cancel();
      expect(model.isClosed, isTrue);
      expect(engine.disposals, 1);
      await expectLater(
        model.openSession(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cause',
            contains('cleanup failed'),
          ),
        ),
      );
    },
    skip: kIsWeb,
  );

  test(
    'failed LoRA cleanup rolls back and prevents contaminated peer inference',
    () async {
      engine.failLoraCleanup = true;
      final adapted = await model.openChat(loraPath: adapterPath);
      final peer = await model.openSession();
      await adapted.addQuery(edge.Message.text(text: 'adapted', isUser: true));
      await expectLater(
        adapted.generateChatResponse(),
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'SDK cause',
            isA<llama.LlamaInferenceException>(),
          ),
        ),
      );
      expect(model.isClosed, isTrue);
      await expectLater(
        peer.addQueryChunk(edge.Message.text(text: 'peer', isUser: true)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cause',
            contains('cleanup failed'),
          ),
        ),
      );
      await model.close().timeout(const Duration(seconds: 2));
      expect(engine.disposals, 1);
      expect(engine.requests.length, 1);
    },
    skip: kIsWeb,
  );

  test(
    'blank generated arguments remain valid on next turn and restore',
    () async {
      engine.script = [_toolChunk(0, 'search', '', id: 'empty')];
      final chat = await model.openChat(tools: [tool]);
      await chat.addQuery(edge.Message.text(text: 'call', isUser: true));
      final call =
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      expect(call.args, isEmpty);
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: call.id,
          toolName: call.name,
          response: {'ok': true},
        ),
      );
      engine.script = null;
      await chat.generateChatResponse();
      final saved = List<edge.Message>.of(chat.fullHistory);
      for (var cycle = 0; cycle < 2; cycle++) {
        final calls = engine.requests.last
            .expand((m) => m.parts)
            .whereType<llama.LlamaToolCallContent>();
        expect(calls.single.rawJson, '{}');
        await chat.clearHistory(replayHistory: saved);
        await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
        await chat.generateChatResponse();
      }
    },
  );

  for (final args in ['null', '""', '"   "']) {
    test('replay accepts no-argument parameters $args', () async {
      final chat = await model.openChat(tools: [tool]);
      await chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'call', isUser: true),
          edge.Message.toolCall(text: '{"name":"search","parameters":$args}'),
          edge.Message.toolResponse(toolName: 'search', response: {'ok': true}),
        ],
      );
      await chat.generateChatResponse();
      expect(
        engine.requests.last
            .expand((m) => m.parts)
            .whereType<llama.LlamaToolCallContent>()
            .single
            .rawJson,
        '{}',
      );
    });
  }

  test(
    'fullHistory survives session replacement and model close for recovery',
    () async {
      final chat = await model.createChat();
      await chat.addQuery(edge.Message.text(text: 'saved', isUser: true));
      await chat.generateChatResponse();
      final original = List.of(chat.fullHistory);
      await model.createChat();
      expect(chat.fullHistory, original);
      await model.close();
      expect(chat.fullHistory, original);
      engine = _FakeEngine();
      model = LlamaInferenceModel(
        engine: engine,
        maxTokens: 2048,
        activeBackend: edge.PreferredBackend.cpu,
      );
      final restored = await model.createChat();
      await restored.clearHistory(replayHistory: chat.fullHistory);
      await restored.addQuery(edge.Message.text(text: 'next', isUser: true));
      await restored.generateChatResponse();
      expect(engine.requests.last.map((m) => m.content), [
        'saved',
        'Hello world',
        'next',
      ]);
      await restored.close();
      expect(restored.fullHistory, hasLength(4));
    },
  );

  for (final thinking in [false, true]) {
    test(
      'saved tool calls omit reasoning and runtime wire fields ($thinking)',
      () async {
        engine.script = [
          _thinking('PRIVATE'),
          _toolChunk(0, 'search', '{}', id: 'call00001'),
        ];
        final chat = await model.openChat(
          tools: [tool],
          enableThinking: thinking,
        );
        await chat.addQuery(edge.Message.text(text: 'call', isUser: true));
        await chat.generateChatResponse();
        final saved = chat.fullHistory
            .singleWhere((m) => m.type == edge.MessageType.toolCall)
            .text;
        expect(jsonDecode(saved), {
          'tool_calls': [
            {'id': 'call00001', 'name': 'search', 'arguments': {}},
          ],
        });
        expect(saved, isNot(contains('PRIVATE')));
        await chat.clearHistory(replayHistory: chat.fullHistory);
      },
    );
  }

  for (final stop in [false, true]) {
    test(
      'restored trailing user rolls back on ${stop ? "stop" : "failure"}',
      () async {
        final chat = await model.openChat();
        await chat.clearHistory(
          replayHistory: [
            edge.Message.text(text: 'committed', isUser: true),
            edge.Message.text(text: 'answer'),
            edge.Message.text(text: 'pending', isUser: true),
          ],
        );
        engine.blockGeneration = stop;
        engine.failAfterFirstToken = !stop;
        if (stop) {
          final first = Completer<void>();
          final subscription = chat.generateChatResponseAsync().listen((_) {
            if (!first.isCompleted) first.complete();
          });
          await first.future;
          await chat.stopGeneration();
          await subscription.cancel();
        } else {
          await expectLater(
            chat.generateChatResponse(),
            throwsA(
              isA<RuntimeStateError>().having(
                (e) => e.cause,
                'SDK cause',
                isA<llama.LlamaInferenceException>(),
              ),
            ),
          );
        }
        expect(chat.fullHistory.map((m) => m.text), ['committed', 'answer']);
        engine.blockGeneration = engine.failAfterFirstToken = false;
        await chat.addQuery(edge.Message.text(text: 'retry', isUser: true));
        await chat.generateChatResponse();
        expect(engine.requests.last.map((m) => m.role), [
          llama.LlamaChatRole.user,
          llama.LlamaChatRole.assistant,
          llama.LlamaChatRole.user,
        ]);
      },
    );
  }

  test('out-of-order repeated tool results retain IDs after replay', () async {
    engine.script = [
      _toolChunk(0, 'search', '{"q":"first"}', id: 'call00001'),
      _toolChunk(1, 'search', '{"q":"second"}', id: 'call00002'),
    ];
    final chat = await model.openChat(tools: [tool]);
    await chat.addQuery(edge.Message.text(text: 'parallel', isUser: true));
    final response =
        await chat.generateChatResponse() as edge.ParallelFunctionCallResponse;
    // The public base list supports ordinary FunctionCallResponse entries.
    response.calls.add(
      const edge.FunctionCallResponse(name: 'extra', args: {}),
    );
    for (final id in ['call00002', 'call00001']) {
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: id,
          toolName: 'search',
          response: {'for': id},
        ),
      );
    }
    engine.script = null;
    await chat.generateChatResponse();
    // Persist ordinary core fields, as an app/database or another engine does.
    final saved = [
      for (final message in chat.fullHistory)
        edge.Message(
          text: message.text,
          type: message.type,
          isUser: message.isUser,
          toolName: message.toolName,
        ),
    ];
    await chat.clearHistory(replayHistory: saved);
    await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
    await chat.generateChatResponse();
    final results = engine.requests.last
        .expand((m) => m.parts)
        .whereType<llama.LlamaToolResultContent>();
    expect(results.map((r) => [r.id, r.result]), [
      [
        'call00001',
        {'for': 'call00001'},
      ],
      [
        'call00002',
        {'for': 'call00002'},
      ],
    ]);
  });

  test(
    'separate flat tool-call parts preserve result pairing after ordinary persistence',
    () async {
      final chat = await model.openChat(tools: [tool]);
      await chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'parallel', isUser: true),
          edge.Message.toolCall(
            text: '{"id":"a","name":"search","parameters":{"q":"first"}}',
          ),
          edge.Message.toolCall(
            text: '{"id":"b","name":"search","parameters":{"q":"second"}}',
          ),
          edge.Message.toolResponse(
            toolCallId: 'b',
            toolName: 'search',
            response: {'for': 'b'},
          ),
          edge.Message.toolResponse(
            toolCallId: 'a',
            toolName: 'search',
            response: {'for': 'a'},
          ),
        ],
      );
      await chat.generateChatResponse();
      final saved = [
        for (final message in chat.fullHistory)
          edge.Message(
            text: message.text,
            isUser: message.isUser,
            type: message.type,
            toolName: message.toolName,
          ),
      ];
      await chat.clearHistory(replayHistory: saved);
      await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
      await chat.generateChatResponse();
      final results = engine.requests.last
          .expand((m) => m.parts)
          .whereType<llama.LlamaToolResultContent>();
      expect(results.map((r) => [r.id, r.result]), [
        [
          '000000000',
          {'for': 'a'},
        ],
        [
          '000000001',
          {'for': 'b'},
        ],
      ]);
    },
  );

  test(
    'staged tool replay preserves repeated results through plain-message persistence',
    () async {
      final chat = await model.openChat(tools: [tool]);
      for (final message in [
        edge.Message.text(text: 'parallel', isUser: true),
        edge.Message.toolCall(
          text:
              '[{"id":"a","name":"search","parameters":{}},{"id":"b","name":"search","parameters":{}}]',
        ),
        edge.Message.toolResponse(
          toolCallId: 'b',
          toolName: 'search',
          response: {'for': 'b'},
        ),
        edge.Message.toolResponse(
          toolCallId: 'a',
          toolName: 'search',
          response: {'for': 'a'},
        ),
      ]) {
        await chat.addQuery(message);
      }
      await chat.generateChatResponse();
      final saved = [
        for (final message in chat.fullHistory)
          edge.Message(
            text: message.text,
            isUser: message.isUser,
            type: message.type,
            toolName: message.toolName,
          ),
      ];
      await chat.clearHistory(replayHistory: saved);
      await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
      await chat.generateChatResponse();
      final results = engine.requests.last
          .expand((m) => m.parts)
          .whereType<llama.LlamaToolResultContent>();
      expect(results.map((r) => [r.id, r.result]), [
        [
          '000000000',
          {'for': 'a'},
        ],
        [
          '000000001',
          {'for': 'b'},
        ],
      ]);
    },
  );

  test(
    'tool IDs stay unique in fullHistory after runtime context trimming',
    () async {
      final chat = await model.openChat(tools: [tool], tokenBuffer: 256);
      engine.promptCounter = (messages) =>
          messages.where((m) => m.role == llama.LlamaChatRole.user).length > 1
          ? 1900
          : 100;
      for (var turn = 0; turn < 3; turn++) {
        engine.script = [_toolChunk(0, 'search', '{}', id: 'reused')];
        await chat.addQuery(
          edge.Message.text(text: 'turn $turn', isUser: true),
        );
        final call =
            await chat.generateChatResponse() as edge.FunctionCallResponse;
        await chat.addQuery(
          edge.Message.toolResponse(
            toolCallId: call.id,
            toolName: 'search',
            response: {'turn': turn},
          ),
        );
        engine.script = null;
        await chat.generateChatResponse();
      }
      final calls = chat.fullHistory
          .where((m) => m.type == edge.MessageType.toolCall)
          .expand(
            (m) =>
                (jsonDecode(m.text) as Map<String, dynamic>)['tool_calls']
                    as List,
          );
      expect(calls.map((call) => call['id']).toSet(), hasLength(3));
      final saved = [
        for (final message in chat.fullHistory)
          edge.Message(
            text: message.text,
            isUser: message.isUser,
            type: message.type,
            toolName: message.toolName,
          ),
      ];
      await chat.clearHistory(replayHistory: saved);
      await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
      await chat.generateChatResponse();
      expect(
        chat.fullHistory.where((m) => m.type == edge.MessageType.toolCall),
        hasLength(3),
      );
    },
  );

  test(
    'unusable SDK context closes the model and preserves prior transcript',
    () async {
      final chat = await model.openChat();
      await chat.addQuery(edge.Message.text(text: 'saved', isUser: true));
      await chat.generateChatResponse();
      engine.generationError = llama.LlamaStateException(
        'context is unusable after a llama.cpp exception in llama_decode. Unload the model and load it again.',
      );
      await chat.addQuery(edge.Message.text(text: 'failure', isUser: true));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'cause',
            same(engine.generationError),
          ),
        ),
      );
      expect(model.isClosed, isTrue);
      await model.close();
      expect(chat.fullHistory.map((m) => m.text), ['saved', 'Hello world']);
      await expectLater(
        model.openSession(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cause',
            contains('unusable'),
          ),
        ),
      );
    },
  );

  test(
    'queued peer receives failure when owner invalidates the model',
    () async {
      engine.blockGeneration = true;
      engine.failLoraCleanup = true;
      final owner = await model.openChat(loraPath: adapterPath);
      final peer = await model.openChat();
      await owner.addQuery(edge.Message.text(text: 'owner', isUser: true));
      final first = Completer<void>();
      final ownerErrors = <Object>[];
      final subscription = owner.generateChatResponseAsync().listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: ownerErrors.add);
      await first.future;
      await peer.addQuery(edge.Message.text(text: 'queued', isUser: true));
      final assertion = expectLater(
        peer.generateChatResponse(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'cause',
            contains('cleanup failed'),
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await owner.stopGeneration();
      await assertion;
      await subscription.cancel();
      await model.close();
      expect(ownerErrors, isNotEmpty);
      expect(engine.requests, hasLength(1));
    },
    skip: kIsWeb,
  );

  test('primary SDK error survives a separate cleanup error', () async {
    engine.failAfterFirstToken = engine.failLoraCleanup = true;
    final diagnostics = <String?>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        diagnostics.add(message);
    try {
      final chat = await model.openChat(loraPath: adapterPath);
      await chat.addQuery(edge.Message.text(text: 'fail', isUser: true));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<RuntimeStateError>()
              .having(
                (e) => e.cause,
                'SDK cause',
                isA<llama.LlamaInferenceException>(),
              )
              .having(
                (e) => (e.cause as llama.LlamaException).message,
                'original',
                'test failure',
              ),
        ),
      );
      await model.close();
      expect(diagnostics.join(), contains('cleanup failed'));
    } finally {
      debugPrint = originalPrint;
    }
  }, skip: kIsWeb);

  test('self-close disposal failures are reported', () async {
    final failedEngine = _FakeEngine()
      ..generationError = llama.LlamaStateException(
        'context is unusable after a llama.cpp exception in llama_decode.',
      )
      ..disposalError = StateError('dispose failed');
    final failedModel = LlamaInferenceModel(
      engine: failedEngine,
      maxTokens: 2048,
      activeBackend: edge.PreferredBackend.cpu,
    );
    final diagnostics = <String?>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) =>
        diagnostics.add(message);
    try {
      final chat = await failedModel.openChat();
      await chat.addQuery(edge.Message.text(text: 'fail', isUser: true));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<RuntimeStateError>().having(
            (e) => e.cause,
            'cause',
            same(failedEngine.generationError),
          ),
        ),
      );
      await expectLater(failedModel.close(), throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
      expect(diagnostics.join(), contains('dispose failed'));
    } finally {
      debugPrint = originalPrint;
    }
  });

  test(
    'Web explicit GPU SDK capability rejection uses UnsupportedError',
    () async {
      final provider = createLlamaProviderForTest(
        loader: (_, _) async =>
            throw llama.LlamaUnsupportedException('WebGPU unavailable'),
      );
      await expectLater(
        provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: 'model.gguf',
            preferredBackend: edge.PreferredBackend.gpu,
            maxTokens: 2048,
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
    skip: !kIsWeb,
  );
  test('round4 idle close preserves staged answers for replay', () async {
    final chat = await model.openChat(tools: [tool]);
    engine.script = [_toolChunk(0, 'search', '{}', id: 'call00001')];
    await chat.addQuery(edge.Message.text(text: 'search', isUser: true));
    final call = await chat.generateChatResponse() as edge.FunctionCallResponse;
    await chat.addQuery(
      edge.Message.toolResponse(
        toolCallId: call.id,
        toolName: 'search',
        response: {'found': true},
      ),
    );
    await model.close();
    expect(chat.fullHistory.map((m) => m.type), [
      edge.MessageType.text,
      edge.MessageType.toolCall,
      edge.MessageType.toolResponse,
    ]);
    final replacement = LlamaInferenceModel(
      engine: _FakeEngine(),
      maxTokens: 2048,
      activeBackend: edge.PreferredBackend.cpu,
    );
    addTearDown(replacement.close);
    final restored = await replacement.openChat(tools: [tool]);
    await restored.clearHistory(replayHistory: chat.fullHistory);
    await restored.addQuery(edge.Message.text(text: 'continue', isUser: true));
    await restored.generateChatResponse();
  });

  test(
    'round4 none permits historical tools while disabling generated calls',
    () async {
      final chat = await model.openChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.none,
      );
      await chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'old', isUser: true),
          edge.Message.toolCall(text: '{"name":"search","parameters":null}'),
          edge.Message.toolResponse(
            toolName: 'search',
            response: {'found': true},
          ),
          edge.Message.text(text: 'continue', isUser: true),
        ],
      );
      await chat.generateChatResponse();
      expect(engine.lastToolChoice, llama.ToolChoice.none);
      engine.script = [_toolChunk(0, 'search', '{}', id: 'call00002')];
      await chat.addQuery(edge.Message.text(text: 'disabled', isUser: true));
      await expectLater(chat.generateChatResponse(), throwsStateError);
    },
  );

  test('round4 live results match saved and restored call order', () async {
    final chat = await model.openChat(tools: [tool]);
    engine.script = [
      _toolChunk(0, 'search', '{}', id: 'call00001'),
      _toolChunk(1, 'search', '{}', id: 'call00002'),
    ];
    await chat.addQuery(edge.Message.text(text: 'parallel', isUser: true));
    await chat.generateChatResponse();
    for (final id in ['call00002', 'call00001']) {
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: id,
          toolName: 'search',
          response: {'id': id},
        ),
      );
    }
    engine.script = null;
    await chat.generateChatResponse();
    expect(
      engine.requests.last
          .where((m) => m.role == llama.LlamaChatRole.tool)
          .map((m) => (m.parts.single as llama.LlamaToolResultContent).id),
      ['call00001', 'call00002'],
    );
  });

  test('round4 generated and replay IDs satisfy Mistral length', () async {
    final chat = await model.openChat(tools: [tool]);
    await chat.clearHistory(
      replayHistory: [
        edge.Message.text(text: 'old', isUser: true),
        edge.Message.toolCall(text: '{"name":"search","parameters":{}}'),
      ],
    );
    var calls =
        (jsonDecode(chat.fullHistory.last.text) as Map)['tool_calls'] as List;
    expect(calls.single['id'], matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
    await chat.addQuery(
      edge.Message.toolResponse(toolName: 'search', response: {}),
    );
    engine.script = [_toolChunk(0, 'search', '{}')];
    final call = await chat.generateChatResponse() as edge.FunctionCallResponse;
    expect(call.id, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
    expect(call.id, isNot(calls.single['id']));
  });

  test('round4 replay permits reused IDs only across answered turns', () async {
    final chat = await model.openChat(tools: [tool]);
    final history = <edge.Message>[];
    for (var i = 0; i < 2; i++) {
      history.addAll([
        edge.Message.text(text: 'turn $i', isUser: true),
        edge.Message.toolCall(
          text: '{"id":"call_0","name":"search","arguments":{}}',
        ),
        edge.Message.toolResponse(
          toolCallId: 'call_0',
          toolName: 'search',
          response: {'turn': i},
        ),
        edge.Message.text(text: 'answer $i'),
      ]);
    }
    await chat.clearHistory(replayHistory: history);
    await chat.addQuery(edge.Message.text(text: 'next', isUser: true));
    await chat.generateChatResponse();
    final ids = engine.requests.last
        .expand((m) => m.parts.whereType<llama.LlamaToolCallContent>())
        .map((c) => c.id)
        .toList();
    expect(ids, hasLength(2));
    expect(ids.toSet(), hasLength(2));
  });

  test('round4 schema-backed GLM grammar contains required arguments', () {
    final definition = SchemaToolDefinition(
      edge.Tool(
        name: 'get_weather',
        description: 'Weather',
        parameters: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
            'days': {'type': 'integer'},
          },
          'required': ['city'],
        },
      ),
    );
    final grammar = Glm45Handler().buildGrammar([definition])!;
    expect(grammar, contains('city'));
    expect(grammar, contains('days'));
    expect(definition.parameters.first.required, isTrue);
  });

  for (final operation in ['generation', 'tokenization', 'preflight']) {
    test('round4 worker failure in $operation evicts the model', () async {
      final chat = await model.openChat();
      final error = llama.LlamaStateException(
        'The llama.cpp worker exited unexpectedly.',
      );
      if (operation == 'generation') {
        engine.generationError = error;
        await chat.addQuery(edge.Message.text(text: 'fail', isUser: true));
        await expectLater(
          chat.generateChatResponse(),
          throwsA(isA<StateError>()),
        );
      } else if (operation == 'tokenization') {
        engine.tokenError = error;
        await expectLater(
          chat.session.sizeInTokens('fail'),
          throwsA(isA<StateError>()),
        );
      } else {
        engine.templateError = error;
        await expectLater(
          model.openChat(tools: [tool]),
          throwsA(isA<StateError>()),
        );
      }
      expect(model.isClosed, isTrue);
      await model.close();
    });
  }

  test(
    'round4 closed during generation reports failure and releases waiters',
    () async {
      engine.blockGeneration = true;
      final chat = await model.openChat();
      await chat.addQuery(edge.Message.text(text: 'close', isUser: true));
      final first = Completer<void>();
      final errors = <Object>[];
      final done = Completer<void>();
      chat.generateChatResponseAsync().listen(
        (_) {
          if (!first.isCompleted) first.complete();
        },
        onError: errors.add,
        onDone: done.complete,
      );
      await first.future;
      await model.close().timeout(const Duration(seconds: 2));
      await done.future.timeout(const Duration(seconds: 2));
      expect(errors.single, isA<StateError>());
      expect(chat.fullHistory, isEmpty);
    },
  );

  test('round4 load errors survive failing disposal', () async {
    engine.disposalError = StateError('secondary dispose');
    final provider = createLlamaProviderForTest(
      loader: (_, _) async => engine,
      projectorResolver: (_, _) async =>
          throw ArgumentError('primary projector'),
    );
    await expectLater(
      provider.createModel(
        _spec('test.gguf'),
        const RuntimeConfig(
          modelPath: '/models/test.gguf',
          maxTokens: 2048,
          supportImage: true,
        ),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'primary',
          contains('primary projector'),
        ),
      ),
    );
    engine.disposalError = null;
  });

  test(
    'round4 context downgrade fails instead of changing the contract',
    () async {
      engine.contextSize = 512;
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => engine,
      );
      await expectLater(
        provider.createModel(
          _spec('test.gguf'),
          const RuntimeConfig(modelPath: '/models/test.gguf', maxTokens: 2048),
        ),
        throwsA(isA<StateError>()),
      );
      expect(engine.disposals, 1);
    },
  );

  test(
    'round4 unsupported SDK loads map consistently on every platform',
    () async {
      final provider = createLlamaProviderForTest(
        loader: (_, _) async =>
            throw llama.LlamaUnsupportedException('GPU missing'),
      );
      await expectLater(
        provider.createModel(
          _spec('test.gguf'),
          const RuntimeConfig(
            modelPath: '/models/test.gguf',
            maxTokens: 2048,
            preferredBackend: edge.PreferredBackend.gpu,
          ),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    },
  );

  test('round4 corrupt format becomes invalid argument with cause', () async {
    final cause = llama.LlamaModelFormatException(
      detected: llama.ModelFormat.liteRtLm,
      declared: llama.ModelFormat.gguf,
    );
    final provider = createLlamaProviderForTest(
      loader: (_, _) async => throw cause,
    );
    await expectLater(
      provider.createModel(
        _spec('test.gguf'),
        const RuntimeConfig(modelPath: '/models/test.gguf', maxTokens: 2048),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('round4 template preflight preserves the usable legacy chat', () async {
    final previous = await model.createChat();
    engine.templateError = llama.LlamaUnsupportedException(
      'Tool name cannot be expressed',
    );
    await expectLater(
      model.createChat(tools: [tool]),
      throwsA(isA<UnsupportedError>()),
    );
    engine.templateError = null;
    await previous.addQuery(
      edge.Message.text(text: 'still works', isUser: true),
    );
    expect(await previous.generateChatResponse(), isA<edge.TextResponse>());
  });

  test('round4 tool response equality and copying retain call identity', () {
    final a = edge.Message.toolResponse(
      toolCallId: 'a',
      toolName: 'search',
      response: {'ok': true},
    );
    final b = edge.Message.toolResponse(
      toolCallId: 'b',
      toolName: 'search',
      response: {'ok': true},
    );
    expect(a, isNot(b));
    expect(
      a.copyWith(text: '{"ok":false}'),
      isA<edge.Message>().having((m) => m.toolCallId, 'callId', 'a'),
    );
  });
  test(
    'round4 rich specialized schemas fail preflight before replacing chat',
    () async {
      final previous = await model.createChat();
      engine.templateFormat = llama.ChatFormat.glm45.index;
      final rich = edge.Tool(
        name: 'search',
        description: 'Search',
        parameters: {
          'type': 'object',
          'properties': {
            'q': {'type': 'string', 'minLength': 1},
          },
        },
      );
      await expectLater(
        model.createChat(tools: [rich]),
        throwsUnsupportedError,
      );
      engine.templateFormat = 0;
      await previous.addQuery(
        edge.Message.text(text: 'still usable', isUser: true),
      );
      await previous.generateChatResponse();
      expect(engine.requests.single.single.content, 'still usable');
    },
  );

  test(
    'round4 hidden reasoning has one notice per chat without leaking text',
    () async {
      final logs = <String>[];
      await runZoned(
        () async {
          final chat = await model.openChat(enableThinking: false);
          for (var turn = 0; turn < 2; turn++) {
            engine.script = [_thinking('HIDDEN SECRET'), _chunk('visible')];
            await chat.addQuery(
              edge.Message.text(text: 'turn $turn', isUser: true),
            );
            final response =
                await chat.generateChatResponse() as edge.TextResponse;
            expect(response.token, 'visible');
            expect(
              chat.fullHistory.any((m) => m.text.contains('HIDDEN SECRET')),
              isFalse,
            );
          }
          engine.script = [_thinking('HIDDEN SECRET')];
          await chat.addQuery(
            edge.Message.text(text: 'no answer', isUser: true),
          );
          await expectLater(
            chat.generateChatResponse(),
            throwsA(
              isA<StateError>().having(
                (e) => e.message,
                'budget advice',
                isNot(contains('disable thinking')),
              ),
            ),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, String line) => logs.add(line),
        ),
      );
      expect(
        logs.where(
          (line) => line.contains('model reasoned although thinking is off'),
        ),
        hasLength(1),
      );
      expect(logs.any((line) => line.contains('HIDDEN SECRET')), isFalse);
    },
  );

  test('round4 Web blob projector loads through a path source', () async {
    final provider = createLlamaProviderForTest(
      loader: (_, _) async => engine,
      projectorResolver: (_, _) async => 'blob:https://app.invalid/projector',
    );
    final loaded = await provider.createModel(
      _spec('model.gguf'),
      const RuntimeConfig(
        modelPath: 'https://app.invalid/model.gguf',
        maxTokens: 2048,
        supportImage: true,
      ),
    );
    expect(engine.projector, 'blob:https://app.invalid/projector');
    await loaded.close();
  }, skip: !kIsWeb);
  for (final toolsPresent in [false, true]) {
    test(
      'round5 replacement cancels an active turn (tools: $toolsPresent)',
      () async {
        engine.blockGeneration = true;
        final previous = await model.createChat();
        await previous.addQuery(
          edge.Message.text(text: 'running', isUser: true),
        );
        final first = Completer<void>();
        final done = Completer<void>();
        final errors = <Object>[];
        previous.generateChatResponseAsync().listen(
          (_) {
            if (!first.isCompleted) first.complete();
          },
          onError: errors.add,
          onDone: done.complete,
        );
        await first.future;
        final next = await model
            .createChat(tools: toolsPresent ? [tool] : [])
            .timeout(const Duration(seconds: 2));
        await done.future.timeout(const Duration(seconds: 2));
        expect(engine.cancels, greaterThan(0));
        expect(errors.single, isA<StateError>());
        expect(previous.fullHistory, isEmpty);
        engine.blockGeneration = false;
        await next.addQuery(edge.Message.text(text: 'new', isUser: true));
        expect(await next.generateChatResponse(), isA<edge.TextResponse>());
      },
    );
  }

  test('round5 close completes while a replacement is pending', () async {
    engine.blockGeneration = true;
    final previous = await model.createChat();
    await previous.addQuery(edge.Message.text(text: 'running', isUser: true));
    final first = Completer<void>();
    final done = Completer<void>();
    previous.generateChatResponseAsync().listen(
      (_) {
        if (!first.isCompleted) first.complete();
      },
      onError: (Object _) {},
      onDone: done.complete,
    );
    await first.future;
    final replacement = model.createChat(tools: [tool]);
    final checked = expectLater(replacement, throwsStateError);
    await model.close().timeout(const Duration(seconds: 2));
    await checked;
    await done.future.timeout(const Duration(seconds: 2));
    expect(engine.disposals, 1);
  });

  test('round5 rejected replacement leaves the running turn intact', () async {
    engine.blockGeneration = true;
    final previous = await model.createChat();
    await previous.addQuery(edge.Message.text(text: 'running', isUser: true));
    final first = Completer<void>();
    final done = Completer<void>();
    previous.generateChatResponseAsync().listen((_) {
      if (!first.isCompleted) first.complete();
    }, onDone: done.complete);
    await first.future;
    engine.templateError = llama.LlamaUnsupportedException(
      'Invalid tool template',
    );
    final cancels = engine.cancels;
    await expectLater(
      model.createChat(tools: [tool]).timeout(const Duration(seconds: 2)),
      throwsUnsupportedError,
    );
    expect(engine.cancels, cancels);
    expect(engine.active, 1);
    engine.templateError = null;
    await previous.stopGeneration();
    await done.future;
  });

  test(
    'round5 load-time model failures preserve the SDK exception and stack',
    () async {
      final cause = llama.LlamaModelException(
        'Failed to load model from test.gguf',
      );
      final stack = StackTrace.fromString('load-failure-origin');
      final provider = createLlamaProviderForTest(
        loader: (_, _) async => Error.throwWithStackTrace(cause, stack),
      );
      try {
        await provider.createModel(
          _spec('test.gguf'),
          const RuntimeConfig(modelPath: '/models/test.gguf', maxTokens: 2048),
        );
        fail('Expected load failure');
      } catch (error, caughtStack) {
        expect(error, same(cause));
        expect(error, isNot(isA<StateError>()));
        expect(caughtStack.toString(), contains('load-failure-origin'));
      }
    },
  );

  test('round5 mixed XML tools retain untyped parameter names', () async {
    final nullableTool = edge.Tool(
      name: 'book_table',
      description: 'Book',
      parameters: {
        'type': 'object',
        'properties': {
          'date': {
            'type': ['string', 'null'],
          },
        },
        'required': ['date'],
      },
    );
    await model.openChat(tools: [tool, nullableTool]);
    final definitions = engine.lastTemplateTools;
    expect(definitions.every((t) => t.parameters.isEmpty), isTrue);
    final grammar = Qwen3CoderXmlHandler().buildGrammar(definitions)!;
    expect(grammar, contains('param-name ::= identifier'));
    expect(definitions.last.toJsonSchema(), nullableTool.parameters);
    // A fully typed set still retains its optimized argument names.
    await model.openChat(tools: [tool]);
    expect(engine.lastTemplateTools.single.parameters, isNotEmpty);
    engine.templateFormat = llama.ChatFormat.glm45.index;
    await expectLater(
      model.openChat(tools: [tool, nullableTool]),
      throwsUnsupportedError,
    );
  });

  for (final schema in <Map<String, dynamic>>[
    {
      'type': 'object',
      'properties': {'x': true},
    },
    {
      'type': 'object',
      'properties': {'x': false},
    },
    {
      'type': 'object',
      'required': ['x'],
    },
  ]) {
    test(
      'round5 valid untypable schema reaches the template: $schema',
      () async {
        final special = edge.Tool(
          name: 'special',
          description: 'Special',
          parameters: schema,
        );
        await model.openChat(tools: [special]);
        expect(engine.lastTemplateTools.single.toJsonSchema(), schema);
        expect(engine.lastTemplateTools.single.parameters, isEmpty);
        engine.templateFormat = llama.ChatFormat.hunyuanV3.index;
        await expectLater(
          model.openChat(tools: [special]),
          throwsUnsupportedError,
        );
      },
    );
  }
  for (final schema in <Map<String, dynamic>>[
    {'type': 'object', 'properties': []},
    {'type': 'object', 'properties': null},
    {'type': 'object', 'required': null},
    {'type': 'object', 'required': 'x'},
    {
      'type': 'object',
      'required': [1],
    },
    {
      'type': 'object',
      'properties': {'x': 7},
    },
    {
      'type': 'object',
      'properties': {
        'nullable': {'anyOf': []},
        'invalid': 7,
      },
    },
  ]) {
    test('round5 structurally invalid schemas still fail: $schema', () async {
      await expectLater(
        model.openChat(
          tools: [
            edge.Tool(name: 'bad', description: 'Bad', parameters: schema),
          ],
        ),
        throwsArgumentError,
      );
    });
  }

  test(
    'round5 typed cloud tool history aliases IDs and owns frozen arguments',
    () async {
      final chat = await model.openChat(tools: [tool]);
      final source = {
        'q': 'cloud',
        'nested': {
          'list': [1, 2],
        },
      };
      final supplied = ['call_cloud_123', 'toolu_cloud_456', '', 'abcDEF123'];
      final calls = edge.Message.toolCall(
        text: 'Opaque display text; typed calls are authoritative.',
        calls: [
          for (final id in supplied)
            edge.FunctionCallResponse(id: id, name: 'search', args: source),
        ],
      );
      source['q'] = 'mutated';
      await chat.clearHistory(
        replayHistory: [
          edge.Message.text(text: 'search', isUser: true),
          calls,
        ],
      );
      final recorded = toolCallsOf(chat.fullHistory.last);
      final ids = recorded.map((c) => c.id!).toList();
      expect(ids.toSet(), hasLength(supplied.length));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[a-zA-Z0-9]{9}$')));
      }
      expect(ids.last, 'abcDEF123');
      expect(recorded.first.args['q'], 'cloud');
      for (final id in supplied.reversed) {
        await chat.addQuery(
          edge.Message.toolResponse(
            toolCallId: id,
            toolName: 'search',
            response: {'source': id},
          ),
        );
      }
      await chat.generateChatResponse();
      final request = engine.requests.last;
      final runtimeCalls = request
          .expand((m) => m.parts.whereType<llama.LlamaToolCallContent>())
          .toList();
      final results = request
          .expand((m) => m.parts.whereType<llama.LlamaToolResultContent>())
          .toList();
      expect(runtimeCalls.map((c) => c.id), ids);
      expect(results.map((r) => r.id), ids);
      expect(results.map((r) => (r.result as Map)['source']), supplied);
      runtimeCalls.first.arguments['q'] = 'runtime-mutated';
      (runtimeCalls.first.arguments['nested'] as Map)['list'] = [3];
      expect(toolCallsOf(chat.fullHistory[1]).first.args['q'], 'cloud');
      expect(
        ((toolCallsOf(chat.fullHistory[1]).first.args['nested']
            as Map)['list']),
        [1, 2],
      );
      final restored = await model.openChat(tools: [tool]);
      await restored.clearHistory(replayHistory: chat.fullHistory);
      await restored.addQuery(
        edge.Message.text(text: 'continue', isUser: true),
      );
      await restored.generateChatResponse();
    },
  );
  group('structured output', () {
    const schema = <String, Object?>{
      'type': 'object',
      'properties': {
        'a': {'type': 'integer'},
        'b': {'type': 'string'},
      },
      'required': ['a'],
      'additionalProperties': false,
    };
    final object = edge.ResponseFormat.jsonObject();
    final stop = _chunk(null, finishReason: 'stop');
    late LlamaInferenceModel structured;
    setUp(() {
      structured = LlamaInferenceModel(
        engine: engine,
        maxTokens: 2048,
        activeBackend: edge.PreferredBackend.cpu,
        structuredOutput: const edge.StructuredOutputSupport(
          keywords: edge.ResponseFormat.dialect,
        ),
      );
    });
    tearDown(() => structured.close());

    // The engine's own session behind core's structured wrapper.
    LlamaInferenceSession engineSession() =>
        // ignore: invalid_use_of_protected_member
        structured.engineSessions.whereType<LlamaInferenceSession>().last;

    edge.Message user(String text) =>
        edge.Message.text(text: text, isUser: true);

    test('a model built outside the provider enforces no format', () async {
      expect(model.structuredOutputSupport.isSupported, isFalse);
      await expectLater(
        model.openSession(responseFormat: object),
        throwsA(isA<edge.ResponseFormatUnsupportedException>()),
      );
      expect(engine.requests, isEmpty);
    });

    test(
      'the format reaches llamadart, named, with thinking sent off',
      () async {
        final session = await structured.openSession(
          responseFormat: edge.ResponseFormat.jsonSchema(
            schema,
            name: 'answer',
          ),
        );
        engine.script = [_chunk('{"a":'), _chunk('1}'), stop];
        await session.addQueryChunk(user('q'));
        expect(await session.getResponse(), '{"a":1}');
        final sent = {
          'type': 'json_schema',
          'json_schema': {'schema': schema, 'name': 'answer', 'strict': true},
        };
        expect(engine.lastResponseFormat, sent);
        expect(engine.lastTemplateResponseFormat, sent);
        // The grammar emits properties in the caller's order.
        expect(
          jsonEncode(engine.lastResponseFormat!['json_schema']['schema']),
          jsonEncode(schema),
        );
        expect(engine.lastThinking, isFalse);

        final unnamed = await structured.openSession(responseFormat: object);
        engine.script = [_chunk('{}'), stop];
        await unnamed.addQueryChunk(user('q'));
        await unnamed.getResponse();
        expect(engine.lastResponseFormat, {
          'type': 'json_schema',
          'json_schema': {
            'schema': {'type': 'object'},
            'strict': true,
          },
        });

        final plain = await structured.openSession();
        engine.script = [_chunk('text'), stop];
        await plain.addQueryChunk(user('q'));
        await plain.getResponse();
        expect(engine.lastResponseFormat, isNull);
        expect(engine.lastTemplateResponseFormat, isNull);
      },
    );

    test(
      'a structured session sends thinking off whatever it was given',
      () async {
        final session = LlamaInferenceSession(
          engine: engine,
          contextSize: 2048,
          params: llama.GenerationParams(),
          onClose: () {},
          enableThinking: true,
          responseFormat: object as edge.JsonSchemaResponseFormat,
        );
        addTearDown(session.close);
        engine.script = [_chunk('{}'), stop];
        await session.addQueryChunk(user('q'));
        final turn = session.startTurn();
        expect(await turn.text.join(), '{}');
        expect(await turn.end, edge.TurnEnd.endOfSequence);
        expect(engine.lastThinking, isFalse);
      },
    );

    test('an integral double bound is sent to llamadart as an int', () async {
      final session = await structured.openSession(
        responseFormat: edge.ResponseFormat.jsonSchema({
          'type': 'array',
          'items': {'type': 'string', 'maxLength': 3.0},
          'minItems': 1.0,
        }),
      );
      engine.script = [_chunk('["ab"]'), stop];
      await session.addQueryChunk(user('q'));
      expect(await session.getResponse(), '["ab"]');
      final sent = engine.lastResponseFormat!['json_schema']['schema'] as Map;
      expect(sent['minItems'], isA<int>());
      expect((sent['items'] as Map)['maxLength'], isA<int>());
    });

    test('a non-conforming reply fails the guard and is recorded', () async {
      final session = await structured.openSession(
        responseFormat: edge.ResponseFormat.jsonSchema(schema),
      );
      engine.script = [_chunk('{"a":"x"}'), stop];
      await session.addQueryChunk(user('q'));
      await expectLater(
        session.getResponse(),
        throwsA(
          isA<edge.NonConformingStructuredOutputException>().having(
            (e) => e.text,
            'text',
            '{"a":"x"}',
          ),
        ),
      );
      expect(engineSession().messages.map((m) => m.text), ['q', '{"a":"x"}']);
    });

    // The prompt is 10 tokens of 2048, so 2038 remain: a cap up to that is
    // the budget that ran out, a larger one or none means the context did.
    for (final (cap, end) in [
      (8, edge.TurnEnd.outputLimit),
      (2038, edge.TurnEnd.outputLimit),
      (2039, edge.TurnEnd.contextLimit),
      (null, edge.TurnEnd.contextLimit),
    ]) {
      test('a length finish under cap $cap is incomplete with ${end.name}, '
          'and recorded', () async {
        final session = await structured.openSession(
          responseFormat: object,
          maxOutputTokens: cap,
        );
        engine.script = [_chunk('{"a":'), _chunk(null, finishReason: 'length')];
        await session.addQueryChunk(user('cut'));
        await expectLater(
          session.getResponse(),
          throwsA(
            isA<edge.IncompleteStructuredOutputException>()
                .having((e) => e.end, 'end', end)
                .having((e) => e.partialText, 'partialText', '{"a":'),
          ),
        );
        expect(
          engine.lastParams!.maxTokens,
          cap == null || cap > 2038 ? 2038 : cap,
        );
        expect(engineSession().messages.map((m) => m.text), ['cut', '{"a":']);
        engine.script = [_chunk('{}'), stop];
        await session.addQueryChunk(user('again'));
        expect(await session.getResponse(), '{}');
        expect(engine.requests.last.map((m) => m.content), [
          'cut',
          '{"a":',
          'again',
        ]);
      });
    }

    for (final structuredSession in [true, false]) {
      test('an input the context cannot hold is refused '
          '(${structuredSession ? 'structured' : 'plain'})', () async {
        // The contract every engine keeps: an error on the text, end
        // contextLimit, and nothing of the turn kept, so core's chat can
        // take the turn's messages back.
        final session = await structured.openSession(
          responseFormat: structuredSession ? object : null,
        );
        final llamaSession = engineSession();
        engine.promptTokens = 2048;
        await session.addQueryChunk(user('too long'));
        final turn = llamaSession.startTurn();
        await expectLater(
          turn.text.join(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('fills the 2048-token context'),
            ),
          ),
        );
        expect(await turn.end, edge.TurnEnd.contextLimit);
        expect(engine.requests, isEmpty);
        expect(llamaSession.messages, isEmpty);
        // Through core's own session the error reaches the caller as is.
        await session.addQueryChunk(user('too long again'));
        await expectLater(session.getResponse(), throwsA(isA<StateError>()));
        expect(llamaSession.messages, isEmpty);
        engine.promptTokens = 10;
        engine.script = [_chunk('{}'), stop];
        await session.addQueryChunk(user('short'));
        expect(await session.getResponse(), '{}');
        expect(engine.requests.single.map((m) => m.content), ['short']);
      });
    }

    for (final how in ['stop', 'cancel', 'close']) {
      test('a $how mid-reply is incomplete and keeps what streamed', () async {
        final session = await structured.openSession(responseFormat: object);
        engine
          ..blockGeneration = true
          ..firstText = '{"a":';
        await session.addQueryChunk(user('q'));
        final firstToken = Completer<void>();
        final failure = Completer<Object>();
        final subscription = session.getResponseAsync().listen((_) {
          if (!firstToken.isCompleted) firstToken.complete();
        }, onError: failure.complete);
        await firstToken.future;
        final llamaSession = engineSession();
        switch (how) {
          case 'stop':
            await session.stopGeneration();
          case 'cancel':
            await subscription.cancel();
          default:
            await session.close();
        }
        expect(engine.cancels, greaterThan(0));
        if (how != 'cancel') {
          expect(
            await failure.future,
            isA<edge.IncompleteStructuredOutputException>()
                .having(
                  (e) => e.end,
                  'end',
                  how == 'stop' ? edge.TurnEnd.stopped : edge.TurnEnd.closed,
                )
                .having((e) => e.partialText, 'partialText', '{"a":'),
          );
          await subscription.cancel();
        }
        expect(llamaSession.messages.map((m) => m.text), ['q', '{"a":']);
        if (how == 'close') return;
        engine.blockGeneration = false;
        engine.script = [_chunk('{}'), stop];
        await session.addQueryChunk(user('next'));
        expect(await session.getResponse(), '{}');
        expect(engine.requests.last.map((m) => m.content), [
          'q',
          '{"a":',
          'next',
        ]);
      });
    }

    test('a stop before the first token records nothing', () async {
      // A lone user turn would make the next request two user turns in a
      // row, which templates that require alternating roles refuse.
      final chat = await structured.openChat(responseFormat: object);
      engine
        ..blockGeneration = true
        ..firstText = '';
      await chat.addQuery(user('q'));
      final failure = Completer<Object>();
      chat.generateChatResponseAsync().listen(
        (_) {},
        onError: failure.complete,
      );
      while (engine.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await chat.session.stopGeneration();
      expect(
        await failure.future,
        isA<edge.IncompleteStructuredOutputException>()
            .having((e) => e.end, 'end', edge.TurnEnd.stopped)
            .having((e) => e.partialText, 'partialText', ''),
      );
      expect(chat.fullHistory, isEmpty);
      engine.blockGeneration = false;
      engine.script = [_chunk('{}'), stop];
      await chat.addQuery(user('next'));
      await chat.generateChatResponse();
      expect(engine.requests.last.map((m) => m.content), ['next']);
    });

    test('a cancelled structured turn ends stopped, after its text', () async {
      final session = LlamaInferenceSession(
        engine: engine,
        contextSize: 2048,
        params: llama.GenerationParams(),
        onClose: () {},
        responseFormat: object as edge.JsonSchemaResponseFormat,
      );
      addTearDown(session.close);
      engine
        ..blockGeneration = true
        ..firstText = '{"a":';
      await session.addQueryChunk(user('q'));
      final turn = session.startTurn();
      final firstToken = Completer<void>();
      final subscription = turn.text.listen((_) {
        if (!firstToken.isCompleted) firstToken.complete();
      });
      await firstToken.future;
      await subscription.cancel();
      expect(await turn.end, edge.TurnEnd.stopped);
      expect(session.messages.map((m) => m.text), ['q', '{"a":']);
    });

    test('plain turns report their ends too', () async {
      final session = await structured.openSession(maxOutputTokens: 8);
      engine.script = [_chunk('done'), stop];
      await session.addQueryChunk(user('q'));
      var turn = engineSession().startTurn();
      expect(await turn.text.join(), 'done');
      expect(await turn.end, edge.TurnEnd.endOfSequence);
      engine.script = [_chunk('cut'), _chunk(null, finishReason: 'length')];
      await session.addQueryChunk(user('q'));
      turn = engineSession().startTurn();
      expect(await turn.text.join(), 'cut');
      expect(await turn.end, edge.TurnEnd.outputLimit);
      engine.promptTokens = 2048;
      await session.addQueryChunk(user('q'));
      turn = engineSession().startTurn();
      await expectLater(turn.text.join(), throwsA(isA<StateError>()));
      expect(await turn.end, edge.TurnEnd.contextLimit);
      // Any other error ends the turn closed.
      engine
        ..promptTokens = 10
        ..templateError = llama.LlamaInferenceException('template failed');
      await session.addQueryChunk(user('q'));
      turn = engineSession().startTurn();
      await expectLater(turn.text.join(), throwsA(isA<StateError>()));
      expect(await turn.end, edge.TurnEnd.closed);
      engine.templateError = null;
    });

    test('a structured chat reads its history from the session', () async {
      final chat = await structured.openChat(responseFormat: object);
      engine.script = [_chunk('{"a":1}'), stop];
      await chat.addQuery(user('one'));
      final reply = await chat.generateChatResponse() as edge.TextResponse;
      expect(reply.token, '{"a":1}');
      engine.script = [_chunk('nope'), stop];
      await chat.addQuery(user('two'));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(isA<edge.NonConformingStructuredOutputException>()),
      );
      expect(chat.fullHistory.map((m) => m.text), [
        'one',
        '{"a":1}',
        'two',
        'nope',
      ]);
    });

    for (final (buffer, request) in [
      (300, ['two']),
      (1, ['one', '{}', 'two']),
    ]) {
      test(
        'input staged on chat.session gets the chat buffer ($buffer)',
        () async {
          // 3 messages of 600 tokens leave 248 of 2048: a buffer of 300 drops
          // the first turn, a buffer of 1 does not.
          final chat = await structured.openChat(
            responseFormat: object,
            tokenBuffer: buffer,
          );
          engine.promptCounter = (messages) => messages.length * 600;
          engine.script = [_chunk('{}'), stop];
          await chat.session.addQueryChunk(user('one'));
          await chat.generateChatResponse();
          engine.script = [_chunk('{}'), stop];
          await chat.session.addQueryChunk(user('two'));
          await chat.generateChatResponse();
          expect(engine.requests.last.map((m) => m.content), request);
        },
      );
    }

    test('a long structured chat at full context keeps its session', () async {
      // Each message is 450 tokens and each reply reports prompt + 450: the
      // kept four messages (1800) reach the rebuild threshold 2048 - 256, so
      // the session drops the oldest turn after each reply instead of core
      // rebuilding it.
      final chat = await structured.openChat(
        responseFormat: object,
        tokenBuffer: 256,
      );
      engine.promptCounter = (messages) => messages.length * 450;
      final session = chat.session;
      for (var turn = 1; turn <= 6; turn++) {
        engine.script = [
          _chunk('{"t":$turn}'),
          _chunk(
            null,
            finishReason: 'stop',
            usage: llama.LlamaGenerationUsage(
              promptTokens: (turn == 1 ? 1 : 3) * 450,
              completionTokens: 450,
            ),
          ),
        ];
        await chat.addQuery(user('u$turn'));
        final reply = await chat.generateChatResponse() as edge.TextResponse;
        expect(reply.token, '{"t":$turn}');
        expect(chat.session, same(session), reason: 'turn $turn');
        if (turn > 1) {
          expect(engine.requests.last.map((m) => m.content), [
            'u${turn - 1}',
            '{"t":${turn - 1}}',
            'u$turn',
          ]);
        }
      }
      expect(engineSession().retainedTokens, 900);
      expect(chat.currentTokens, 900);
    });

    test('a reply too long to trim rebuilds the session', () async {
      // One turn of 2000 tokens cannot be trimmed under 1792: core rebuilds
      // the session from its history.
      final chat = await structured.openChat(
        responseFormat: object,
        tokenBuffer: 256,
      );
      engine.promptCounter = (messages) => messages.length * 1000;
      engine.script = [_chunk('{"a":1}'), stop];
      await chat.addQuery(user('one'));
      final before = chat.session;
      await chat.generateChatResponse();
      expect(chat.session, isNot(same(before)));
      expect(chat.responseFormat, object);
      expect(chat.fullHistory.map((m) => m.text), ['one', '{"a":1}']);
      engine.script = [_chunk('{}'), stop];
      await chat.addQuery(user('two'));
      await chat.generateChatResponse();
      expect(engine.lastResponseFormat, isNotNull);
      // The replayed turn is dropped again to keep the buffer free.
      expect(engine.requests.last.map((m) => m.content), ['two']);
    });

    test('a failed rebuild is the turn error, after its reply', () async {
      final refusing = _RefusingRebuildModel(engine);
      addTearDown(refusing.close);
      final chat = await refusing.openChat(
        responseFormat: object,
        tokenBuffer: 256,
      );
      engine.promptCounter = (messages) => messages.length * 1000;
      engine.script = [_chunk('{"a":1}'), stop];
      await chat.addQuery(user('one'));
      await expectLater(
        chat.generateChatResponse(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'rebuild refused',
          ),
        ),
      );
      expect(chat.fullHistory.map((m) => m.text), ['one', '{"a":1}']);
    });

    for (final how in ['stop', 'close']) {
      test('a cancel error after a $how cuts the turn', () async {
        final session = await structured.openSession(responseFormat: object);
        engine
          ..blockGeneration = true
          ..firstText = '{"a":'
          ..cancelError = llama.LlamaInferenceException('generation cancelled');
        await session.addQueryChunk(user('q'));
        final firstToken = Completer<void>();
        final failure = Completer<Object>();
        final subscription = session.getResponseAsync().listen((_) {
          if (!firstToken.isCompleted) firstToken.complete();
        }, onError: failure.complete);
        await firstToken.future;
        final llamaSession = engineSession();
        if (how == 'stop') {
          await session.stopGeneration();
        } else {
          await session.close();
        }
        expect(
          await failure.future,
          isA<edge.IncompleteStructuredOutputException>()
              .having(
                (e) => e.end,
                'end',
                how == 'stop' ? edge.TurnEnd.stopped : edge.TurnEnd.closed,
              )
              .having((e) => e.partialText, 'partialText', '{"a":'),
        );
        await subscription.cancel();
        expect(llamaSession.messages.map((m) => m.text), ['q', '{"a":']);
      });
    }

    test('a cancel error after a stop is printed once per session', () async {
      final logs = <String>[];
      await runZoned(
        () async {
          final session = await structured.openSession(responseFormat: object);
          engine
            ..blockGeneration = true
            ..firstText = '{"a":'
            ..cancelError = llama.LlamaInferenceException('bridge cancelled');
          for (final turn in ['one', 'two']) {
            await session.addQueryChunk(user(turn));
            final firstToken = Completer<void>();
            final failure = Completer<Object>();
            final subscription = session.getResponseAsync().listen((_) {
              if (!firstToken.isCompleted) firstToken.complete();
            }, onError: failure.complete);
            await firstToken.future;
            await session.stopGeneration();
            expect(
              await failure.future,
              isA<edge.IncompleteStructuredOutputException>(),
            );
            await subscription.cancel();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, String line) => logs.add(line),
        ),
      );
      // Printed once; the second time only reaches edgeAiLog.
      final warnings = logs.where(
        (line) => line.startsWith('[flutter_edge_ai] WARNING:'),
      );
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('bridge cancelled'));
    });

    test(
      'a failed adapter restore after a stop is printed, nothing recorded',
      () async {
        final logs = <String>[];
        late LlamaInferenceSession llamaSession;
        await runZoned(
          () async {
            final session = await structured.openSession(
              responseFormat: object,
              loraPath: adapterPath,
            );
            llamaSession = engineSession();
            engine
              ..blockGeneration = true
              ..firstText = '{"a":'
              // The restore after the stop fails; its retry succeeds, so
              // the runtime stays usable and the stop keeps the turn.
              ..failLoraCleanupCount = 1;
            await session.addQueryChunk(user('q'));
            final firstToken = Completer<void>();
            final failure = Completer<Object>();
            final subscription = session.getResponseAsync().listen((_) {
              if (!firstToken.isCompleted) firstToken.complete();
            }, onError: failure.complete);
            await firstToken.future;
            await session.stopGeneration();
            expect(
              await failure.future,
              isA<edge.IncompleteStructuredOutputException>().having(
                (e) => e.end,
                'end',
                edge.TurnEnd.stopped,
              ),
            );
            await subscription.cancel();
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, String line) => logs.add(line),
          ),
        );
        expect(structured.isClosed, isFalse);
        expect(llamaSession.messages, isEmpty);
        expect(
          logs.where(
            (line) =>
                line.startsWith('[flutter_edge_ai] WARNING:') &&
                line.contains('failed after its stop'),
          ),
          hasLength(1),
        );
      },
      skip: kIsWeb,
    );

    test('llama.cpp poisoning after a stop is still an error', () async {
      final session = await structured.openSession(responseFormat: object);
      engine
        ..blockGeneration = true
        ..firstText = '{"a":'
        ..cancelError = llama.LlamaInferenceException(
          'llama.cpp raised an exception: abort',
        );
      await session.addQueryChunk(user('q'));
      final firstToken = Completer<void>();
      final failure = Completer<Object>();
      final subscription = session.getResponseAsync().listen((_) {
        if (!firstToken.isCompleted) firstToken.complete();
      }, onError: failure.complete);
      await firstToken.future;
      await session.stopGeneration();
      expect(
        await failure.future,
        isNot(isA<edge.StructuredOutputException>()),
      );
      await subscription.cancel();
    });

    test(
      'schemas llamadart cannot enforce are refused at their path',
      () async {
        for (final (refused, path) in <(Map<String, Object?>, String)>[
          (
            {
              'type': 'object',
              'properties': {
                'score': {'type': 'number', 'minimum': 0, 'maximum': 1},
              },
            },
            '/properties/score/minimum',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'c': {
                  'type': 'string',
                  'enum': ['x'],
                  'minLength': 1,
                },
              },
            },
            '/properties/c/minLength',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'n': {'type': 'integer', 'minimum': 105},
              },
            },
            '/properties/n/minimum',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'a.b': {'type': 'string', 'maxLength': 2001},
              },
            },
            '/properties/a.b/maxLength',
          ),
          (
            {
              'type': 'array',
              'items': {'type': 'integer', 'maximum': -105},
            },
            '/items/maximum',
          ),
          ({'type': 'integer', 'minimum': 105}, '/minimum'),
          (
            {
              'type': 'object',
              'properties': {
                't': {'minLength': 1},
              },
            },
            '/properties/t/minLength',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'a': {
                  'type': 'object',
                  'properties': {
                    'b': {'type': 'number', 'minimum': 0},
                  },
                },
                'a.properties.b': {'type': 'string'},
              },
            },
            '/properties/a/properties/b/minimum',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'my key': {'type': 'number', 'minimum': 0},
              },
            },
            '/properties/my key/minimum',
          ),
          (
            {
              'type': 'object',
              'properties': {
                'a/b': {
                  'type': 'integer',
                  'enum': ['x'],
                },
              },
            },
            '/properties/a~1b/enum',
          ),
        ]) {
          final format = edge.ResponseFormat.jsonSchema(refused);
          final refusal = structured.refusalFor(format);
          expect(refusal?.schemaPath, path, reason: '$refused');
          expect(refusal!.message, contains("llama.cpp's grammar"));
          await expectLater(
            structured.openSession(responseFormat: format),
            throwsA(isA<edge.ResponseFormatUnsupportedException>()),
          );
        }
        expect(engine.requests, isEmpty);
      },
    );

    test('the dialect llamadart enforces is accepted', () {
      for (final accepted in <Map<String, Object?>>[
        {
          'type': 'object',
          'title': 'all keywords',
          'description': 'd',
          'examples': [
            {'s': 'x'},
          ],
          'properties': {
            's': {'type': 'string', 'minLength': 1, 'maxLength': 2000},
            'i': {'type': 'integer', 'minimum': -1000000, 'maximum': 1000000},
            'low': {'type': 'integer', 'minimum': 0},
            'n': {'type': 'number'},
            'b': {'type': 'boolean'},
            'z': {'type': 'null'},
            'e': {
              'type': 'string',
              'enum': ['x', 'y'],
            },
            'mixed': {
              'enum': [
                1,
                'a',
                null,
                {'k': true},
              ],
            },
            'c': {
              'const': {
                'k': [1, 2],
              },
            },
            'list': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'x': {'type': 'string'},
                },
                'additionalProperties': false,
              },
              'minItems': 1,
              'maxItems': 2000,
            },
            'any': {'description': 'anything'},
          },
          'required': ['s', 'i'],
          'additionalProperties': false,
        },
        {'type': 'object', 'additionalProperties': false},
        {'type': 'array', 'minItems': 3},
        {'type': 'string', 'maxLength': 0},
      ]) {
        expect(
          structured.refusalFor(edge.ResponseFormat.jsonSchema(accepted)),
          isNull,
          reason: '$accepted',
        );
      }
    });

    test('the provider reads grammar support and the host at load', () async {
      Future<edge.InferenceModel> load() async {
        final provider = createLlamaProviderForTest(
          loader: (_, _) async => engine,
        );
        return provider.createModel(
          _spec('model.gguf'),
          const RuntimeConfig(
            modelPath: '/models/model.gguf',
            maxTokens: 2048,
            preferredBackend: edge.PreferredBackend.cpu,
          ),
        );
      }

      var loaded = await load();
      expect(loaded.structuredOutputSupport.reason, contains('grammar'));
      await loaded.close();

      engine
        ..structuredSupport = true
        ..grammarSupport = true
        ..capabilityError = StateError('probe failed');
      loaded = await load();
      expect(loaded.structuredOutputSupport.reason, contains('probe failed'));
      await loaded.close();

      // Each half of the capability check refuses on its own.
      for (final (structuredOutput, grammar) in [
        (true, false),
        (false, true),
      ]) {
        engine
          ..capabilityError = null
          ..structuredSupport = structuredOutput
          ..grammarSupport = grammar;
        loaded = await load();
        expect(
          loaded.structuredOutputSupport.reason,
          contains('grammar'),
          reason: 'structured output $structuredOutput, grammar $grammar',
        );
        await loaded.close();
      }

      // The table, written out: a CPU model is enabled on macOS arm64 only
      // (the Web enables WebGPU, never CPU).
      engine
        ..structuredSupport = true
        ..grammarSupport = true;
      loaded = await load();
      final support = loaded.structuredOutputSupport;
      if (!kIsWeb && hostAbi() == 'macos_arm64') {
        expect(support.isSupported, isTrue, reason: '$support');
        expect(support.keywords, edge.ResponseFormat.dialect);
      } else {
        expect(support.isSupported, isFalse);
        expect(support.reason, contains('have not been run'));
      }
      await loaded.close();
    });
  });

  for (final format in [
    llama.ChatFormat.hermes,
    llama.ChatFormat.deepseekV3,
    llama.ChatFormat.qwen3CoderXml,
  ]) {
    test(
      'closed ${format.name} thought is hidden before a structured reply',
      () async {
        // The guard checks the filtered text: with the thought left in, the
        // reply is not JSON and fails it.
        final structured = LlamaInferenceModel(
          engine: engine,
          maxTokens: 2048,
          activeBackend: edge.PreferredBackend.cpu,
          structuredOutput: const edge.StructuredOutputSupport(
            keywords: edge.ResponseFormat.dialect,
          ),
        );
        addTearDown(structured.close);
        engine.templateFormat = format.index;
        engine.templatePrompt = 'assistant\n<think>\n\n</think>\n';
        const raw =
            ' \n<think>reason</think>\t<think>more</think>{"a":"<think>x</think>"}';
        const visible = '{"a":"<think>x</think>"}';
        final responseFormat = edge.ResponseFormat.jsonSchema({
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
          },
          'required': ['a'],
        });
        for (final tokens in [
          [raw],
          raw.split(''),
          for (var split = 1; split < raw.length; split++)
            [raw.substring(0, split), raw.substring(split)],
        ]) {
          engine.script = [
            ...tokens.map(_chunk),
            _chunk(null, finishReason: 'stop'),
          ];
          final session = await structured.openSession(
            responseFormat: responseFormat,
          );
          await session.addQueryChunk(
            edge.Message.text(text: 'first', isUser: true),
          );
          expect(await session.getResponse(), visible, reason: '$tokens');
          expect(engine.lastThinking, isFalse);
          // ignore: invalid_use_of_protected_member
          final llamaSession = structured.engineSessions
              .whereType<LlamaInferenceSession>()
              .last;
          expect(llamaSession.hiddenThinkingCharacters, 10);
          expect(llamaSession.messages.last.text, visible);
          await session.close();
        }
      },
    );
  }
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
  int Function(List<llama.LlamaChatMessage>)? promptCounter;
  int? gpuLayers = 0;
  String? backendName;
  @override
  Future<String> getBackendName() async =>
      backendName ??
      (gpuLayers == null
          ? 'unknown'
          : gpuLayers! > 0
          ? 'Vulkan'
          : 'CPU');
  @override
  Future<bool> isGpuSupported() async => gpuLayers != null && gpuLayers! > 0;
  int cancels = 0;
  int disposals = 0;
  Completer<void>? disposeGate;
  final Completer<void> disposeStarted = Completer<void>();
  bool blockGeneration = false;
  bool failAfterFirstToken = false;
  Object? generationError;
  Object? tokenError;
  Object? capabilityError;
  Object? templateError;
  int contextSize = 2048;
  int templateFormat = 0;
  String templatePrompt = 'rendered';
  bool templateThinkingForcedOpen = false;
  String firstText = 'Hello';
  Object? disposalError;
  List<llama.LlamaCompletionChunk>? script;
  List<List<llama.LlamaCompletionChunk>> scripts = [];
  bool failLoraCleanup = false;
  int failLoraCleanupCount = 0;
  String? failLoraSetPath;
  bool toolSupport = true;
  bool visionSupport = true;
  Object? cancelError;
  bool structuredSupport = false;
  bool grammarSupport = false;
  Map<String, dynamic>? lastResponseFormat;
  Map<String, dynamic>? lastTemplateResponseFormat;
  String? projector;
  String? activeAdapter;
  final List<String?> adaptersAtGeneration = [];
  final List<String> loraEvents = [];
  List<llama.ToolDefinition> lastTools = [];
  List<llama.ToolDefinition> lastTemplateTools = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<llama.LlamaEngineCapabilities> get capabilities async {
    if (capabilityError != null) throw capabilityError!;
    return llama.LlamaEngineCapabilities(
      isSupported: true,
      supportsToolCalling: toolSupport,
      supportsVision: visionSupport,
      supportsAudio: true,
      supportsStructuredOutput: structuredSupport,
      supportsGrammar: grammarSupport,
    );
  }

  @override
  Future<void> loadMultimodalProjectorSource(
    llama.ModelSource source, {
    llama.ModelLoadOptions? download,
    llama.ModelLoadOptions? options,
    llama.ModelDownloadProgressCallback? onProgress,
  }) async {
    projector = source.path ?? source.url?.toString();
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
    if (source.path == failLoraSetPath) {
      throw llama.LlamaInferenceException('wrong-base adapter');
    }
  }

  @override
  Future<void> removeLoraSource(llama.ModelSource source) async {
    if (failLoraCleanup || failLoraCleanupCount-- > 0) {
      throw llama.LlamaInferenceException('cleanup failed');
    }
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
  Future<int> getContextSize() async => contextSize;

  @override
  Future<int> getTokenCount(String text) async {
    if (tokenError != null) throw tokenError!;
    return text.length;
  }

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
    if (templateError != null) throw templateError!;
    lastTemplateTools = tools ?? [];
    lastTemplateResponseFormat = responseFormat;
    return llama.LlamaChatTemplateResult(
      prompt: templatePrompt,
      format: templateFormat,
      thinkingForcedOpen: templateThinkingForcedOpen,
      tokenCount: promptCounter?.call(messages) ?? promptTokens,
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
      lastResponseFormat = responseFormat;
      final custom = scripts.isNotEmpty ? scripts.removeAt(0) : script;
      if (custom != null) {
        yield* Stream.fromIterable(custom);
        return;
      }
      if (blockGeneration) _release = Completer<void>();
      yield _chunk(firstText);
      if (generationError != null) throw generationError!;
      if (failAfterFirstToken) {
        throw llama.LlamaInferenceException('test failure');
      }
      if (blockGeneration) {
        await _release!.future;
        if (cancelError != null) throw cancelError!;
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
    if (disposalError != null) throw disposalError!;
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

/// Opens the chat's first session, then refuses every later one: core's
/// rebuild after a full context fails.
class _RefusingRebuildModel extends LlamaInferenceModel {
  _RefusingRebuildModel(llama.LlamaEngine engine)
    : super(
        engine: engine,
        maxTokens: 2048,
        activeBackend: edge.PreferredBackend.cpu,
        structuredOutput: const edge.StructuredOutputSupport(
          keywords: edge.ResponseFormat.dialect,
        ),
      );

  int _opens = 0;

  @override
  Future<LlamaInferenceSession> openEngineSession(SessionRequest request) {
    if (++_opens > 1) return Future.error(StateError('rebuild refused'));
    return super.openEngineSession(request);
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
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

  test('registry claims only binary GGUF specs', () {
    const provider = LlamaEngineProvider();
    EngineRegistry.instance.registerAll([provider]);
    expect(
      EngineRegistry.instance.findFor(_spec('model.gguf')),
      same(provider),
    );
    expect(
      EngineRegistry.instance.findFor(_spec('model.GGUF')),
      same(provider),
    );
    for (final filename in ['model.bin', 'model.task', 'model.litertlm']) {
      expect(EngineRegistry.instance.findFor(_spec(filename)), isNull);
    }
    expect(
      EngineRegistry.instance.findFor(
        _spec('model.gguf', edge.ModelFileType.task),
      ),
      isNull,
    );
  });

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
      final embeddingEngine = _FakeEngine();
      final embedder = LlamaEmbeddingProvider(
        loader: (_, _) async => embeddingEngine,
      );
      await expectLater(
        embedder.createModel(
          edge.EmbeddingModelSpec(
            name: 'embed',
            modelSource: _source('/models/embed.gguf'),
            tokenizerSource: _source('/models/tokenizer.json'),
          ),
          const RuntimeConfig(
            modelPath: 'embed.gguf',
            maxTokens: 0,
            preferredBackend: edge.PreferredBackend.gpu,
          ),
        ),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
      expect(embeddingEngine.disposals, 1);
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
      throwsA(isA<llama.LlamaArgumentException>()),
    );
    expect(
      () => model.createSession(topP: 0),
      throwsA(isA<llama.LlamaArgumentException>()),
    );
  });

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

  test(
    'concurrent dimension requests perform exactly one embedding probe',
    () async {
      final embedder = LlamaEmbeddingModel(
        engine: engine,
        activeBackend: edge.PreferredBackend.cpu,
      );
      expect(
        await Future.wait(List.generate(20, (_) => embedder.getDimension())),
        everyElement(3),
      );
      expect(engine.embeddingInputs, hasLength(1));
      await embedder.close();
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

  test('GGUF embeddings preserve task prefixes, batch order, dimension and lifecycle', () async {
    final provider = LlamaEmbeddingProvider(
      loader: (_, params) async {
        expect(params.device, llama.ComputeDevice.cpu);
        return engine;
      },
    );
    final spec = edge.EmbeddingModelSpec(
      name: 'embed',
      modelSource: _source('/models/embed.gguf'),
      tokenizerSource: _source('/models/tokenizer.json'),
    );
    expect(provider.canHandle(spec), isTrue);
    final embedder = await provider.createModel(
      spec,
      const RuntimeConfig(
        modelPath: 'embed.gguf',
        maxTokens: 0,
        preferredBackend: edge.PreferredBackend.cpu,
      ),
    );
    final vector = await embedder.generateEmbedding('question');
    expect(vector, [1.0, 2.0, 3.0]);
    expect(
      engine.embeddingInputs.last,
      '${edge.TaskType.retrievalQuery.prefix}question',
    );
    expect(await embedder.getDimension(), 3);
    expect(
      await embedder.generateEmbeddings([
        'a',
        'b',
      ], taskType: edge.TaskType.retrievalDocument),
      [
        [1.0, 2.0, 3.0],
        [1.0, 2.0, 3.0],
      ],
    );
    expect(
      engine.embeddingInputs.last,
      '${edge.TaskType.retrievalDocument.prefix}b',
    );
    var closes = 0;
    embedder.addCloseListener(() => closes++);
    await embedder.close();
    await embedder.close();
    expect(closes, 1);
    expect(embedder.isClosed, isTrue);
    await expectLater(
      embedder.getDimension(),
      throwsA(isA<llama.LlamaStateException>()),
    );
  });

  test(
    'queued embedding batches own a snapshot of their caller input',
    () async {
      final embedder = LlamaEmbeddingModel(
        engine: engine,
        activeBackend: edge.PreferredBackend.cpu,
        useTaskPrefixes: false,
      );
      final inputs = ['original'];
      final request = embedder.generateEmbeddings(inputs);
      inputs[0] = 'mutated';
      inputs.add('extra');
      expect(await request, hasLength(1));
      expect(engine.embeddingInputs, ['original']);
      await embedder.close();
    },
  );

  test(
    'embedding corruption and unsupported runtimes fail explicitly',
    () async {
      final embedder = LlamaEmbeddingModel(
        engine: engine,
        activeBackend: edge.PreferredBackend.cpu,
        useTaskPrefixes: false,
      );
      engine.embeddingVector = [0, 0];
      await expectLater(
        embedder.generateEmbedding('raw'),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      expect(engine.embeddingInputs.single, 'raw');
      engine.embeddingVector = [double.nan];
      await expectLater(
        embedder.generateEmbedding('raw'),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      engine.embeddingVector = [1, 2];
      await embedder.generateEmbedding('raw');
      engine.embeddingVector = [1, 2, 3];
      await expectLater(
        embedder.generateEmbedding('raw'),
        throwsA(isA<llama.LlamaInferenceException>()),
      );
      await embedder.close();
      engine.embeddingSupport = false;
      final provider = LlamaEmbeddingProvider(loader: (_, _) async => engine);
      final spec = edge.EmbeddingModelSpec(
        name: 'embed',
        modelSource: _source('/models/embed.gguf'),
        tokenizerSource: _source('/models/tokenizer.json'),
      );
      await expectLater(
        provider.createModel(
          spec,
          const RuntimeConfig(modelPath: 'embed.gguf', maxTokens: 0),
        ),
        throwsA(isA<llama.LlamaUnsupportedException>()),
      );
    },
  );
}

edge.InferenceModelSpec _spec(
  String filename, [
  edge.ModelFileType fileType = edge.ModelFileType.binary,
]) => edge.InferenceModelSpec(
  name: filename,
  modelSource: _source('/models/$filename'),
  modelType: edge.ModelType.general,
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
  bool blockGeneration = false;
  bool failAfterFirstToken = false;
  List<llama.LlamaCompletionChunk>? script;
  List<List<llama.LlamaCompletionChunk>> scripts = [];
  bool failLoraCleanup = false;
  bool toolSupport = true;
  bool visionSupport = true;
  bool embeddingSupport = true;
  String? projector;
  String? activeAdapter;
  final List<String?> adaptersAtGeneration = [];
  final List<String> loraEvents = [];
  final List<String> embeddingInputs = [];
  List<double> embeddingVector = [1, 2, 3];
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
        supportsEmbeddings: embeddingSupport,
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

  @override
  Future<List<double>> embed(String text, {bool normalize = true}) async {
    embeddingInputs.add(text);
    return embeddingVector;
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> texts, {
    bool normalize = true,
  }) async {
    embeddingInputs.addAll(texts);
    return [for (final _ in texts) embeddingVector];
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

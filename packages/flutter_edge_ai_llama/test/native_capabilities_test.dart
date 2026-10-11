import 'dart:io';

import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

const _toolModel = String.fromEnvironment('GGUF_TOOL_MODEL_PATH');
const _embeddingModel = String.fromEnvironment('GGUF_EMBEDDING_MODEL_PATH');
const _audioModel = String.fromEnvironment('GGUF_AUDIO_MODEL_PATH');
const _audioProjector = String.fromEnvironment('GGUF_AUDIO_PROJECTOR_PATH');
const _audioFile = String.fromEnvironment('GGUF_AUDIO_FILE_PATH');
const _loraModel = String.fromEnvironment('GGUF_LORA_MODEL_PATH');
const _loraAdapter = String.fromEnvironment('GGUF_LORA_ADAPTER_PATH');
const _visionModel = String.fromEnvironment('GGUF_VISION_MODEL_PATH');
const _visionProjector = String.fromEnvironment('GGUF_VISION_PROJECTOR_PATH');
const _visionFile = String.fromEnvironment('GGUF_VISION_FILE_PATH');
const _gpuModel = String.fromEnvironment('GGUF_GPU_MODEL_PATH');

edge.InferenceModelSpec _spec(String path) => edge.InferenceModelSpec(
  name: 'native',
  modelSource: edge.ModelSource.file(path),
  modelType: edge.ModelType.general,
  fileType: edge.ModelFileType.binary,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    llama.LlamaLogging.configure(level: llama.LlamaLogLevel.error);
    edge.FlutterEdgeAi.logLevel = edge.EdgeAiLogLevel.none;
  });

  test(
    'native typed thinking and required tools with a Qwen GGUF',
    () async {
      final model = await const LlamaEngineProvider().createModel(
        _spec(_toolModel),
        RuntimeConfig(
          modelPath: _toolModel,
          maxTokens: 4096,
          preferredBackend: edge.PreferredBackend.cpu,
        ),
      );
      addTearDown(model.close);
      final thinking = await model.openChat(
        enableThinking: true,
        temperature: 0,
        maxOutputTokens: 256,
      );
      await thinking.addQuery(
        edge.Message.text(text: 'What is 2 + 3?', isUser: true),
      );
      final response = await thinking.generateChatResponseAsync().toList();
      expect(response.whereType<edge.ThinkingResponse>(), isNotEmpty);
      const tool = edge.Tool(
        name: 'get_weather',
        description: 'Get current weather for a city',
        parameters: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string'},
          },
          'required': ['city'],
          'additionalProperties': false,
        },
      );
      final chat = await model.openChat(
        tools: [tool],
        toolChoice: edge.ToolChoice.required,
        temperature: 0,
        maxOutputTokens: 128,
      );
      await chat.addQuery(
        edge.Message.text(text: 'Use get_weather for Montreal.', isUser: true),
      );
      final call =
          await chat.generateChatResponse() as LlamaFunctionCallResponse;
      expect(call.name, 'get_weather');
      expect(call.args['city'], isA<String>());
      await chat.addQuery(
        LlamaToolResponseMessage(
          callId: call.id,
          toolName: call.name,
          response: {'temperature': 18},
        ),
      );
      // A second independent chat must remain usable after tool generation.
      await thinking.addQuery(
        edge.Message.text(text: 'Say hello.', isUser: true),
      );
      expect(await thinking.generateChatResponseAsync().toList(), isNotEmpty);
    },
    skip: _toolModel.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'native GGUF embedder produces normalized 384-dimensional vectors',
    () async {
      final spec = edge.EmbeddingModelSpec(
        name: 'bge-small',
        modelSource: edge.ModelSource.file(_embeddingModel),
        tokenizerSource: edge.ModelSource.file('/unused/tokenizer.json'),
      );
      final embedder =
          await const LlamaEmbeddingProvider(
            useTaskPrefixes: false,
            contextSize: 512,
          ).createModel(
            spec,
            RuntimeConfig(
              modelPath: _embeddingModel,
              maxTokens: 0,
              preferredBackend: edge.PreferredBackend.cpu,
            ),
          );
      addTearDown(embedder.close);
      final vectors = await embedder.generateEmbeddings([
        'The cat sleeps on the sofa.',
        'A cat is resting on a couch.',
        'The rocket orbits Mars.',
      ]);
      expect(await embedder.getDimension(), 384);
      expect(vectors, hasLength(3));
      for (final vector in vectors) {
        expect(vector, hasLength(384));
        expect(vector.every((x) => x.isFinite), isTrue);
        expect(
          vector.fold<double>(0, (sum, x) => sum + x * x),
          closeTo(1, .001),
        );
      }
      double dot(List<double> a, List<double> b) =>
          List.generate(a.length, (i) => a[i] * b[i]).fold(0, (a, b) => a + b);
      expect(
        dot(vectors[0], vectors[1]),
        greaterThan(dot(vectors[0], vectors[2])),
      );
    },
    skip: _embeddingModel.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native audio projector accepts encoded WAV message bytes',
    () async {
      final provider = LlamaEngineProvider(
        projectorResolver: (_, _) async =>
            llama.ModelSource.path(_audioProjector),
      );
      final model = await provider.createModel(
        _spec(_audioModel),
        RuntimeConfig(
          modelPath: _audioModel,
          maxTokens: 4096,
          preferredBackend: edge.PreferredBackend.cpu,
          supportAudio: true,
        ),
      );
      addTearDown(model.close);
      final chat = await model.createChat(
        supportAudio: true,
        temperature: 0,
        maxOutputTokens: 128,
      );
      await chat.addQuery(
        edge.Message.audioOnly(
          audioBytes: await File(_audioFile).readAsBytes(),
          isUser: true,
        ),
      );
      final response = await chat.generateChatResponse() as edge.TextResponse;
      expect(response.token.trim(), isNotEmpty);
    },
    skip: _audioModel.isEmpty || _audioProjector.isEmpty || _audioFile.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'native vision projector accepts encoded PNG message bytes',
    () async {
      final provider = LlamaEngineProvider(
        projectorResolver: (_, _) async =>
            llama.ModelSource.path(_visionProjector),
      );
      final model = await provider.createModel(
        _spec(_visionModel),
        RuntimeConfig(
          modelPath: _visionModel,
          maxTokens: 4096,
          preferredBackend: edge.PreferredBackend.gpu,
          supportImage: true,
        ),
      );
      addTearDown(model.close);
      final chat = await model.createChat(
        supportImage: true,
        temperature: 0,
        maxOutputTokens: 128,
      );
      await chat.addQuery(
        edge.Message.withImage(
          text: 'Text Recognition:',
          imageBytes: await File(_visionFile).readAsBytes(),
          isUser: true,
        ),
      );
      final response = await chat.generateChatResponse() as edge.TextResponse;
      expect(response.token.trim(), isNotEmpty);
    },
    skip:
        _visionModel.isEmpty || _visionProjector.isEmpty || _visionFile.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'native LoRA session and base peer can alternate without reload',
    () async {
      final model = await const LlamaEngineProvider().createModel(
        _spec(_loraModel),
        RuntimeConfig(
          modelPath: _loraModel,
          maxTokens: 2048,
          preferredBackend: edge.PreferredBackend.cpu,
        ),
      );
      addTearDown(model.close);
      final adapted = await model.openSession(
        loraPath: _loraAdapter,
        maxOutputTokens: 16,
      );
      final base = await model.openSession(maxOutputTokens: 16);
      for (final session in [adapted, base, adapted]) {
        await session.addQueryChunk(
          edge.Message.text(text: 'Once upon a time', isUser: true),
        );
        expect(await session.getResponse(), isNotEmpty);
      }
    },
    skip: _loraModel.isEmpty || _loraAdapter.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'explicit GPU loads and reports GPU without CPU fallback',
    () async {
      final model = await const LlamaEngineProvider().createModel(
        _spec(_gpuModel),
        RuntimeConfig(
          modelPath: _gpuModel,
          maxTokens: 2048,
          preferredBackend: edge.PreferredBackend.gpu,
        ),
      );
      addTearDown(model.close);
      expect(model.activeBackend, edge.PreferredBackend.gpu);
      final chat = await model.createChat(temperature: 0, maxOutputTokens: 16);
      await chat.addQuery(edge.Message.text(text: 'Hello', isUser: true));
      expect(
        (await chat.generateChatResponse() as edge.TextResponse).token,
        isNotEmpty,
      );
    },
    skip: _gpuModel.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

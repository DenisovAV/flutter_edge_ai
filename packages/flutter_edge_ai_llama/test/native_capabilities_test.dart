import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' as edge;
import 'package:flutter_edge_ai_llama/flutter_edge_ai_llama.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' as llama;

const _toolModel = String.fromEnvironment('GGUF_TOOL_MODEL_PATH');
const _audioModel = String.fromEnvironment('GGUF_AUDIO_MODEL_PATH');
const _audioProjector = String.fromEnvironment('GGUF_AUDIO_PROJECTOR_PATH');
const _audioFile = String.fromEnvironment('GGUF_AUDIO_FILE_PATH');
const _loraModel = String.fromEnvironment('GGUF_LORA_MODEL_PATH');
const _loraAdapter = String.fromEnvironment('GGUF_LORA_ADAPTER_PATH');
const _visionModel = String.fromEnvironment('GGUF_VISION_MODEL_PATH');
const _visionProjector = String.fromEnvironment('GGUF_VISION_PROJECTOR_PATH');
const _visionFile = String.fromEnvironment('GGUF_VISION_FILE_PATH');
const _gpuModel = String.fromEnvironment('GGUF_GPU_MODEL_PATH');
const _structuredModel = String.fromEnvironment('GGUF_STRUCTURED_MODEL_PATH');
const _structuredBackend = String.fromEnvironment(
  'GGUF_STRUCTURED_BACKEND',
  defaultValue: 'cpu',
);

edge.InferenceModelSpec _spec(String path) => edge.InferenceModelSpec(
  name: 'native',
  modelSource: edge.ModelSource.file(path),
  modelType: edge.ModelType.general,
  fileType: edge.ModelFileType.gguf,
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
        // Leave room for reasoning before the visible answer.
        maxOutputTokens: 1024,
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
          await chat.generateChatResponse() as edge.FunctionCallResponse;
      expect(call.name, 'get_weather');
      expect(call.args['city'], isA<String>());
      await chat.addQuery(
        edge.Message.toolResponse(
          toolCallId: call.id,
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
    'native audio projector accepts encoded WAV message bytes',
    () async {
      final provider = LlamaEngineProvider(
        projectorResolver: (_, _) async => _audioProjector,
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
      final chat = await model.openChat(
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
        projectorResolver: (_, _) async => _visionProjector,
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
      final chat = await model.openChat(
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
      final chat = await model.openChat(temperature: 0, maxOutputTokens: 16);
      await chat.addQuery(edge.Message.text(text: 'Hello', isUser: true));
      expect(
        (await chat.generateChatResponse() as edge.TextResponse).token,
        isNotEmpty,
      );
    },
    skip: _gpuModel.isEmpty,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  // The discriminating run that enables a response format on a host and
  // backend: an enum the model would not produce unprompted, checked
  // unconstrained first, so a pass shows the grammar at work.
  test(
    'native structured output enforces a schema the model would not produce',
    () async {
      final backend = edge.PreferredBackend.values.byName(_structuredBackend);
      final model = await const LlamaEngineProvider().createModel(
        _spec(_structuredModel),
        RuntimeConfig(
          modelPath: _structuredModel,
          maxTokens: 2048,
          preferredBackend: backend,
        ),
      );
      addTearDown(model.close);
      expect(model.activeBackend, backend);
      expect(
        model.structuredOutputSupport.isSupported,
        isTrue,
        reason: '${model.structuredOutputSupport}',
      );
      const codes = ['QX-7731-ZETA', 'WV-0042-OMICRON'];
      final format = edge.ResponseFormat.jsonSchema({
        'type': 'object',
        'properties': {
          'code': {'type': 'string', 'enum': codes},
          'count': {'type': 'integer', 'minimum': 3, 'maximum': 9},
          'note': {'type': 'string', 'maxLength': 24},
        },
        'required': ['code', 'count', 'note'],
        'additionalProperties': false,
      }, name: 'fruit_order');
      const prompt = 'Name a fruit and say how many of them you would eat.';
      bool conforms(String text) {
        try {
          final value = jsonDecode(text.trim());
          return value is Map &&
              codes.contains(value['code']) &&
              value['count'] is int &&
              (value['count'] as int) >= 3 &&
              (value['count'] as int) <= 9 &&
              value['note'] is String &&
              (value['note'] as String).runes.length <= 24 &&
              value.length == 3;
        } on FormatException {
          return false;
        }
      }

      final control = await model.openSession(
        temperature: 0,
        maxOutputTokens: 128,
      );
      await control.addQueryChunk(
        edge.Message.text(text: prompt, isUser: true),
      );
      final unconstrained = await control.getResponse();
      final plainSpeed = control.getSessionMetrics().tokensPerSecond;
      await control.close();
      expect(conforms(unconstrained), isFalse, reason: unconstrained);

      final session = await model.openSession(
        temperature: 0,
        maxOutputTokens: 128,
        responseFormat: format,
      );
      await session.addQueryChunk(
        edge.Message.text(text: prompt, isUser: true),
      );
      // Core's guard throws if the reply does not conform.
      final constrained = await session.getResponse();
      final structuredSpeed = session.getSessionMetrics().tokensPerSecond;
      await session.close();
      expect(conforms(constrained), isTrue, reason: constrained);

      final chat = await model.openChat(
        temperature: 0,
        maxOutputTokens: 128,
        responseFormat: format,
      );
      for (final turn in [prompt, 'And another fruit?']) {
        await chat.addQuery(edge.Message.text(text: turn, isUser: true));
        final reply = await chat.generateChatResponse() as edge.TextResponse;
        expect(conforms(reply.token), isTrue, reason: reply.token);
      }
      expect(chat.fullHistory, hasLength(4));
      await chat.close();
      // ignore: avoid_print
      print(
        'structured ${backend.name}: unconstrained "$unconstrained" '
        '(${plainSpeed?.toStringAsFixed(1)} tok/s); '
        'constrained "$constrained" '
        '(${structuredSpeed?.toStringAsFixed(1)} tok/s)',
      );
    },
    skip: _structuredModel.isEmpty,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

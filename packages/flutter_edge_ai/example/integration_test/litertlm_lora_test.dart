// A text LoRA on a .litertlm through core (openChat(loraPath:)), on the CPU
// and the GPU of the device: the adapter of LiteRT-LM's FunctionGemma LoRA
// Colab turns its first held-out prompt into the fine-tuned tool call; the
// base model, a chat without the adapter on the same model before and after
// the LoRA chat, does not.
//
// Stage, beside the other models (Android: /data/local/tmp/flutter_gemma_test/;
// macOS: ~/models; other desktop and iOS: app Documents):
//   functiongemma_270m_dynamic_lora.litertlm  FunctionGemma 270M exported with
//       LoRA input signatures (the Colab's step 3)
//   functiongemma_270m_task_lora.tflite  the Colab's task adapter
//
//   flutter test integration_test/litertlm_lora_test.dart -d <device>
//   (Android phones on DDP: run_instrumented.sh, Rule 6)
//
// No setUp (Rule 6b): each body finds its files first.
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'local_model_file_io.dart' show macosStagedFilePath;
import 'voice_test_helpers.dart' show stagedModelPath;

const _model = 'functiongemma_270m_dynamic_lora.litertlm';
const _adapter = 'functiongemma_270m_task_lora.tflite';

/// The Colab's smart-home tools (its tools.json).
const _tools = [
  Tool(
    name: 'set_device_state',
    description: 'Turn a smart-home device on or off.',
    parameters: {
      'type': 'object',
      'properties': {
        'device_id': {
          'type': 'string',
          'description': 'Device ID formatted as <device_type>.<room>',
        },
        'state': {'type': 'string', 'description': 'on or off'},
      },
      'required': ['device_id', 'state'],
    },
  ),
  Tool(
    name: 'set_brightness',
    description: 'Set the brightness of a light.',
    parameters: {
      'type': 'object',
      'properties': {
        'device_id': {
          'type': 'string',
          'description': 'Light ID formatted as light.<room>',
        },
        'level': {
          'type': 'integer',
          'description': 'Brightness percentage from 0 to 100',
        },
      },
      'required': ['device_id', 'level'],
    },
  ),
  Tool(
    name: 'set_temperature',
    description: 'Set the target temperature of a room.',
    parameters: {
      'type': 'object',
      'properties': {
        'zone_id': {
          'type': 'string',
          'description': 'Climate zone ID formatted as climate.<room>',
        },
        'celsius': {
          'type': 'integer',
          'description': 'Target temperature in degrees Celsius',
        },
      },
      'required': ['zone_id', 'celsius'],
    },
  ),
];

Future<String?> _staged(String file) async =>
    Platform.isMacOS ? macosStagedFilePath(file) : stagedModelPath(file);

/// The first tool call of one chat on [model], with [loraPath] or without.
Future<FunctionCallResponse?> _firstCall(
  InferenceModel model, {
  String? loraPath,
}) async {
  final chat = await model.openChat(
    topK: 1,
    tools: _tools,
    supportsFunctionCalls: true,
    modelType: ModelType.functionGemma,
    loraPath: loraPath,
  );
  try {
    await chat.addQueryChunk(
      const Message(text: 'Turn on the living room lights', isUser: true),
    );
    FunctionCallResponse? first;
    await for (final r in chat.generateChatResponseWithTools(
      onToolCall: (call) async {
        first ??= call;
        return {'status': 'ok'};
      },
      maxToolTurns: 1,
      onMaxToolTurns: () {},
    )) {
      if (r is FunctionCallResponse) first ??= r;
    }
    return first;
  } finally {
    await chat.close();
  }
}

bool _fineTuned(FunctionCallResponse? call) =>
    call != null &&
    call.name == 'set_device_state' &&
    call.args['device_id'] == 'light.living_room' &&
    call.args['state'] == 'on';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final backend in [PreferredBackend.cpu, PreferredBackend.gpu]) {
    testWidgets('${backend.name}: the task adapter gives the fine-tuned call; '
        'the base model before and after it does not', (tester) async {
      await registerTestEngines();
      final model = await _staged(_model);
      final adapter = await _staged(_adapter);
      expect(
        model != null && adapter != null,
        isTrue,
        reason: 'stage $_model and $_adapter (see the file header)',
      );
      await FlutterEdgeAi.installModel(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.litertlm,
      ).fromFile(model!).install();
      final active = await FlutterEdgeAi.getActiveModel(
        maxTokens: 1024,
        preferredBackend: backend,
      );
      try {
        final before = await _firstCall(active);
        final tuned = await _firstCall(active, loraPath: adapter);
        final after = await _firstCall(active);
        // ignore: avoid_print
        print(
          '[lora ${backend.name}] before=$before tuned=$tuned after=$after',
        );
        expect(_fineTuned(tuned), isTrue, reason: 'with the adapter: $tuned');
        expect(_fineTuned(before), isFalse, reason: 'base, before: $before');
        expect(_fineTuned(after), isFalse, reason: 'base, after: $after');
      } finally {
        await active.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

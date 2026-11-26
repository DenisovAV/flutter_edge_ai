// On-device: core's ToolChoice on a `.litertlm` model whose tools LiteRT-LM
// renders (Gemma 4, FunctionGemma), through openChat. `required` reaches the
// model as litertlm_dart's per-message ToolChoice and makes it call a tool for
// a question no tool answers; `none` opens the conversation without the tools,
// so the model never sees them. Each model's `auto` answer is the control: on
// Gemma 4 it is text (so `required` is what makes it call), while the base
// FunctionGemma 270M calls the tool even then (so `none` is what stops it).
//
// macOS: ~/models (container Documents fallback); other desktop and iOS: app
// Documents; Android: /data/local/tmp/flutter_gemma_test/.
//   gemma-4-E2B-it.litertlm         litert-community/gemma-4-E2B-it-litert-lm
//   functiongemma-270M-it.litertlm  sasha-denisov/function-gemma-270M-it
//
// Run: flutter test integration_test/litertlm_tool_choice_test.dart -d <device>
// CPU by default; --dart-define=TOOLS_BACKEND=gpu for the GPU backend.
//
// No setUp (Rule 6b): each body finds its files first.
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'local_model_file_io.dart' show macosStagedFilePath;
import 'voice_test_helpers.dart' show stagedModelPath;

const _backendName = String.fromEnvironment(
  'TOOLS_BACKEND',
  defaultValue: 'cpu',
);

const _tools = [
  Tool(
    name: 'get_weather',
    description: 'Get the current weather for a city.',
    parameters: {
      'type': 'object',
      'properties': {
        'city': {'type': 'string', 'description': 'The city name.'},
      },
      'required': ['city'],
    },
  ),
];

/// A question no tool answers.
const _question = 'Tell me a short joke about cats.';

Future<String?> _modelPath(String file) async {
  if (Platform.isMacOS) return macosStagedFilePath(file);
  return stagedModelPath(file);
}

Future<InferenceModel> _load(String file, ModelType modelType) async {
  await registerTestEngines();
  final path = await _modelPath(file);
  expect(path, isNotNull, reason: 'stage $file (see the header)');
  await FlutterEdgeAi.installModel(
    modelType: modelType,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
  return FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.values.byName(_backendName),
  );
}

/// One turn of a chat opened with [choice]: the calls the model made and its
/// text.
Future<({List<FunctionCallResponse> calls, String text})> _turn(
  InferenceModel model,
  ModelType modelType,
  ToolChoice choice,
) async {
  final chat = await model.openChat(
    topK: 1,
    tools: _tools,
    supportsFunctionCalls: true,
    modelType: modelType,
    toolChoice: choice,
    maxOutputTokens: 128,
  );
  try {
    await chat.addQuery(const Message(text: _question, isUser: true));
    final calls = <FunctionCallResponse>[];
    final text = StringBuffer();
    await for (final r in chat.generateChatResponseAsync()) {
      switch (r) {
        case FunctionCallResponse():
          calls.add(r);
        case ParallelFunctionCallResponse(calls: final parallel):
          calls.addAll(parallel);
        case TextResponse(:final token):
          text.write(token);
        case ThinkingResponse():
          break;
      }
    }
    return (calls: calls, text: text.toString());
  } finally {
    await chat.close();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Whether the model calls the tool for [_question] under `auto` (measured
  // on macOS, CPU and Metal, greedy).
  for (final (file, modelType, autoCalls) in [
    ('gemma-4-E2B-it.litertlm', ModelType.gemma4, false),
    ('functiongemma-270M-it.litertlm', ModelType.functionGemma, true),
  ]) {
    testWidgets('$modelType ($_backendName): auto '
        '${autoCalls ? 'calls' : 'answers in text'}, required calls a tool, '
        'none calls none', (tester) async {
      final model = await _load(file, modelType);
      try {
        final auto = await _turn(model, modelType, ToolChoice.auto);
        // ignore: avoid_print
        print('[tool choice] $modelType auto: $auto');
        final required = await _turn(model, modelType, ToolChoice.required);
        // ignore: avoid_print
        print('[tool choice] $modelType required: $required');
        final none = await _turn(model, modelType, ToolChoice.none);
        // ignore: avoid_print
        print('[tool choice] $modelType none: $none');

        expect(auto.calls.isNotEmpty, autoCalls, reason: 'auto: $auto');
        expect(required.calls, isNotEmpty, reason: 'required: $required');
        expect(required.calls.first.name, 'get_weather');
        expect(none.calls, isEmpty, reason: 'none: $none');
        expect(none.text.trim(), isNotEmpty, reason: 'none: $none');
        // With the tools declared, a call under LiteRT-LM's own none can come
        // back as the reply's raw tool-call JSON instead of a parsed call.
        expect(
          none.text,
          isNot(contains('get_weather')),
          reason: 'none: $none',
        );
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}

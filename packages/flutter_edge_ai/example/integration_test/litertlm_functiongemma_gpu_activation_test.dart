// On-device: a FunctionGemma bundle that declares no `prefer_activation_type`
// on the GPU. At the GPU's FP16 default such a bundle can answer every prompt
// with `<pad>` to the token limit, or with nothing, and no error
// (LiteRT-LM#3280); the engine builds its GPU attempt at FP32 for it. Each case
// is a separate engine, because the precision is set per engine.
//
// Stage the model in /data/local/tmp/flutter_gemma_test/ (Android), or the app
// documents dir (desktop/iOS):
//   functiongemma-270M-it.litertlm      sasha-denisov/function-gemma-270M-it
//   (sha256 680fead1…; its header declares no prefer_activation_type)
//
// Not every GPU shows the defect: FunctionGemma answers at the default on
// Adreno 750 and Mali (#552), so the first test cannot tell fixed from broken
// there and prints INCONCLUSIVE. Measured on an Adreno 616 (vivo 1933): the
// default precision produced no call and no text, and the engine's float32
// called `multiply` with the right arguments.
//
// Run: flutter test integration_test/litertlm_functiongemma_gpu_activation_test.dart -d <device>
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'platform_helper.dart' show isIosSimulator;
import 'voice_test_helpers.dart' show stagedModelPath;

const _file = 'functiongemma-270M-it.litertlm';

const _multiply = Tool(
  name: 'multiply',
  description:
      'Multiply two numbers and return the exact product. Use this for any '
      'multiplication instead of working it out yourself.',
  parameters: {
    'type': 'object',
    'properties': {
      'a': {'type': 'number', 'description': 'The first number.'},
      'b': {'type': 'number', 'description': 'The second number.'},
    },
    'required': ['a', 'b'],
  },
);

Future<InferenceModel> _load({ActivationDataType? activationDataType}) async {
  await registerTestEngines();
  final path = await stagedModelPath(_file);
  expect(path, isNotNull, reason: 'stage $_file, see the header of this file');
  await FlutterEdgeAi.installModel(
    modelType: ModelType.functionGemma,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
  return FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.gpu,
    activationDataType: activationDataType,
  );
}

typedef _Answer = ({List<FunctionCallResponse> calls, String text});

/// One question through the tool path; the calls and the answer text.
Future<_Answer> _ask(InferenceModel model) async {
  final chat = await model.createChat(
    topK: 1,
    tools: const [_multiply],
    supportsFunctionCalls: true,
    modelType: ModelType.functionGemma,
    maxOutputTokens: 64,
  );
  await chat.addQueryChunk(
    const Message(text: 'how much is 12 times 12?', isUser: true),
  );
  final calls = <FunctionCallResponse>[];
  final text = StringBuffer();
  await for (final r in chat.generateChatResponseWithTools(
    onToolCall: (call) async {
      calls.add(call);
      return {'result': 144};
    },
    maxToolTurns: 4,
    onMaxToolTurns: () {},
  )) {
    if (r is TextResponse) text.write(r.token);
  }
  return (calls: calls, text: text.toString());
}

/// What the model said once the `<pad>` filler is taken out.
String _words(String text) => text.replaceAll('<pad>', '').trim();

/// Whether the answer is the working one: a `multiply` call and some text.
bool _answers(_Answer a) =>
    a.calls.isNotEmpty &&
    a.calls.first.name == 'multiply' &&
    _words(a.text).isNotEmpty;

String _describe(String label, InferenceModel model, _Answer a) =>
    'ACTIVATION $label: backend=${model.activeBackend?.name} '
    'calls=${a.calls.map((c) => '${c.name}${c.args}').toList()} '
    'text="${a.text.replaceAll('\n', ' ')}"';

/// The iOS Simulator has no GPU backend: a model that fell back to CPU there
/// proves nothing about the GPU, so the test says so and stops.
bool _notOnGpuOnSimulator(InferenceModel model) =>
    isIosSimulator && model.activeBackend != PreferredBackend.gpu;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'FunctionGemma on GPU: the engine default answers, float16 may not',
    (tester) async {
      // Control first: the same file at the GPU's FP16, set explicitly.
      final control = await _load(
        activationDataType: ActivationDataType.float16,
      );
      late _Answer atFloat16;
      try {
        if (_notOnGpuOnSimulator(control)) {
          debugPrint('[activation] iOS Simulator: no GPU backend, skipped.');
          return;
        }
        expect(control.activeBackend, PreferredBackend.gpu);
        atFloat16 = await _ask(control);
        debugPrint(_describe('float16', control, atFloat16));
      } finally {
        await control.close();
      }

      // No argument: the engine reads the header and chooses.
      final model = await _load();
      try {
        expect(model.activeBackend, PreferredBackend.gpu);
        final atDefault = await _ask(model);
        debugPrint(_describe('default', model, atDefault));

        // The engine's choice must answer wherever the bundle is runnable.
        expect(atDefault.calls, isNotEmpty);
        expect(atDefault.calls.first.name, 'multiply');
        expect(_words(atDefault.text), isNotEmpty);

        if (_answers(atFloat16)) {
          debugPrint(
            '[activation] INCONCLUSIVE: float16 answered on this GPU too, so '
            'this pass does not show that float32 fixed anything.',
          );
        }
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets('FunctionGemma on GPU: explicit float32 answers', (tester) async {
    final model = await _load(activationDataType: ActivationDataType.float32);
    try {
      if (_notOnGpuOnSimulator(model)) {
        debugPrint('[activation] iOS Simulator: no GPU backend, skipped.');
        return;
      }
      expect(model.activeBackend, PreferredBackend.gpu);
      final answer = await _ask(model);
      debugPrint(_describe('float32', model, answer));
      expect(answer.calls, isNotEmpty);
      expect(answer.calls.first.name, 'multiply');
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

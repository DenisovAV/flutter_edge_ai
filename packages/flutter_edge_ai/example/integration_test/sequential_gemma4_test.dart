// Integration test: Sequential inference with Gemma 4 E2B .litertlm
// Reproduces issue #209 — SIGSEGV crash on second sendMessage
//
// Run:
//   cd example
//   flutter test integration_test/sequential_gemma4_test.dart -d <device>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath = '/data/local/tmp/flutter_gemma_test/gemma-4-E2B-it.litertlm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    if (!Platform.isAndroid) {
      fail('Test requires Android with .litertlm models');
    }
    if (!File(_modelPath).existsSync()) {
      fail(
        'Model not found: $_modelPath\nPush it first: adb push <model> $_modelPath',
      );
    }
  });

  testWidgets(
    'Gemma 4 E2B: two sequential queries on same chat',
    (tester) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(_modelPath).install();

      // No preferredBackend = CPU (default), matching issue #209 reporter's code
      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 2048);

      try {
        final chat = await model.createChat(modelType: ModelType.gemmaIt);

        // First query
        await chat.addQueryChunk(
          const Message(
            text: 'What is 2+2? Answer with just the number.',
            isUser: true,
          ),
        );
        final r1 = await chat.generateChatResponse();
        expect(r1, isA<TextResponse>());
        final text1 = (r1 as TextResponse).token;
        print('[Gemma4] First response: "$text1"');
        expect(text1, isNotEmpty);

        // Second query — crash point in issue #209
        await chat.addQueryChunk(
          const Message(
            text: 'What is 3+3? Answer with just the number.',
            isUser: true,
          ),
        );
        final r2 = await chat.generateChatResponse();
        expect(r2, isA<TextResponse>());
        final text2 = (r2 as TextResponse).token;
        print('[Gemma4] Second response: "$text2"');
        expect(text2, isNotEmpty);
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

// Integration test: model download from network, caching, and basic inference.
// This is the ONLY test that downloads from network — verifies download pipeline.
// Run: flutter test integration_test/inference_download_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

/// FunctionGemma 270M IT — 284MB, no auth required.
const _taskUrl =
    'https://huggingface.co/sasha-denisov/function-gemma-270M-it/resolve/main/functiongemma-270M-it.task';
const _taskFilename = 'functiongemma-270M-it.task';

void main() {
  initIntegrationTest();

  testWidgets(
    'Inference: model download and cache',
    (tester) async {
      // 1. Initialize
      await registerTestEngines();

      // 2. Download model from network
      await FlutterEdgeAi.installModel(
            modelType: ModelType.functionGemma,
            fileType: ModelFileType.task,
          )
          .fromNetwork(_taskUrl)
          .withProgress((progress) => print('[Download] Progress: $progress%'))
          .install();

      // 3. Verify active model
      expect(
        FlutterEdgeAi.hasActiveModel(),
        isTrue,
        reason: 'Active model should be set after install',
      );

      // 4. Verify model installed on disk
      final isInstalled = await FlutterEdgeAi.isModelInstalled(_taskFilename);
      expect(isInstalled, isTrue, reason: 'Model file should exist on disk');

      // 5. Cache check — second install should be instant (no re-download)
      final stopwatch = Stopwatch()..start();
      await FlutterEdgeAi.installModel(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.task,
      ).fromNetwork(_taskUrl).install();
      stopwatch.stop();
      print('[Cache] Second install took ${stopwatch.elapsedMilliseconds}ms');
      expect(
        stopwatch.elapsedMilliseconds,
        lessThan(5000),
        reason: 'Cached model should not trigger re-download',
      );

      // 6. Quick inference sanity check
      final model = await createTestModel();
      try {
        final chat = await createTestChat(model);
        await chat.addQueryChunk(const Message(text: 'Say hi', isUser: true));
        final response = await chat.generateChatResponse();
        expect(response, isA<TextResponse>());
        final text = (response as TextResponse).token;
        print(
          '[Inference] Response: "${text.length > 100 ? text.substring(0, 100) : text}"',
        );
        expect(
          text,
          isNotEmpty,
          reason: 'Model should produce non-empty response',
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

// Integration test: model close + re-create with different config.
// Run: flutter test integration_test/inference_lifecycle_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

void main() {
  initIntegrationTest();

  for (final (:config, :label) in TestModelConfig.allForCurrentPlatform()) {
    _runLifecycleTest(config, label);
  }
}

void _runLifecycleTest(TestModelConfig config, String label) {
  testWidgets(
    'Inference: lifecycle close and re-create ($label)',
    (tester) async {
      await registerTestEngines();
      await forceInstallModel(config);

      // --- Cycle 1: maxTokens=512 ---
      print('[Lifecycle/$label] Cycle 1: maxTokens=512');
      var model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.cpu,
      );
      try {
        final chat1 = await createTestChat(model);
        await chat1.addQueryChunk(
          const Message(text: 'Say one word', isUser: true),
        );
        final response1 = await chat1.generateChatResponse();
        expect(response1, isA<TextResponse>());
        final text1 = (response1 as TextResponse).token;
        print(
          '[Lifecycle/$label] Cycle 1 response: "${text1.length > 50 ? text1.substring(0, 50) : text1}"',
        );
      } finally {
        await model.close();
        print('[Lifecycle/$label] Cycle 1 model closed');
      }

      // --- Cycle 2: maxTokens=256, different config ---
      print('[Lifecycle/$label] Cycle 2: maxTokens=256');
      model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 256,
        preferredBackend: PreferredBackend.cpu,
      );
      try {
        final chat2 = await createTestChat(model);
        await chat2.addQueryChunk(const Message(text: 'Say hi', isUser: true));
        final response2 = await chat2.generateChatResponse();
        expect(response2, isA<TextResponse>());
        final text2 = (response2 as TextResponse).token;
        print(
          '[Lifecycle/$label] Cycle 2 response: "${text2.length > 50 ? text2.substring(0, 50) : text2}"',
        );
      } finally {
        await model.close();
        print('[Lifecycle/$label] Cycle 2 model closed');
      }

      print('[Lifecycle/$label] Both cycles completed successfully');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

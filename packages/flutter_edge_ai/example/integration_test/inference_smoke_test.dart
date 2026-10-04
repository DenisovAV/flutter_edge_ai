// Integration test: basic sync and streaming inference.
// Run: flutter test integration_test/inference_smoke_test.dart -d <device>

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

void main() {
  initIntegrationTest();

  for (final (:config, :label) in TestModelConfig.allForCurrentPlatform()) {
    _runSmokeTest(config, label);
  }
}

void _runSmokeTest(TestModelConfig config, String label) {
  testWidgets(
    'Inference: sync and streaming ($label)',
    (tester) async {
      await registerTestEngines();
      await forceInstallModel(config);

      final model = await createTestModel(maxTokens: 512);
      try {
        // --- Synchronous response ---
        final chat1 = await createTestChat(model);
        await chat1.addQueryChunk(
          const Message(text: 'What is 2+2?', isUser: true),
        );

        final syncResponse = await chat1.generateChatResponse();
        expect(syncResponse, isA<TextResponse>());
        final syncText = (syncResponse as TextResponse).token;
        print(
          '[Sync/$label] Response: "${syncText.length > 100 ? syncText.substring(0, 100) : syncText}"',
        );
        expect(
          syncText,
          isNotEmpty,
          reason: 'Sync response should be non-empty',
        );

        // --- Streaming response ---
        final chat2 = await createTestChat(model);
        await chat2.addQueryChunk(
          const Message(text: 'Say hello', isUser: true),
        );

        final chunks = <String>[];
        await for (final response in chat2.generateChatResponseAsync()) {
          if (response is TextResponse) {
            chunks.add(response.token);
            if (chunks.length <= 5) {
              print(
                '[Stream/$label] Chunk ${chunks.length}: "${response.token}"',
              );
            }
          }
        }

        final streamText = chunks.join();
        print(
          '[Stream/$label] Full (${chunks.length} chunks): "${streamText.length > 100 ? streamText.substring(0, 100) : streamText}"',
        );
        expect(chunks, isNotEmpty, reason: 'Should receive at least 1 chunk');
        expect(
          streamText,
          isNotEmpty,
          reason: 'Streaming response should be non-empty',
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

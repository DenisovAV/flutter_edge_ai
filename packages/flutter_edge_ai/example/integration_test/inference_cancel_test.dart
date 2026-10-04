// Integration test: streaming cancel via stopGeneration().
// Run: flutter test integration_test/inference_cancel_test.dart -d <device>

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

void main() {
  initIntegrationTest();

  for (final (:config, :label) in TestModelConfig.allForCurrentPlatform()) {
    _runCancelTest(config, label);
  }
}

void _runCancelTest(TestModelConfig config, String label) {
  testWidgets(
    'Inference: cancel generation ($label)',
    (tester) async {
      await registerTestEngines();
      await forceInstallModel(config);

      final model = await createTestModel(maxTokens: 512);
      try {
        final chat = await createTestChat(model);
        await chat.addQueryChunk(
          const Message(
            text:
                'Write a very long detailed story about space exploration and all the planets in the solar system',
            isUser: true,
          ),
        );

        final chunks = <String>[];
        var cancelled = false;

        // LiteRT-LM throws PlatformException("Process cancelled") on cancel —
        // that's expected SDK behavior, not a bug.
        try {
          await for (final response in chat.generateChatResponseAsync()) {
            if (response is TextResponse) {
              chunks.add(response.token);
              if (chunks.length <= 5) {
                print(
                  '[Cancel/$label] Chunk ${chunks.length}: "${response.token}"',
                );
              }

              // Cancel after receiving 3+ chunks
              if (chunks.length >= 3 && !cancelled) {
                print(
                  '[Cancel/$label] Requesting stop after ${chunks.length} chunks...',
                );
                await chat.stopGeneration();
                cancelled = true;
              }
            }
          }
          print('[Cancel/$label] Stream ended gracefully.');
        } on PlatformException catch (e) {
          // LiteRT-LM signals cancellation via exception
          expect(
            cancelled,
            isTrue,
            reason: 'PlatformException should only occur after cancel',
          );
          print(
            '[Cancel/$label] Stream cancelled with expected exception: ${e.message}',
          );
        }

        print('[Cancel/$label] Total chunks: ${chunks.length}');
        expect(
          chunks.length,
          greaterThanOrEqualTo(3),
          reason: 'Should have received at least 3 chunks before cancel',
        );
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

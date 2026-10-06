import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

/// Regression test for issue #224: Qwen3-0.6B generates <think> blocks by default
/// even when isThinking is false. Verify that thinking tags are stripped from output.
///
/// Run: flutter test integration_test/desktop_thinking_qwen3_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const modelUrl =
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm';

  testWidgets(
    'Qwen3: thinking tags stripped when isThinking=false',
    (tester) async {
      await registerTestEngines();

      // Install Qwen3 model
      await FlutterEdgeAi.installModel(
        modelType: ModelType.qwen3,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(modelUrl).install();

      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 512);
      try {
        // Create chat WITHOUT thinking mode
        final chat = await model.createChat(
          modelType: ModelType.qwen3,
          enableThinking: false,
        );

        await chat.addQuery(const Message(text: 'What is 2+2?', isUser: true));

        // Test sync response
        final response = await chat.generateChatResponse();
        final text = response is TextResponse
            ? response.token
            : response.toString();
        debugPrint('Response (isThinking=false): $text');

        expect(
          text,
          isNot(contains('<think>')),
          reason: 'Thinking tags should be stripped when isThinking=false',
        );
        expect(
          text,
          isNot(contains('</think>')),
          reason:
              'Thinking close tags should be stripped when isThinking=false',
        );
        expect(
          text.trim(),
          isNotEmpty,
          reason: 'Response should not be empty after stripping',
        );

        await chat.close();
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  testWidgets(
    'Qwen3: thinking tags present when isThinking=true',
    (tester) async {
      await registerTestEngines();

      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 512);
      try {
        // Create chat WITH thinking mode
        final chat = await model.createChat(
          modelType: ModelType.qwen3,
          enableThinking: true,
        );

        await chat.addQuery(const Message(text: 'What is 2+2?', isUser: true));

        // Test streaming response — should emit ThinkingResponse events
        final responses = <ModelResponse>[];
        await for (final response in chat.generateChatResponseAsync()) {
          responses.add(response);
        }

        final hasThinking = responses.any((r) => r is ThinkingResponse);
        final hasText = responses.any((r) => r is TextResponse);

        debugPrint(
          'Thinking responses: ${responses.whereType<ThinkingResponse>().length}',
        );
        debugPrint(
          'Text responses: ${responses.whereType<TextResponse>().length}',
        );

        expect(
          hasThinking,
          isTrue,
          reason: 'Should emit ThinkingResponse when isThinking=true',
        );
        expect(
          hasText,
          isTrue,
          reason: 'Should emit TextResponse after thinking',
        );

        // Verify text responses don't contain raw think tags
        final textContent = responses
            .whereType<TextResponse>()
            .map((r) => r.token)
            .join();
        expect(
          textContent,
          isNot(contains('<think>')),
          reason: 'TextResponse tokens should not contain raw think tags',
        );

        await chat.close();
      } finally {
        await model.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

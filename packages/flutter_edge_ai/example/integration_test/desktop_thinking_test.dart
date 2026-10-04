// Integration test: Gemma 4 thinking mode on Desktop (macOS/Windows/Linux)
// Run with: cd example && flutter test integration_test/desktop_thinking_test.dart -d macos
//
// Prerequisites:
//   Copy gemma-4-E2B-it.litertlm to the app sandbox container:
//   cp ~/Downloads/gemma-4-E2B-it.litertlm \
//      ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelFileName = 'gemma-4-E2B-it.litertlm';

String _resolveModelPath() {
  // Inside macOS sandbox, HOME already points to the container:
  // ~/Library/Containers/<bundle-id>/Data
  final home = Platform.environment['HOME'] ?? '';
  return '$home/Documents/$_modelFileName';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String modelPath;

  group('Desktop Gemma 4 Thinking Mode', () {
    setUpAll(() {
      if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
        fail('Test requires desktop platform');
      }
      modelPath = _resolveModelPath();
      if (!File(modelPath).existsSync()) {
        fail('Model not found: $modelPath');
      }
    });

    testWidgets('thinking_stream', (tester) async {
      print('=== Initializing ===');
      await registerTestEngines();

      print('=== Installing model from file ===');
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      expect(FlutterEdgeAi.hasActiveModel(), isTrue);
      print('Model installed');

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat = await model.createChat(
          temperature: 1.0,
          topK: 64,
          topP: 0.95,
          isThinking: true,
          modelType: ModelType.gemmaIt,
        );

        await chat.addQuery(
          const Message(
            text: 'Explain why the sky is blue. Think step by step.',
            isUser: true,
          ),
        );

        final responses = <ModelResponse>[];
        await tester.runAsync(() async {
          await for (final response in chat.generateChatResponseAsync()) {
            responses.add(response);
          }
        });

        final thinkingTokens = responses
            .whereType<ThinkingResponse>()
            .map((r) => r.content)
            .join();
        final textTokens = responses
            .whereType<TextResponse>()
            .map((r) => r.token)
            .join();

        print(
          '[Gemma 4 E2B Desktop] Thinking tokens: ${thinkingTokens.length} chars',
        );
        print('[Gemma 4 E2B Desktop] Text tokens: ${textTokens.length} chars');

        // Should have thinking content
        expect(
          thinkingTokens.isNotEmpty,
          isTrue,
          reason: 'Expected non-empty thinking content',
        );

        // Should have text content
        expect(
          textTokens.isNotEmpty,
          isTrue,
          reason: 'Expected non-empty text response',
        );

        // Thinking should come before text in stream order
        final firstThinkingIdx = responses.indexWhere(
          (r) => r is ThinkingResponse,
        );
        final firstTextIdx = responses.indexWhere((r) => r is TextResponse);

        if (firstThinkingIdx >= 0 && firstTextIdx >= 0) {
          expect(
            firstThinkingIdx,
            lessThan(firstTextIdx),
            reason: 'First thinking should appear before first text',
          );
        }

        print('[Gemma 4 E2B Desktop] thinking_stream PASSED');
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    testWidgets('no_thinking', (tester) async {
      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.litertlm,
      ).fromFile(modelPath).install();

      final model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
      );

      try {
        final chat = await model.createChat(
          temperature: 1.0,
          topK: 64,
          topP: 0.95,
          isThinking: false,
          modelType: ModelType.gemmaIt,
        );

        await chat.addQuery(const Message(text: 'What is 2+2?', isUser: true));

        final responses = <ModelResponse>[];
        await tester.runAsync(() async {
          await for (final response in chat.generateChatResponseAsync()) {
            responses.add(response);
          }
        });

        // Without thinking enabled, no ThinkingResponse should appear
        final thinkingResponses = responses
            .whereType<ThinkingResponse>()
            .toList();
        expect(
          thinkingResponses,
          isEmpty,
          reason: 'No ThinkingResponse expected with isThinking=false',
        );

        // Should still have text content
        final textTokens = responses
            .whereType<TextResponse>()
            .map((r) => r.token)
            .join();
        expect(
          textTokens.isNotEmpty,
          isTrue,
          reason: 'Expected non-empty text response',
        );

        print('[Gemma 4 E2B Desktop] no_thinking PASSED');
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

// Integration test: thinking mode across DeepSeek and Gemma 4 models.
// Run on Android: flutter test integration_test/thinking_mode_test.dart -d <android-device>
//
// Prerequisites:
//   Push models to device:
//     adb push deepseek_q8_ekv1280.task /data/local/tmp/flutter_gemma_test/
//     adb push gemma-4-E2B-it.litertlm /data/local/tmp/flutter_gemma_test/
//
// Tests per model:
//   - install: model loads from device file
//   - thinking_stream: async stream verifies ThinkingResponse + TextResponse ordering
//   - no_thinking: isThinking: false produces only TextResponse

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _deviceModelDir = '/data/local/tmp/flutter_gemma_test';

/// Test model configuration for thinking mode tests.
class ThinkingTestModel {
  final String name;
  final String filePath;
  final ModelType modelType;
  final ModelFileType fileType;
  final double temperature;
  final int topK;
  final double topP;
  final int maxTokens;

  const ThinkingTestModel({
    required this.name,
    required this.filePath,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.temperature = 1.0,
    this.topK = 64,
    this.topP = 0.95,
    this.maxTokens = 1024,
  });
}

const _testModels = [
  ThinkingTestModel(
    name: 'DeepSeek R1 1.5B',
    filePath: '$_deviceModelDir/deepseek_q8_ekv1280.task',
    modelType: ModelType.deepSeek,
    temperature: 0.6,
    topK: 40,
    topP: 0.7,
  ),
  ThinkingTestModel(
    name: 'Gemma 4 E2B',
    filePath: '$_deviceModelDir/gemma-4-E2B-it.litertlm',
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.litertlm,
    maxTokens: 2048,
  ),
];

Future<void> _ensureModelInstalled(ThinkingTestModel model) async {
  await FlutterEdgeAi.installModel(
    modelType: model.modelType,
    fileType: model.fileType,
  ).fromFile(model.filePath).install();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final model in _testModels) {
    group(model.name, () {
      setUpAll(() {
        if (!Platform.isAndroid) {
          fail('Test requires Android with .litertlm/.task models');
        }
        if (!File(model.filePath).existsSync()) {
          fail(
            'Model not found: ${model.filePath}\n'
            'Push it first: adb push <model> ${model.filePath}',
          );
        }
      });

      testWidgets('install', (tester) async {
        await registerTestEngines();

        print('[${model.name}] Installing from file: ${model.filePath}');
        await _ensureModelInstalled(model);

        expect(FlutterEdgeAi.hasActiveModel(), isTrue);
        print('[${model.name}] Installed successfully');
      }, timeout: const Timeout(Duration(minutes: 5)));

      testWidgets('thinking_stream', (tester) async {
        await registerTestEngines();
        await _ensureModelInstalled(model);

        final inferenceModel = await FlutterEdgeAi.getActiveModel(
          maxTokens: model.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );

        try {
          final chat = await inferenceModel.createChat(
            temperature: model.temperature,
            topK: model.topK,
            topP: model.topP,
            isThinking: true,
            modelType: model.modelType,
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
            '[${model.name}] Thinking tokens: ${thinkingTokens.length} chars',
          );
          print('[${model.name}] Text tokens: ${textTokens.length} chars');

          // Should have thinking content
          expect(
            thinkingTokens.isNotEmpty,
            isTrue,
            reason: '${model.name}: Expected non-empty thinking content',
          );

          // Should have text content
          expect(
            textTokens.isNotEmpty,
            isTrue,
            reason: '${model.name}: Expected non-empty text response',
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
              reason:
                  '${model.name}: First thinking should appear before first text',
            );
          }

          print('[${model.name}] thinking_stream PASSED');
        } finally {
          await inferenceModel.close();
        }
      }, timeout: const Timeout(Duration(minutes: 5)));

      testWidgets('no_thinking', (tester) async {
        await registerTestEngines();
        await _ensureModelInstalled(model);

        final inferenceModel = await FlutterEdgeAi.getActiveModel(
          maxTokens: model.maxTokens,
          preferredBackend: PreferredBackend.cpu,
        );

        try {
          final chat = await inferenceModel.createChat(
            temperature: model.temperature,
            topK: model.topK,
            topP: model.topP,
            isThinking: false,
            modelType: model.modelType,
          );

          await chat.addQuery(
            const Message(text: 'What is 2+2?', isUser: true),
          );

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
            reason:
                '${model.name}: No ThinkingResponse expected with isThinking=false',
          );

          // Should still have text content
          final textTokens = responses
              .whereType<TextResponse>()
              .map((r) => r.token)
              .join();
          expect(
            textTokens.isNotEmpty,
            isTrue,
            reason: '${model.name}: Expected non-empty text response',
          );

          print('[${model.name}] no_thinking PASSED');
        } finally {
          await inferenceModel.close();
        }
      }, timeout: const Timeout(Duration(minutes: 5)));
    });
  }
}

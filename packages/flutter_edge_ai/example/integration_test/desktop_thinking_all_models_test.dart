import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;
import 'local_model_file_io.dart' show macosStagedFilePath;
import 'registry_evidence.dart';

/// Comprehensive thinking mode test for all available models.
/// Verifies that <think> tags are handled correctly for every ModelType.
///
/// Run: flutter test integration_test/desktop_thinking_all_models_test.dart -d macos
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  String stagedPath(String name) {
    if (Platform.isMacOS) return macosStagedFilePath(name)!;
    return '${Platform.environment['HOME']}/Documents/$name';
  }

  final models = <String, _TestModel>{
    'Qwen3-0.6B': _TestModel(
      path: stagedPath('Qwen3-0.6B.litertlm'),
      modelType: ModelType.qwen3,
      fileType: ModelFileType.litertlm,
      generatesThinking: true,
    ),
    'Qwen2.5-1.5B': _TestModel(
      path: stagedPath(
        'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
      ),
      modelType: ModelType.qwen,
      fileType: ModelFileType.litertlm,
      generatesThinking: false,
    ),
    'Gemma4-E2B': _TestModel(
      path: stagedPath('gemma-4-E2B-it.litertlm'),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
      generatesThinking: false, // only with extraContext
    ),
    'Gemma3-1B': _TestModel(
      path: stagedPath('Gemma3-1B-IT_multi-prefill-seq_q4_ekv4096.litertlm'),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
      generatesThinking: false,
    ),
    'Gemma-3n-E2B': _TestModel(
      path: stagedPath('gemma-3n-E2B-it-int4.litertlm'),
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
      generatesThinking: false,
    ),
    'FunctionGemma-270M': _TestModel(
      path: stagedPath('functiongemma-270M-it.litertlm'),
      modelType: ModelType.functionGemma,
      fileType: ModelFileType.litertlm,
      generatesThinking: false,
    ),
  };

  for (final entry in models.entries) {
    final name = entry.key;
    final config = entry.value;

    testWidgets('$name: isThinking=false — no think tags in output', (
      tester,
    ) async {
      if (!File(config.path).existsSync()) {
        debugPrint('SKIP: $name not found at ${config.path}');
        return;
      }

      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: config.modelType,
        fileType: config.fileType,
      ).fromFile(config.path).install();

      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 256);
      try {
        final chat = await model.openChat(
          modelType: config.modelType,
          enableThinking: false,
        );

        await chat.addQuery(
          const Message(text: 'What is 2+2? Answer briefly.', isUser: true),
        );
        final response = await chat.generateChatResponse();
        final text = response is TextResponse
            ? response.token
            : response.toString();
        debugPrint('[$name isThinking=false] Response: $text');

        expect(
          text.trim(),
          isNotEmpty,
          reason: '$name: response should not be empty',
        );
        expect(
          text,
          isNot(contains('<think>')),
          reason: '$name: <think> tags should be stripped',
        );
        expect(
          text,
          isNot(contains('</think>')),
          reason: '$name: </think> tags should be stripped',
        );
        await recordEvidence(
          path: config.path,
          backend: model.activeBackend,
          check: 'text',
        );

        await chat.close();
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));

    testWidgets('$name: isThinking=true — response not empty, no raw tags', (
      tester,
    ) async {
      if (!File(config.path).existsSync()) {
        debugPrint('SKIP: $name not found at ${config.path}');
        return;
      }

      await registerTestEngines();

      await FlutterEdgeAi.installModel(
        modelType: config.modelType,
        fileType: config.fileType,
      ).fromFile(config.path).install();

      final model = await FlutterEdgeAi.getActiveModel(maxTokens: 256);
      try {
        final chat = await model.openChat(
          modelType: config.modelType,
          enableThinking: true,
        );

        await chat.addQuery(
          const Message(text: 'What is 2+2? Answer briefly.', isUser: true),
        );

        final responses = <ModelResponse>[];
        await for (final response in chat.generateChatResponseAsync()) {
          responses.add(response);
        }

        final thinkingCount = responses.whereType<ThinkingResponse>().length;
        final textCount = responses.whereType<TextResponse>().length;

        debugPrint(
          '[$name isThinking=true] Thinking: $thinkingCount, Text: $textCount',
        );

        // Models that generate thinking should have ThinkingResponse
        if (config.generatesThinking) {
          expect(
            responses.any((r) => r is ThinkingResponse),
            isTrue,
            reason: '$name: should emit ThinkingResponse',
          );
        }

        // All models should have some text output
        expect(
          responses.any((r) => r is TextResponse),
          isTrue,
          reason: '$name: should emit TextResponse',
        );

        // TextResponse should never contain raw thinking tags
        final textContent = responses
            .whereType<TextResponse>()
            .map((r) => r.token)
            .join();
        debugPrint('[$name isThinking=true] Text: $textContent');
        expect(
          textContent.trim(),
          isNotEmpty,
          reason: '$name: text response should not be empty',
        );
        expect(
          textContent,
          isNot(contains('<think>')),
          reason: '$name: TextResponse should not contain raw <think>',
        );
        expect(
          textContent,
          isNot(contains('</think>')),
          reason: '$name: TextResponse should not contain raw </think>',
        );
        if (config.generatesThinking) {
          await recordEvidence(
            path: config.path,
            backend: model.activeBackend,
            check: 'thinking',
          );
        }

        await chat.close();
      } finally {
        await model.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}

class _TestModel {
  final String path;
  final ModelType modelType;
  final ModelFileType fileType;
  final bool generatesThinking;

  const _TestModel({
    required this.path,
    required this.modelType,
    required this.fileType,
    required this.generatesThinking,
  });
}

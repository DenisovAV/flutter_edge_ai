// Integration test for systemInstruction support
//
// Run on Android (models must be in /data/local/tmp/flutter_gemma_test/):
//   chmod 666 /data/local/tmp/flutter_gemma_test/*.task
//   chmod 666 /data/local/tmp/flutter_gemma_test/*.litertlm
//   flutter test integration_test/system_instruction_test.dart -d <device_id>
//
// Tests both engines:
//   .task     → gemma-3n-E2B-it-int4.task   (MediaPipe, Dart-level prepend)
//   .litertlm → gemma-4-E2B-it.litertlm     (LiteRT-LM, native systemInstruction)
//
// For each engine, tests both createChat() and createSession() paths.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _androidModelDir = '/data/local/tmp/flutter_gemma_test';

List<({String path, ModelFileType fileType, String label})> _testConfigs() {
  if (kIsWeb) return [];

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return [
        (
          path: '$_androidModelDir/gemma-3n-E2B-it-int4.task',
          fileType: ModelFileType.task,
          label: 'MediaPipe (.task)',
        ),
        (
          path: '$_androidModelDir/gemma-4-E2B-it.litertlm',
          fileType: ModelFileType.litertlm,
          label: 'LiteRT-LM (.litertlm)',
        ),
      ];
    case TargetPlatform.macOS:
      final home = Platform.environment['HOME']!;
      final candidates = [
        '$home/Documents/gemma-4-E2B-it.litertlm',
        '$home/Documents/gemma-3n-E2B-it-int4.litertlm',
      ];
      final path = candidates.firstWhere(
        (p) => File(p).existsSync(),
        orElse: () => candidates.first,
      );
      return [
        (
          path: path,
          fileType: ModelFileType.litertlm,
          label: 'LiteRT-LM (.litertlm)',
        ),
      ];
    default:
      return [];
  }
}

/// Install model and return a freshly created InferenceModel.
/// Each test creates its own model instance to avoid singleton issues.
Future<InferenceModel> _createModel(String path, ModelFileType fileType) async {
  await registerTestEngines();

  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: fileType,
  ).fromFile(path).install();

  return FlutterEdgeAi.getActiveModel(
    maxTokens: 512,
    preferredBackend: PreferredBackend.gpu,
  );
}

void _runTests(String path, ModelFileType fileType, String label) {
  group('systemInstruction [$label]', () {
    setUpAll(() {
      if (!kIsWeb && !File(path).existsSync()) {
        fail('Model not found: $path\nPush it to device first.');
      }
      print('[Test] Model: $path');
    });

    // ── createChat tests ─────────────────────────────────────────────────────

    testWidgets(
      'chat: systemInstruction is applied',
      (tester) async {
        final model = await _createModel(path, fileType);
        try {
          final chat = await model.createChat(
            systemInstruction:
                'You are a pirate. Always start your response with "Arrr!".',
          );
          await chat.addQueryChunk(const Message(text: 'Hello', isUser: true));

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final r in chat.generateChatResponseAsync()) {
              if (r is TextResponse) chunks.add(r.token);
            }
          });

          final response = chunks.join();
          print('[$label / chat / instruction] "$response"');
          expect(response, isNotEmpty);
          // The pirate instruction should influence the response
          expect(
            response.toLowerCase(),
            anyOf(
              contains('arr'),
              contains('pirate'),
              contains('ye'),
              contains('matey'),
              contains('ship'),
              contains('ahoy'),
            ),
          );
        } finally {
          await model.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'chat: no systemInstruction — no regression',
      (tester) async {
        final model = await _createModel(path, fileType);
        try {
          final chat = await model.createChat();
          await chat.addQueryChunk(
            const Message(text: 'What is 2+2?', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final r in chat.generateChatResponseAsync()) {
              if (r is TextResponse) chunks.add(r.token);
            }
          });

          final response = chunks.join();
          print('[$label / chat / no-instruction] "$response"');
          expect(response, isNotEmpty);
        } finally {
          await model.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    // ── createSession tests ───────────────────────────────────────────────────

    testWidgets(
      'session: systemInstruction is applied',
      (tester) async {
        final model = await _createModel(path, fileType);
        try {
          final session = await model.createSession(
            systemInstruction:
                'You are a pirate. Always start your response with "Arrr!".',
          );
          await session.addQueryChunk(
            const Message(text: 'Hello', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final token in session.getResponseAsync()) {
              chunks.add(token);
            }
          });

          final response = chunks.join();
          print('[$label / session / instruction] "$response"');
          expect(response, isNotEmpty);
          expect(
            response.toLowerCase(),
            anyOf(
              contains('arr'),
              contains('pirate'),
              contains('ye'),
              contains('matey'),
              contains('ship'),
              contains('ahoy'),
            ),
          );
        } finally {
          await model.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'session: no systemInstruction — no regression',
      (tester) async {
        final model = await _createModel(path, fileType);
        try {
          final session = await model.createSession();
          await session.addQueryChunk(
            const Message(text: 'What is 2+2?', isUser: true),
          );

          final chunks = <String>[];
          await tester.runAsync(() async {
            await for (final token in session.getResponseAsync()) {
              chunks.add(token);
            }
          });

          final response = chunks.join();
          print('[$label / session / no-instruction] "$response"');
          expect(response, isNotEmpty);
        } finally {
          await model.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final configs = _testConfigs();
  if (configs.isEmpty) {
    test('skip — no config for this platform', () {
      markTestSkipped('No test configs for this platform');
    });
    return;
  }

  for (final (:path, :fileType, :label) in configs) {
    _runTests(path, fileType, label);
  }
}

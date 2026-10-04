// Integration test: Sequential inference with .litertlm models
// Reproduces issue #209 — SIGSEGV crash on second sendMessage
//
// Prerequisites:
//   adb push /path/to/gemma-4-E2B-it.litertlm /data/local/tmp/flutter_gemma_test/
//   adb push /path/to/Qwen3-0.6B.litertlm /data/local/tmp/flutter_gemma_test/
//
// Run:
//   cd example
//   flutter test integration_test/sequential_litertlm_test.dart -d <device>

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _deviceDir = '/data/local/tmp/flutter_gemma_test';

const _models = <({String path, String name, ModelType modelType})>[
  (
    path: '$_deviceDir/gemma-3n-E2B-it-int4.litertlm',
    name: 'Gemma 3n E2B',
    modelType: ModelType.gemmaIt,
  ),
  (
    path: '$_deviceDir/gemma-4-E2B-it.litertlm',
    name: 'Gemma 4 E2B',
    modelType: ModelType.gemmaIt,
  ),
  (
    path: '$_deviceDir/Qwen3-0.6B.litertlm',
    name: 'Qwen3 0.6B',
    modelType: ModelType.qwen3,
  ),
];

Future<InferenceModel> _installAndLoad(String path, ModelType modelType) async {
  await registerTestEngines();

  await FlutterEdgeAi.installModel(
    modelType: modelType,
    fileType: ModelFileType.litertlm,
  ).fromFile(path).install();

  return FlutterEdgeAi.getActiveModel(
    maxTokens: 2048,
    preferredBackend: PreferredBackend.gpu,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  for (final (:path, :name, :modelType) in _models) {
    group('Sequential inference [$name]', () {
      setUpAll(() {
        if (!Platform.isAndroid) {
          fail('Test requires Android with .litertlm models');
        }
        if (!File(path).existsSync()) {
          fail('Model not found: $path\nPush it first: adb push <model> $path');
        }
      });

      // --- Test 1: Two sequential queries on same chat (issue #209 core repro) ---
      testWidgets(
        'two sequential queries on same chat',
        (tester) async {
          final model = await _installAndLoad(path, modelType);
          try {
            final chat = await model.createChat(modelType: modelType);

            // First query — should work
            await chat.addQueryChunk(
              const Message(
                text: 'What is 2+2? Answer with just the number.',
                isUser: true,
              ),
            );
            final r1 = await chat.generateChatResponse();
            expect(r1, isA<TextResponse>());
            final text1 = (r1 as TextResponse).token;
            print('[$name] First response: "$text1"');
            expect(text1, isNotEmpty);

            // Second query — crashes with SIGSEGV in issue #209
            await chat.addQueryChunk(
              const Message(
                text: 'What is 3+3? Answer with just the number.',
                isUser: true,
              ),
            );
            final r2 = await chat.generateChatResponse();
            expect(r2, isA<TextResponse>());
            final text2 = (r2 as TextResponse).token;
            print('[$name] Second response: "$text2"');
            expect(text2, isNotEmpty);
          } finally {
            await model.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );

      // --- Test 2: Three sequential queries (longer conversation) ---
      testWidgets(
        'three sequential queries on same chat',
        (tester) async {
          final model = await _installAndLoad(path, modelType);
          try {
            final chat = await model.createChat(modelType: modelType);

            for (var i = 1; i <= 3; i++) {
              await chat.addQueryChunk(
                Message(
                  text: 'What is ${i}+${i}? Answer briefly.',
                  isUser: true,
                ),
              );
              final r = await chat.generateChatResponse();
              expect(r, isA<TextResponse>());
              final text = (r as TextResponse).token;
              print('[$name] Query $i response: "$text"');
              expect(text, isNotEmpty);
            }
          } finally {
            await model.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 15)),
      );

      // --- Test 3: Streaming sequential queries ---
      testWidgets(
        'two sequential streaming queries on same chat',
        (tester) async {
          final model = await _installAndLoad(path, modelType);
          try {
            final chat = await model.createChat(modelType: modelType);

            // First streaming query
            await chat.addQueryChunk(
              const Message(text: 'Say hello in one word.', isUser: true),
            );
            final chunks1 = <String>[];
            await tester.runAsync(() async {
              await for (final r in chat.generateChatResponseAsync()) {
                if (r is TextResponse) chunks1.add(r.token);
              }
            });
            final text1 = chunks1.join();
            print('[$name] First streaming response: "$text1"');
            expect(text1, isNotEmpty);

            // Second streaming query — issue #209 crash point
            await chat.addQueryChunk(
              const Message(text: 'Say goodbye in one word.', isUser: true),
            );
            final chunks2 = <String>[];
            await tester.runAsync(() async {
              await for (final r in chat.generateChatResponseAsync()) {
                if (r is TextResponse) chunks2.add(r.token);
              }
            });
            final text2 = chunks2.join();
            print('[$name] Second streaming response: "$text2"');
            expect(text2, isNotEmpty);
          } finally {
            await model.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );

      // --- Test 4: New chat per query (workaround test) ---
      testWidgets('new chat per query works', (tester) async {
        final model = await _installAndLoad(path, modelType);
        try {
          for (var i = 1; i <= 2; i++) {
            final chat = await model.createChat(modelType: modelType);
            await chat.addQueryChunk(
              Message(text: 'What is ${i * 10}? Answer briefly.', isUser: true),
            );
            final r = await chat.generateChatResponse();
            expect(r, isA<TextResponse>());
            final text = (r as TextResponse).token;
            print('[$name] New chat #$i response: "$text"');
            expect(text, isNotEmpty);
          }
        } finally {
          await model.close();
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    });
  }
}

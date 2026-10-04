// Integration test: iOS MediaPipe 0.10.33 features.
// Tests: text inference, vision, cancel generation.
// Model: Gemma 3n E2B .task (2.9GB)
//
// Usage:
//   1. flutter test integration_test/ios_mediapipe_033_test.dart -d <device_id>
//   2. Test prints Documents path and waits 5 min for model file
//   3. Copy model via: xcrun devicectl device copy to \
//        --device <udid> --source ~/.cache/flutter_gemma/test_models/gemma-3n-E2B-it-int4.task \
//        --destination Documents/ --domain-type appDataContainer \
//        --domain-identifier <bundle_id>

import 'dart:io' show File, Platform;
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:path_provider/path_provider.dart';

import 'inference_test_helpers.dart';

const _modelFilename = 'gemma-3n-E2B-it-int4.task';

Future<String> _modelPath() async {
  if (Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_modelFilename';
  }
  return '/data/local/tmp/flutter_gemma_test/$_modelFilename';
}

Future<void> _waitForModel(String path) async {
  final file = File(path);
  if (await file.exists()) {
    print('[Wait] Model already exists');
    return;
  }

  print('');
  print('========================================');
  print('WAITING FOR MODEL FILE');
  print('Path: $path');
  print('');
  print('Copy model now using devicectl or Finder');
  print('Timeout: 5 minutes');
  print('========================================');
  print('');

  const timeout = Duration(minutes: 5);
  const poll = Duration(seconds: 5);
  final deadline = DateTime.now().add(timeout);

  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      final size = await file.length();
      print(
        '[Wait] Model found! Size: ${(size / 1024 / 1024).toStringAsFixed(0)} MB',
      );
      return;
    }
    await Future.delayed(poll);
  }

  throw Exception('Model file not found after $timeout: $path');
}

Future<Uint8List> _loadTestImage() async {
  final data = await rootBundle.load('assets/test/test_image.jpg');
  return data.buffer.asUint8List();
}

void main() {
  initIntegrationTest();

  testWidgets(
    'iOS 0.10.33: text + vision + cancel',
    (tester) async {
      await registerTestEngines();

      // Wait for model file to appear in Documents
      final path = await _modelPath();
      await _waitForModel(path);

      // Install from local file
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemmaIt,
        fileType: ModelFileType.task,
      ).fromFile(path).install();
      print('[Test] Model installed');

      // --- 1. Text inference ---
      print('\n=== 1. TEXT INFERENCE ===');
      var model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      try {
        final chat = await model.createChat(modelType: ModelType.gemmaIt);
        await chat.addQueryChunk(
          const Message(text: 'What is 2+2? Answer briefly.', isUser: true),
        );

        final response = await chat.generateChatResponse();
        expect(response, isA<TextResponse>());
        final text = (response as TextResponse).token;
        print(
          '[Text] Response: "${text.length > 150 ? text.substring(0, 150) : text}"',
        );
        expect(text, isNotEmpty);
        print('[Text] PASSED');
      } finally {
        await model.close();
      }

      // --- 2. Vision ---
      print('\n=== 2. VISION ===');
      final imageBytes = await _loadTestImage();
      print('[Vision] Image: ${imageBytes.length} bytes');

      model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 4096,
        preferredBackend: PreferredBackend.gpu,
        supportImage: true,
        maxNumImages: 1,
      );
      try {
        final chat = await model.createChat(
          modelType: ModelType.gemmaIt,
          supportImage: true,
        );
        await chat.addQueryChunk(
          Message.withImage(
            text: 'Describe this image briefly.',
            imageBytes: imageBytes,
            isUser: true,
          ),
        );

        final response = await chat.generateChatResponse();
        expect(response, isA<TextResponse>());
        final text = (response as TextResponse).token;
        print(
          '[Vision] Response: "${text.length > 150 ? text.substring(0, 150) : text}"',
        );
        expect(text, isNotEmpty);
        print('[Vision] PASSED');
      } finally {
        await model.close();
      }

      // --- 3. Cancel generation ---
      print('\n=== 3. CANCEL GENERATION ===');
      model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 512,
        preferredBackend: PreferredBackend.gpu,
      );
      try {
        final chat = await model.createChat(modelType: ModelType.gemmaIt);
        await chat.addQueryChunk(
          const Message(
            text: 'Write a very long story about space exploration',
            isUser: true,
          ),
        );

        final chunks = <String>[];
        var cancelled = false;

        try {
          await for (final response in chat.generateChatResponseAsync()) {
            if (response is TextResponse) {
              chunks.add(response.token);
              if (chunks.length <= 3) {
                print('[Cancel] Chunk ${chunks.length}: "${response.token}"');
              }
              if (chunks.length >= 3 && !cancelled) {
                print('[Cancel] Stopping after ${chunks.length} chunks...');
                await chat.stopGeneration();
                cancelled = true;
              }
            }
          }
          print('[Cancel] Stream ended gracefully.');
        } on PlatformException catch (e) {
          expect(cancelled, isTrue);
          print('[Cancel] Cancelled with: ${e.message}');
        }

        print('[Cancel] Total chunks: ${chunks.length}');
        expect(chunks.length, greaterThanOrEqualTo(3));
        print('[Cancel] PASSED');
      } finally {
        await model.close();
      }

      print('\n=== ALL TESTS PASSED ===');
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

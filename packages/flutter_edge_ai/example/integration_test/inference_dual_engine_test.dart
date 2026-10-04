// Integration test: Android dual engine (MediaPipe + LiteRT-LM).
// Run: flutter test integration_test/inference_dual_engine_test.dart -d <android_device>
// Skipped on non-Android platforms.
//
// Prerequisites: push models to device via adb:
//   ./scripts/prepare_test_models.sh [device_id]
//   adb push functiongemma-270M-it.litertlm /data/local/tmp/flutter_gemma_test/

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

const _deviceModelDir = '/data/local/tmp/flutter_gemma_test';
const _taskPath = '$_deviceModelDir/functiongemma-270M-it.task';
const _litertlmPath = '$_deviceModelDir/functiongemma-270M-it.litertlm';

void main() {
  initIntegrationTest();

  testWidgets(
    'Inference: Android dual engine MediaPipe + LiteRT-LM',
    skip: !_isAndroid,
    (tester) async {
      await registerTestEngines();

      // --- Engine 1: MediaPipe (.task) ---
      print('[DualEngine] Testing MediaPipe (.task)...');
      await FlutterEdgeAi.installModel(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.task,
      ).fromFile(_taskPath).install();

      var model = await createTestModel();
      try {
        final chat1 = await createTestChat(model);
        await chat1.addQueryChunk(
          const Message(text: 'Say hello', isUser: true),
        );
        final response1 = await chat1.generateChatResponse();
        expect(response1, isA<TextResponse>());
        final text1 = (response1 as TextResponse).token;
        print(
          '[DualEngine] MediaPipe response: "${text1.length > 80 ? text1.substring(0, 80) : text1}"',
        );
        expect(text1, isNotEmpty);
      } finally {
        await model.close();
      }

      // --- Engine 2: LiteRT-LM (.litertlm) ---
      print('[DualEngine] Testing LiteRT-LM (.litertlm)...');
      await FlutterEdgeAi.installModel(
        modelType: ModelType.functionGemma,
        fileType: ModelFileType.task,
      ).fromFile(_litertlmPath).install();

      model = await createTestModel();
      try {
        final chat2 = await createTestChat(model);
        await chat2.addQueryChunk(
          const Message(text: 'Say hello', isUser: true),
        );
        final response2 = await chat2.generateChatResponse();
        expect(response2, isA<TextResponse>());
        final text2 = (response2 as TextResponse).token;
        print(
          '[DualEngine] LiteRT-LM response: "${text2.length > 80 ? text2.substring(0, 80) : text2}"',
        );
        expect(text2, isNotEmpty);
      } finally {
        await model.close();
      }

      print('[DualEngine] Both engines work on Android!');
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

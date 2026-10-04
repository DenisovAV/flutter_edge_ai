// Integration test: multimodal inference (vision + audio) with Gemma 3 Nano E2B.
// Run: flutter test integration_test/inference_multimodal_test.dart -d <device>
//
// Prerequisites: push model to device via adb:
//   ./scripts/prepare_test_models.sh [device_id]
//
// Vision: all platforms
// Audio: LiteRT-LM only — skipped here (.task only in test models)

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

const _deviceModelDir = '/data/local/tmp/flutter_gemma_test';
const _gemma3nPath = '$_deviceModelDir/gemma-3n-E2B-it-int4.task';

/// Load test image from bundled assets.
Future<Uint8List> _loadTestImage() async {
  final data = await rootBundle.load('assets/test/test_image.jpg');
  return data.buffer.asUint8List();
}

/// Install Gemma 3n model from device file.
Future<void> _installMultimodalModel() async {
  print('[Multimodal] Installing from file: $_gemma3nPath');

  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
  ).fromFile(_gemma3nPath).install();

  print('[Multimodal] Model installed');
}

void main() {
  initIntegrationTest();

  testWidgets('Multimodal: vision', (tester) async {
    await registerTestEngines();
    await _installMultimodalModel();

    final imageBytes = await _loadTestImage();
    print('[Vision] Image loaded: ${imageBytes.length} bytes');

    final model = await FlutterEdgeAi.getActiveModel(
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
          text: 'What do you see in this image? Describe briefly.',
          imageBytes: imageBytes,
          isUser: true,
        ),
      );

      final response = await chat.generateChatResponse();
      expect(response, isA<TextResponse>());
      final text = (response as TextResponse).token;
      print(
        '[Vision] Response: '
        '"${text.length > 150 ? text.substring(0, 150) : text}"',
      );
      expect(text, isNotEmpty, reason: 'Vision response should be non-empty');
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets(
    'Multimodal: audio (requires LiteRT-LM)',
    skip: true, // .litertlm not in test models; enable when available
    (tester) async {},
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

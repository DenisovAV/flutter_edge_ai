// Integration test: .litertlm format on iOS via MediaPipe.
// Tests whether MediaPipe 0.10.33 can load .litertlm models on iOS.
// Model: Gemma 3n E2B .litertlm (3.1GB, requires HF token)
// Run: flutter test integration_test/ios_litertlm_test.dart -d <device_or_sim> --dart-define=HF_TOKEN=...

import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

import 'inference_test_helpers.dart';

const _litertlmUrl =
    'https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/resolve/main/gemma-3n-E2B-it-int4.litertlm';
const _hfToken = String.fromEnvironment('HF_TOKEN');

Future<Uint8List> _loadTestImage() async {
  final data = await rootBundle.load('assets/test/test_image.jpg');
  return data.buffer.asUint8List();
}

Future<Uint8List> _loadTestAudio() async {
  final data = await rootBundle.load('assets/test/test_audio.wav');
  return data.buffer.asUint8List();
}

void main() {
  initIntegrationTest();

  // --- 1. Text inference with .litertlm ---
  testWidgets('iOS litertlm: text inference', (tester) async {
    await registerTestEngines();

    await FlutterEdgeAi.installModel(
          modelType: ModelType.gemmaIt,
          fileType: ModelFileType.litertlm,
        )
        .fromNetwork(_litertlmUrl, token: _hfToken)
        .withProgress((p) => print('[Download] $p%'))
        .install();

    final model = await FlutterEdgeAi.getActiveModel(
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
        '[Text/litertlm] Response: "${text.length > 150 ? text.substring(0, 150) : text}"',
      );
      expect(text, isNotEmpty);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 20)));

  // --- 2. Vision with .litertlm ---
  testWidgets('iOS litertlm: vision', (tester) async {
    await registerTestEngines();

    final imageBytes = await _loadTestImage();
    print('[Vision/litertlm] Image: ${imageBytes.length} bytes');

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
          text: 'Describe this image briefly.',
          imageBytes: imageBytes,
          isUser: true,
        ),
      );

      final response = await chat.generateChatResponse();
      expect(response, isA<TextResponse>());
      final text = (response as TextResponse).token;
      print(
        '[Vision/litertlm] Response: "${text.length > 150 ? text.substring(0, 150) : text}"',
      );
      expect(text, isNotEmpty);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  // --- 3. Audio with .litertlm ---
  testWidgets('iOS litertlm: audio', (tester) async {
    await registerTestEngines();

    final audioBytes = await _loadTestAudio();
    print('[Audio/litertlm] Audio: ${audioBytes.length} bytes');

    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: PreferredBackend.gpu,
      supportAudio: true,
    );
    try {
      final chat = await model.createChat(
        modelType: ModelType.gemmaIt,
        supportAudio: true,
      );
      await chat.addQueryChunk(
        Message.withAudio(
          text: 'What do you hear in this audio?',
          audioBytes: audioBytes,
          isUser: true,
        ),
      );

      final response = await chat.generateChatResponse();
      expect(response, isA<TextResponse>());
      final text = (response as TextResponse).token;
      print(
        '[Audio/litertlm] Response: "${text.length > 150 ? text.substring(0, 150) : text}"',
      );
      expect(text, isNotEmpty);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

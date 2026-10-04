/// FastVLM-0.5B vision smoke — our existing desktop VLM, re-verified on the
/// v0.14.0 runtime. Installs from the network in the test body (macOS sandbox
/// can't read the external Documents path). Run with `--timeout none`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/FastVLM-0.5B/resolve/main/FastVLM-0.5B.litertlm';

InferenceModel? _model;

Future<Uint8List> _testImage() async {
  final b = await rootBundle.load('assets/test/test_image.jpg');
  return b.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    print('Platform: ${Platform.operatingSystem}');
  });

  tearDownAll(() async {
    await _model?.close();
    _model = null;
  });

  testWidgets(
    'FastVLM install + image + text (GPU)',
    (t) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_url).install();
      final image = await _testImage();
      _model = await FlutterEdgeAi.getActiveModel(
        maxTokens: 2048,
        preferredBackend: PreferredBackend.gpu,
        supportImage: true,
        maxNumImages: 1,
      );
      final session = await _model!.createSession(
        temperature: 0.7,
        topK: 40,
        enableVisionModality: true,
      );
      await session.addQueryChunk(
        Message(
          text: 'Describe this image in one short sentence.',
          isUser: true,
          imageBytes: image,
        ),
      );
      final chunks = <String>[];
      await for (final c in session.getResponseAsync()) {
        chunks.add(c);
      }
      await session.close();
      final r = chunks.join();
      print('[FastVLM] $r');
      expect(r.trim(), isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

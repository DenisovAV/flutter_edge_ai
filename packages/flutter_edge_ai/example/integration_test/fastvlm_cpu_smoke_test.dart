/// FastVLM-0.5B CPU characterization for #268 / upstream LiteRT-LM #1829.
/// Runs text-only and image+text on the CPU backend to see whether the broken
/// decode (raw special tokens / empty output) is GPU-specific or general.
/// Run with `--timeout none`.
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

Future<String> _chat(String prompt, {Uint8List? image}) async {
  final session = await _model!.createSession(
    temperature: 0.7,
    topK: 40,
    enableVisionModality: image != null,
  );
  await session.addQueryChunk(
    Message(text: prompt, isUser: true, imageBytes: image),
  );
  final chunks = <String>[];
  await for (final c in session.getResponseAsync()) {
    chunks.add(c);
  }
  await session.close();
  return chunks.join();
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

  testWidgets('FastVLM CPU: text-only + image', (t) async {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(_url).install();
    _model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 2048,
      preferredBackend: PreferredBackend.cpu,
      supportImage: true,
      maxNumImages: 1,
    );
    final textOnly = await _chat('Say hi in one word.');
    print('[FastVLM CPU text] len=${textOnly.length} :: $textOnly');
    final withImage = await _chat(
      'Describe this image in one short sentence.',
      image: await _testImage(),
    );
    print('[FastVLM CPU image] len=${withImage.length} :: $withImage');
    // Non-empty is a weak check; the print output is what we inspect for
    // raw <start_of_*>/<end_of_turn> tokens vs real text.
    expect(textOnly.isNotEmpty || withImage.isNotEmpty, isTrue);
  }, timeout: const Timeout(Duration(minutes: 30)));
}

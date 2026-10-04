/// Smoke test for the litert-community models added for v0.14.0 coverage:
///   - SmolLM3-3B          (text)
///   - Phi-4-mini-reasoning (text + thinking)
///   - Qwen2-VL-2B          (vision — image + text)
///
/// Each model is loaded from a locally-cached `.litertlm` file (place it in the
/// platform models dir — see [_localPath]) and exercised with a single
/// inference. The goal is to confirm the v0.14.0 LiteRT-LM runtime drives
/// non-Gemma architectures end-to-end (load → session → stream), not to grade
/// output quality.
///
/// Model dirs (same convention as litertlm_ffi_test.dart):
///   macOS:   ~/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/
///   Linux:   ~/models/
///   Android: /data/local/tmp/flutter_gemma_test/
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

String get _androidDir => '/data/local/tmp/flutter_gemma_test';
String get _macosDir =>
    '${Platform.environment['HOME']}/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents';
String get _linuxDir => '${Platform.environment['HOME']}/models';
String get _windowsDir => '${Platform.environment['USERPROFILE']}\\models';

String? _localPath(String filename) {
  if (Platform.isAndroid) return '$_androidDir/$filename';
  if (Platform.isMacOS) return '$_macosDir/$filename';
  if (Platform.isLinux) return '$_linuxDir/$filename';
  if (Platform.isWindows) return '$_windowsDir\\$filename';
  return null;
}

Future<void> _install({
  required String? localPath,
  required String networkUrl,
}) async {
  if (localPath != null && File(localPath).existsSync()) {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.litertlm,
    ).fromFile(localPath).install();
  } else {
    await FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.litertlm,
    ).fromNetwork(networkUrl).install();
  }
}

InferenceModel? _model;

Future<InferenceModel> _open({
  bool supportImage = false,
  int maxTokens = 4096,
}) async {
  _model = await FlutterEdgeAi.getActiveModel(
    maxTokens: maxTokens,
    preferredBackend: PreferredBackend.gpu,
    supportImage: supportImage,
    maxNumImages: supportImage ? 1 : null,
  );
  return _model!;
}

Future<void> _close() async {
  await _model?.close();
  _model = null;
}

Future<String> _chat(
  String prompt, {
  bool supportImage = false,
  bool enableThinking = false,
  Uint8List? image,
}) async {
  final session = await _model!.createSession(
    temperature: 0.7,
    topK: 40,
    enableVisionModality: supportImage,
    enableThinking: enableThinking,
  );
  await session.addQueryChunk(
    Message(text: prompt, isUser: true, imageBytes: image),
  );
  final chunks = <String>[];
  await for (final chunk in session.getResponseAsync()) {
    chunks.add(chunk);
  }
  await session.close();
  return chunks.join();
}

Future<Uint8List> _loadTestImage() async {
  // Prefer the on-disk test image next to the models; fall back to a bundled asset.
  for (final p in [
    if (Platform.isMacOS) '$_macosDir/test_image.png',
    if (Platform.isLinux) '$_linuxDir/test_image.png',
    if (Platform.isAndroid) '$_androidDir/test_image.png',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f.readAsBytes();
  }
  final bytes = await rootBundle.load('assets/test_image.png');
  return bytes.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    print('Platform: ${Platform.operatingSystem}');
  });

  group('SmolLM3-3B (text)', () {
    setUpAll(() async {
      await _install(
        localPath: _localPath('SmolLM3-3B_q4_block32_ekv4096.litertlm'),
        networkUrl:
            'https://huggingface.co/litert-community/SmolLM3-3B/resolve/main/SmolLM3-3B_q4_block32_ekv4096.litertlm',
      );
      await _open();
    });
    tearDownAll(_close);

    testWidgets('text generation', (t) async {
      final r = await _chat('Name three primary colors.');
      print('[SmolLM3] $r');
      expect(r.trim(), isNotEmpty);
    });
  });

  group('Phi-4-mini-reasoning (thinking)', () {
    setUpAll(() async {
      await _install(
        localPath: _localPath('Phi-4-mini-reasoning.litertlm'),
        networkUrl:
            'https://huggingface.co/litert-community/Phi-4-mini-reasoning/resolve/main/model.litertlm',
      );
      await _open();
    });
    tearDownAll(_close);

    testWidgets('reasoning generation', (t) async {
      final r = await _chat(
        'If a train travels 60 km in 40 minutes, what is its speed in km/h?',
        enableThinking: true,
      );
      print('[Phi-4-reasoning] $r');
      expect(r.trim(), isNotEmpty);
    });
  });

  group('Qwen2-VL-2B (vision)', () {
    setUpAll(() async {
      await _install(
        localPath: _localPath('Qwen2-VL-2B.litertlm'),
        networkUrl:
            'https://huggingface.co/litert-community/Qwen2-VL-2B/resolve/main/Qwen2-VL-2B.litertlm',
      );
      await _open(supportImage: true);
    });
    tearDownAll(_close);

    testWidgets('image + text', (t) async {
      final image = await _loadTestImage();
      final r = await _chat(
        'Describe this image in one sentence.',
        supportImage: true,
        image: image,
      );
      print('[Qwen2-VL] $r');
      expect(r.trim(), isNotEmpty);
    });
  });
}

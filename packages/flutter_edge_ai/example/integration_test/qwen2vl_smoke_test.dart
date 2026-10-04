/// Qwen2-VL-2B multimodal (vision) smoke — verifies a non-Gemma VLM does
/// image+text on the v0.14.0 LiteRT-LM runtime. Loads a locally-cached
/// `.litertlm` (see [_localPath]) + a test image, and runs one GPU vision
/// generation.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _file = 'Qwen2-VL-2B.litertlm';
const _url =
    'https://huggingface.co/litert-community/Qwen2-VL-2B/resolve/main/Qwen2-VL-2B.litertlm';

String _docsDir() {
  if (Platform.isAndroid) return '/data/local/tmp/flutter_gemma_test';
  if (Platform.isMacOS) {
    return '${Platform.environment['HOME']}/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents';
  }
  if (Platform.isLinux) return '${Platform.environment['HOME']}/models';
  if (Platform.isIOS) return const String.fromEnvironment('IOS_TEST_DOCS_DIR');
  return '';
}

String? _localPath() {
  final d = _docsDir();
  if (d.isEmpty) return null;
  final p = '$d/$_file';
  return File(p).existsSync() ? p : null;
}

Future<Uint8List> _testImage() async {
  final p = '${_docsDir()}/test_image.png';
  if (_docsDir().isNotEmpty && File(p).existsSync())
    return File(p).readAsBytes();
  final b = await rootBundle.load('assets/test/test_image.jpg');
  return b.buffer.asUint8List();
}

InferenceModel? _model;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    final lp = _localPath();
    final installer = FlutterEdgeAi.installModel(
      modelType: ModelType.general,
      fileType: ModelFileType.litertlm,
    );
    if (lp != null) {
      await installer.fromFile(lp).install();
    } else {
      await installer.fromNetwork(_url).install();
    }
    print('Platform: ${Platform.operatingSystem}');
  });

  tearDownAll(() async {
    await _model?.close();
    _model = null;
  });

  testWidgets('Qwen2-VL image + text (GPU)', (t) async {
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
    print('[Qwen2-VL] $r');
    expect(r.trim(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

/// SmolLM3-3B single-model smoke — used for the v0.14.0 vs 0.13.1 differential
/// on Android (no macOS code-signing). Loads a locally-cached `.litertlm`
/// (Android: /data/local/tmp/flutter_gemma_test/) and runs one CPU + one GPU
/// generation.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _file = 'SmolLM3-3B_q4_block32_ekv4096.litertlm';
const _url =
    'https://huggingface.co/litert-community/SmolLM3-3B/resolve/main/SmolLM3-3B_q4_block32_ekv4096.litertlm';

String? _localPath() {
  if (Platform.isAndroid) return '/data/local/tmp/flutter_gemma_test/$_file';
  if (Platform.isMacOS) {
    return '${Platform.environment['HOME']}/Library/Containers/dev.flutterberlin.flutterGemmaExample55/Data/Documents/$_file';
  }
  if (Platform.isLinux) return '${Platform.environment['HOME']}/models/$_file';
  if (Platform.isIOS) {
    const d = String.fromEnvironment('IOS_TEST_DOCS_DIR');
    if (d.isNotEmpty && File('$d/$_file').existsSync()) return '$d/$_file';
    return null;
  }
  return null;
}

InferenceModel? _model;

Future<String> _run(PreferredBackend backend) async {
  _model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 2048,
    preferredBackend: backend,
  );
  final session = await _model!.createSession(temperature: 0.7, topK: 40);
  await session.addQueryChunk(
    const Message(text: 'Name three primary colors.', isUser: true),
  );
  final chunks = <String>[];
  await for (final c in session.getResponseAsync()) {
    chunks.add(c);
  }
  await session.close();
  await _model!.close();
  _model = null;
  return chunks.join();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await registerTestEngines();
    final lp = _localPath();
    if (lp != null && File(lp).existsSync()) {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromFile(lp).install();
    } else {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_url).install();
    }
    print('Platform: ${Platform.operatingSystem}');
  });

  testWidgets('SmolLM3 CPU text', (t) async {
    final r = await _run(PreferredBackend.cpu);
    print('[SmolLM3 CPU] $r');
    expect(r.trim(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('SmolLM3 GPU text', (t) async {
    final r = await _run(PreferredBackend.gpu);
    print('[SmolLM3 GPU] $r');
    expect(r.trim(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 15)));
}

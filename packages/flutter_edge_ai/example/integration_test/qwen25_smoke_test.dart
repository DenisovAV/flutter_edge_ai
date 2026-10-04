/// Qwen2.5-1.5B-Instruct smoke — the most-downloaded litert-community text
/// model, on the v0.14.0 runtime. Installs from the network in the test body
/// (macOS sandbox can't read the external Documents path). Run `--timeout none`.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm';

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
    print('Platform: ${Platform.operatingSystem}');
  });

  testWidgets(
    'Qwen2.5-1.5B install + text (CPU + GPU)',
    (t) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_url).install();
      final cpu = await _run(PreferredBackend.cpu);
      print('[Qwen2.5 CPU] $cpu');
      expect(cpu.trim(), isNotEmpty);
      final gpu = await _run(PreferredBackend.gpu);
      print('[Qwen2.5 GPU] $gpu');
      expect(gpu.trim(), isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

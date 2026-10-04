/// Phi-4-mini-reasoning smoke — verifies the reasoning (thinking) path of a
/// non-Gemma text model on the v0.14.0 LiteRT-LM runtime. The macOS app sandbox
/// can't read the external Documents path, so this installs from the network
/// (run with `--timeout none`; the model is ~2.8 GB).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _url =
    'https://huggingface.co/litert-community/Phi-4-mini-reasoning/resolve/main/model.litertlm';

InferenceModel? _model;

Future<String> _run(PreferredBackend backend) async {
  _model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 2048,
    preferredBackend: backend,
  );
  final session = await _model!.createSession(
    temperature: 0.7,
    topK: 40,
    enableThinking: true,
  );
  await session.addQueryChunk(
    const Message(
      text:
          'If a train travels 60 km in 40 minutes, what is its speed in km/h?',
      isUser: true,
    ),
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

  // Install + both backends in one test body so the ~2.8 GB in-app download is
  // bound by this Timeout, not the 12-min setUpAll cap (--timeout none does not
  // lift the setUpAll cap).
  testWidgets(
    'Phi-4 install + reasoning (CPU + GPU)',
    (t) async {
      await FlutterEdgeAi.installModel(
        modelType: ModelType.general,
        fileType: ModelFileType.litertlm,
      ).fromNetwork(_url).install();
      final cpu = await _run(PreferredBackend.cpu);
      print('[Phi-4 CPU] $cpu');
      expect(cpu.trim(), isNotEmpty);
      final gpu = await _run(PreferredBackend.gpu);
      print('[Phi-4 GPU] $gpu');
      expect(gpu.trim(), isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

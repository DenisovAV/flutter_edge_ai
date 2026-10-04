// Backend matrix for a single .litertlm bundle: run the SAME prompt through
// PreferredBackend.gpu and .cpu and print what each returns. Written to settle
// whether TranslateGemma's GPU problem is a load failure (it is not) or silent
// padding (it is) — see translategemma_gpu_probe_test.dart for the narrower
// "does the GPU path work at all" check.
//
// Stage a bundle first (macOS App Sandbox redirects $HOME, so the on-disk
// location is double-nested while the path below is what the app sees):
//   ~/Library/Containers/<id>/Data/Library/Containers/<id>/Data/Documents/
//
// Run (defaults to the int4 TranslateGemma bundle):
//   flutter test integration_test/translategemma_backend_matrix_test.dart -d macos
//
// Control — a bundle known to be correct on GPU, same code path:
//   ... -d macos --dart-define=TG_BUNDLE=gemma-4-E2B-it.litertlm \
//       --dart-define=TG_MODEL_TYPE=gemma4 \
//       --dart-define=TG_PROMPT='Translate to German: Good morning'
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// One bundle per run on purpose: two 2-4 GB loads in a single run is what the
// OOM killer takes out on a 16 GB machine.
//   --dart-define=TG_BUNDLE=translategemma-int8.litertlm
const _fileName = String.fromEnvironment(
  'TG_BUNDLE',
  defaultValue: 'translategemma-int4.litertlm',
);

// The control: run the SAME code against an ordinary .litertlm bundle. If a
// known-good model also comes back as padding on Metal, the fault is this
// stack or this machine, not the conversion under test.
const _modelTypeName = String.fromEnvironment(
  'TG_MODEL_TYPE',
  defaultValue: 'general',
);
const _prompt = String.fromEnvironment(
  'TG_PROMPT',
  defaultValue: '<src>en</src><dst>de</dst><text>Good morning</text>',
);

ModelType get _modelType =>
    ModelType.values.firstWhere((t) => t.name == _modelTypeName);

// Inside the sandbox $HOME is ALREADY the app container, so this single-nested
// path is what the double-nested on-disk staging location resolves to. Writing
// the double path here would nest a third time and silently find nothing.
String get _stagedPath {
  final home = Platform.environment['HOME'];
  const id = 'dev.flutterberlin.flutterGemmaExample55';
  return '$home/Library/Containers/$id/Data/Documents/$_fileName';
}

Future<String?> _probe(PreferredBackend backend) async {
  InferenceModel? model;
  InferenceModelSession? session;
  try {
    model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 1024,
      preferredBackend: backend,
    );
    session = await model.createSession();
    await session.addQueryChunk(
      const Message(text: _prompt, isUser: true),
    );
    final reply = await session.getResponse();
    final active = model.activeBackend;
    final pads = RegExp('<pad>').allMatches(reply).length;
    final visible = reply.replaceAll('<pad>', '').trim();
    print(
      '  [$backend] LOADED (active=$active) chars=${reply.length} '
      'pad-tokens=$pads visible="${visible.isEmpty ? "<nothing>" : visible}"',
    );
    return null;
  } catch (e) {
    print('  [$backend] FAILED: $e');
    return '$e';
  } finally {
    // The GPU arm is the one expected to misbehave, and a 2-4 GB model left
    // open here is what makes the CPU arm that follows fail for the wrong
    // reason — or get killed for memory before it reports anything.
    try {
      await session?.close();
    } catch (_) {}
    try {
      await model?.close();
    } catch (_) {}
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('TranslateGemma int4: GPU vs CPU', (tester) async {
    final staged = File(_stagedPath);
    if (!staged.existsSync()) {
      print('SKIP: no bundle staged at $_stagedPath');
      return;
    }
    print(
      'bundle: $_fileName '
      '${(staged.lengthSync() / 1e9).toStringAsFixed(2)} GB '
      'modelType=$_modelTypeName',
    );

    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
    await FlutterEdgeAi.installModel(
      modelType: _modelType,
      fileType: ModelFileType.litertlm,
    ).fromFile(_stagedPath).install();

    final gpuError = await _probe(PreferredBackend.gpu);
    final cpuError = await _probe(PreferredBackend.cpu);

    print('=== RESULT');
    print('  gpu: ${gpuError ?? "ok"}');
    print('  cpu: ${cpuError ?? "ok"}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}

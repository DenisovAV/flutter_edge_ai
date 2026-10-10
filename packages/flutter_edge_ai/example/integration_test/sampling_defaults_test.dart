// On-device: a session with no sampler set takes the sampler the `.litertlm`
// bundle ships, read through LiteRT-LM's model_info C API (#572). Before
// flutter_edge_ai 2.2 core always sent `topK: 1` and overrode it.
//
// Stage the models in the app documents dir (desktop/iOS) or
// /data/local/tmp/flutter_gemma_test/ (Android):
//   Qwen3-0.6B.litertlm       litert-community/Qwen3-0.6B (ships a sampler)
//   gemma-4-E2B-it.litertlm   litert-community/gemma-4-E2B-it-litert-lm (none)
//
// Run: flutter test integration_test/sampling_defaults_test.dart -d <device>
// CPU by default; --dart-define=TOOLS_BACKEND=gpu for the GPU backend.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_model_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _backendName = String.fromEnvironment(
  'TOOLS_BACKEND',
  defaultValue: 'cpu',
);

Future<FfiInferenceModel> _load(String file, ModelType modelType) async {
  await registerTestEngines();
  final path = await stagedModelPath(file);
  expect(path, isNotNull, reason: 'stage $file first');
  await FlutterEdgeAi.installModel(
    modelType: modelType,
    fileType: ModelFileType.litertlm,
  ).fromFile(path!).install();
  final model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.values.byName(_backendName),
  );
  return model as FfiInferenceModel;
}

/// libLiteRtLm, opened the way the engine opens it.
DynamicLibrary _liteRtLm() {
  if (Platform.isIOS) {
    return DynamicLibrary.open(
      '@executable_path/Frameworks/LiteRtLm.framework/LiteRtLm',
    );
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('LiteRtLm.framework/LiteRtLm');
  }
  if (Platform.isWindows) return DynamicLibrary.open('LiteRtLm.dll');
  return DynamicLibrary.open('libLiteRtLm.so');
}

Future<String> _reply(InferenceModel model) async {
  final chat = await model.createChat();
  await chat.addQueryChunk(
    const Message(text: 'Name one planet. One word.', isUser: true),
  );
  final reply = StringBuffer();
  await for (final r in chat.generateChatResponseAsync()) {
    if (r is TextResponse) reply.write(r.token);
  }
  return reply.toString();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Read without an engine: with native-v0.18.0-c this Qwen3 bundle does not
  // load ("piece must not include null character" from its tokenizer), and
  // the read does not need one.
  testWidgets('Qwen3: the bundle sampler is read', (tester) async {
    final path = await stagedModelPath('Qwen3-0.6B.litertlm');
    expect(path, isNotNull, reason: 'stage Qwen3-0.6B.litertlm first');
    final read = tryReadBundleSampler(_liteRtLm(), path!);
    expect(read.error, isNull);
    expect(read.sampler.topK, 20);
    expect(read.sampler.topP, closeTo(0.95, 1e-6));
    expect(read.sampler.temperature, closeTo(0.6, 1e-6));
  });

  testWidgets('Gemma 4: no bundle sampler, the family defaults apply', (
    tester,
  ) async {
    final model = await _load('gemma-4-E2B-it.litertlm', ModelType.gemma4);
    try {
      // Read, and found nothing: a failed read is empty too, so check both.
      expect(model.ffiClient.bundleSamplerError, isNull);
      expect(model.ffiClient.bundleSampler.isEmpty, isTrue);
      expect(await _reply(model), isNotEmpty);
    } finally {
      await model.close();
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

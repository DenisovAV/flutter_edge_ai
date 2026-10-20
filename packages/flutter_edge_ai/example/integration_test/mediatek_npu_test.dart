// MediaTek NPU on a real phone (`mediatek_npu: true`, which the example sets).
//
// 1. The device: LiteRT's MediaTek rule, which NeuroPilot adapters open in
//    this app's linker namespace (the open question on an OEM image), and
//    whether this build carries the dispatch. Needs no model.
// 2. A bundle compiled for this phone's SoC on the NPU, when one is staged in
//    /data/local/tmp/flutter_gemma_test/ and named by MTK_MODEL; skipped
//    without it.
// 3. An EmbeddingGemma 2 MediaTek bundle named by MTK_EG2: embeds on the NPU
//    when it is compiled for this phone's SoC, else is refused with the
//    reason (LiteRT's dispatch loaded, the engine refused the other SoC's
//    graph); skipped without it.
//
// No setUp/setUpAll: everything that can fail runs inside the test body.
//
// Run (DDP, see .claude/skills/ddp-device-test):
//   run_instrumented.sh mtk integration_test/mediatek_npu_test.dart \
//     MTK_MODEL=Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm MTK_MAX_TOKENS=1280
// ignore_for_file: avoid_print, implementation_imports
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/backend_preference.dart'
    show mediaTekDeviceRefusal, platformNpuProbes;
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart'
    show checkNpuStackInManifest;
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _model = String.fromEnvironment('MTK_MODEL');
const _maxTokens = int.fromEnvironment('MTK_MAX_TOKENS', defaultValue: 1280);
const _eg2 = String.fromEnvironment('MTK_EG2');

String? _prop(String key) {
  final r = Process.runSync('getprop', [key]);
  return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the device runs the MediaTek NPU and this app can open '
      'NeuroPilot', (tester) async {
    for (final key in [
      'ro.product.model',
      'ro.build.version.sdk',
      'ro.build.id',
      'ro.soc.manufacturer',
      'ro.soc.model',
    ]) {
      print('[mtk] $key=${_prop(key)}');
    }
    for (final lib in mediatekAndroidSystemLibs) {
      try {
        DynamicLibrary.open(lib);
        print('[mtk] opens: $lib');
      } on Object catch (e) {
        print('[mtk] does not open: $lib (${'$e'.split('\n').first})');
      }
    }
    final stack = await checkNpuStackInManifest(NpuVendor.mediatek);
    print('[mtk] stack bundled=${stack.bundled} ${stack.reason ?? ''}');
    final refusal = mediaTekDeviceRefusal(_prop);
    final probe = platformNpuProbes.androidMediaTekRuntime();
    print('[mtk] device rule: ${refusal ?? 'ok'}; probe: ${probe ?? 'ok'}');

    expect(stack.bundled, isTrue, reason: stack.reason);
    expect(refusal, isNull);
    expect(probe, isNull);
  });

  testWidgets('a bundle compiled for this SoC generates on the NPU', (
    tester,
  ) async {
    final path = await stagedModelPath(_model);
    expect(path, isNotNull, reason: 'stage $_model first');
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(backendFallback: false)],
    );
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(path!).install();

    final load = Stopwatch()..start();
    final model = await FlutterEdgeAi.getActiveModel(
      maxTokens: _maxTokens,
      preferredBackend: PreferredBackend.npu,
    );
    try {
      print(
        '[mtk] loaded on ${model.activeBackend} in '
        '${load.elapsedMilliseconds} ms',
      );
      expect(model.activeBackend, PreferredBackend.npu);

      final session = await model.createSession(maxOutputTokens: 48);
      try {
        await session.addQueryChunk(
          const Message(
            text: 'Name three colours of the rainbow.',
            isUser: true,
          ),
        );
        final sw = Stopwatch()..start();
        Duration? first;
        final out = StringBuffer();
        await for (final chunk in session.getResponseAsync()) {
          first ??= sw.elapsed;
          out.write(chunk);
        }
        final text = out.toString().trim();
        print(
          '[mtk] first token ${first?.inMilliseconds} ms, total '
          '${sw.elapsedMilliseconds} ms: $text',
        );
        expect(text, isNotEmpty);
      } finally {
        await session.close();
      }
    } finally {
      await model.close();
    }
  }, skip: _model.isEmpty);

  testWidgets(
    'an EmbeddingGemma 2 MediaTek bundle embeds on this SoC, or is refused '
    'for another',
    (tester) async {
      final path = await stagedModelPath(_eg2);
      expect(path, isNotNull, reason: 'stage $_eg2 first');
      await registerTestEngines();
      await FlutterEdgeAi.installEmbedder().modelFromFile(path!).install();
      final soc = (_prop('ro.soc.model') ?? '').toLowerCase();
      final same = _eg2.toLowerCase().contains(soc);
      final load = Stopwatch()..start();
      try {
        final model = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.npu,
        );
        print(
          '[mtk] eg2 loaded on ${model.activeBackend} in '
          '${load.elapsedMilliseconds} ms',
        );
        final sw = Stopwatch()..start();
        final v = await model.embed(
          EmbeddingInput.text('a red bicycle'),
          taskType: TaskType.retrievalQuery,
        );
        print('[mtk] eg2 embed ${sw.elapsedMilliseconds} ms, dim ${v.length}');
        expect(same, isTrue, reason: 'a bundle for another SoC loaded');
        expect(model.activeBackend, PreferredBackend.npu);
        await model.close();
      } on EmbeddingLoadException catch (e) {
        print('[mtk] eg2 refused after ${load.elapsedMilliseconds} ms: $e');
        expect(same, isFalse, reason: '$e');
      }
    },
    skip: _eg2.isEmpty,
  );
}

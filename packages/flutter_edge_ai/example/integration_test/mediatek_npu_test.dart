// MediaTek NPU on a real phone (`mediatek_npu: true`, which the example sets).
//
// 1. The device: LiteRT's MediaTek rule, which NeuroPilot adapters open in
//    this app's linker namespace (the open question on an OEM image), and
//    whether this build carries the dispatch. Needs no model.
// 2. A MediaTek LLM bundle staged in /data/local/tmp/flutter_gemma_test/ and
//    named by MTK_MODEL: generates on the NPU when it is compiled for this
//    phone's SoC, else is refused when the engine is created and nothing
//    else is tried (the reason is LiteRT-LM's; NeuroPilot rejecting the other
//    SoC's graph is in logcat, not in what the test asserts); skipped
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
//     MTK_MODEL=Gemma3-1B-IT_q4_ekv1280_mt6989.litertlm
// MTK_CONTEXT sets maxTokens (default 1280, what the Gemma 3 1B bundles are
// compiled for); run_instrumented.sh refuses a define named *TOKEN*.
// ignore_for_file: avoid_print
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
// ignore: implementation_imports — asks the MediaTek device rule and probe the engine asks
import 'package:flutter_edge_ai_litertlm/src/ffi/backend_preference.dart'
    show mediaTekDeviceRefusal, platformNpuProbes;
// ignore: implementation_imports — reads whether this build bundled the MediaTek dispatch
import 'package:flutter_edge_ai_litertlm/src/ffi/npu_stack_manifest.dart'
    show checkNpuStackInManifest;
// ignore: implementation_imports — the NeuroPilot libraries the probe lists
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _model = String.fromEnvironment('MTK_MODEL');
const _maxTokens = int.fromEnvironment('MTK_CONTEXT', defaultValue: 1280);
const _eg2 = String.fromEnvironment('MTK_EG2');

String? _prop(String key) {
  final r = Process.runSync('getprop', [key]);
  return r.exitCode == 0 ? '${r.stdout}'.trim() : null;
}

/// Whether [file] is compiled for this phone's SoC, from its name.
bool _forThisSoc(String file) {
  final soc = (_prop('ro.soc.model') ?? '').toLowerCase();
  expect(soc, isNotEmpty, reason: 'ro.soc.model is not readable');
  return file.toLowerCase().contains(soc);
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
    final stack = await checkNpuStackInManifest(NpuStack.mediatek);
    print('[mtk] stack bundled=${stack.bundled} ${stack.reason ?? ''}');
    final refusal = mediaTekDeviceRefusal(_prop);
    final probe = platformNpuProbes.androidMediaTekRuntime();
    print('[mtk] device rule: ${refusal ?? 'ok'}; probe: ${probe ?? 'ok'}');

    expect(stack.bundled, isTrue, reason: stack.reason);
    expect(refusal, isNull);
    expect(probe, isNull);
  });

  testWidgets('a MediaTek LLM bundle generates on the NPU on its SoC, or is '
      'refused at engine create on another', (tester) async {
    final path = await stagedModelPath(_model);
    expect(path, isNotNull, reason: 'stage $_model first');
    final same = _forThisSoc(_model);
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine(backendFallback: false)],
    );
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemmaIt,
      fileType: ModelFileType.litertlm,
    ).fromFile(path!).install();

    final load = Stopwatch()..start();
    final InferenceModel model;
    try {
      model = await FlutterEdgeAi.getActiveModel(
        maxTokens: _maxTokens,
        preferredBackend: PreferredBackend.npu,
      );
    } on BackendInitException catch (e) {
      print('[mtk] refused after ${load.elapsedMilliseconds} ms: $e');
      expect(same, isFalse, reason: '$e');
      // Refused at engine create with nothing else tried, not by a missing
      // stack, adapter or dispatch directory before it.
      expect('$e', contains('Failed to create engine on npu'));
      expect('$e', contains('compiled for the MediaTek'));
      return;
    }
    expect(same, isTrue, reason: 'a bundle for another SoC loaded');
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
      final same = _forThisSoc(_eg2);
      final load = Stopwatch()..start();
      final EmbeddingModel model;
      try {
        model = await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.npu,
        );
      } on EmbeddingLoadException catch (e) {
        print('[mtk] eg2 refused after ${load.elapsedMilliseconds} ms: $e');
        expect(same, isFalse, reason: '$e');
        // Refused at engine create, not by a missing stack, adapter or
        // dispatch directory before it.
        expect('$e', contains('could not create the embedding engine'));
        expect('$e', contains('on the MediaTek'));
        return;
      }
      try {
        print(
          '[mtk] eg2 loaded on ${model.activeBackend} in '
          '${load.elapsedMilliseconds} ms',
        );
        expect(same, isTrue, reason: 'a bundle for another SoC loaded');
        expect(model.activeBackend, PreferredBackend.npu);
        final sw = Stopwatch()..start();
        final v = await model.embed(
          EmbeddingInput.text('a red bicycle'),
          taskType: TaskType.retrievalQuery,
        );
        print('[mtk] eg2 embed ${sw.elapsedMilliseconds} ms, dim ${v.length}');
      } finally {
        await model.close();
      }
    },
    skip: _eg2.isEmpty,
  );
}

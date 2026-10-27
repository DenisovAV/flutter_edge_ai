// EmbeddingGemma 2 270m text on LiteRT-LM's GPU executor, where
// flutter_edge_ai_litertlm runs it: Windows x64 and Linux x64 (the WebGPU
// accelerator over DX12 / Vulkan). Skipped on every other host, where a `gpu`
// request still runs on CPU.
//
// What it holds the GPU to, against the same bundle on CPU and the golden
// (integration_test/goldens/eg2_text_golden.json, through its .dart twin):
// - `preferredBackend: gpu` loads with activeBackend gpu, 768-d unit vectors;
// - min cos >= 0.995 to the CPU vectors (measured 0.9969-0.9970 on Lunar Lake
//   and a Tesla T4, 2026-10-22) but < 0.9999 (FP16 activations: a run that
//   stayed on the CPU would match), and >= 0.97 to Sentence Transformers fp32;
// - every query ranks its document first;
// - a second gpu request and an automatic one reuse the GPU embedder;
// - images on the GPU are refused before anything is loaded, and the GPU
//   embedder keeps working;
// - GPU, then CPU, then GPU again in one process gives the first GPU vectors
//   back (cos >= 0.9999), and a GPU embedder closed and loaded again works;
// - a ~900-token text stays close to its CPU vector (the GPU runs FP16
//   activations by default);
// - with GPU_LLM_MODEL_FILE (a Gemma 4 E2B .litertlm) a GPU LLM and a GPU
//   embedder run in one process, the embedder loaded before and after the LLM.
// - the first GPU load writes ML Drift's weight and program caches by the end
//   of its probe embedding; the cache directory is listed after the cold load,
//   one embedding, close and a warm second load, with both load times.
// The backend is registered with requireWeightCache: true, so a CPU load that
// wrote no weight cache, or a GPU load that wrote neither ML Drift cache (or
// could not, its path past MAX_PATH), fails the run.
//
// Run: flutter test integration_test/embeddinggemma2_gpu_test.dart -d windows
// (or -d linux, under xvfb-run on a headless box). EG2_MODEL_FILE or
// EG2_MODEL_URL override the catalog download, as in embeddinggemma2_test.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'goldens/eg2_text_golden.dart';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');
const _llmFile = String.fromEnvironment('GPU_LLM_MODEL_FILE');

final _gpuHost =
    (Platform.isWindows && Abi.current() == Abi.windowsX64) ||
    (Platform.isLinux && Abi.current() == Abi.linuxX64);

bool _initialized = false;

/// Rule 6b: called first thing in every test body.
Future<void> _ensureEg2() async {
  if (!_initialized) {
    await FlutterEdgeAi.initialize(
      inferenceEngines: const [LiteRtLmEngine()],
      embeddingBackends: const [
        LiteRtEmbeddingBackend(requireWeightCache: true),
      ],
    );
    _initialized = true;
  }
  final builder = FlutterEdgeAi.installEmbedder();
  if (_fileOverride.isNotEmpty) {
    builder.modelFromFile(_fileOverride, filename: _eg2.filename);
  } else {
    builder.modelFromNetwork(
      _urlOverride.isEmpty ? _eg2.url : _urlOverride,
      filename: _eg2.filename,
    );
  }
  await builder.install();
}

typedef _Item = ({String id, String role, String text, List<double> st});

final List<_Item> _golden = [
  for (final item
      in ((jsonDecode(eg2TextGoldenJson) as Map)['items'] as List)
          .cast<Map<String, dynamic>>())
    (
      id: item['id'] as String,
      role: item['role'] as String,
      text: item['text'] as String,
      st: _f32(item['vector_st_fp32_f32le'] as String),
    ),
];

List<double> _f32(String encoded) {
  final bytes = ByteData.sublistView(base64.decode(encoded));
  return [
    for (var i = 0; i < bytes.lengthInBytes ~/ 4; i++)
      bytes.getFloat32(i * 4, Endian.little),
  ];
}

double _cos(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// Every file under the embedder cache root (`flutter_edge_ai/emb` in the app
/// cache directory) with its size: when ML Drift writes its GPU caches — at
/// create, at the first run, or at engine delete — is read from these lines
/// (the pass itself logs its directory after create and after the probe).
Future<void> _listCaches(String when) async {
  final root = Directory(
    '${(await getApplicationCacheDirectory()).path}'
    '${Platform.pathSeparator}flutter_edge_ai${Platform.pathSeparator}emb',
  );
  final files = root.existsSync()
      ? (root.listSync(recursive: true).whereType<File>().toList()
          ..sort((a, b) => a.path.compareTo(b.path)))
      : const <File>[];
  final lines = [
    for (final f in files)
      '  ${f.path.substring(root.path.length + 1)} ${f.lengthSync()} B',
  ];
  _cacheLog(
    'cache ${root.path} $when:${lines.isEmpty ? ' empty' : '\n${lines.join('\n')}'}',
  );
}

void _cacheLog(String line) => debugPrint('[eg2-gpu-cache] $line');

TaskType _taskFor(String role) =>
    role == 'query' ? TaskType.retrievalQuery : TaskType.retrievalDocument;

Future<Map<String, List<double>>> _embedGolden(EmbeddingModel model) async => {
  for (final item in _golden)
    item.id: await model.embed(
      EmbeddingInput.text(item.text),
      taskType: _taskFor(item.role),
    ),
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // First, so the cold load is this process's first GPU load of the bundle.
  testWidgets(
    'the GPU caches: written by the first load (requireWeightCache would '
    'refuse it otherwise), kept at close, and a warm second load',
    (tester) async {
      await _ensureEg2();
      // Nothing may hold the cache files open while they are deleted
      // (Windows): close whatever embedder is loaded.
      await (await FlutterEdgeAi.getActiveEmbedder()).close();
      final root = Directory(
        '${(await getApplicationCacheDirectory()).path}'
        '${Platform.pathSeparator}flutter_edge_ai${Platform.pathSeparator}emb',
      );
      if (root.existsSync()) root.deleteSync(recursive: true);
      await _listCaches('before the cold GPU load');

      final cold = Stopwatch()..start();
      final first = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      cold.stop();
      expect(first.activeBackend, PreferredBackend.gpu);
      await _listCaches('after the cold GPU load (create + probe)');
      List<String> mlDrift() => [
        for (final f in root.listSync(recursive: true).whereType<File>())
          if (f.path.contains('_mldrift_')) f.path.split(RegExp(r'[\\/]')).last,
      ]..sort();
      final afterLoad = mlDrift();
      await first.embed(
        EmbeddingInput.text(_golden.first.text),
        taskType: TaskType.retrievalQuery,
      );
      await _listCaches('after one embedding');
      await first.close();
      await _listCaches('after close (engine delete)');

      final warm = Stopwatch()..start();
      final second = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      warm.stop();
      expect(second.activeBackend, PreferredBackend.gpu);
      await _listCaches('after the warm GPU load');
      _cacheLog(
        'EG2 GPU on ${Abi.current()}: cold load ${cold.elapsedMilliseconds} '
        'ms, warm load ${warm.elapsedMilliseconds} ms; ML Drift files after '
        'the cold load: $afterLoad',
      );
      expect(
        afterLoad.where((n) => n.endsWith('_mldrift_weight_cache.bin')),
        hasLength(1),
      );
      expect(
        afterLoad.where((n) => n.endsWith('_mldrift_program_cache.bin')),
        hasLength(1),
      );
      final vector = await second.embed(
        EmbeddingInput.text(_golden.first.text),
        taskType: TaskType.retrievalQuery,
      );
      expect(vector, hasLength(768));
    },
    skip: !_gpuHost,
  );

  testWidgets(
    'gpu runs on the GPU, close to the CPU vectors, every query ranking its '
    'document first',
    (tester) async {
      await _ensureEg2();
      final cpuModel = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.cpu,
      );
      expect(cpuModel.activeBackend, PreferredBackend.cpu);
      final cpu = await _embedGolden(cpuModel);

      final load = Stopwatch()..start();
      final model = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      load.stop();
      expect(model.activeBackend, PreferredBackend.gpu);
      expect(model.dimension, 768);
      final gpu = await _embedGolden(model);

      var worstCpu = 1.0, worstSt = 1.0;
      for (final item in _golden) {
        final vector = gpu[item.id]!;
        expect(vector, hasLength(768));
        expect(vector.every((v) => v.isFinite), isTrue);
        final norm = math.sqrt(vector.fold(0.0, (s, v) => s + v * v));
        expect(norm, closeTo(1, 1e-3), reason: '${item.id} norm');
        worstCpu = math.min(worstCpu, _cos(vector, cpu[item.id]!));
        worstSt = math.min(worstSt, _cos(vector, item.st));
      }
      debugPrint(
        'EG2 GPU on ${Abi.current()}: load ${load.elapsedMilliseconds} ms, '
        'min cos to CPU $worstCpu, to ST fp32 $worstSt',
      );
      expect(worstCpu, greaterThanOrEqualTo(0.995));
      // FP16 activations: GPU vectors are close to the CPU ones but never
      // equal, so a run that silently stayed on the CPU fails here.
      expect(
        worstCpu,
        lessThan(0.9999),
        reason: 'GPU vectors identical to the CPU ones: not on the GPU',
      );
      expect(worstSt, greaterThanOrEqualTo(0.97));

      final pairs = _golden.where((item) => item.role == 'query').length;
      for (var i = 0; i < pairs; i++) {
        final scores = [
          for (var j = 0; j < pairs; j++) _cos(gpu['q$i']!, gpu['d$j']!),
        ];
        final best = scores.indexOf(scores.reduce(math.max));
        expect(best, i, reason: 'q$i ranks d$best first: $scores');
      }

      expect(
        await FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.gpu,
        ),
        same(model),
      );
      expect(await FlutterEdgeAi.getActiveEmbedder(), same(model));
    },
    skip: !_gpuHost,
  );

  testWidgets(
    'images on the GPU are refused before anything loads; the GPU embedder '
    'keeps working',
    (tester) async {
      await _ensureEg2();
      final model = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      expect(model.activeBackend, PreferredBackend.gpu);
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(
          preferredBackend: PreferredBackend.gpu,
          supportImage: true,
        ),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            contains('has no vision encoder'),
          ),
        ),
      );
      expect(model.isClosed, isFalse);
      final vector = await model.embed(
        EmbeddingInput.text('Still on the GPU.'),
        taskType: TaskType.retrievalQuery,
      );
      expect(vector, hasLength(768));
    },
    skip: !_gpuHost,
  );

  testWidgets(
    'GPU, CPU, GPU again: the same GPU vectors; closed and loaded again, the '
    'GPU embedder works',
    (tester) async {
      await _ensureEg2();
      final first = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      final a = await _embedGolden(first);
      final cpu = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.cpu,
      );
      expect(cpu.activeBackend, PreferredBackend.cpu);
      expect(first.isClosed, isTrue, reason: 'core replaced the GPU embedder');
      final second = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      expect(second.activeBackend, PreferredBackend.gpu);
      final b = await _embedGolden(second);
      var worst = 1.0;
      for (final item in _golden) {
        worst = math.min(worst, _cos(a[item.id]!, b[item.id]!));
      }
      debugPrint('EG2 GPU re-create: min cos to the first GPU run $worst');
      expect(worst, greaterThanOrEqualTo(0.9999));
      await second.close();
      expect(second.isClosed, isTrue);
      final third = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      expect(third, isNot(same(second)));
      final c = await _embedGolden(third);
      expect(_cos(c['q0']!, a['q0']!), greaterThanOrEqualTo(0.9999));
    },
    skip: !_gpuHost,
  );

  testWidgets('a ~900-token text on the GPU stays close to its CPU vector', (
    tester,
  ) async {
    await _ensureEg2();
    final long = EmbeddingInput.text(
      List.filled(
        60,
        'The northern lights are caused by charged particles from the sun.',
      ).join(' '),
    );
    final cpu = await (await FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: PreferredBackend.cpu,
    )).embed(long, taskType: TaskType.retrievalDocument);
    final gpuModel = await FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: PreferredBackend.gpu,
    );
    final gpu = await gpuModel.embed(
      long,
      taskType: TaskType.retrievalDocument,
    );
    final cos = _cos(cpu, gpu);
    debugPrint('EG2 GPU long text: cos to CPU $cos');
    expect(cos, greaterThanOrEqualTo(0.99));
  }, skip: !_gpuHost);

  testWidgets(
    'a GPU LLM and a GPU embedder in one process, the embedder loaded before '
    'and after the LLM',
    (tester) async {
      await _ensureEg2();
      final before = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      final q0 = await before.embed(
        EmbeddingInput.text(_golden.first.text),
        taskType: TaskType.retrievalQuery,
      );
      await FlutterEdgeAi.installModel(
        modelType: ModelType.gemma4,
        fileType: ModelFileType.litertlm,
      ).fromFile(_llmFile).install();
      final llm = await FlutterEdgeAi.getActiveModel(
        preferredBackend: PreferredBackend.gpu,
        maxTokens: 1024,
      );
      addTearDown(llm.close);
      expect(llm.activeBackend, PreferredBackend.gpu);
      Future<String> ask() async {
        final session = await llm.createSession(topK: 1, maxOutputTokens: 24);
        try {
          await session.addQueryChunk(
            const Message(
              text: 'Reply with one word: the capital of France?',
              isUser: true,
            ),
          );
          return (await session.getResponse()).trim();
        } finally {
          await session.close();
        }
      }

      final reply1 = await ask();
      final again = await before.embed(
        EmbeddingInput.text(_golden.first.text),
        taskType: TaskType.retrievalQuery,
      );
      expect(_cos(again, q0), greaterThanOrEqualTo(0.9999));
      await before.close();
      final after = await FlutterEdgeAi.getActiveEmbedder(
        preferredBackend: PreferredBackend.gpu,
      );
      expect(after.activeBackend, PreferredBackend.gpu);
      final q0After = await after.embed(
        EmbeddingInput.text(_golden.first.text),
        taskType: TaskType.retrievalQuery,
      );
      expect(_cos(q0After, q0), greaterThanOrEqualTo(0.9999));
      final reply2 = await ask();
      debugPrint('EG2 GPU + LLM GPU: "$reply1" / "$reply2"');
      expect(reply1.toLowerCase(), contains('paris'));
      expect(reply2.toLowerCase(), contains('paris'));
    },
    skip: !_gpuHost || _llmFile.isEmpty,
  );
}

// EmbeddingGemma 2 270m text on LiteRT-LM's GPU executor, where
// flutter_edge_ai_litertlm runs it: Windows x64 and Linux x64 (the WebGPU
// accelerator over DX12 / Vulkan). Skipped on every other host, where a `gpu`
// request still runs on CPU.
//
// What it holds the GPU to, against the same bundle on CPU and the golden
// (integration_test/goldens/eg2_text_golden.json, through its .dart twin):
// - `preferredBackend: gpu` loads with activeBackend gpu, 768-d unit vectors;
// - min cos >= 0.995 to the CPU vectors (measured 0.9969-0.9970 on Lunar Lake
//   and a Tesla T4, 2026-10-22) and >= 0.97 to Sentence Transformers fp32;
// - every query ranks its document first;
// - a second gpu request and an automatic one reuse the GPU embedder;
// - images on the GPU are refused before anything is loaded, and the GPU
//   embedder keeps working.
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

import 'goldens/eg2_text_golden.dart';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');

final _gpuHost =
    (Platform.isWindows && Abi.current() == Abi.windowsX64) ||
    (Platform.isLinux && Abi.current() == Abi.linuxX64);

bool _initialized = false;

/// Rule 6b: called first thing in every test body.
Future<void> _ensureEg2() async {
  if (!_initialized) {
    await FlutterEdgeAi.initialize(
      embeddingBackends: const [LiteRtEmbeddingBackend()],
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
            contains('runs on the GPU for text only'),
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
}

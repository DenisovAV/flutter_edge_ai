// EmbeddingGemma 2 440m and 740m with `preferredBackend: gpu` where
// flutter_edge_ai_litertlm runs EG2 on the GPU (Windows x64, Linux x64): the
// text tower on LiteRT-LM's GPU executor, the vision and audio towers named
// cpu at create. Skipped on every other host.
//
// What it holds each bundle to, against the same bundle on CPU in the same
// process:
// - `gpu` with images (and audio on the 740m) loads with activeBackend gpu;
// - text: min cos >= 0.995 to the CPU vectors but < 0.9999 (FP16
//   activations: a text tower that stayed on CPU would match), every golden
//   query ranking its document first;
// - images: cos >= 0.999 to the CPU vectors (the vision tower runs on CPU);
// - audio (740m): cos >= 0.99 to the CPU vectors (the audio encoder runs on
//   CPU; its int8 activations move the last bits between runs, see
//   embeddinggemma2_audio_test);
// - load times and per-item latency on each backend are printed, with the
//   cache directory after the GPU run and after its close, and the time of a
//   warm second GPU load.
//
// Run: flutter test integration_test/embeddinggemma2_gpu_towers_test.dart
// -d windows (or -d linux, under xvfb-run on a headless box).
// EG2_440M_MODEL_FILE / EG2_740M_MODEL_FILE override the catalog download.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'goldens/eg2_text_golden.dart';

const _file440m = String.fromEnvironment('EG2_440M_MODEL_FILE');
const _file740m = String.fromEnvironment('EG2_740M_MODEL_FILE');

final _gpuHost =
    (Platform.isWindows && Abi.current() == Abi.windowsX64) ||
    (Platform.isLinux && Abi.current() == Abi.linuxX64);

const _images = ['circle.png', 'bar_chart.png', 'house_scene.png'];
const _clips = ['kitchen_lights.wav', 'piano_lesson.wav'];

bool _initialized = false;

/// Rule 6b: called first thing in every test body.
Future<void> _ensure(catalog.EmbeddingModel model, String file) async {
  if (!_initialized) {
    await FlutterEdgeAi.initialize(
      embeddingBackends: const [LiteRtEmbeddingBackend()],
    );
    _initialized = true;
  }
  final builder = FlutterEdgeAi.installEmbedder();
  if (file.isNotEmpty) {
    builder.modelFromFile(file, filename: model.filename);
  } else {
    builder.modelFromNetwork(model.url, filename: model.filename);
  }
  await builder.install();
}

typedef _Item = ({String id, String role, String text});

final List<_Item> _golden = [
  for (final item
      in ((jsonDecode(eg2TextGoldenJson) as Map)['items'] as List)
          .cast<Map<String, dynamic>>())
    (
      id: item['id'] as String,
      role: item['role'] as String,
      text: item['text'] as String,
    ),
];

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

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void _log(String line) {
  // ignore: avoid_print
  print('[eg2-gpu-towers] $line');
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

void _cacheLog(String line) => _log(line);

typedef _Run = ({
  Map<String, List<double>> vectors,
  int loadMs,
  int textMs,
  int mediaMs,
});

Future<_Run> _run(PreferredBackend backend, {required bool audio}) async {
  final load = Stopwatch()..start();
  final model = await FlutterEdgeAi.getActiveEmbedder(
    preferredBackend: backend,
    supportImage: true,
    supportAudio: audio,
  );
  load.stop();
  expect(model.activeBackend, backend);
  final vectors = <String, List<double>>{};
  final text = Stopwatch()..start();
  for (final item in _golden) {
    vectors[item.id] = await model.embed(
      EmbeddingInput.text(item.text),
      taskType: _taskFor(item.role),
    );
  }
  text.stop();
  final media = Stopwatch()..start();
  for (final image in _images) {
    vectors[image] = await model.embed(
      EmbeddingInput.image(await _asset('assets/eg2_vision/$image')),
      taskType: TaskType.retrievalDocument,
    );
  }
  if (audio) {
    for (final clip in _clips) {
      vectors[clip] = await model.embed(
        EmbeddingInput.audio(await _asset('assets/eg2_audio/$clip')),
        taskType: TaskType.retrievalDocument,
      );
    }
  }
  media.stop();
  return (
    vectors: vectors,
    loadMs: load.elapsedMilliseconds,
    textMs: text.elapsedMilliseconds ~/ _golden.length,
    mediaMs:
        media.elapsedMilliseconds ~/
        (_images.length + (audio ? _clips.length : 0)),
  );
}

Future<void> _compare(
  catalog.EmbeddingModel model,
  String file, {
  required bool audio,
}) async {
  await _ensure(model, file);
  final cpu = await _run(PreferredBackend.cpu, audio: audio);
  final gpu = await _run(PreferredBackend.gpu, audio: audio);
  await _listCaches('after the ${model.filename} GPU load and its embeddings');
  await (await FlutterEdgeAi.getActiveEmbedder()).close();
  await _listCaches('after the ${model.filename} GPU embedder closed');
  final warm = Stopwatch()..start();
  final again = await FlutterEdgeAi.getActiveEmbedder(
    preferredBackend: PreferredBackend.gpu,
    supportImage: true,
    supportAudio: audio,
  );
  warm.stop();
  expect(again.activeBackend, PreferredBackend.gpu);
  _log(
    '${model.filename}: warm second GPU load ${warm.elapsedMilliseconds} ms',
  );
  _log(
    '${model.filename}: load cpu ${cpu.loadMs} ms, gpu ${gpu.loadMs} ms; '
    'text cpu ${cpu.textMs} ms, gpu ${gpu.textMs} ms; '
    'media cpu ${cpu.mediaMs} ms, gpu ${gpu.mediaMs} ms',
  );

  var worstText = 1.0;
  for (final item in _golden) {
    final c = _cos(gpu.vectors[item.id]!, cpu.vectors[item.id]!);
    worstText = math.min(worstText, c);
  }
  _log('text min cos gpu/cpu ${worstText.toStringAsFixed(5)}');
  expect(worstText, greaterThanOrEqualTo(0.995));
  expect(
    worstText,
    lessThan(0.9999),
    reason: 'GPU vectors equal to the CPU ones: the text tower stayed on CPU',
  );

  for (final query in _golden.where((i) => i.role == 'query')) {
    final docs = _golden.where((i) => i.role != 'query');
    final best = docs.reduce(
      (a, b) =>
          _cos(gpu.vectors[query.id]!, gpu.vectors[a.id]!) >=
              _cos(gpu.vectors[query.id]!, gpu.vectors[b.id]!)
          ? a
          : b,
    );
    // The golden pairs qN with dN.
    expect(
      best.id.substring(1),
      query.id.substring(1),
      reason: '${query.id} ranked ${best.id} first',
    );
  }

  for (final image in _images) {
    final c = _cos(gpu.vectors[image]!, cpu.vectors[image]!);
    _log('$image cos gpu/cpu ${c.toStringAsFixed(6)}');
    expect(c, greaterThanOrEqualTo(0.999), reason: image);
  }
  if (audio) {
    for (final clip in _clips) {
      final c = _cos(gpu.vectors[clip]!, cpu.vectors[clip]!);
      _log('$clip cos gpu/cpu ${c.toStringAsFixed(6)}');
      expect(c, greaterThanOrEqualTo(0.99), reason: clip);
    }
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    '440m: text on the GPU, images on the vision tower on CPU',
    (tester) => _compare(
      catalog.EmbeddingModel.embeddingGemma2TextVision440m,
      _file440m,
      audio: false,
    ),
    skip: !_gpuHost,
  );

  testWidgets(
    '740m: text on the GPU, images and audio on their towers on CPU',
    (tester) => _compare(
      catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m,
      _file740m,
      audio: true,
    ),
    skip: !_gpuHost,
  );
}

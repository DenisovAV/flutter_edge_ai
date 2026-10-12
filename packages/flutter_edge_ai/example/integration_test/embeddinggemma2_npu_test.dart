// EmbeddingGemma 2 on a Qualcomm NPU (flutter_edge_ai_litertlm 1.13.1): the
// per-SoC bundles litert-community publishes beside the generic ones, through
// `installEmbedder()` → `getActiveEmbedder(preferredBackend: npu)` → core's
// worker isolate → the `.litertlm` pass on LiteRT-LM's EmbeddingEngine with
// the Qualcomm dispatch. Every line it measures starts with `[eg2-npu]`.
//
// What it holds the device to:
// - the 270m loads on the NPU: `activeBackend` npu, 768 dimensions, 1024 input
//   tokens, text only; vectors finite, not all zero, unit norm;
// - the 12 golden strings: cosine against the CPU golden (`vector`, macOS
//   arm64, native-v0.18.0-d) printed min/mean, at least 0.70 each — a floor
//   that catches garbage (a wrong graph, a broken dispatch), not drift: the
//   NPU's vectors sit measurably apart from the CPU's (mean 0.83, min 0.787 on
//   SM8650 and QCS8275), which is why an NPU index has its own profile id —
//   and every query ranks its own document first;
// - refusals, each an EmbeddingLoadException that leaves the loaded NPU
//   embedder serving: the NPU bundle without npu (null and cpu); the generic
//   bundle with npu; then the generic bundle on CPU on this device, and the
//   cosine of the NPU vectors against it (min/mean);
// - the 440m on the NPU: {text, image}; its text vectors equal the 270m's on
//   the NPU (one text tower); the ten scenes' image vectors against the CPU
//   image golden (min/mean); text → image top-1 on the ten scenes;
// - load and per-embed times.
//
// The bundle is picked by SoC: --dart-define=EG2_NPU_SOC=<SM8850|SM8650|
// QCS8275>, else the device's own (Android `ro.soc.model`), else the first SoC
// whose 270m is staged. Bundles are staged under their Hugging Face names (the
// generic 270m for the refusal too; it is downloaded when absent):
//   Android  /data/local/tmp/flutter_gemma_test/  (adb push, or FTL
//            --other-files)
//   Linux    ~/models/
// or under --dart-define=EG2_NPU_DIR=<dir>. Each file's SHA-256 is checked
// against its pin before anything is compared.
//
// The app must be built with `qualcomm_npu: true` (this example's pubspec sets
// it). No setUp/setUpAll (Rule 6b): every body calls a guarded `_ensure…()`.
//   Linux arm64:  flutter test integration_test/embeddinggemma2_npu_test.dart
//                 -d linux
//   Android:      gradle instrumentation (QDC, FTL); trust the I/flutter lines

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/image_search/eg2_vision_samples.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'goldens/eg2_image_golden.dart';
import 'goldens/eg2_text_golden.dart';

const _socDefine = String.fromEnvironment('EG2_NPU_SOC');
const _dirDefine = String.fromEnvironment('EG2_NPU_DIR');

/// The per-SoC bundles this suite knows, with their pinned SHA-256s
/// (Hugging Face `lfs.oid`, revisions 9be6e8b9 / e301f74d): SoC → (270m,
/// 440m).
const _pins = <String, (String, String)>{
  'SM8850': (
    '72992b649c812ae9e30ffa9ad88fc662e649f7b643500d28051fbd457ad0d22a',
    '661369235aa9fc23cf04a213d4e445c4634073832279f5a261ed22650a8ebc5b',
  ),
  'SM8650': (
    '7dabcb17eed982d6de4435aaf29cc56147a627f6ab20a1e37aadd7af5399457b',
    'ec7d2ee513830337343567409f32fea4a3e4f8f7b94facd0a20f3d3523cd7480',
  ),
  'QCS8275': (
    '128c32151613a5bbf8b5695b2d9ae271057338febbf06e3aeebf29e1353cb51d',
    'ce8ccce80a12f6bc9acfe664b76c3cc46a698f0da81ae857f706b06b9a4c7d38',
  ),
};

const _generic = catalog.EmbeddingModel.embeddingGemma2Text270m;

String get _dir => _dirDefine.isNotEmpty
    ? _dirDefine
    : Platform.isAndroid
    ? '/data/local/tmp/flutter_gemma_test'
    : '${Platform.environment['HOME']}/models';

String _bundle270m(String soc) =>
    '$_dir/embeddinggemma-2-text-270m_Qualcomm_$soc.litertlm';
String _bundle440m(String soc) =>
    '$_dir/embeddinggemma-2-text-vision-440m_Qualcomm_$soc.litertlm';

void _log(String line) {
  // ignore: avoid_print
  print('[eg2-npu] $line');
}

// ── Guarded set-up (Rule 6b) ───────────────────────────────────────────────

bool _initialized = false;
String? _soc;
final _verified = <String>{};

/// The SoC under test, or null (the test is then skipped) when no bundle for
/// a known SoC is staged.
Future<String?> _pickSoc() async {
  if (_soc != null) return _soc;
  if (_socDefine.isNotEmpty) return _soc = _socDefine.toUpperCase();
  String? device;
  if (Platform.isAndroid) {
    final result = await Process.run('/system/bin/getprop', ['ro.soc.model']);
    device = '${result.stdout}'.trim().toUpperCase();
  }
  _log(
    'device SoC: ${device ?? '-'} (${Platform.operatingSystem}); staged in '
    '$_dir',
  );
  if (device != null &&
      _pins.containsKey(device) &&
      File(_bundle270m(device)).existsSync()) {
    return _soc = device;
  }
  for (final soc in _pins.keys) {
    if (File(_bundle270m(soc)).existsSync()) return _soc = soc;
  }
  return null;
}

Future<void> _initialize() async {
  if (_initialized) return;
  await FlutterEdgeAi.initialize(
    embeddingBackends: const [LiteRtEmbeddingBackend()],
  );
  _initialized = true;
}

/// Checks [path] against [sha256] once per run.
Future<void> _verify(String path, String sha256Hex) async {
  if (_verified.contains(path)) return;
  final watch = Stopwatch()..start();
  final digest = await sha256.bind(File(path).openRead()).first;
  expect(
    '$digest',
    sha256Hex,
    reason: '$path is not the pinned bundle; nothing below would mean much',
  );
  _verified.add(path);
  _log('sha256 ok: ${path.split('/').last} (${watch.elapsedMilliseconds} ms)');
}

/// Makes [path] (a staged bundle) the active embedder.
Future<void> _activate(String path, String sha256Hex) async {
  await _initialize();
  await _verify(path, sha256Hex);
  await FlutterEdgeAi.installEmbedder().modelFromFile(path).install();
}

/// The SoC's 270m, active; false when nothing is staged (the test skipped).
Future<bool> _ensureNpu270m() async {
  final soc = await _pickSoc();
  if (soc == null) {
    markTestSkipped('no EmbeddingGemma 2 NPU bundle staged in $_dir');
    return false;
  }
  await _activate(_bundle270m(soc), _pins[soc]!.$1);
  return true;
}

/// The SoC's 440m, active; false when it is not staged (the test skipped).
Future<bool> _ensureNpu440m() async {
  final soc = await _pickSoc();
  if (soc == null || !File(_bundle440m(soc)).existsSync()) {
    markTestSkipped('no EmbeddingGemma 2 440m NPU bundle staged in $_dir');
    return false;
  }
  await _activate(_bundle440m(soc), _pins[soc]!.$2);
  return true;
}

/// The generic 270m, active: staged, or downloaded from its pinned URL.
Future<void> _ensureGeneric() async {
  await _initialize();
  final staged = '$_dir/embeddinggemma-2-text-270m.litertlm';
  final builder = FlutterEdgeAi.installEmbedder();
  if (File(staged).existsSync()) {
    await _verify(staged, _generic.sha256!);
    builder.modelFromFile(staged);
  } else {
    builder.modelFromNetwork(_generic.url, filename: _generic.filename);
  }
  await builder.install();
}

/// The active embedder on the NPU.
Future<EmbeddingModel> _npu({bool images = false}) =>
    FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: PreferredBackend.npu,
      supportImage: images,
    );

// ── Goldens and maths ──────────────────────────────────────────────────────

List<double> _f32(String encoded) {
  final bytes = ByteData.sublistView(base64.decode(encoded));
  return [
    for (var i = 0; i < bytes.lengthInBytes ~/ 4; i++)
      bytes.getFloat32(i * 4, Endian.little),
  ];
}

typedef _Golden = ({
  String id,
  String role,
  String text,
  List<double> vector,
  List<double> stVector,
});

final List<_Golden> _golden = [
  for (final item
      in ((jsonDecode(eg2TextGoldenJson) as Map)['items'] as List)
          .cast<Map<String, dynamic>>())
    (
      id: item['id'] as String,
      role: item['role'] as String,
      text: item['text'] as String,
      vector: _f32(item['vector_f32le'] as String),
      stVector: _f32(item['vector_st_fp32_f32le'] as String),
    ),
];

final Map<String, List<double>> _imageGolden = {
  for (final MapEntry(:key, :value)
      in ((jsonDecode(eg2ImageGoldenJson) as Map)['images'] as Map).entries)
    key as String: _f32((value as Map)['vector_f32le'] as String),
};

TaskType _taskFor(String role) =>
    role == 'query' ? TaskType.retrievalQuery : TaskType.retrievalDocument;

double _cos(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

double _norm(List<double> v) => math.sqrt(v.fold(0.0, (s, x) => s + x * x));

String _stats(List<double> values) {
  final min = values.reduce(math.min);
  final mean = values.reduce((a, b) => a + b) / values.length;
  return 'min ${min.toStringAsFixed(5)} mean ${mean.toStringAsFixed(5)} '
      '(n=${values.length})';
}

String _times(List<int> micros) {
  final sorted = micros.toList()..sort();
  return 'median ${(sorted[sorted.length ~/ 2] / 1000).toStringAsFixed(1)} ms, '
      'max ${(sorted.last / 1000).toStringAsFixed(1)} ms';
}

void _expectSane(List<double> vector, String what) {
  expect(vector, hasLength(768), reason: what);
  expect(vector.every((v) => v.isFinite), isTrue, reason: '$what: NaN/inf');
  expect(vector.any((v) => v != 0), isTrue, reason: '$what: all zeros');
  expect(_norm(vector), closeTo(1.0, 1e-3), reason: '$what: not unit norm');
}

/// The golden strings embedded by [model], with the time of each.
Future<({Map<String, List<double>> vectors, List<int> micros})> _embedGolden(
  EmbeddingModel model,
) async {
  final vectors = <String, List<double>>{};
  final micros = <int>[];
  for (final item in _golden) {
    final watch = Stopwatch()..start();
    vectors[item.id] = await model.embed(
      EmbeddingInput.text(item.text),
      taskType: _taskFor(item.role),
    );
    micros.add(watch.elapsedMicroseconds);
  }
  return (vectors: vectors, micros: micros);
}

Matcher _refusal(Object message) => throwsA(
  isA<EmbeddingLoadException>().having((e) => e.message, 'message', message),
);

final _scenes = eg2VisionSampleCaptions.keys.toList();

/// Texts of growing length — from a few tokens to past the 128 and 256-token
/// signatures — to see whether the NPU's distance from CPU depends on how
/// much of the signature is padding.
final List<String> _lengthSweep = [
  for (final words in [4, 16, 48, 90, 110, 200, 400])
    List.generate(
      words,
      (i) => const [
        'the',
        'river',
        'carried',
        'small',
        'boats',
        'past',
        'old',
        'mills',
        'toward',
        'a',
        'quiet',
        'harbour',
        'where',
        'fishermen',
        'mended',
        'nets',
        'before',
        'dawn',
      ][i % 18],
    ).join(' '),
];

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the 270m loads on the NPU: activeBackend npu, 768-d unit '
      'vectors, 1024 input tokens', (tester) async {
    if (!await _ensureNpu270m()) return;
    // A fresh build, so the load time is the NPU engine's.
    final old = await _npu();
    await old.close();

    final watch = Stopwatch()..start();
    final model = await _npu();
    final loadMs = watch.elapsedMilliseconds;
    expect(model.activeBackend, PreferredBackend.npu);
    expect(model.dimension, 768);
    expect(model.maxInputTokens, 1024);
    expect(model.modalities, {EmbeddingModality.text});

    final first = Stopwatch()..start();
    final vector = await model.embed(
      EmbeddingInput.text('The northern lights over Tromsø.'),
      taskType: TaskType.retrievalDocument,
    );
    _expectSane(vector, 'first vector');
    _log(
      'soc=$_soc 270m load $loadMs ms (includes the NPU probe embed), first '
      'embed ${first.elapsedMicroseconds / 1000} ms, norm ${_norm(vector)}',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('the golden strings on the NPU: cosine against the CPU golden, '
      'and every query ranks its own document first', (tester) async {
    if (!await _ensureNpu270m()) return;
    final model = await _npu();
    final (:vectors, :micros) = await _embedGolden(model);
    final vsCpu = <double>[], vsSt = <double>[];
    for (final item in _golden) {
      _expectSane(vectors[item.id]!, item.id);
      vsCpu.add(_cos(vectors[item.id]!, item.vector));
      vsSt.add(_cos(vectors[item.id]!, item.stVector));
    }
    _log('soc=$_soc text cos vs CPU golden (macOS, -d): ${_stats(vsCpu)}');
    _log('soc=$_soc text cos vs Sentence Transformers fp32: ${_stats(vsSt)}');
    _log('soc=$_soc text embed ${_times(micros)}');
    _log(
      'soc=$_soc text cos vs CPU golden per string: '
      '${[for (final (i, cos) in vsCpu.indexed) '${_golden[i].id}=${cos.toStringAsFixed(4)}/${_golden[i].text.length}ch']}',
    );
    // A floor that catches garbage (a wrong graph, a broken dispatch), not
    // drift: how far the NPU's vectors sit from the CPU's is measured and
    // printed above (SM8650 on FTL, 2026-10-12: min 0.787, mean 0.833).
    for (final (i, cos) in vsCpu.indexed) {
      expect(cos, greaterThanOrEqualTo(0.70), reason: _golden[i].id);
    }
    for (var i = 0; i < 6; i++) {
      final scores = [
        for (var j = 0; j < 6; j++) _cos(vectors['q$i']!, vectors['d$j']!),
      ];
      final best = scores.indexOf(scores.reduce(math.max));
      expect(best, i, reason: 'q$i ranks d$best first: $scores');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  testWidgets('refusals: the NPU bundle without npu, the generic bundle with '
      'npu — and the NPU embedder keeps serving; the NPU vectors against the '
      'CPU bundle on this device', (tester) async {
    if (!await _ensureNpu270m()) return;
    final npu = await _npu();
    final (vectors: onNpu, micros: _) = await _embedGolden(npu);
    final sweepOnNpu = [
      for (final text in _lengthSweep)
        await npu.embed(EmbeddingInput.text(text), taskType: TaskType.none),
    ];

    for (final other in [null, PreferredBackend.cpu]) {
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(preferredBackend: other),
        _refusal(
          allOf(
            contains('compiled for the Qualcomm $_soc NPU'),
            contains('PreferredBackend.npu'),
          ),
        ),
        reason: '$other',
      );
    }
    expect(npu.isClosed, isFalse, reason: 'a refusal closes nothing');
    _expectSane(
      await npu.embed(
        EmbeddingInput.text('still here'),
        taskType: TaskType.none,
      ),
      'after the refusals',
    );
    expect(await _npu(), same(npu), reason: 'npu is still served by it');
    _log('soc=$_soc refused: NPU bundle with null and cpu');

    await _ensureGeneric();
    await expectLater(
      _npu(),
      _refusal(
        allOf(
          contains('generic EmbeddingGemma 2 bundle'),
          contains('no NPU graph'),
        ),
      ),
    );
    _log('soc=$_soc refused: generic bundle with npu');

    final cpu = await FlutterEdgeAi.getActiveEmbedder();
    expect(cpu.activeBackend, PreferredBackend.cpu);
    final (vectors: onCpu, :micros) = await _embedGolden(cpu);
    final npuVsCpu = <double>[], cpuVsGolden = <double>[];
    for (final item in _golden) {
      npuVsCpu.add(_cos(onNpu[item.id]!, onCpu[item.id]!));
      cpuVsGolden.add(_cos(onCpu[item.id]!, item.vector));
    }
    _log('soc=$_soc text cos NPU vs CPU (this device): ${_stats(npuVsCpu)}');
    // Short inputs are padded to the 128-token signature; one that fills it
    // has no padding. If padding were the cause, the cosine would rise with
    // the length.
    final sweep = <String>[];
    for (final (i, text) in _lengthSweep.indexed) {
      final onCpuVector = await cpu.embed(
        EmbeddingInput.text(text),
        taskType: TaskType.none,
      );
      sweep.add(
        '${text.split(' ').length}w=${_cos(sweepOnNpu[i], onCpuVector).toStringAsFixed(4)}',
      );
    }
    _log('soc=$_soc text cos NPU vs CPU by length (words): $sweep');
    _log(
      'soc=$_soc generic CPU on this device vs golden: ${_stats(cpuVsGolden)}; '
      'CPU embed ${_times(micros)}',
    );
    await cpu.close();
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('the 440m on the NPU: text and images, its text tower the '
      "270m's, image vectors against the CPU golden, text → image top-1 on the "
      'ten scenes', (tester) async {
    if (!await _ensureNpu270m()) return;
    final text270 = await _embedGolden(await _npu());
    if (!await _ensureNpu440m()) return;

    final watch = Stopwatch()..start();
    final model = await _npu(images: true);
    final loadMs = watch.elapsedMilliseconds;
    expect(model.activeBackend, PreferredBackend.npu);
    expect(model.modalities, {EmbeddingModality.text, EmbeddingModality.image});

    final text440 = await _embedGolden(model);
    final towers = [
      for (final item in _golden)
        _cos(text440.vectors[item.id]!, text270.vectors[item.id]!),
    ];
    _log(
      'soc=$_soc 440m load $loadMs ms; text cos 440m vs 270m (NPU): '
      '${_stats(towers)}',
    );

    final images = <List<double>>[];
    final imageMicros = <int>[];
    final vsGolden = <double>[];
    for (final scene in _scenes) {
      final bytes = await _asset(eg2VisionSampleAsset(scene));
      final imageWatch = Stopwatch()..start();
      final vector = await model.embed(
        EmbeddingInput.image(bytes),
        taskType: TaskType.retrievalDocument,
      );
      imageMicros.add(imageWatch.elapsedMicroseconds);
      _expectSane(vector, scene);
      images.add(vector);
      vsGolden.add(_cos(vector, _imageGolden[scene]!));
    }
    _log('soc=$_soc image cos vs CPU golden (140 tokens): ${_stats(vsGolden)}');
    _log('soc=$_soc image embed ${_times(imageMicros)}');

    var top1 = 0;
    final misses = <String>[];
    for (final (i, caption) in eg2VisionSampleCaptions.values.indexed) {
      final query = await model.embed(
        EmbeddingInput.text(caption),
        taskType: TaskType.none,
      );
      final scores = [for (final image in images) _cos(query, image)];
      final best = scores.indexOf(scores.reduce(math.max));
      if (best == i) {
        top1++;
      } else {
        misses.add('${_scenes[i]}->${_scenes[best]}');
      }
    }
    _log('soc=$_soc text→image top-1 $top1/10 $misses');
    expect(top1, 10, reason: '$misses');
    await model.close();
  }, timeout: const Timeout(Duration(minutes: 20)));
}

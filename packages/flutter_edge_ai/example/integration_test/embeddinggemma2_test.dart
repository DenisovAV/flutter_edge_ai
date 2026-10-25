// EmbeddingGemma 2 text on a device (R5 §10.1): the pinned
// litert-community/embeddinggemma-2-text-270m-litert-lm bundle through
// `installEmbedder()` → `getActiveEmbedder()` → core's worker isolate →
// flutter_edge_ai_litertlm's `.litertlm` pass → LiteRT-LM's EmbeddingEngine.
//
// What it holds the device to:
// - 768 dimensions, unit norm, finite, not all zero; maxInputTokens 1024;
// - the engine's weight cache lands in the pass-owned directory under
//   <appCache>/flutter_edge_ai/emb/ — the platform cache directory, never
//   backed up (well under MAX_PATH on Windows);
// - the golden (integration_test/goldens/eg2_text_golden.json, through its
//   generated .dart twin): cos >= 0.9999 against `vector` on macOS arm64 (the
//   build and platform the golden came from), >= 0.998 anywhere else, and
//   >= 0.97 against Sentence Transformers fp32 everywhere; every query ranks
//   its document first;
// - the 9 TaskTypes give 9 different vectors;
// - an over-long text is EmbeddingInputTooLongException with the exact
//   counts (1024 of 11509, as Google's litert-lm wheel counts the same input)
//   and the model keeps working (native-v0.18.0-e);
// - the calling isolate stays live during a 50-text batch (#299);
// - closing during a batch returns, fails the queued requests with
//   EmbedderClosedException, and gives the memory back (M12; measured on
//   Android only: iOS reports no file-backed pages);
// - an LLM .litertlm installed as an embedder is refused at load;
// - supportImage on the 270m is refused from the bundle (no vision encoder,
//   naming the 440m) before any engine or vision cache exists;
// - close and recreate.
// And, in the "EG2 vision" group, on the pinned
// litert-community/embeddinggemma-2-text-vision-440m-litert-lm bundle (R5
// §10.2), over the ten generated scenes in assets/eg2_vision:
// - {text, image}, the vision cache in the pass-owned directory, the text
//   tower identical to the 270m's (golden), RSS by step;
// - text → image top-1 on the ten scenes (raw queries, as rag sends them),
//   and M10: the same with the retrieval-query prefix, margins printed;
// - image → image: each near-duplicate JPEG finds its PNG;
// - GIF and BMP decode; WebP, TIFF and HEIC are refused on the calling
//   isolate with the format named; a truncated PNG is
//   EmbeddingEngineException(nativeCode: 3) and the model keeps working;
// - LiteRtEmbeddingBackend(visionTokensPerImage: 280) is refused;
// - the calling isolate stays live during a batch of 20 images (#299);
// - a RAG image index: add, text search, and reopening it as text refused;
// - a text index and an image index on one bundle, alternating: one rebuild,
//   no EmbedderClosedException;
// - the Image Search screen: samples, text → image, image → image;
// - a camera JPEG stored sideways with EXIF Orientation 6: raw bytes (the
//   engine ignores EXIF) vs the example's flow (Flutter decodes it upright,
//   at most 1024 px) against its upright twin; a 12 MP JPEG raw vs prepared;
//   the ten scenes at 70 vision tokens per image.
// It prints load and per-embed timings, and the cosines.
//
// No setUp/setUpAll (Rule 6b): each test body calls the guarded
// `_ensureEg2()` or `_ensureEg2Vision()`, which installs the pinned revision
// (a no-op once installed), makes it the active embedder and, once per run,
// checks the file's SHA-256. Both bundles are ungated. Runs on Android, iOS,
// macOS, Linux and Windows:
//   flutter test integration_test/embeddinggemma2_test.dart -d <device>
// Optional: --dart-define=EG2_MODEL_URL / EG2_440M_MODEL_URL=<a copy of the
// same bytes> (a mirror), or EG2_MODEL_FILE / EG2_440M_MODEL_FILE=<path the
// app can read> (a local copy; on macOS that is inside the app's sandbox
// container). Either must have the pinned SHA-256, or the suite fails before
// comparing anything.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/engine.dart' show RuntimeConfig;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_example/image_search/eg2_vision_samples.dart';
import 'package:flutter_edge_ai_example/image_search/image_search_app_dependencies.dart';
import 'package:flutter_edge_ai_example/image_search/image_search_controller.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_edge_ai_example/image_search_screen.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'goldens/eg2_text_golden.dart';
import 'goldens/litertlm_llm_header.dart';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');
const _eg2Vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
const _visionUrlOverride = String.fromEnvironment('EG2_440M_MODEL_URL');
const _visionFileOverride = String.fromEnvironment('EG2_440M_MODEL_FILE');

/// What LiteRT-LM decodes, as the 440m reports it at load.
final _imageFormats = {
  EncodedMediaFormat.jpeg,
  EncodedMediaFormat.png,
  EncodedMediaFormat.gif,
  EncodedMediaFormat.bmp,
};

const _mb = 1024 * 1024;

/// Where the last section of the Gemma 3 1B bundle behind
/// goldens/litertlm_llm_header.dart ends: its declared length.
const _llmBundleLength = 584413712;

// ── Guarded set-up (Rule 6b: called first thing in every test body) ────────

bool _initialized = false;
final _verified = <catalog.EmbeddingModel>{};

/// Registers the LiteRT backend once — and no tokenizer provider: an
/// EmbeddingGemma 2 app needs none. Installs the pinned 270m bundle (a no-op
/// once installed), makes it the active embedder, and checks its SHA-256 once.
Future<void> _ensureEg2() =>
    _ensure(_eg2, file: _fileOverride, url: _urlOverride);

/// The same for the 440m bundle (text + vision).
Future<void> _ensureEg2Vision() =>
    _ensure(_eg2Vision, file: _visionFileOverride, url: _visionUrlOverride);

Future<void> _ensure(
  catalog.EmbeddingModel model, {
  required String file,
  required String url,
}) async {
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
    builder.modelFromNetwork(
      url.isEmpty ? model.url : url,
      filename: model.filename,
    );
  }
  await builder.install();
  if (_verified.contains(model)) return;
  final path = await FlutterEdgeAi.getModelPath(model.filename);
  final digest = await sha256.bind(File(path).openRead()).first;
  expect(
    '$digest',
    model.sha256,
    reason:
        '$path is not the pinned ${Uri.parse(model.url).pathSegments.last}; '
        'every comparison below would be against the wrong file',
  );
  _verified.add(model);
}

// ── Golden ─────────────────────────────────────────────────────────────────

typedef _GoldenItem = ({
  String id,
  String role,
  String text,
  List<double> vector,
  List<double> stVector,
});

List<double> _f32(String encoded) {
  final bytes = ByteData.sublistView(base64.decode(encoded));
  return [
    for (var i = 0; i < bytes.lengthInBytes ~/ 4; i++)
      bytes.getFloat32(i * 4, Endian.little),
  ];
}

final List<_GoldenItem> _golden = [
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

/// The golden's `vector` came from native-v0.18.0-d on macOS arm64.
bool get _sameBuildAsGolden =>
    Platform.isMacOS && Abi.current() == Abi.macosArm64;

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

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];

void _log(String line) {
  // ignore: avoid_print
  print('[eg2] $line');
}

/// The cached embedder, closed, so the next `getActiveEmbedder()` builds.
Future<void> _closeActive() async {
  final model = await FlutterEdgeAi.getActiveEmbedder();
  await model.close();
}

/// The name of the file the engine opens for [model]: the catalog name, or a
/// local copy's own name under [fileOverride] (an in-place FileSource). The
/// engine names its weight caches after it.
String _openedName(catalog.EmbeddingModel model, String fileOverride) =>
    fileOverride.isEmpty
    ? model.filename
    : fileOverride.split(RegExp(r'[/\\]')).last;

/// `<appCache>/flutter_edge_ai/emb`, where the pass keeps the weight caches.
Future<Directory> _cacheBase() async {
  final sep = Platform.pathSeparator;
  return Directory(
    '${(await getApplicationCacheDirectory()).path}'
    '${sep}flutter_edge_ai${sep}emb',
  );
}

/// Every file under [_cacheBase], with its size and modification time.
Future<Map<String, String>> _cacheTree() async {
  final base = await _cacheBase();
  if (!base.existsSync()) return const {};
  return {
    for (final entry in base.listSync(recursive: true))
      entry.path: entry is File
          ? '${entry.lengthSync()} ${entry.lastModifiedSync()}'
          : 'dir',
  };
}

/// The bytes of an example asset.
Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

/// The process's resident memory, where it can be read: the diagnostics
/// package on Android and iOS, `ProcessInfo.currentRss` elsewhere.
Future<int?> _residentBytes() async {
  if (FlutterEdgeAiDiagnostics.isSupported) {
    final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
    return (snapshot.anonymousBytes ?? 0) + (snapshot.fileBackedBytes ?? 0);
  }
  return ProcessInfo.currentRss;
}

String _mib(int? bytes) => bytes == null ? '-' : '${bytes ~/ _mb}';

/// Each query's rank among [documents]: how many find their own document
/// first, and the mean margin of the right document over the best wrong one.
({int top1, double margin, List<String> misses}) _rank(
  List<List<double>> queries,
  List<List<double>> documents,
  List<String> names,
) {
  var top1 = 0;
  var margin = 0.0;
  final misses = <String>[];
  for (var i = 0; i < queries.length; i++) {
    final scores = [for (final d in documents) _cos(queries[i], d)];
    final best = scores.indexOf(scores.reduce(math.max));
    if (best == i) {
      top1++;
    } else {
      misses.add('${names[i]}->${names[best]}');
    }
    margin +=
        scores[i] -
        [
          for (var j = 0; j < scores.length; j++)
            if (j != i) scores[j],
        ].reduce(math.max);
  }
  return (top1: top1, margin: margin / queries.length, misses: misses);
}

final _scenes = eg2VisionSampleCaptions.keys.toList();

/// A fresh directory for one test's RAG stores.
Future<String> _scratch(String name) async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
    'eg2_vision_${name}_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  return dir.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads: 768-d unit vectors, maxInputTokens 1024, text, CPU', (
    tester,
  ) async {
    await _ensureEg2();
    await _closeActive();

    final loadWatch = Stopwatch()..start();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    loadWatch.stop();
    expect(model.dimension, 768);
    expect(model.maxInputTokens, 1024);
    expect(model.modalities, {EmbeddingModality.text});
    expect(model.activeBackend, PreferredBackend.cpu);

    final firstWatch = Stopwatch()..start();
    final vector = await model.embed(
      EmbeddingInput.text('The northern lights over Tromsø.'),
      taskType: TaskType.retrievalDocument,
    );
    firstWatch.stop();
    expect(vector, hasLength(768));
    expect(vector.every((v) => v.isFinite), isTrue, reason: 'NaN or infinity');
    expect(vector.any((v) => v != 0), isTrue, reason: 'all zeros');
    expect(_norm(vector), closeTo(1.0, 1e-3));
    _log(
      '${Platform.operatingSystem}/${Abi.current()}: getActiveEmbedder '
      '${loadWatch.elapsedMilliseconds} ms, first embed '
      '${firstWatch.elapsedMilliseconds} ms',
    );
  }, timeout: const Timeout(Duration(minutes: 20)));

  testWidgets('the engine writes its weight cache into the directory the '
      'pass owns (D22)', (tester) async {
    await _ensureEg2();
    await FlutterEdgeAi.getActiveEmbedder();
    final sep = Platform.pathSeparator;
    final base = Directory(
      '${(await getApplicationCacheDirectory()).path}'
      '${sep}flutter_edge_ai${sep}emb',
    );
    final caches = [
      for (final dir in base.listSync().whereType<Directory>())
        for (final file in dir.listSync().whereType<File>())
          if (file.path.endsWith('.xnnpack_cache') &&
              file.path.contains(_openedName(_eg2, _fileOverride)))
            file,
    ];
    final longest = caches.isEmpty
        ? 0
        : caches.map((f) => f.path.length).reduce(math.max);
    _log(
      'weight cache: ${caches.map((f) => '${f.path} '
          '(${f.lengthSync() ~/ _mb} MiB)').join(', ')}; longest path '
      '$longest characters',
    );
    // Without it the engine runs with no weight cache: about 290 MB more and
    // a slow create, reported only in the native log.
    expect(
      caches.where((f) => f.lengthSync() > _mb),
      isNotEmpty,
      reason:
          'no .xnnpack_cache for ${_openedName(_eg2, _fileOverride)} under '
          '${base.path}',
    );
    if (Platform.isWindows) {
      // 232 for the example app with a 20-character user name.
      expect(longest, lessThan(260), reason: 'past MAX_PATH');
    }
  });

  testWidgets('reproduces the golden vectors and ranks every query\'s '
      'document first', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    final minGolden = _sameBuildAsGolden ? 0.9999 : 0.998;

    final vectors = <String, List<double>>{};
    final micros = <int>[];
    var worstGolden = 1.0, worstSt = 1.0;
    for (final item in _golden) {
      final watch = Stopwatch()..start();
      final vector = await model.embed(
        EmbeddingInput.text(item.text),
        taskType: _taskFor(item.role),
      );
      micros.add(watch.elapsedMicroseconds);
      final cosGolden = _cos(vector, item.vector);
      final cosSt = _cos(vector, item.stVector);
      worstGolden = math.min(worstGolden, cosGolden);
      worstSt = math.min(worstSt, cosSt);
      expect(
        cosGolden,
        greaterThanOrEqualTo(minGolden),
        reason: '${item.id} against the native-v0.18.0-d macOS golden',
      );
      expect(
        cosSt,
        greaterThanOrEqualTo(0.97),
        reason: '${item.id} against Sentence Transformers fp32',
      );
      vectors[item.id] = vector;
    }
    _log(
      'golden: min cos vs vector $worstGolden (need $minGolden), vs ST fp32 '
      '$worstSt; per embed median ${_median(micros) / 1000} ms, max '
      '${micros.reduce(math.max) / 1000} ms',
    );

    final pairs = _golden.where((item) => item.role == 'query').length;
    for (var i = 0; i < pairs; i++) {
      final scores = [
        for (var j = 0; j < pairs; j++) _cos(vectors['q$i']!, vectors['d$j']!),
      ];
      final best = scores.indexOf(scores.reduce(math.max));
      expect(best, i, reason: 'q$i ranks d$best first: $scores');
    }
  });

  testWidgets('the 9 TaskTypes give 9 different vectors', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    final vectors = {
      for (final taskType in TaskType.values)
        taskType: await model.embed(
          EmbeddingInput.text('How tall is Mount Everest?'),
          taskType: taskType,
        ),
    };
    var closest = -1.0;
    for (final a in TaskType.values) {
      for (final b in TaskType.values) {
        if (a.index >= b.index) continue;
        final cos = _cos(vectors[a]!, vectors[b]!);
        closest = math.max(closest, cos);
        expect(cos, lessThan(1.0), reason: '$a and $b gave the same vector');
      }
    }
    _log('TaskTypes: the closest two vectors have cos $closest');
  });

  testWidgets('an over-long text is EmbeddingInputTooLongException with the '
      'exact counts, and the model keeps working', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    final text = 'lorem ipsum dolor sit amet ' * 2300; // ~62,000 characters
    // 11509 tokens with the document prefix, BOS and EOS: what Google's
    // litert-lm 0.18.0 wheel reports for this input (its kError message).
    await expectLater(
      model.embed(
        EmbeddingInput.text(text),
        taskType: TaskType.retrievalDocument,
      ),
      throwsA(
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
            .having(
              (e) => e.maxInputTokens,
              'model.maxInputTokens',
              model.maxInputTokens,
            )
            .having((e) => e.actualTokens, 'actualTokens', 11509),
      ),
    );
    expect(model.isClosed, isFalse);
    final vector = await model.embed(
      EmbeddingInput.text('still working'),
      taskType: TaskType.retrievalQuery,
    );
    expect(vector, hasLength(768));
  });

  testWidgets('the calling isolate stays live during a 50-text batch (#299)', (
    tester,
  ) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    await model.embed(
      EmbeddingInput.text('warm up'),
      taskType: TaskType.retrievalQuery,
    );
    final texts = [
      for (var i = 0; i < 50; i++)
        EmbeddingInput.text(
          'Sentence $i about renewable energy, grids, batteries and the '
          'engineers who keep the lights on through winter storms.',
        ),
    ];

    // A self-rescheduling zero-timer loop on this isolate. If a forward pass
    // ran here, the loop would stall for the whole pass.
    var ticks = 0;
    var longestGap = Duration.zero;
    var running = true;
    final gapWatch = Stopwatch()..start();
    Future<void> spin() async {
      while (running) {
        ticks++;
        final gap = gapWatch.elapsed;
        if (gap > longestGap) longestGap = gap;
        gapWatch.reset();
        await Future<void>.delayed(Duration.zero);
      }
    }

    final spinner = spin();
    final batchWatch = Stopwatch()..start();
    final vectors = await model.embedAll(
      texts,
      taskType: TaskType.retrievalDocument,
    );
    batchWatch.stop();
    running = false;
    await spinner;

    expect(vectors, hasLength(50));
    _log(
      '#299: 50 texts in ${batchWatch.elapsedMilliseconds} ms '
      '(${(batchWatch.elapsedMilliseconds / 50).toStringAsFixed(1)} ms each); '
      'main-isolate ticks $ticks, longest gap ${longestGap.inMilliseconds} ms',
    );
    // A synchronous forward would allow about one tick per text.
    expect(
      ticks,
      greaterThan(10 * texts.length),
      reason: 'the calling isolate barely advanced: a forward pass blocks it',
    );
    expect(
      longestGap,
      lessThan(const Duration(milliseconds: 500)),
      reason: 'the calling isolate froze for ${longestGap.inMilliseconds} ms',
    );
  });

  testWidgets('closing during a batch returns, fails the queued requests, and '
      'frees the engine (M12)', (tester) async {
    await _ensureEg2();
    await _closeActive();
    final measure = FlutterEdgeAiDiagnostics.isSupported;
    Future<int?> resident() async {
      if (!measure) return null;
      final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
      // iOS reports no file-backed pages (only phys_footprint, which leaves
      // out clean file mappings): the 270m's weights and its 67 MiB XNNPack
      // cache are invisible there, and loading EG2 added +1 MiB (iPhone 17
      // Pro, 2026-10-12). Null skips the memory checks below.
      final fileBacked = snapshot.fileBackedBytes;
      if (fileBacked == null) return null;
      return (snapshot.anonymousBytes ?? 0) + fileBacked;
    }

    await Future<void>.delayed(const Duration(seconds: 1));
    final baseline = await resident();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    for (var i = 0; i < 3; i++) {
      await model.embed(
        EmbeddingInput.text('warm up $i: a short paragraph about rivers.'),
        taskType: TaskType.retrievalDocument,
      );
    }
    final loaded = await resident();

    // 200 embed() calls from one loop: queued at the worker in one turn,
    // which is what close must overtake (embedAll would keep only two
    // outstanding).
    final calls = [
      for (var i = 0; i < 200; i++)
        model.embed(
          EmbeddingInput.text('Queued request $i about mountains and rivers.'),
          taskType: TaskType.retrievalDocument,
        ),
    ];
    final outcomes = [
      for (final call in calls)
        call.then<Object?>((_) => null, onError: (Object e) => e),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 200));

    final closeWatch = Stopwatch()..start();
    await model.close();
    closeWatch.stop();
    final results = await Future.wait(outcomes);
    final succeeded = results.takeWhile((e) => e == null).length;
    final failed = results.skip(succeeded).toList();

    await Future<void>.delayed(const Duration(seconds: 1));
    final closed = await resident();

    _log(
      'M12: close ${closeWatch.elapsedMilliseconds} ms, $succeeded served, '
      '${failed.length} refused; resident MiB baseline '
      '${baseline == null ? '-' : baseline ~/ _mb} loaded '
      '${loaded == null ? '-' : loaded ~/ _mb} closed '
      '${closed == null ? '-' : closed ~/ _mb}'
      '${measure ? '' : ' (not measured on ${Platform.operatingSystem})'}',
    );

    expect(closeWatch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(failed, isNotEmpty, reason: 'the whole batch ran before close');
    expect(
      failed,
      everyElement(isA<EmbedderClosedException>()),
      reason: 'served in order: successes are a prefix, then only refusals',
    );
    expect(model.isClosed, isTrue);
    await expectLater(
      model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
      throwsA(isA<EmbedderClosedException>()),
    );

    if (baseline != null && loaded != null && closed != null) {
      final added = loaded - baseline;
      expect(
        added,
        greaterThan(64 * _mb),
        reason:
            'loading EG2 added only ${added ~/ _mb} MiB: the probe '
            'cannot see the engine',
      );
      expect(
        closed - baseline,
        lessThan(added ~/ 2),
        reason:
            'after close ${(closed - baseline) ~/ _mb} MiB of the '
            '${added ~/ _mb} MiB the load added are still resident',
      );
    } else if (measure) {
      _log(
        'M12 memory: not measured here — phys_footprint leaves out the '
        'file-mapped weights (fileBackedBytes is null)',
      );
    }
  });

  testWidgets('supportImage on the 270m is refused from the bundle, naming '
      'the 440m, before any engine or vision cache exists', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    final before = await _cacheTree();
    await expectLater(
      FlutterEdgeAi.getActiveEmbedder(supportImage: true),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having(
              (e) => e.message,
              'message',
              '${_openedName(_eg2, _fileOverride)} has no vision encoder; '
                  'install embeddinggemma-2-text-vision-440m',
            ),
      ),
    );
    expect(
      await _cacheTree(),
      before,
      reason: 'refused from ModelInfo: no new directory, no tower cache',
    );
    expect(
      before.keys.where(
        (path) =>
            path.contains(_openedName(_eg2, _fileOverride)) &&
            path.contains('vision'),
      ),
      isEmpty,
      reason: 'the 270m never wrote a vision cache',
    );
    // The refusal came from the worker's load(), after core had made room
    // for the wider model, so the text embedder was closed (R5_adjustments,
    // §4.6): the next text call builds a new one.
    expect(model.isClosed, isTrue);
    final again = await FlutterEdgeAi.getActiveEmbedder();
    expect(again.modalities, {EmbeddingModality.text});
    expect(
      await again.embed(
        EmbeddingInput.text('still here'),
        taskType: TaskType.retrievalQuery,
      ),
      hasLength(768),
    );
  });

  testWidgets('an LLM .litertlm installed as an embedder is refused at load', (
    tester,
  ) async {
    await _ensureEg2();
    const name = 'gemma3-1b-header-fixture.litertlm';
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$name');
    final bytes = base64.decode(
      litertlmLlmHeaderBase64.replaceAll(RegExp(r'\s'), ''),
    );
    expect(sha256.convert(bytes).toString(), litertlmLlmHeaderSha256);
    // The header, then the file extended (sparse: the zeros take no disk) to
    // where its last section ends, 584,413,712 bytes in the real bundle.
    // describe() reads every TFLiteModel section's metadata for an NPU stamp,
    // so a header alone is a truncated container ("not a readable .litertlm
    // bundle"); zeros read as a section with no metadata. ModelInfo then
    // copies the main section into the heap as it would the real one (about
    // 560 MB of zeros for a moment, measured in the VM) and names the LLM.
    // Core also refuses a model file under 1 MiB before any engine sees it.
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.writeFrom(bytes);
      await raf.truncate(_llmBundleLength);
      await raf.flush();
    } finally {
      await raf.close();
    }
    try {
      await FlutterEdgeAi.installEmbedder()
          .modelFromFile(file.path, filename: name)
          .install();
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having(
                (e) => e.message,
                'message',
                contains('is an LLM bundle, not an embedder'),
              ),
        ),
      );
    } finally {
      await FlutterEdgeAi.uninstallModel(name);
      if (file.existsSync()) file.deleteSync();
      await _ensureEg2(); // the next test, or the next launch, gets EG2 back
    }
  });

  testWidgets('close and recreate: a new model, the same vectors', (
    tester,
  ) async {
    await _ensureEg2();
    final first = await FlutterEdgeAi.getActiveEmbedder();
    final input = EmbeddingInput.text('Close me and build me again.');
    final before = await first.embed(input, taskType: TaskType.clustering);
    await first.close();
    expect(first.isClosed, isTrue);

    final second = await FlutterEdgeAi.getActiveEmbedder();
    expect(identical(first, second), isFalse);
    expect(await second.embed(input, taskType: TaskType.clustering), before);
  });

  group('EG2 vision', () {
    testWidgets('the 440m: text and images, the vision cache in the '
        'pass-owned directory, the 270m\'s text tower; RSS by step', (
      tester,
    ) async {
      await _ensureEg2Vision();
      await _closeActive();
      await Future<void>.delayed(const Duration(seconds: 1));
      final baseline = await _residentBytes();

      final loadWatch = Stopwatch()..start();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      loadWatch.stop();
      expect(model.dimension, 768);
      expect(model.maxInputTokens, 1024);
      expect(model.activeBackend, PreferredBackend.cpu);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });

      final golden = _golden.first;
      final text = await model.embed(
        EmbeddingInput.text(golden.text),
        taskType: _taskFor(golden.role),
      );
      expect(
        _cos(text, golden.vector),
        greaterThanOrEqualTo(_sameBuildAsGolden ? 0.9999 : 0.998),
        reason: 'the 440m carries the 270m\'s text tower, byte for byte',
      );
      final loaded = await _residentBytes();

      final firstWatch = Stopwatch()..start();
      final image = await model.embed(
        EmbeddingInput.image(await _asset(eg2VisionSampleAsset('circle'))),
        taskType: TaskType.retrievalDocument,
      );
      firstWatch.stop();
      expect(image, hasLength(768));
      expect(image.every((v) => v.isFinite), isTrue, reason: 'NaN/infinity');
      expect(_norm(image), closeTo(1.0, 1e-3));
      final afterImage = await _residentBytes();

      final base = await _cacheBase();
      final caches = <String, int>{
        for (final dir in base.listSync().whereType<Directory>())
          for (final file in dir.listSync().whereType<File>())
            if (file.path.contains(
              _openedName(_eg2Vision, _visionFileOverride),
            ))
              file.path.split('.').reversed.elementAt(1): file.lengthSync(),
      };
      _log(
        'vision: getActiveEmbedder(supportImage) '
        '${loadWatch.elapsedMilliseconds} ms, first image '
        '${firstWatch.elapsedMilliseconds} ms; caches MiB '
        '${caches.map((k, v) => MapEntry(k, v ~/ _mb))}; resident MiB '
        'baseline ${_mib(baseline)}, loaded+text ${_mib(loaded)}, after the '
        'first image ${_mib(afterImage)}',
      );
      expect(
        caches.keys,
        containsAll(['text_encoder', 'vision_encoder']),
        reason: 'the engine writes the vision cache at create, in our dir',
      );
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('text → image: each caption finds its scene among ten (raw, '
        'as rag sends a text query over images); M10 compares the query '
        'prefix', (tester) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      final images = <List<double>>[];
      final micros = <int>[];
      for (final scene in _scenes) {
        final bytes = await _asset(eg2VisionSampleAsset(scene));
        final watch = Stopwatch()..start();
        images.add(
          await model.embed(
            EmbeddingInput.image(bytes),
            taskType: TaskType.retrievalDocument,
          ),
        );
        micros.add(watch.elapsedMicroseconds);
      }
      Future<List<List<double>>> captions(TaskType taskType) async => [
        for (final caption in eg2VisionSampleCaptions.values)
          await model.embed(EmbeddingInput.text(caption), taskType: taskType),
      ];
      final raw = _rank(await captions(TaskType.none), images, _scenes);
      final query = _rank(
        await captions(TaskType.retrievalQuery),
        images,
        _scenes,
      );
      _log(
        'text→image (140 tokens/image): per image median '
        '${_median(micros) / 1000} ms, max ${micros.reduce(math.max) / 1000} '
        'ms; raw top-1 ${raw.top1}/10, mean margin '
        '${raw.margin.toStringAsFixed(4)} ${raw.misses}; M10 with '
        'TaskType.retrievalQuery top-1 ${query.top1}/10, mean margin '
        '${query.margin.toStringAsFixed(4)} ${query.misses}',
      );
      expect(raw.top1, 10, reason: '${raw.misses}');
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('image → image: each near-duplicate JPEG (75 %, quality 70) '
        'finds its PNG', (tester) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      final originals = [
        for (final scene in _scenes)
          await model.embed(
            EmbeddingInput.image(await _asset(eg2VisionSampleAsset(scene))),
            taskType: TaskType.retrievalDocument,
          ),
      ];
      final duplicates = [
        for (final scene in _scenes)
          await model.embed(
            EmbeddingInput.image(await _asset(eg2VisionDuplicateAsset(scene))),
            taskType: TaskType.none,
          ),
      ];
      final dup = _rank(duplicates, originals, _scenes);
      final self = [
        for (var i = 0; i < _scenes.length; i++)
          _cos(duplicates[i], originals[i]),
      ];
      _log(
        'image→image: top-1 ${dup.top1}/10, margin '
        '${dup.margin.toStringAsFixed(4)}, cos(duplicate, original) min '
        '${self.reduce(math.min).toStringAsFixed(4)}',
      );
      expect(dup.top1, 10, reason: '${dup.misses}');
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('GIF and BMP decode; WebP, TIFF and HEIC are refused on the '
        'calling isolate with the format named; a truncated PNG is '
        'EmbeddingEngineException(nativeCode: 3), and the model keeps '
        'working', (tester) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      Future<List<double>> embed(Uint8List bytes) =>
          model.embed(EmbeddingInput.image(bytes), taskType: TaskType.none);

      final png = await embed(
        await _asset('assets/eg2_vision/small_circle.png'),
      );
      final gif = await embed(
        await _asset('assets/eg2_vision/small_circle.gif'),
      );
      final bmp = await embed(
        await _asset('assets/eg2_vision/small_circle.bmp'),
      );
      expect(_cos(bmp, png), greaterThan(0.999), reason: 'BMP is lossless');
      expect(_cos(gif, png), greaterThan(0.98), reason: 'GIF is paletted');

      for (final (file, format) in [
        ('small_circle.webp', EncodedMediaFormat.webp),
        ('small_circle.tiff', EncodedMediaFormat.tiff),
        ('small_circle.heic', EncodedMediaFormat.heic),
      ]) {
        final bytes = await _asset('assets/eg2_vision/$file');
        final watch = Stopwatch()..start();
        await expectLater(
          embed(bytes),
          throwsA(
            isA<EmbeddingFormatNotSupportedException>()
                .having((e) => e.detected, 'detected', format)
                .having((e) => e.accepted, 'accepted', _imageFormats)
                .having((e) => e.modality, 'modality', EmbeddingModality.image),
          ),
          reason: file,
        );
        watch.stop();
        // Refused before anything was sent: an image the engine decodes
        // takes 170 ms or more on any device.
        expect(
          watch.elapsed,
          lessThan(const Duration(milliseconds: 100)),
          reason: '$file was refused by the engine, not on this isolate',
        );
      }
      // In a batch, the refusal names the input, before the first is sent.
      await expectLater(
        model.embedAll([
          EmbeddingInput.image(await _asset(eg2VisionSampleAsset('circle'))),
          EmbeddingInput.image(
            await _asset('assets/eg2_vision/small_circle.heic'),
          ),
        ], taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>().having(
            (e) => e.message,
            'message',
            startsWith('Input 1 of 2'),
          ),
        ),
      );

      final whole = await _asset(eg2VisionSampleAsset('circle'));
      await expectLater(
        embed(Uint8List.sublistView(whole, 0, whole.length ~/ 2)),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having((e) => e.nativeCode, 'nativeCode', 3),
        ),
      );
      expect(model.isClosed, isFalse);
      expect(await embed(whole), hasLength(768));
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('LiteRtEmbeddingBackend(visionTokensPerImage: 280) is refused '
        '(only 140 and 70 have signatures)', (tester) async {
      await _ensureEg2Vision();
      final spec = FlutterEdgeAi.activeEmbedderSpec!;
      final config = RuntimeConfig(
        maxTokens: 0,
        modelPath: await FlutterEdgeAi.getModelPath(_eg2Vision.filename),
        supportImage: true,
      );
      await expectLater(
        const LiteRtEmbeddingBackend(
          visionTokensPerImage: 280,
        ).describe(spec, config),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having(
                (e) => e.message,
                'message',
                contains('visionTokensPerImage: 280'),
              ),
        ),
      );
      // The default and the opt-in are accepted.
      for (final budget in [140, 70]) {
        await LiteRtEmbeddingBackend(
          visionTokensPerImage: budget,
        ).describe(spec, config);
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('the calling isolate stays live during a batch of 20 images '
        '(#299)', (tester) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      final inputs = [
        for (var i = 0; i < 20; i++)
          EmbeddingInput.image(
            await _asset(eg2VisionSampleAsset(_scenes[i % _scenes.length])),
          ),
      ];
      await model.embed(inputs.first, taskType: TaskType.none); // warm up

      var ticks = 0;
      var longestGap = Duration.zero;
      var running = true;
      final gapWatch = Stopwatch()..start();
      Future<void> spin() async {
        while (running) {
          ticks++;
          final gap = gapWatch.elapsed;
          if (gap > longestGap) longestGap = gap;
          gapWatch.reset();
          await Future<void>.delayed(Duration.zero);
        }
      }

      final spinner = spin();
      final batchWatch = Stopwatch()..start();
      final vectors = await model.embedAll(
        inputs,
        taskType: TaskType.retrievalDocument,
      );
      batchWatch.stop();
      running = false;
      await spinner;

      expect(vectors, hasLength(20));
      _log(
        '#299 images: 20 in ${batchWatch.elapsedMilliseconds} ms '
        '(${(batchWatch.elapsedMilliseconds / 20).toStringAsFixed(0)} ms '
        'each); main-isolate ticks $ticks, longest gap '
        '${longestGap.inMilliseconds} ms',
      );
      expect(
        ticks,
        greaterThan(10 * inputs.length),
        reason: 'the calling isolate barely advanced: a forward pass blocks it',
      );
      expect(
        longestGap,
        lessThan(const Duration(milliseconds: 500)),
        reason: 'the calling isolate froze for ${longestGap.inMilliseconds} ms',
      );
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('a RAG image index: add the scenes, find one by text, and the '
        'location refuses to reopen for text', (tester) async {
      await _ensureEg2Vision();
      final rag = FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      );
      final location =
          '${await _scratch('rag')}${Platform.pathSeparator}photos.db';
      final openWatch = Stopwatch()..start();
      final photos = await rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: location,
          documents: EmbeddingModality.image,
        ),
        embedder: FlutterEdgeAiActiveEmbedder(
          profileId: _eg2Vision.imageRagProfileId!,
          supportImage: true,
        ),
      );
      openWatch.stop();
      try {
        expect(photos.documents, EmbeddingModality.image);
        expect(photos.embeddingProfile.id, endsWith('-vis140'));
        final addMs = <int>[];
        for (final scene in _scenes) {
          final addWatch = Stopwatch()..start();
          await photos.add(
            id: scene,
            document: EmbeddingInput.image(
              await _asset(eg2VisionSampleAsset(scene)),
            ),
            content: 'asset:${eg2VisionSampleAsset(scene)}',
          );
          addMs.add(addWatch.elapsedMilliseconds);
        }
        await photos.flush();
        _log(
          'rag image index: open ${openWatch.elapsedMilliseconds} ms; add '
          '(embed + store) per photo $addMs ms',
        );
        expect((await photos.stats()).documentCount, 10);
        for (final scene in ['stop_sign', 'taxi_receipt', 'pie_chart']) {
          final hits = await photos.search(
            query: EmbeddingInput.text(eg2VisionSampleCaptions[scene]!),
            topK: 3,
          );
          _log(
            'rag "${eg2VisionSampleCaptions[scene]}": '
            '${[for (final h in hits) '${h.id} ${h.similarity.toStringAsFixed(3)}']}',
          );
          expect(hits.first.id, scene);
          expect(hits.first.content, 'asset:${eg2VisionSampleAsset(scene)}');
        }
        final byPhoto = await photos.search(
          query: EmbeddingInput.image(
            await _asset(eg2VisionDuplicateAsset('house_scene')),
          ),
          topK: 1,
        );
        expect(byPhoto.single.id, 'house_scene');
      } finally {
        await photos.dispose();
      }

      await expectLater(
        rag.open(
          spec: VectorStoreSpec(
            providerId: SqliteVectorStoreProvider.providerId,
            location: location,
          ),
          embedder: FlutterEdgeAiActiveEmbedder(
            profileId: _eg2Vision.ragProfileId,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('is bound to'),
          ),
        ),
      );
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('a text index and an image index on one bundle, used in '
        'turn: one rebuild, no EmbedderClosedException', (tester) async {
      await _ensureEg2Vision();
      await _closeActive();
      final rag = FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      );
      final dir = await _scratch('two');
      final sep = Platform.pathSeparator;
      final notes = await rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: '$dir${sep}notes.db',
        ),
        embedder: FlutterEdgeAiActiveEmbedder(
          profileId: _eg2Vision.ragProfileId,
        ),
      );
      final textModel = await FlutterEdgeAi.getActiveEmbedder();
      expect(textModel.modalities, {EmbeddingModality.text});

      final photos = await rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: '$dir${sep}photos.db',
          documents: EmbeddingModality.image,
        ),
        embedder: FlutterEdgeAiActiveEmbedder(
          profileId: _eg2Vision.imageRagProfileId!,
          supportImage: true,
        ),
      );
      final both = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      expect(textModel.isClosed, isTrue, reason: 'widened once, to both');
      expect(both.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      try {
        for (var round = 0; round < 3; round++) {
          final scene = _scenes[round];
          await notes.add(
            id: 'note-$round',
            document: EmbeddingInput.text(
              'Note $round: ${eg2VisionSampleCaptions[scene]}',
            ),
          );
          await photos.add(
            id: scene,
            document: EmbeddingInput.image(
              await _asset(eg2VisionSampleAsset(scene)),
            ),
            content: 'asset:${eg2VisionSampleAsset(scene)}',
          );
          expect(
            await notes.search(query: EmbeddingInput.text(scene), topK: 1),
            hasLength(1),
          );
          expect(
            await photos.search(
              query: EmbeddingInput.text(eg2VisionSampleCaptions[scene]!),
              topK: 1,
            ),
            hasLength(1),
          );
        }
        expect(
          identical(await FlutterEdgeAi.getActiveEmbedder(), both),
          isTrue,
          reason: 'the text index is served by the widened model: no rebuild',
        );
        expect(both.isClosed, isFalse);
      } finally {
        await notes.dispose();
        await photos.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('EXIF: a camera JPEG stored sideways is embedded sideways '
        'from its raw bytes, and upright through the example\'s flow', (
      tester,
    ) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      Future<List<double>> embed(Uint8List bytes) =>
          model.embed(EmbeddingInput.image(bytes), taskType: TaskType.none);
      final rotated = await _asset('assets/eg2_vision/portrait_exif6.jpg');
      final upright = await _asset('assets/eg2_vision/portrait_upright.jpg');

      final before = _cos(await embed(rotated), await embed(upright));
      final preparedRotated = await preparePhotoForEmbedding(rotated);
      final preparedUpright = await preparePhotoForEmbedding(upright);
      final after = _cos(
        await embed(preparedRotated.bytes),
        await embed(preparedUpright.bytes),
      );
      _log(
        'EXIF 6 vs its upright twin: raw bytes cos ${before.toStringAsFixed(4)}'
        ', prepared cos ${after.toStringAsFixed(4)}; this platform decodes the '
        'camera JPEG as ${preparedRotated.width}x${preparedRotated.height}',
      );
      // Flutter applies the EXIF orientation on this platform.
      expect((preparedRotated.width, preparedRotated.height), (480, 640));
      expect(after, greaterThan(0.99), reason: 'the same picture, upright');
      expect(after, greaterThan(before), reason: 'the raw bytes lie sideways');
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('a 12 MP photo: raw bytes vs prepared to 1024 px', (
      tester,
    ) async {
      await _ensureEg2Vision();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
      final large = await _asset('assets/eg2_vision/large_12mp.jpg');
      // Warm the vision tower first, so neither side pays for it.
      await model.embed(
        EmbeddingInput.image(await _asset(eg2VisionSampleAsset('circle'))),
        taskType: TaskType.none,
      );
      final rawMs = <int>[], prepareMs = <int>[], preparedMs = <int>[];
      late List<double> raw, prepared;
      for (var i = 0; i < 3; i++) {
        var watch = Stopwatch()..start();
        raw = await model.embed(
          EmbeddingInput.image(large),
          taskType: TaskType.none,
        );
        rawMs.add(watch.elapsedMilliseconds);
        watch = Stopwatch()..start();
        final photo = await preparePhotoForEmbedding(large);
        prepareMs.add(watch.elapsedMilliseconds);
        expect((photo.width, photo.height), (1024, 768));
        watch = Stopwatch()..start();
        prepared = await model.embed(
          EmbeddingInput.image(photo.bytes),
          taskType: TaskType.none,
        );
        preparedMs.add(watch.elapsedMilliseconds);
      }
      _log(
        '12 MP (4032x3024, ${large.length ~/ 1024} KiB JPEG): raw embed '
        '$rawMs ms; prepare (decode to 1024 + BMP) $prepareMs ms + embed '
        '$preparedMs ms; cos(raw, prepared) ${_cos(raw, prepared).toStringAsFixed(4)}',
      );
      expect(_cos(raw, prepared), greaterThan(0.95), reason: 'same scene');
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('the ten scenes at 70 vision tokens per image: per-image time '
        'and text → image top-1', (tester) async {
      await _ensureEg2Vision();
      // One engine at a time: the cached 140-token embedder goes first.
      await _closeActive();
      final spec = FlutterEdgeAi.activeEmbedderSpec!;
      final descriptor =
          await const LiteRtEmbeddingBackend(visionTokensPerImage: 70).describe(
            spec,
            RuntimeConfig(
              maxTokens: 0,
              modelPath: await FlutterEdgeAi.getModelPath(_eg2Vision.filename),
              supportImage: true,
            ),
          );
      // The pass itself, on this isolate (no worker): its calls block it,
      // which a test can afford.
      final pass = descriptor.build();
      await pass.load();
      try {
        final images = <List<double>>[];
        final micros = <int>[];
        for (final scene in _scenes) {
          final bytes = await _asset(eg2VisionSampleAsset(scene));
          final watch = Stopwatch()..start();
          images.add(
            await pass.embed(
              EmbeddingInput.image(bytes),
              TaskType.retrievalDocument,
            ),
          );
          micros.add(watch.elapsedMicroseconds);
        }
        final captions = [
          for (final caption in eg2VisionSampleCaptions.values)
            await pass.embed(EmbeddingInput.text(caption), TaskType.none),
        ];
        final rank = _rank(captions, images, _scenes);
        _log(
          '70 tokens/image: per image median ${_median(micros) / 1000} ms, max '
          '${micros.reduce(math.max) / 1000} ms; text→image top-1 '
          '${rank.top1}/10, mean margin ${rank.margin.toStringAsFixed(4)} '
          '${rank.misses}',
        );
        expect(rank.top1, 10, reason: '${rank.misses}');
      } finally {
        await pass.close();
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('the Image Search screen on the real 440m: the samples, a '
        'text, and a photo find the right scenes', (tester) async {
      await _ensureEg2Vision();
      final app = imageSearchAppDependencies();
      final pieDuplicate = (
        name: 'pie_chart_dup.jpg',
        bytes: await _asset(eg2VisionDuplicateAsset('pie_chart')),
      );
      final local =
          _visionFileOverride.isNotEmpty || _visionUrlOverride.isNotEmpty;
      final dependencies = ImageSearchDependencies(
        hasActiveEmbedder: app.hasActiveEmbedder,
        // A local copy or a mirror is not the catalog's source, so the app's
        // provenance (rightly) cannot name its space; _ensureEg2Vision checked
        // its SHA-256, so the catalog's id is the true one.
        textProfileId: local
            ? () async => _eg2Vision.ragProfileId
            : app.textProfileId,
        loadEmbedder: app.loadEmbedder,
        ragEmbedder: app.ragEmbedder,
        openIndex: app.openIndex,
        photos: app.photos,
        // No photo library on a test device: the query photo is handed in.
        pickPhotos: () async => const <PickedPhotoSource>[],
        pickQueryPhoto: () async => pieDuplicate,
        loadSample: app.loadSample,
      );
      tester.view
        ..physicalSize = const Size(1200, 4000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      /// Waits until [finder] shows AND the screen is idle (no operation
      /// running: its controls are enabled again), failing on an error card.
      Future<void> until(Finder finder, String what) async {
        final watch = Stopwatch()..start();
        final error = find.byKey(const Key('image-search-error'));
        final busy = find.byType(LinearProgressIndicator);
        while (finder.evaluate().isEmpty || busy.evaluate().isNotEmpty) {
          if (error.evaluate().isNotEmpty) {
            final text = find.descendant(
              of: error,
              matching: find.byType(SelectableText),
            );
            fail(
              'the screen shows an error while waiting for $what: '
              '${tester.widget<SelectableText>(text).data}',
            );
          }
          if (watch.elapsed > const Duration(minutes: 5)) {
            fail('waited 5 minutes for $what');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      }

      String text(String key) =>
          tester.widget<Text>(find.byKey(Key(key))).data!;

      await tester.pumpWidget(
        MaterialApp(home: ImageSearchScreen(dependencies: dependencies)),
      );
      await until(
        find.byKey(const Key('image-search-add-samples')),
        'the image index to open',
      );
      expect(find.byKey(const Key('image-search-error')), findsNothing);
      expect(find.textContaining('Backend: cpu · loaded in'), findsOneWidget);

      await tester.tap(find.byKey(const Key('image-search-add-samples')));
      await tester.pump();
      await until(
        find.textContaining('Per image:'),
        'the samples to be embedded',
      );
      expect(text('image-search-count'), endsWith('photos in the index'));

      await tester.enterText(
        find.byKey(const Key('image-search-query')),
        'a red stop sign',
      );
      await tester.tap(find.byKey(const Key('image-search-search-text')));
      await tester.pump();
      await until(
        find.textContaining('Closest to "a red stop sign"'),
        'the text search',
      );
      expect(text('image-search-label-0'), 'stop_sign.png');
      final textScore = text('image-search-score-0');

      await tester.tap(find.byKey(const Key('image-search-search-photo')));
      await tester.pump();
      await until(
        find.textContaining('Closest to pie_chart_dup.jpg'),
        'the photo search',
      );
      expect(text('image-search-label-0'), 'pie_chart.png');
      _log(
        'screen: ${[for (final line in find.textContaining('Per image:').evaluate()) (line.widget as Text).data]}; '
        'top hit for the text $textScore, for the photo '
        '${text('image-search-score-0')}',
      );

      await tester.tap(find.byKey(const Key('image-search-clear')));
      await tester.pump();
      await until(
        find.text('0 photos in the index'),
        'the index to be cleared',
      );
      expect(find.byKey(const Key('image-search-error')), findsNothing);
      await tester.pumpWidget(const SizedBox()); // disposes: closes the model
    }, timeout: const Timeout(Duration(minutes: 20)));
  });
}

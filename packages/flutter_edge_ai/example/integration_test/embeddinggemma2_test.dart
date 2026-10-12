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
// - an over-long text is EmbeddingInputTooLongException(1024, null) and the
//   model keeps working;
// - the calling isolate stays live during a 50-text batch (#299);
// - closing during a batch returns, fails the queued requests with
//   EmbedderClosedException, and gives the memory back (M12; measured on
//   Android only: iOS reports no file-backed pages);
// - an LLM .litertlm installed as an embedder is refused at load;
// - supportImage is refused in 1.13.0, and the text embedder survives it;
// - close and recreate.
// It prints load and per-embed timings, and the cosines.
//
// No setUp/setUpAll (Rule 6b): each test body calls the guarded
// `_ensureEg2()`, which installs the pinned revision (a no-op once installed),
// makes it the active embedder and, once per run, checks the file's SHA-256.
// The bundle is ungated. Runs on Android, iOS, macOS, Linux and Windows:
//   flutter test integration_test/embeddinggemma2_test.dart -d <device>
// Optional: --dart-define=EG2_MODEL_URL=<a copy of the same bytes> (a mirror),
// or --dart-define=EG2_MODEL_FILE=<path the app can read> (a local copy; on
// macOS that is inside the app's sandbox container). Either must have the
// pinned SHA-256, or the suite fails before comparing anything.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'goldens/eg2_text_golden.dart';
import 'goldens/litertlm_llm_header.dart';

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');

const _textOnly =
    'flutter_edge_ai_litertlm 1.13.0 embeds text only; images arrive in '
    '1.14.0, audio in 1.16.0';

const _mb = 1024 * 1024;

// ── Guarded set-up (Rule 6b: called first thing in every test body) ────────

bool _initialized = false;
bool _verified = false;

/// Registers the LiteRT backend once — and no tokenizer provider: an
/// EmbeddingGemma 2 app needs none. Installs the pinned bundle (a no-op once
/// installed), makes it the active embedder, and checks its SHA-256 once.
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
  if (_verified) return;
  final path = await FlutterEdgeAi.getModelPath(_eg2.filename);
  final digest = await sha256.bind(File(path).openRead()).first;
  expect(
    '$digest',
    _eg2.sha256,
    reason:
        '$path is not the pinned embeddinggemma-2-text-270m.litertlm '
        '(revision 9be6e8b9); every comparison below would be against the '
        'wrong file',
  );
  _verified = true;
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
    // The engine names its cache after the file it opened. With
    // EG2_MODEL_FILE that is the local copy, read in place under its own
    // name, not `_eg2.filename`.
    final modelFile = (await FlutterEdgeAi.getModelPath(
      _eg2.filename,
    )).split(RegExp(r'[/\\]')).last;
    final caches = [
      for (final dir in base.listSync().whereType<Directory>())
        for (final file in dir.listSync().whereType<File>())
          if (file.path.endsWith('.xnnpack_cache') &&
              file.path.contains(modelFile))
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
      reason: 'no .xnnpack_cache for $modelFile under ${base.path}',
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

    for (var i = 0; i < 6; i++) {
      final scores = [
        for (var j = 0; j < 6; j++) _cos(vectors['q$i']!, vectors['d$j']!),
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

  testWidgets('an over-long text is EmbeddingInputTooLongException(1024, '
      'null), and the model keeps working', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    final text = 'lorem ipsum dolor sit amet ' * 2300; // ~62,000 characters
    await expectLater(
      model.embed(EmbeddingInput.text(text), taskType: TaskType.retrievalQuery),
      throwsA(
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
            .having(
              (e) => e.maxInputTokens,
              'model.maxInputTokens',
              model.maxInputTokens,
            )
            .having((e) => e.actualTokens, 'actualTokens', isNull),
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

  testWidgets('supportImage is refused in 1.13.0, and the text embedder '
      'survives it', (tester) async {
    await _ensureEg2();
    final model = await FlutterEdgeAi.getActiveEmbedder();
    await expectLater(
      FlutterEdgeAi.getActiveEmbedder(supportImage: true),
      throwsA(
        isA<EmbeddingLoadException>()
            .having((e) => e.engine, 'engine', 'LiteRT-LM')
            .having((e) => e.message, 'message', _textOnly),
      ),
    );
    expect(model.isClosed, isFalse, reason: 'refused before anything closed');
    expect(identical(await FlutterEdgeAi.getActiveEmbedder(), model), isTrue);
    expect(
      await model.embed(
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
    // Core refuses a model file under 1 MiB before any engine sees it; the
    // zeros after the LlmMetadata section are never read by ModelInfo.
    final padded = Uint8List(_mb + 1)..setAll(0, bytes);
    await file.writeAsBytes(padded, flush: true);
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
}

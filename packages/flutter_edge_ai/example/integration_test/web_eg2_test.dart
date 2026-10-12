/// EmbeddingGemma 2 in the browser (R5 §7 P2w, §10.3): the pinned
/// litert-community 270m (text) and 440m (text + vision) bundles through
/// `installEmbedder()` → `getActiveEmbedder()` → core's inline host →
/// flutter_edge_ai_litertlm's web `.litertlm` pass → `@litert-lm/core` 0.18.0's
/// `EmbeddingEngine` on WebGPU, with `WebStorageMode.cacheApi`. WebGPU because
/// the runtime's CPU (WebAssembly) path cannot load these bundles ("Failed to
/// get external weight for buffer id …"); there is no CPU fallback.
///
/// What it holds the browser to:
/// - 768 dimensions, unit norm, finite; `maxInputTokens` 1024; `{text}`; GPU;
/// - the native golden (integration_test/goldens/eg2_text_golden.dart, from
///   native-v0.18.0-d on macOS arm64, CPU): every vector finite and non-zero,
///   cos >= 0.99 against `vector` (WebGPU drifts from the native CPU, measured
///   about 0.995), >= 0.97 against Sentence Transformers fp32; every query
///   ranks its document first;
/// - the 9 TaskTypes give 9 different vectors; empty text embeds;
/// - W2 and the exact overflow counts: a text of exactly 1024 tokens (prefix,
///   BOS and EOS included) embeds, 1025 and 3000 are
///   EmbeddingInputTooLongException(1024, 1025 / 3000) — counts from Python
///   sentencepiece 0.2.2 on the bundle's own tokenizer (sha256 e594c8a9…), the
///   measurement's `text_with_total` — and the model keeps working;
/// - a page without `window.EmbeddingEngine = m.EmbeddingEngine;` fails the
///   load with the EmbeddingLoadException that names the line;
/// - supportImage on the 270m is refused naming the 440m;
/// - the 440m: {text, image}; each scene's vector against the native CPU
///   image golden (cos >= 0.99; measured about 0.998); text → image top-1
///   10/10 on the ten scenes; across platforms (integration_test/goldens/
///   eg2_image_golden.dart): the web captions find the native image vectors,
///   and the native caption vectors find the web image vectors, top-1 10/10
///   each — an index built on one platform answers queries from the other;
///   near-duplicate JPEG → its PNG 10/10; GIF/BMP decode; WebP/TIFF/HEIC are
///   refused before anything is sent; a truncated PNG is
///   EmbeddingEngineException and the model keeps working; 70 tokens per
///   image through the public describe();
/// - the example's photo preparation in the browser (CanvasKit / skwasm
///   decode, the BMP written on the page): a 12 MP JPEG becomes 1024x768, and
///   a camera JPEG stored sideways (EXIF 6) comes out upright — its vector
///   matches its upright twin's (cos > 0.99);
/// - the Image Search screen on the 440m, with a photo kept in OPFS;
/// - close and recreate: the same vectors;
/// - a page without WebGPU (`navigator.gpu` hidden): the load is refused
///   before `EmbeddingEngine.create`, with the EmbeddingLoadException that
///   says EmbeddingGemma 2 on the web needs WebGPU and why;
/// - last: the CPU path, asked for directly, still fails in
///   `EmbeddingEngine.create` on both bundles, and the error says why — the
///   day a newer `@litert-lm/core` loads them there, this test says so.
/// Measured, never asserted (in the response file and the log):
/// - M11: the longest main-thread stall while images and texts are embedded
///   on WebGPU;
/// - short-text latency with the runtime's single 1024 signature vs
///   `minInputLength: 128`.
///
/// GCE VM only (never a local browser). Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive \
///     --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_eg2_test.dart \
///     -d web-server --browser-name=chrome --headless
/// then the same with `-d chrome`. The browser needs WebGPU with a GPU behind
/// it (on the VM: `--enable-unsafe-webgpu`, Vulkan, a real display). Both
/// bundles are ungated (165 MB + 388 MB on the first run);
/// `--dart-define=EG2_MODEL_URL=…` and
/// `--dart-define=EG2_440M_MODEL_URL=…` serve the same bytes from elsewhere
/// (each is checked against its pinned SHA-256 before anything is compared).
///
/// The driver writes this suite's data to `build/web_eg2_response.json` even
/// when a test fails.
///
/// Rule 6b: no setUp/setUpAll — every fallible step is a guarded helper called
/// inside the test body, and the last test checks that every test before it
/// started. After a green run, confirm the report lists all of them.
@TestOn('chrome')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/engine.dart' show RuntimeConfig;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/image_search/eg2_vision_samples.dart';
import 'package:flutter_edge_ai_example/image_search/image_search_app_dependencies.dart';
import 'package:flutter_edge_ai_example/image_search/image_search_controller.dart';
import 'package:flutter_edge_ai_example/image_search/photo_preparation.dart';
import 'package:flutter_edge_ai_example/image_search_screen.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
// ignore: implementation_imports — the CPU record and the minInputLength measurement build the web pass with a backend and a setting the public backend does not offer
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'goldens/eg2_image_golden.dart';
import 'goldens/eg2_text_golden.dart';
import 'web_embeddings_support.dart';

/// Every test in this file, in order; the last one checks they all started.
const _tests = [
  'EG2 load',
  'EG2 golden',
  'EG2 task types',
  'EG2 empty text',
  'EG2 overflow',
  'EG2 shim missing',
  'EG2 270m images refused',
  'EG2 close and recreate',
  'EG2 440m load',
  'EG2 text to image',
  'EG2 cross-platform retrieval',
  'EG2 image to image',
  'EG2 formats',
  'EG2 70 tokens',
  'photo preparation',
  'M11',
  'Image Search screen',
  'minInputLength',
  'no WebGPU',
  // Last: a CPU failure that took the page's WASM module down must not fail
  // a WebGPU test after it.
  'CPU refused',
];

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _eg2Vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _visionUrlOverride = String.fromEnvironment('EG2_440M_MODEL_URL');

final _scenes = eg2VisionSampleCaptions.keys.toList();

/// What LiteRT-LM decodes, as the 440m reports it at load.
final _imageFormats = {
  EncodedMediaFormat.jpeg,
  EncodedMediaFormat.png,
  EncodedMediaFormat.gif,
  EncodedMediaFormat.bmp,
};

// ── Guarded set-up (Rule 6b: called first thing in every test body) ────────

final _verified = <catalog.EmbeddingModel>{};

/// Installs [model] (a no-op once installed), makes it the active embedder
/// and, once per run, checks the installed bytes against its pinned SHA-256.
Future<void> _ensure(catalog.EmbeddingModel model, String urlOverride) async {
  await ensureInitialized(WebStorageMode.cacheApi);
  await FlutterEdgeAi.installEmbedder()
      .modelFromNetwork(
        urlOverride.isEmpty ? model.url : urlOverride,
        filename: model.filename,
      )
      .install();
  if (_verified.contains(model)) return;
  final digest = await _sha256(await _installedUrl());
  expect(
    digest,
    model.sha256,
    reason:
        'the installed ${model.filename} is not the pinned bundle; every '
        'comparison below would be against the wrong file',
  );
  _verified.add(model);
}

Future<void> _ensureEg2() => _ensure(_eg2, _urlOverride);

Future<void> _ensureEg2Vision() => _ensure(_eg2Vision, _visionUrlOverride);

/// The URL core registered for the active (self-contained) embedder: a
/// `blob:` URL of the Cache API copy.
Future<String> _installedUrl() async {
  final spec = FlutterEdgeAi.activeEmbedderSpec!;
  final paths = await FlutterEdgeAiPlugin.instance.modelManager
      .getModelFilePaths(spec);
  expect(paths, isNotNull, reason: '${spec.name} is not installed');
  expect(paths!.values, hasLength(1), reason: 'a .litertlm is one file');
  return paths.values.single;
}

/// SHA-256 of what [url] serves, by the browser's own digest.
Future<String> _sha256(String url) async {
  final digest = globalContext.callMethod<JSPromise<JSString>>(
    'eval'.toJS,
    '''
    (async () => {
      const bytes = await (await fetch(${jsonEncode(url)})).arrayBuffer();
      const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
      return Array.from(hash, (b) => b.toString(16).padStart(2, '0')).join('');
    })()
    '''
        .toJS,
  );
  return (await digest.toDart).toDart;
}

/// The embedder the suite last got from `getActiveEmbedder()` — the one core
/// has cached, while it is open.
EmbeddingModel? _held;

/// `getActiveEmbedder()`, remembering the model so [_releaseActive] can close
/// it without building a new one first.
Future<EmbeddingModel> _active({bool images = false}) async =>
    _held = await FlutterEdgeAi.getActiveEmbedder(supportImage: images);

/// Closes the cached embedder, if one is open, so the next
/// `getActiveEmbedder()` builds — or so a pass built directly is the only
/// engine on the page.
Future<void> _releaseActive() async {
  final model = _held;
  _held = null;
  if (model != null && !model.isClosed) await model.close();
}

void _start(String name) {
  expect(_tests, contains(name));
  startedTests.add(name);
}

void _log(String line) {
  // ignore: avoid_print
  print('[web-eg2] $line');
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

final _imageGoldenJson = jsonDecode(eg2ImageGoldenJson) as Map;

/// The 440m's native CPU vector for each scene (140 tokens per image):
/// integration_test/goldens/eg2_image_golden.dart, written by
/// flutter_edge_ai_litertlm's test/eg2_image_golden_test.dart.
final Map<String, List<double>> _imageGolden = {
  for (final MapEntry(:key, :value)
      in (_imageGoldenJson['images'] as Map)
          .cast<String, Map<String, dynamic>>()
          .entries)
    key: _f32(value['vector_f32le'] as String),
};

/// The same pass's native CPU text vector of each scene's caption
/// (TaskType.none), and the caption it was computed from.
final Map<String, ({String text, List<double> vector})> _captionGolden = {
  for (final MapEntry(:key, :value)
      in (_imageGoldenJson['captions'] as Map)
          .cast<String, Map<String, dynamic>>()
          .entries)
    key: (
      text: value['text'] as String,
      vector: _f32(value['vector_f32le'] as String),
    ),
};

/// The bar the web's WebGPU vectors are held to against the native CPU
/// goldens: measured on a Tesla T4 (Chrome 155), text min cos 0.99486 and
/// images 0.99766 — reduced-precision GPU arithmetic, not a different model.
const _vsNativeCpu = 0.99;

TaskType _taskFor(String role) =>
    role == 'query' ? TaskType.retrievalQuery : TaskType.retrievalDocument;

// ── Overflow texts (W2) ────────────────────────────────────────────────────

/// `TaskType.retrievalQuery`'s prefix + `'the'` tokenizes to 10 tokens with
/// BOS and EOS (Python sentencepiece 0.2.2 on the bundle's tokenizer, sha256
/// e594c8a9…); each further `' the'` is one token.
const _queryBase = 10;

/// A text that, under `TaskType.retrievalQuery`, is exactly [tokens] tokens —
/// prefix, BOS and EOS included.
String _textOfTokens(int tokens) => 'the${' the' * (tokens - _queryBase)}';

// ── Images ──────────────────────────────────────────────────────────────────

Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

double _median(List<int> values) =>
    (values.toList()..sort())[values.length ~/ 2] / 1000;

/// Each query's rank among [documents]: top-1 count and the mean margin of
/// the right document over the best wrong one.
({int top1, double margin, List<String> misses}) _rank(
  List<List<double>> queries,
  List<List<double>> documents,
) {
  var top1 = 0;
  var margin = 0.0;
  final misses = <String>[];
  for (var i = 0; i < queries.length; i++) {
    final scores = [for (final d in documents) cosine(queries[i], d)];
    final best = scores.indexOf(scores.reduce(math.max));
    if (best == i) {
      top1++;
    } else {
      misses.add('${_scenes[i]}->${_scenes[best]}');
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

/// The web (WebGPU) vectors of the ten scenes, kept for the comparisons
/// after the test that makes them.
final _webSceneVectors = <String, List<double>>{};

// ── M11: main-thread stalls ─────────────────────────────────────────────────

/// Runs [work] while a 4 ms timer ticks on the page's main thread, and
/// reports how long the longest stretch without a tick was — the time the
/// page could not paint a frame.
Future<(T, Map<String, Object>)> _watchMainThread<T>(
  Future<T> Function() work,
) async {
  final watch = Stopwatch()..start();
  var last = 0;
  var longest = 0;
  var ticks = 0;
  var over50 = 0;
  final timer = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final now = watch.elapsedMilliseconds;
    final gap = now - last;
    if (gap > longest) longest = gap;
    if (gap > 50) over50++;
    last = now;
    ticks++;
  });
  try {
    final result = await work();
    final now = watch.elapsedMilliseconds;
    longest = math.max(longest, now - last);
    return (
      result,
      <String, Object>{
        'totalMs': now,
        'ticks': ticks,
        'longestStallMs': longest,
        'stallsOver50Ms': over50,
      },
    );
  } finally {
    timer.cancel();
  }
}

/// What the page reports about where it runs.
Map<String, Object?> _page() => {
  'userAgent': (globalContext['navigator']! as JSObject)
      .getProperty<JSString>('userAgent'.toJS)
      .toDart,
  'webgpu': (globalContext['navigator']! as JSObject).has('gpu'),
  'crossOriginIsolated': globalContext
      .getProperty<JSBoolean?>('crossOriginIsolated'.toJS)
      ?.toDart,
  'hardwareConcurrency': (globalContext['navigator']! as JSObject)
      .getProperty<JSNumber?>('hardwareConcurrency'.toJS)
      ?.toDartInt,
};

/// A web pass of the installed bundle built directly — for what the public
/// backend does not offer (the CPU backend, `minInputLength`).
Future<LiteRtLmWebEmbeddingPass> _directPass({
  required catalog.EmbeddingModel model,
  LiteRtLmWebBackend backend = LiteRtLmWebBackend.gpu,
  bool images = false,
  int? minInputLength,
}) async {
  final spec = FlutterEdgeAi.activeEmbedderSpec!;
  final described = await const LiteRtEmbeddingBackend().describe(
    spec,
    RuntimeConfig(
      maxTokens: 0,
      modelPath: await _installedUrl(),
      supportImage: images,
    ),
  );
  final config = described.config as LiteRtLmWebEmbeddingConfig;
  return LiteRtLmWebEmbeddingPass(
    LiteRtLmWebEmbeddingConfig(
      modelPath: config.modelPath,
      fileName: model.filename,
      runtime: config.runtime,
      resolveUrl: config.resolveUrl,
      revokeUrl: config.revokeUrl,
      declaredMedia: config.declaredMedia,
      visionTokensPerImage: config.visionTokensPerImage,
      backend: backend,
      minInputLength: minInputLength,
    ),
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_eg2_response');

  testWidgets('the 270m loads in getActiveEmbedder: 768 dims, 1024 tokens, '
      'text, GPU', (tester) async {
    _start('EG2 load');
    report('page', _page());
    await _ensureEg2();
    await _releaseActive();

    final load = Stopwatch()..start();
    final model = await _active();
    load.stop();
    expect(model.dimension, 768);
    expect(model.maxInputTokens, 1024);
    expect(model.modalities, {EmbeddingModality.text});
    expect(model.activeBackend, PreferredBackend.gpu);

    final first = Stopwatch()..start();
    final vector = await model.embed(
      EmbeddingInput.text('The northern lights over Tromsø.'),
      taskType: TaskType.retrievalDocument,
    );
    first.stop();
    expectUnitVector(vector, 768, what: 'first embed');
    report('eg2_load', {
      'getActiveEmbedderMs': load.elapsedMilliseconds,
      'firstEmbedMs': first.elapsedMilliseconds,
    });
    _log(
      'getActiveEmbedder ${load.elapsedMilliseconds} ms, first embed '
      '${first.elapsedMilliseconds} ms',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('WebGPU reproduces the native CPU golden (finite, non-zero, '
      'cos >= 0.99) and ranks every query\'s document first', (tester) async {
    _start('EG2 golden');
    await _ensureEg2();
    final model = await _active();
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
      expectUnitVector(vector, 768, what: item.id);
      worstGolden = math.min(worstGolden, cosine(vector, item.vector));
      worstSt = math.min(worstSt, cosine(vector, item.stVector));
      vectors[item.id] = vector;
    }
    report('eg2_golden', {
      'minCosVsNativeCpu': worstGolden,
      'minCosVsStFp32': worstSt,
      'perEmbedMedianMs': _median(micros),
      'perEmbedMaxMs': micros.reduce(math.max) / 1000,
    });
    _log(
      'golden: min cos vs native CPU $worstGolden, vs ST fp32 $worstSt; per '
      'embed median ${_median(micros)} ms',
    );
    expect(worstGolden, greaterThanOrEqualTo(_vsNativeCpu));
    expect(worstSt, greaterThanOrEqualTo(0.97));
    for (var i = 0; i < 6; i++) {
      final scores = [
        for (var j = 0; j < 6; j++) cosine(vectors['q$i']!, vectors['d$j']!),
      ];
      expect(scores.indexOf(scores.reduce(math.max)), i, reason: '$scores');
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('the 9 TaskTypes give 9 different vectors', (tester) async {
    _start('EG2 task types');
    await _ensureEg2();
    await expectEveryTaskTypeDistinct(
      await _active(),
      'How tall is Mount Everest?',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('empty and whitespace-only text embed, as on native', (
    tester,
  ) async {
    _start('EG2 empty text');
    await _ensureEg2();
    final model = await _active();
    for (final text in ['', '   ']) {
      expectUnitVector(
        await model.embed(
          EmbeddingInput.text(text),
          taskType: TaskType.retrievalQuery,
        ),
        768,
        what: '"$text"',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('W2: 1024 tokens embed; 1025 and 3000 are '
      'EmbeddingInputTooLongException with the exact counts; the model keeps '
      'working', (tester) async {
    _start('EG2 overflow');
    await _ensureEg2();
    final model = await _active();
    expectUnitVector(
      await model.embed(
        EmbeddingInput.text(_textOfTokens(1024)),
        taskType: TaskType.retrievalQuery,
      ),
      768,
      what: 'exactly 1024 tokens',
    );
    for (final tokens in [1025, 3000]) {
      await expectLater(
        model.embed(
          EmbeddingInput.text(_textOfTokens(tokens)),
          taskType: TaskType.retrievalQuery,
        ),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', tokens),
        ),
      );
    }
    expect(model.isClosed, isFalse);
    expectUnitVector(
      await model.embed(
        EmbeddingInput.text('still working'),
        taskType: TaskType.retrievalQuery,
      ),
      768,
      what: 'after the overflows',
    );
    report('w2', {'maxInputTokens': model.maxInputTokens, 'boundary': 1024});
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('a page without window.EmbeddingEngine fails the load with the '
      'EmbeddingLoadException naming the line', (tester) async {
    _start('EG2 shim missing');
    await _ensureEg2();
    await _releaseActive();
    final saved = globalContext['EmbeddingEngine'];
    globalContext.delete('EmbeddingEngine'.toJS);
    try {
      await expectLater(
        FlutterEdgeAi.getActiveEmbedder(),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having(
                (e) => e.message,
                'message',
                contains('window.EmbeddingEngine = m.EmbeddingEngine;'),
              ),
        ),
      );
    } finally {
      globalContext['EmbeddingEngine'] = saved;
    }
    expect((await _active()).dimension, 768);
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('supportImage on the 270m is refused, naming the 440m; text '
      'still works after', (tester) async {
    _start('EG2 270m images refused');
    await _ensureEg2();
    EmbeddingLoadException? refusal;
    try {
      await FlutterEdgeAi.getActiveEmbedder(supportImage: true);
    } on EmbeddingLoadException catch (e) {
      refusal = e;
    }
    // The runtime's own reason, for the record: the web has no ModelInfo, so
    // this is the only evidence that `create` refuses a vision tower the
    // bundle lacks (rather than failing at the first image).
    report('eg2_270m_images_refusal', refusal?.message);
    expect(refusal, isNotNull, reason: 'the 270m loaded with images');
    expect(refusal!.engine, 'LiteRT-LM');
    expect(refusal.cause, isNotNull, reason: 'no runtime error behind it');
    expect(
      refusal.message,
      contains('could not create the embedding engine'),
      reason: 'refused somewhere other than EmbeddingEngine.create',
    );
    expect(refusal.message, contains('embeddinggemma-2-text-vision-440m'));
    final model = await _active();
    expect(model.modalities, {EmbeddingModality.text});
    expect(
      await model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
      hasLength(768),
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('close and recreate: a new model, the same vectors', (
    tester,
  ) async {
    _start('EG2 close and recreate');
    await _ensureEg2();
    final model = await _active();
    final input = EmbeddingInput.text('The cat sat on the mat.');
    final before = await model.embed(input, taskType: TaskType.none);
    await model.close();
    await expectLater(
      model.embed(input, taskType: TaskType.none),
      throwsA(isA<EmbedderClosedException>()),
    );
    final next = await _active();
    expect(identical(next, model), isFalse);
    expect(
      cosine(before, await next.embed(input, taskType: TaskType.none)),
      closeTo(1.0, 1e-6),
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  group('the 440m', () {
    testWidgets('loads with images: {text, image}, the 270m\'s text tower '
        '(golden), unit image vectors', (tester) async {
      _start('EG2 440m load');
      await _ensureEg2Vision();
      final load = Stopwatch()..start();
      final model = await _active(images: true);
      load.stop();
      expect(model.dimension, 768);
      expect(model.maxInputTokens, 1024);
      expect(model.activeBackend, PreferredBackend.gpu);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      final golden = _golden.first;
      expect(
        cosine(
          await model.embed(
            EmbeddingInput.text(golden.text),
            taskType: _taskFor(golden.role),
          ),
          golden.vector,
        ),
        greaterThanOrEqualTo(_vsNativeCpu),
        reason: 'the 440m carries the 270m\'s text tower, byte for byte',
      );
      final first = Stopwatch()..start();
      final image = await model.embed(
        EmbeddingInput.image(await _asset(eg2VisionSampleAsset('circle'))),
        taskType: TaskType.retrievalDocument,
      );
      first.stop();
      expectUnitVector(image, 768, what: 'first image');
      report('eg2_440m_load', {
        'getActiveEmbedderMs': load.elapsedMilliseconds,
        'firstImageMs': first.elapsedMilliseconds,
      });
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('text → image: each caption finds its scene among ten (raw); '
        'the retrieval-query prefix recorded (M10)', (tester) async {
      _start('EG2 text to image');
      await _ensureEg2Vision();
      final model = await _active(images: true);
      final images = <List<double>>[];
      final micros = <int>[];
      for (final scene in _scenes) {
        final bytes = await _asset(eg2VisionSampleAsset(scene));
        final watch = Stopwatch()..start();
        final vector = await model.embed(
          EmbeddingInput.image(bytes),
          taskType: TaskType.retrievalDocument,
        );
        micros.add(watch.elapsedMicroseconds);
        expectUnitVector(vector, 768, what: scene);
        images.add(vector);
        _webSceneVectors[scene] = vector;
      }
      Future<List<List<double>>> captions(TaskType taskType) async => [
        for (final caption in eg2VisionSampleCaptions.values)
          await model.embed(EmbeddingInput.text(caption), taskType: taskType),
      ];
      final raw = _rank(await captions(TaskType.none), images);
      final query = _rank(await captions(TaskType.retrievalQuery), images);
      final vsNative = [
        for (final scene in _scenes)
          cosine(_webSceneVectors[scene]!, _imageGolden[scene]!),
      ].reduce(math.min);
      report('text_to_image', {
        'imageMinCosVsNativeCpu': vsNative,
        'perImageMedianMs': _median(micros),
        'perImageMaxMs': micros.reduce(math.max) / 1000,
        'rawTop1': raw.top1,
        'rawMargin': raw.margin,
        'queryPrefixTop1': query.top1,
        'queryPrefixMargin': query.margin,
      });
      _log(
        'text→image: image min cos vs native CPU $vsNative; per image median '
        '${_median(micros)} ms; raw top-1 ${raw.top1}/10 margin '
        '${raw.margin.toStringAsFixed(4)} ${raw.misses}; retrievalQuery '
        '${query.top1}/10 margin ${query.margin.toStringAsFixed(4)}',
      );
      expect(raw.top1, 10, reason: '${raw.misses}');
      expect(
        vsNative,
        greaterThanOrEqualTo(_vsNativeCpu),
        reason: 'the web WebGPU image vectors against the native CPU golden',
      );
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('across platforms: web captions find the native image vectors, '
        'native captions find the web image vectors (top-1 10/10 each)', (
      tester,
    ) async {
      _start('EG2 cross-platform retrieval');
      await _ensureEg2Vision();
      final model = await _active(images: true);
      expect(
        {
          for (final MapEntry(:key, :value) in _captionGolden.entries)
            key: value.text,
        },
        eg2VisionSampleCaptions,
        reason: 'the golden\'s captions are not the example\'s',
      );
      final webImages = [
        for (final scene in _scenes)
          _webSceneVectors[scene] ??= await model.embed(
            EmbeddingInput.image(await _asset(eg2VisionSampleAsset(scene))),
            taskType: TaskType.retrievalDocument,
          ),
      ];
      final webCaptions = <List<double>>[];
      var captionVsNative = 1.0;
      for (final scene in _scenes) {
        final vector = await model.embed(
          EmbeddingInput.text(eg2VisionSampleCaptions[scene]!),
          taskType: TaskType.none,
        );
        webCaptions.add(vector);
        captionVsNative = math.min(
          captionVsNative,
          cosine(vector, _captionGolden[scene]!.vector),
        );
      }
      final nativeImages = [for (final scene in _scenes) _imageGolden[scene]!];
      final nativeCaptions = [
        for (final scene in _scenes) _captionGolden[scene]!.vector,
      ];
      // A web query against an index built natively, and the other way round.
      final webToNative = _rank(webCaptions, nativeImages);
      final nativeToWeb = _rank(nativeCaptions, webImages);
      // The same search within each platform, for the margin it gives up.
      final nativeToNative = _rank(nativeCaptions, nativeImages);
      report('cross_platform', {
        'captionMinCosVsNativeCpu': captionVsNative,
        'webCaptionsToNativeImagesTop1': webToNative.top1,
        'webCaptionsToNativeImagesMargin': webToNative.margin,
        'nativeCaptionsToWebImagesTop1': nativeToWeb.top1,
        'nativeCaptionsToWebImagesMargin': nativeToWeb.margin,
        'nativeToNativeTop1': nativeToNative.top1,
        'nativeToNativeMargin': nativeToNative.margin,
      });
      _log(
        'cross-platform: web captions → native images ${webToNative.top1}/10 '
        'margin ${webToNative.margin.toStringAsFixed(4)} '
        '${webToNative.misses}; native captions → web images '
        '${nativeToWeb.top1}/10 margin '
        '${nativeToWeb.margin.toStringAsFixed(4)} ${nativeToWeb.misses}; '
        'native → native ${nativeToNative.top1}/10 margin '
        '${nativeToNative.margin.toStringAsFixed(4)}; caption min cos vs '
        'native CPU $captionVsNative',
      );
      expect(captionVsNative, greaterThanOrEqualTo(_vsNativeCpu));
      expect(webToNative.top1, 10, reason: '${webToNative.misses}');
      expect(nativeToWeb.top1, 10, reason: '${nativeToWeb.misses}');
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('image → image: each near-duplicate JPEG finds its PNG', (
      tester,
    ) async {
      _start('EG2 image to image');
      await _ensureEg2Vision();
      final model = await _active(images: true);
      final originals = [
        for (final scene in _scenes)
          _webSceneVectors[scene] ??= await model.embed(
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
      final dup = _rank(duplicates, originals);
      report('image_to_image', {'top1': dup.top1, 'margin': dup.margin});
      expect(dup.top1, 10, reason: '${dup.misses}');
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('GIF and BMP decode; WebP, TIFF and HEIC are refused before '
        'anything is sent; a truncated PNG is EmbeddingEngineException, and '
        'the model keeps working', (tester) async {
      _start('EG2 formats');
      await _ensureEg2Vision();
      final model = await _active(images: true);
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
      expect(cosine(bmp, png), greaterThan(0.999), reason: 'BMP is lossless');
      expect(cosine(gif, png), greaterThan(0.98), reason: 'GIF is paletted');

      for (final (file, format) in [
        ('small_circle.webp', EncodedMediaFormat.webp),
        ('small_circle.tiff', EncodedMediaFormat.tiff),
        ('small_circle.heic', EncodedMediaFormat.heic),
      ]) {
        await expectLater(
          embed(await _asset('assets/eg2_vision/$file')),
          throwsA(
            isA<EmbeddingFormatNotSupportedException>()
                .having((e) => e.detected, 'detected', format)
                .having((e) => e.accepted, 'accepted', _imageFormats),
          ),
          reason: file,
        );
      }

      final whole = await _asset(eg2VisionSampleAsset('circle'));
      await expectLater(
        embed(Uint8List.sublistView(whole, 0, whole.length ~/ 2)),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.engine,
            'engine',
            'LiteRT-LM',
          ),
        ),
      );
      expect(model.isClosed, isFalse);
      expectUnitVector(await embed(whole), 768, what: 'after the bad PNG');
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('70 vision tokens per image through the public describe(): '
        'loads, embeds, and differs slightly from the native 140 vector', (
      tester,
    ) async {
      _start('EG2 70 tokens');
      await _ensureEg2Vision();
      await _releaseActive(); // one engine at a time on the page
      final described =
          await const LiteRtEmbeddingBackend(visionTokensPerImage: 70).describe(
            FlutterEdgeAi.activeEmbedderSpec!,
            RuntimeConfig(
              maxTokens: 0,
              modelPath: await _installedUrl(),
              supportImage: true,
            ),
          );
      final pass = described.build();
      try {
        await pass.load();
        final bytes = await _asset(eg2VisionSampleAsset('stop_sign'));
        final watch = Stopwatch()..start();
        final at70 = await pass.embed(
          EmbeddingInput.image(bytes),
          TaskType.retrievalDocument,
        );
        watch.stop();
        expectUnitVector(at70, 768, what: '70 tokens');
        // Against the native 140-token vector: close, but not equal — equal
        // would mean the budget never reached EmbeddingEngine.create.
        final cosVs140 = cosine(at70, _imageGolden['stop_sign']!);
        report('vision70', {
          'imageMs': watch.elapsedMilliseconds,
          'cosVsNative140': cosVs140,
        });
        expect(cosVs140, inExclusiveRange(0.9, 0.99999));
      } finally {
        await pass.close();
      }
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('photo preparation in the browser: a 12 MP JPEG becomes '
        '1024x768, and an EXIF-6 camera JPEG comes out upright', (
      tester,
    ) async {
      _start('photo preparation');
      await _ensureEg2Vision();
      final model = await _active(images: true);
      Future<List<double>> embed(Uint8List bytes) =>
          model.embed(EmbeddingInput.image(bytes), taskType: TaskType.none);

      final large = await _asset('assets/eg2_vision/large_12mp.jpg');
      final watch = Stopwatch()..start();
      final small = await preparePhotoForEmbedding(large);
      final prepareMs = watch.elapsedMilliseconds;
      expect((small.width, small.height), (1024, 768));
      expect((small.sourceWidth, small.sourceHeight), (4032, 3024));
      expect(sniffEncodedMediaFormat(small.bytes), EncodedMediaFormat.bmp);

      final rotated = await _asset('assets/eg2_vision/portrait_exif6.jpg');
      final upright = await _asset('assets/eg2_vision/portrait_upright.jpg');
      final before = cosine(await embed(rotated), await embed(upright));
      final preparedRotated = await preparePhotoForEmbedding(rotated);
      final preparedUpright = await preparePhotoForEmbedding(upright);
      final after = cosine(
        await embed(preparedRotated.bytes),
        await embed(preparedUpright.bytes),
      );
      report('photo_preparation', {
        'prepare12MpMs': prepareMs,
        'exif6PreparedSize':
            '${preparedRotated.width}x${preparedRotated.height}',
        'exif6RawCosVsUpright': before,
        'exif6PreparedCosVsUpright': after,
      });
      _log(
        'prepare 12 MP: $prepareMs ms; EXIF 6 raw cos $before, prepared cos '
        '$after (${preparedRotated.width}x${preparedRotated.height})',
      );
      // The browser's decoder applies the EXIF orientation, as Flutter's does
      // natively.
      expect((preparedRotated.width, preparedRotated.height), (480, 640));
      expect(after, greaterThan(0.99), reason: 'the same picture, upright');
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('M11 (measured): the longest main-thread stall while ten '
        'images and ten texts are embedded on WebGPU', (tester) async {
      _start('M11');
      await _ensureEg2Vision();
      final model = await _active(images: true);
      final images = [
        for (final scene in _scenes)
          EmbeddingInput.image(await _asset(eg2VisionSampleAsset(scene))),
      ];
      final texts = [
        for (final caption in eg2VisionSampleCaptions.values)
          EmbeddingInput.text(caption),
      ];
      final (_, imageStalls) = await _watchMainThread(
        () => model.embedAll(images, taskType: TaskType.retrievalDocument),
      );
      final (_, textStalls) = await _watchMainThread(
        () => model.embedAll(texts, taskType: TaskType.retrievalQuery),
      );
      report('m11_webgpu', {'images': imageStalls, 'texts': textStalls});
      _log('M11 WebGPU: images $imageStalls; texts $textStalls');
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('the Image Search screen on the 440m: the samples, a picked '
        'photo kept in OPFS, a text and a photo find the right scenes', (
      tester,
    ) async {
      _start('Image Search screen');
      await _ensureEg2Vision();
      final app = imageSearchAppDependencies();
      final pieDuplicate = (
        name: 'pie_chart_dup.jpg',
        bytes: await _asset(eg2VisionDuplicateAsset('pie_chart')),
      );
      final dependencies = ImageSearchDependencies(
        hasActiveEmbedder: app.hasActiveEmbedder,
        // A mirror is not the catalog's source, so the app's provenance
        // (rightly) cannot name its space; _ensure checked its SHA-256.
        textProfileId: _visionUrlOverride.isNotEmpty
            ? () async => _eg2Vision.ragProfileId
            : app.textProfileId,
        loadEmbedder: app.loadEmbedder,
        ragEmbedder: app.ragEmbedder,
        openIndex: app.openIndex,
        photos: app.photos,
        // No file dialog under a driver: the picker hands in one photo,
        // which the web photo store keeps in OPFS.
        pickPhotos: () async => [
          (name: pieDuplicate.name, read: () async => pieDuplicate.bytes),
        ],
        pickQueryPhoto: () async => pieDuplicate,
        loadSample: app.loadSample,
      );
      tester.view
        ..physicalSize = const Size(1200, 4000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

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
          if (watch.elapsed > const Duration(minutes: 15)) {
            fail('waited 15 minutes for $what');
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
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
      expect(find.textContaining('Backend: gpu · loaded in'), findsOneWidget);

      await tester.tap(find.byKey(const Key('image-search-add-samples')));
      await tester.pump();
      await until(find.textContaining('Per image:'), 'the samples');

      await tester.tap(find.byKey(const Key('image-search-add-photos')));
      await tester.pump();
      await until(find.textContaining('Per image:'), 'the picked photo');
      expect(
        find.byKey(const Key('image-search-add-failures')),
        findsNothing,
        reason: 'the web photo store could not keep the photo',
      );

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

      await tester.tap(find.byKey(const Key('image-search-search-photo')));
      await tester.pump();
      await until(
        find.textContaining('Closest to pie_chart_dup.jpg'),
        'the photo search',
      );
      // The picked copy itself is in the index now, so it ranks first; the
      // sample it duplicates comes right after.
      final top = {text('image-search-label-0'), text('image-search-label-1')};
      expect(top, contains('pie_chart.png'));
      // Let the thumbnails (one read back from OPFS) decode and paint.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const Key('image-search-clear')));
      await tester.pump();
      await until(find.text('0 photos in the index'), 'the index to clear');
      await tester.pumpWidget(const SizedBox()); // disposes: closes the model
    }, timeout: const Timeout(Duration(minutes: 45)));
  });

  testWidgets('minInputLength (measured): short-text latency with the '
      'runtime\'s one 1024 signature vs minInputLength 128, and whether the '
      'vectors are the same', (tester) async {
    _start('minInputLength');
    await _ensureEg2();
    await _releaseActive(); // one engine at a time on the page
    final record = <String, Object?>{};
    final texts = [for (final item in _golden) item];
    Future<(List<List<double>>, double)> run(int? minInputLength) async {
      final pass = await _directPass(
        model: _eg2,
        minInputLength: minInputLength,
      );
      try {
        await pass.load();
        final vectors = <List<double>>[];
        final micros = <int>[];
        for (final item in texts) {
          final watch = Stopwatch()..start();
          vectors.add(
            await pass.embed(
              EmbeddingInput.text(item.text),
              _taskFor(item.role),
            ),
          );
          micros.add(watch.elapsedMicroseconds);
        }
        return (vectors, _median(micros));
      } finally {
        await pass.close();
      }
    }

    final (single, singleMs) = await run(null);
    record['default_perTextMedianMs'] = singleMs;
    try {
      final (many, manyMs) = await run(128);
      record['min128_perTextMedianMs'] = manyMs;
      record['min128_minCosVsDefault'] = [
        for (var i = 0; i < single.length; i++) cosine(single[i], many[i]),
      ].reduce(math.min);
    } on EmbeddingLoadException catch (e) {
      record['min128_loadFailed'] = e.message;
    }
    report('min_input_length', record);
    _log('minInputLength: $record');
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('a page without WebGPU: the load is refused before '
      'EmbeddingEngine.create, saying EmbeddingGemma 2 on the web needs WebGPU '
      'and why; with WebGPU back it loads', (tester) async {
    _start('no WebGPU');
    await _ensureEg2();
    await _releaseActive();
    final created = <String>[];
    // Hide navigator.gpu (an own property shadows the prototype's getter),
    // and count the engines the runtime is asked to create meanwhile.
    final engine = globalContext['EmbeddingEngine']! as JSObject;
    final create = engine['create'];
    engine['create'] = ((JSAny settings) {
      created.add('create');
      return (create! as JSFunction).callAsFunction(engine, settings);
    }).toJS;
    globalContext.callMethod<JSAny?>(
      'eval'.toJS,
      "Object.defineProperty(navigator, 'gpu', "
              '{configurable: true, value: undefined})'
          .toJS,
    );
    EmbeddingLoadException? refusal;
    try {
      await FlutterEdgeAi.getActiveEmbedder();
    } on EmbeddingLoadException catch (e) {
      refusal = e;
    } finally {
      globalContext.callMethod<JSAny?>(
        'eval'.toJS,
        'delete navigator.gpu'.toJS,
      );
      engine['create'] = create;
    }
    report('no_webgpu_refusal', refusal?.message);
    _log('no WebGPU: ${refusal?.message}');
    expect(refusal, isNotNull, reason: 'loaded without navigator.gpu');
    expect(refusal!.engine, 'LiteRT-LM');
    expect(
      refusal.message,
      allOf(
        startsWith('EmbeddingGemma 2 on the web needs WebGPU'),
        contains('this browser has no WebGPU'),
        contains('There is no CPU fallback'),
        contains('cannot read the external weights'),
      ),
    );
    expect(created, isEmpty, reason: 'EmbeddingEngine.create was called');
    final model = await _active();
    expect(model.activeBackend, PreferredBackend.gpu);
    expectUnitVector(
      await model.embed(EmbeddingInput.text('x'), taskType: TaskType.none),
      768,
      what: 'with WebGPU back',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('CPU, asked for directly: @litert-lm/core 0.18.0 still cannot '
      'load either bundle there, and the error says why', (tester) async {
    _start('CPU refused');
    final record = <String, Object?>{};
    for (final (model, ensure, images) in [
      (_eg2, _ensureEg2, false),
      (_eg2Vision, _ensureEg2Vision, true),
    ]) {
      await ensure();
      await _releaseActive(); // one engine at a time on the page
      final pass = await _directPass(
        model: model,
        backend: LiteRtLmWebBackend.cpu,
        images: images,
      );
      EmbeddingLoadException? refusal;
      try {
        await pass.load();
      } on EmbeddingLoadException catch (e) {
        refusal = e;
      } finally {
        await pass.close();
      }
      record[model.filename] = refusal?.message;
      expect(
        refusal,
        isNotNull,
        reason:
            '${model.filename} loaded on the CPU: @litert-lm/core now reads '
            'its external weights there, and the WebGPU-only rule (and its '
            'documentation) should be revisited',
      );
      expect(
        refusal!.message,
        allOf(
          contains('could not create the embedding engine'),
          contains('Failed to get external weight'),
          contains(
            'The CPU (WebAssembly) path of @litert-lm/core 0.18.0 cannot read '
            'the external weights',
          ),
        ),
      );
    }
    report('cpu_refusal', record);
    _log('CPU: $record');
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
  });
}

/// EmbeddingGemma 2 audio and combined inputs in the browser (litertlm
/// 1.13.2): the pinned litert-community 740m bundle through
/// `installEmbedder()` → `getActiveEmbedder(supportAudio: true)` → core's
/// inline host → flutter_edge_ai_litertlm's web `.litertlm` pass →
/// `@litert-lm/core` 0.18.0's `EmbeddingEngine` on WebGPU (text, vision and
/// audio towers), with `WebStorageMode.cacheApi`. The web twin of
/// embeddinggemma2_audio_test.dart, held to the same golden.
///
/// What it holds the browser to, over the clips in assets/eg2_audio
/// (integration_test/tools/generate_eg2_audio_clips.py):
/// - {text, audio}, GPU, 768 dimensions, 1024 tokens; the text tower against
///   the native text golden (WebGPU bound, as web_eg2_test.dart);
/// - each clip against goldens/eg2_audio_golden.json: cos >= [_minAudio]
///   against `vector_native` (our native-v0.18.0-e build, CPU) and against
///   Google's litert-lm 0.18.0 wheel (`vector`). The audio encoder quantizes
///   its activations to int8, so the last bits of another kernel move a clip
///   by up to cos 0.05 natively already (see the native suite); WebGPU adds
///   its own rounding. Retrieval is the real bar;
/// - text → audio top-1 on the six spoken sentences, raw and with the
///   retrieval-query prefix; and across platforms: web queries find the
///   native audio vectors;
/// - FLAC, 44.1 kHz stereo WAV and MP3 decode in the page's WebAssembly
///   (miniaudio, as natively); M4A and Ogg are refused before anything is
///   sent; a RIFF header over garbage is EmbeddingEngineException and the
///   model keeps working;
/// - a 60-second clip is EmbeddingInputTooLongException(1024, 1504) — the
///   native and wheel count, media tokens included — and 40 s fits;
/// - combined inputs (text+image, text+audio, image+audio, all three) against
///   the golden;
/// - supportAudio on the 270m and on the 440m is refused from the bundle's
///   container header, naming the 740m, before `EmbeddingEngine.create` is
///   called — and the embedder the app holds keeps working.
/// Measured, never asserted: per-clip latency, load time.
///
/// GCE VM only (never a local browser). Run from packages/flutter_edge_ai/example:
///   chromedriver --port=4444 &
///   flutter drive \
///     --driver=test_driver/web_embeddings_driver.dart \
///     --target=integration_test/web_eg2_audio_test.dart \
///     -d web-server --browser-name=chrome
/// The browser needs WebGPU with a GPU behind it (on the VM:
/// `--enable-unsafe-webgpu`, Vulkan, a real display). The bundles are
/// ungated (485 MB + 165 MB + 388 MB on the first run);
/// `--dart-define=EG2_740M_MODEL_URL=…`, `EG2_MODEL_URL=…` and
/// `EG2_440M_MODEL_URL=…` serve the same bytes from elsewhere (each is
/// checked against its pinned SHA-256 before anything is compared).
///
/// The driver writes this suite's data to `build/web_eg2_audio_response.json`
/// even when a test fails.
///
/// Rule 6b: no setUp/setUpAll — every fallible step is a guarded helper called
/// inside the test body, and the last test checks that every test before it
/// started. After a green run, confirm the report lists all of them.
@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'goldens/eg2_audio_golden.dart';
import 'goldens/eg2_text_golden.dart';
import 'web_embeddings_support.dart';

/// Every test in this file, in order; the last one checks they all started.
const _tests = [
  'audio load',
  'text to audio',
  'cross-platform audio',
  'containers',
  'audio overflow',
  'combined',
  'combined overflow',
  'audio refused',
];

const _eg2Audio = catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m;
const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _eg2Vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
const _audioUrlOverride = String.fromEnvironment('EG2_740M_MODEL_URL');
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _visionUrlOverride = String.fromEnvironment('EG2_440M_MODEL_URL');

/// What LiteRT-LM's miniaudio decodes, as the 740m reports it at load.
final _audioFormats = {
  EncodedMediaFormat.wav,
  EncodedMediaFormat.mp3,
  EncodedMediaFormat.flac,
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

Future<void> _ensureEg2Audio() => _ensure(_eg2Audio, _audioUrlOverride);

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

/// The embedder the suite last got from `getActiveEmbedder()`.
EmbeddingModel? _held;

Future<EmbeddingModel> _active({
  bool images = false,
  bool audio = true,
}) async => _held = await FlutterEdgeAi.getActiveEmbedder(
  supportImage: images,
  supportAudio: audio,
);

/// Closes the cached embedder, if one is open, so the next
/// `getActiveEmbedder()` builds.
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
  print('[web-eg2-audio] $line');
}

// ── Goldens ────────────────────────────────────────────────────────────────

final Map<String, dynamic> _golden =
    jsonDecode(eg2AudioGoldenJson) as Map<String, dynamic>;

Map<String, dynamic> _group(String name) =>
    (_golden[name] as Map).cast<String, dynamic>();

List<double> _f32(String encoded) {
  final bytes = ByteData.sublistView(base64.decode(encoded));
  return [
    for (var i = 0; i < bytes.lengthInBytes ~/ 4; i++)
      bytes.getFloat32(i * 4, Endian.little),
  ];
}

/// The bound for a vector with audio in it, against our native build and
/// against the wheel. Measured on a Tesla T4 (Chrome 155, WebGPU audio
/// tower): clips 0.974-0.991 against our native build and 0.975-0.995
/// against the wheel; combined inputs with audio 0.983-0.997. Natively the
/// same int8 activations already move a clip by up to cos 0.05 between CPU
/// kernels, so this catches a broken tower, not drift; retrieval below is the
/// real check.
const _minAudio = 0.95;

/// Text and images on WebGPU against the native CPU goldens: the bound
/// web_eg2_test.dart holds them to (measured 0.995 / 0.998 on a Tesla T4).
const _minTextImage = 0.99;

int _median(List<int> values) => (values.toList()..sort())[values.length ~/ 2];

/// The bytes of an example asset.
Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> _clip(String file) => _asset('assets/eg2_audio/$file');

Future<Uint8List> _image(String file) => _asset('assets/eg2_vision/$file');

/// Each query's rank among [documents]: how many find their own document
/// first, the mean margin and the smallest margin of the right document over
/// the best wrong one.
({int top1, double margin, double minMargin, List<String> misses}) _rank(
  List<List<double>> queries,
  List<List<double>> documents,
  List<String> names,
) {
  var top1 = 0;
  var margin = 0.0;
  var minMargin = double.infinity;
  final misses = <String>[];
  for (var i = 0; i < queries.length; i++) {
    final scores = [for (final d in documents) cosine(queries[i], d)];
    final best = scores.indexOf(scores.reduce(math.max));
    if (best == i) {
      top1++;
    } else {
      misses.add('${names[i]}->${names[best]}');
    }
    final right =
        scores[i] -
        [
          for (var j = 0; j < scores.length; j++)
            if (j != i) scores[j],
        ].reduce(math.max);
    margin += right;
    minMargin = math.min(minMargin, right);
  }
  return (
    top1: top1,
    margin: margin / queries.length,
    minMargin: minMargin,
    misses: misses,
  );
}

/// [seconds] of a 440 Hz tone as a 16 kHz mono PCM16 WAV — the native suite's
/// overflow clip, byte for byte.
Uint8List _toneWav(int seconds) {
  const rate = 16000;
  final samples = seconds * rate;
  final data = ByteData(44 + samples * 2);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, rate, Endian.little)
    ..setUint32(28, rate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    data.setInt16(
      44 + i * 2,
      (8000 * math.sin(2 * math.pi * 440 * i / rate)).round(),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

/// The web vectors of the six clips, kept for the comparisons after the test
/// that makes them.
final _webClipVectors = <String, List<double>>{};

Future<List<double>> _clipVector(EmbeddingModel model, String name) async =>
    _webClipVectors[name] ??= await model.embed(
      EmbeddingInput.audio(
        await _clip((_group('clips')[name] as Map)['file'] as String),
      ),
      taskType: TaskType.retrievalDocument,
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  reportTo('web_eg2_audio_response');

  testWidgets('the 740m with audio: {text, audio} on GPU; the text tower is '
      'the native one; every clip reproduces the native golden', (
    tester,
  ) async {
    _start('audio load');
    await _ensureEg2Audio();
    await _releaseActive();
    final load = Stopwatch()..start();
    final model = await _active();
    load.stop();
    expect(model.dimension, 768);
    expect(model.maxInputTokens, 1024);
    expect(model.modalities, {EmbeddingModality.text, EmbeddingModality.audio});
    expect(model.activeBackend, PreferredBackend.gpu);

    final textGolden =
        ((jsonDecode(eg2TextGoldenJson) as Map)['items'] as List).first as Map;
    final text = await model.embed(
      EmbeddingInput.text(textGolden['text'] as String),
      taskType: textGolden['role'] == 'query'
          ? TaskType.retrievalQuery
          : TaskType.retrievalDocument,
    );
    final textCos = cosine(text, _f32(textGolden['vector_f32le'] as String));

    final clips = _group('clips');
    final micros = <int>[];
    final toNative = <String, double>{};
    final toWheel = <String, double>{};
    for (final MapEntry(:key, :value) in clips.entries) {
      final clip = (value as Map).cast<String, dynamic>();
      final bytes = await _clip(clip['file'] as String);
      final watch = Stopwatch()..start();
      final vector = await model.embed(
        EmbeddingInput.audio(bytes),
        taskType: TaskType.retrievalDocument,
      );
      micros.add(watch.elapsedMicroseconds);
      expectUnitVector(vector, 768, what: key);
      _webClipVectors[key] = vector;
      toNative[key] = cosine(vector, _f32(clip['vector_native'] as String));
      toWheel[key] = cosine(vector, _f32(clip['vector'] as String));
    }
    final minNative = toNative.values.reduce(math.min);
    final minWheel = toWheel.values.reduce(math.min);
    report('audio_load', {
      'getActiveEmbedderMs': load.elapsedMilliseconds,
      'perClipMedianMs': _median(micros) / 1000,
      'perClipMaxMs': micros.reduce(math.max) / 1000,
      'textTowerCosVsNative': textCos,
      'clipCosVsNative': toNative,
      'clipCosVsWheel': toWheel,
    });
    _log(
      '740m audio: load ${load.elapsedMilliseconds} ms; per clip (2.6-3.6 s '
      'of speech) median ${_median(micros) / 1000} ms, max '
      '${micros.reduce(math.max) / 1000} ms; min cos vs our native build '
      '${minNative.toStringAsFixed(5)}, vs the wheel '
      '${minWheel.toStringAsFixed(5)} (need $_minAudio); text tower vs the '
      'native golden ${textCos.toStringAsFixed(6)}',
    );
    expect(textCos, greaterThanOrEqualTo(_minTextImage));
    expect(minNative, greaterThanOrEqualTo(_minAudio), reason: '$toNative');
    expect(minWheel, greaterThanOrEqualTo(_minAudio), reason: '$toWheel');
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('text → audio: every spoken sentence is found by its query, raw '
      'and with the retrieval-query prefix', (tester) async {
    _start('text to audio');
    await _ensureEg2Audio();
    final model = await _active();
    final clips = _group('clips');
    final names = clips.keys.toList();
    final documents = [
      for (final name in names) await _clipVector(model, name),
    ];
    Future<List<List<double>>> queries(TaskType taskType) async => [
      for (final name in names)
        await model.embed(
          EmbeddingInput.text((clips[name] as Map)['query'] as String),
          taskType: taskType,
        ),
    ];
    final raw = _rank(await queries(TaskType.none), documents, names);
    final query = _rank(
      await queries(TaskType.retrievalQuery),
      documents,
      names,
    );
    report('text_to_audio', {
      'rawTop1': raw.top1,
      'rawMargin': raw.margin,
      'rawMinMargin': raw.minMargin,
      'queryPrefixTop1': query.top1,
      'queryPrefixMargin': query.margin,
      'queryPrefixMinMargin': query.minMargin,
    });
    _log(
      'text → audio: raw top-1 ${raw.top1}/${names.length} margin mean '
      '${raw.margin.toStringAsFixed(4)} min '
      '${raw.minMargin.toStringAsFixed(4)} ${raw.misses}; retrieval-query '
      'prefix top-1 ${query.top1}/${names.length} margin mean '
      '${query.margin.toStringAsFixed(4)} min '
      '${query.minMargin.toStringAsFixed(4)} ${query.misses}',
    );
    expect(raw.top1, names.length, reason: '${raw.misses}');
    expect(query.top1, names.length, reason: '${query.misses}');
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('across platforms: web text queries find the native audio '
      'vectors, and the web audio vectors answer them as the native ones '
      'do', (tester) async {
    _start('cross-platform audio');
    await _ensureEg2Audio();
    final model = await _active();
    final clips = _group('clips');
    final names = clips.keys.toList();
    final queries = [
      for (final name in names)
        await model.embed(
          EmbeddingInput.text((clips[name] as Map)['query'] as String),
          taskType: TaskType.none,
        ),
    ];
    final native = [
      for (final name in names)
        _f32((clips[name] as Map)['vector_native'] as String),
    ];
    final web = [for (final name in names) await _clipVector(model, name)];
    // A web query against an audio index built natively, and against the
    // web's own.
    final toNative = _rank(queries, native, names);
    final toWeb = _rank(queries, web, names);
    report('cross_platform_audio', {
      'webQueriesToNativeAudioTop1': toNative.top1,
      'webQueriesToNativeAudioMargin': toNative.margin,
      'webQueriesToWebAudioTop1': toWeb.top1,
      'webQueriesToWebAudioMargin': toWeb.margin,
    });
    _log(
      'cross-platform: web queries → native audio ${toNative.top1}/6 margin '
      '${toNative.margin.toStringAsFixed(4)} ${toNative.misses}; → web audio '
      '${toWeb.top1}/6 margin ${toWeb.margin.toStringAsFixed(4)}',
    );
    expect(toNative.top1, names.length, reason: '${toNative.misses}');
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('containers: FLAC, 44.1 kHz stereo WAV and MP3 decode in the '
      'page; M4A and Ogg are refused before anything is sent; a corrupt WAV is '
      'EmbeddingEngineException and the model keeps working', (tester) async {
    _start('containers');
    await _ensureEg2Audio();
    final model = await _active();
    final wav = await _clipVector(model, 'kitchen_lights');
    final variants = _group('variants');
    final toWav = <String, double>{};
    final toNative = <String, double>{};
    for (final MapEntry(:key, :value) in variants.entries) {
      final vector = await model.embed(
        EmbeddingInput.audio(await _clip(key)),
        taskType: TaskType.retrievalDocument,
      );
      expectUnitVector(vector, 768, what: key);
      toWav[key] = cosine(vector, wav);
      toNative[key] = cosine(
        vector,
        _f32((value as Map)['vector_native'] as String),
      );
    }

    for (final (file, format) in [
      ('kitchen_lights.m4a', EncodedMediaFormat.m4a),
      ('kitchen_lights.ogg', EncodedMediaFormat.ogg),
    ]) {
      await expectLater(
        model.embed(
          EmbeddingInput.audio(await _clip(file)),
          taskType: TaskType.retrievalDocument,
        ),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>()
              .having((e) => e.modality, 'modality', EmbeddingModality.audio)
              .having((e) => e.detected, 'detected', format)
              .having((e) => e.accepted, 'accepted', _audioFormats),
        ),
      );
    }

    EmbeddingEngineException? corrupt;
    try {
      await model.embed(
        EmbeddingInput.audio(await _clip('corrupt_riff.wav')),
        taskType: TaskType.none,
      );
    } on EmbeddingEngineException catch (e) {
      corrupt = e;
    }
    expect(model.isClosed, isFalse);
    final again = await model.embed(
      EmbeddingInput.audio(await _clip('kitchen_lights.wav')),
      taskType: TaskType.retrievalDocument,
    );
    report('containers', {
      'cosToWav': toWav,
      'cosToNative': toNative,
      'corruptWav': corrupt?.message,
      'afterCorruptCos': cosine(again, wav),
    });
    _log(
      'containers vs the 16 kHz WAV: $toWav; vs native $toNative; corrupt '
      'WAV: ${corrupt?.message}',
    );
    expect(corrupt, isNotNull, reason: 'a RIFF header over garbage embedded');
    expect(corrupt!.engine, 'LiteRT-LM');
    expect(corrupt.message, contains('could not embed the audio clip'));
    expect(cosine(again, wav), greaterThan(0.999));
    // FLAC is the same samples; the 44.1 kHz stereo file and the MP3 cost
    // what they cost natively (0.92-0.96 there).
    expect(toWav['kitchen_lights.flac'], greaterThan(0.999));
    expect(toWav['kitchen_lights_44k_stereo.wav'], greaterThan(0.90));
    expect(toWav['kitchen_lights.mp3'], greaterThan(0.90));
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('a 60-second clip is EmbeddingInputTooLongException(1024, 1504) '
      '— the native count, media tokens included — and 40 s fits', (
    tester,
  ) async {
    _start('audio overflow');
    await _ensureEg2Audio();
    final model = await _active();
    final watch = Stopwatch()..start();
    await expectLater(
      model.embed(EmbeddingInput.audio(_toneWav(60)), taskType: TaskType.none),
      throwsA(
        isA<EmbeddingInputTooLongException>()
            .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
            .having((e) => e.actualTokens, 'actualTokens', 1504),
      ),
    );
    watch.stop();
    expect(model.isClosed, isFalse);
    final fits = Stopwatch()..start();
    final vector = await model.embed(
      EmbeddingInput.audio(_toneWav(40)),
      taskType: TaskType.none,
    );
    fits.stop();
    expectUnitVector(vector, 768, what: '40 s');
    report('audio_overflow', {
      'refusedMs': watch.elapsedMilliseconds,
      'fortySecondsMs': fits.elapsedMilliseconds,
    });
    _log(
      'audio overflow: 60 s refused in ${watch.elapsedMilliseconds} ms; 40 s '
      'embedded in ${fits.elapsedMilliseconds} ms',
    );
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('combined inputs: text+image, text+audio, image+audio and all '
      'three reproduce the native golden', (tester) async {
    _start('combined');
    await _ensureEg2Audio();
    await _releaseActive(); // the next load widens to images + audio
    final model = await _active(images: true);
    expect(model.modalities, EmbeddingModality.values.toSet());
    final combined = _group('combined');
    final document = TaskType.retrievalDocument.prefix;
    final toNative = <String, double>{};
    final toWheel = <String, double>{};
    final ms = <String, int>{};
    for (final MapEntry(:key, :value) in combined.entries) {
      final item = (value as Map).cast<String, dynamic>();
      final text = item['text'] as String?;
      if (text != null) expect(text, startsWith(document));
      final input = EmbeddingInput(
        text: text?.substring(document.length),
        images: [
          for (final image in (item['images'] as List).cast<String>())
            await _image(image),
        ],
        audio: item['audio'] == null
            ? null
            : await _clip(item['audio'] as String),
      );
      final watch = Stopwatch()..start();
      final vector = await model.embed(
        input,
        taskType: TaskType.retrievalDocument,
      );
      ms[key] = watch.elapsedMilliseconds;
      expectUnitVector(vector, 768, what: key);
      toNative[key] = cosine(vector, _f32(item['vector_native'] as String));
      toWheel[key] = cosine(vector, _f32(item['vector'] as String));
    }
    report('combined', {
      'cosVsNative': toNative,
      'cosVsWheel': toWheel,
      'ms': ms,
    });
    _log('combined: vs native $toNative; vs the wheel $toWheel; ms $ms');
    for (final MapEntry(:key, :value) in toNative.entries) {
      final bound = (combined[key] as Map)['audio'] == null
          ? _minTextImage
          : _minAudio;
      expect(value, greaterThanOrEqualTo(bound), reason: key);
      expect(toWheel[key], greaterThanOrEqualTo(_minAudio), reason: key);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('a combined input over the limit is '
      'EmbeddingInputTooLongException with every part counted', (tester) async {
    _start('combined overflow');
    await _ensureEg2Audio();
    final model = await _active(images: true);
    // 40 s alone fits (1004 tokens); with a caption it does not.
    EmbeddingInputTooLongException? refusal;
    try {
      await model.embed(
        EmbeddingInput(
          text: List.filled(100, 'the').join(' '),
          audio: _toneWav(40),
        ),
        taskType: TaskType.none,
      );
    } on EmbeddingInputTooLongException catch (e) {
      refusal = e;
    }
    report('combined_overflow', {
      'maxInputTokens': refusal?.maxInputTokens,
      'actualTokens': refusal?.actualTokens,
    });
    _log('combined overflow: ${refusal?.message}');
    expect(refusal, isNotNull, reason: '100 words + 40 s embedded');
    expect(refusal!.maxInputTokens, 1024);
    expect(refusal.actualTokens, 1104, reason: '100 words + the 40 s clip');
    expect(model.isClosed, isFalse);
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('supportAudio on the 270m and on the 440m is refused from the '
      'bundle\'s container, naming the 740m, before EmbeddingEngine.create — '
      'and the embedder the app holds keeps working', (tester) async {
    _start('audio refused');
    for (final (model, url) in [
      (_eg2, _urlOverride),
      (_eg2Vision, _visionUrlOverride),
    ]) {
      await _ensure(model, url);
      await _releaseActive();
      final held = await _active(audio: false);
      final created = <String>[];
      final engine = globalContext['EmbeddingEngine']! as JSObject;
      final create = engine['create'];
      engine['create'] = ((JSAny settings) {
        created.add('create');
        return (create! as JSFunction).callAsFunction(engine, settings);
      }).toJS;
      EmbeddingLoadException? refusal;
      try {
        await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
      } on EmbeddingLoadException catch (e) {
        refusal = e;
      } finally {
        engine['create'] = create;
      }
      report('audio_refused_${model.name}', refusal?.message);
      _log('${model.name} + supportAudio: ${refusal?.message}');
      expect(refusal, isNotNull, reason: '${model.name} loaded audio');
      expect(refusal!.engine, 'LiteRT-LM');
      expect(
        refusal.message,
        allOf(
          contains('has no audio encoder'),
          contains('embeddinggemma-2-740m'),
        ),
      );
      expect(created, isEmpty, reason: 'EmbeddingEngine.create was called');
      // Refused in describe(), before core closes the cached embedder.
      expect(held.isClosed, isFalse);
      expectUnitVector(
        await held.embed(
          EmbeddingInput.text('still a text model'),
          taskType: TaskType.retrievalQuery,
        ),
        768,
        what: '${model.name} after the refusal',
      );
      expect(identical(await FlutterEdgeAi.getActiveEmbedder(), held), isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));

  testWidgets('every test above started (an absent test reads as a pass '
      'under flutter drive)', (tester) async {
    expect(startedTests, unorderedEquals(_tests));
  });
}

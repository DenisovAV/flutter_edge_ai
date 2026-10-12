// EmbeddingGemma 2 audio and combined inputs on a device (R5 §10.4): the
// pinned litert-community/embeddinggemma-2-740m-litert-lm bundle through
// `installEmbedder()` → `getActiveEmbedder(supportAudio: true)` → core's
// worker isolate → flutter_edge_ai_litertlm's `.litertlm` pass (1.13.1) →
// LiteRT-LM's EmbeddingEngine. Needs native-v0.18.0-e (the response getters).
//
// What it holds the device to, over the clips in assets/eg2_audio
// (integration_test/tools/generate_eg2_audio_clips.py):
// - {text, audio}, WAV/MP3/FLAC accepted, the audio weight cache in the
//   pass-owned directory, RSS by step;
// - each clip against the golden (goldens/eg2_audio_golden.json, through its
//   .dart twin): cos >= 0.9999 against `vector_native` on macOS arm64 (our
//   native-v0.18.0-e build, the one the golden measured, deterministic at any
//   thread count), and >= 0.94 against it anywhere else and against Google's
//   litert-lm 0.18.0 wheel (`vector`). The audio encoder quantizes its
//   activations to int8 (120 QUANTIZE ops), so a last-bit difference — another
//   CPU kernel, or one sample changed by 1 — moves a clip's vector by up to
//   cos 0.05 in any build (measured: ±1 LSB dither, min 0.948, in our build
//   and the wheel alike; the wheel even differs from itself run to run, by
//   thread scheduling). Retrieval is the real bar there;
// - the 740m's text tower is the 270m's: the text golden reproduces;
// - text → audio top-1 on the six spoken sentences, raw (as rag sends a text
//   query over media) and with the retrieval-query prefix, margins printed;
// - FLAC, 44.1 kHz stereo WAV and MP3 of the same speech (resampled and mixed
//   down by the engine); M4A and Ogg refused on the calling isolate; a RIFF
//   header over garbage is EmbeddingEngineException(nativeCode: 2) and the
//   model keeps working;
// - a 60-second clip is EmbeddingInputTooLongException(1024, 1504) — the
//   wheel's count for the same clip, media tokens included — and 40 s fits;
// - combined inputs (text+image, text+audio, image+audio, all three) against
//   the golden, the same bounds;
// - a RAG audio index: add the clips, find one by text;
// - supportAudio on the 270m and on the 440m is refused from the bundle (no
//   audio encoder, naming the 740m), before any engine or cache exists —
//   though ModelInfo claims audio on both (D23).
// It prints `[eg2]` lines: load and per-clip timings, RSS, cosines, margins.
//
// No setUp/setUpAll (Rule 6b): each test body calls a guarded `_ensure…()`,
// which installs the pinned revision (a no-op once installed), makes it the
// active embedder and, once per run, checks the file's SHA-256. The bundles
// are ungated. Runs on Android, iOS, macOS, Linux and Windows:
//   flutter test integration_test/embeddinggemma2_audio_test.dart -d <device>
// Optional: --dart-define=EG2_740M_MODEL_URL / EG2_740M_MODEL_FILE (and the
// 270m's EG2_MODEL_URL / EG2_MODEL_FILE, the 440m's EG2_440M_MODEL_URL /
// EG2_440M_MODEL_FILE) = a mirror of the same bytes, or a local copy the app
// can read (on macOS: inside the app's sandbox container). Either must have
// the pinned SHA-256, or the suite fails before comparing anything.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'goldens/eg2_audio_golden.dart';
import 'goldens/eg2_text_golden.dart';

const _eg2Audio = catalog.EmbeddingModel.embeddingGemma2TextVisionAudio740m;
const _audioUrlOverride = String.fromEnvironment('EG2_740M_MODEL_URL');
const _audioFileOverride = String.fromEnvironment('EG2_740M_MODEL_FILE');
const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _urlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _fileOverride = String.fromEnvironment('EG2_MODEL_FILE');
const _eg2Vision = catalog.EmbeddingModel.embeddingGemma2TextVision440m;
const _visionUrlOverride = String.fromEnvironment('EG2_440M_MODEL_URL');
const _visionFileOverride = String.fromEnvironment('EG2_440M_MODEL_FILE');

const _mb = 1024 * 1024;

/// What LiteRT-LM's miniaudio decodes, as the 740m reports it at load.
final _audioFormats = {
  EncodedMediaFormat.wav,
  EncodedMediaFormat.mp3,
  EncodedMediaFormat.flac,
};

// ── Guarded set-up (Rule 6b: called first thing in every test body) ────────

bool _initialized = false;
final _verified = <catalog.EmbeddingModel>{};

Future<void> _ensureEg2Audio() =>
    _ensure(_eg2Audio, file: _audioFileOverride, url: _audioUrlOverride);

Future<void> _ensureEg2() =>
    _ensure(_eg2, file: _fileOverride, url: _urlOverride);

Future<void> _ensureEg2Vision() =>
    _ensure(_eg2Vision, file: _visionFileOverride, url: _visionUrlOverride);

/// Registers the LiteRT backend once (no tokenizer provider: EmbeddingGemma 2
/// needs none), installs [model] (a no-op once installed), makes it the
/// active embedder and checks its SHA-256 once.
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

/// `vector_native` came from native-v0.18.0-e on macOS arm64.
bool get _sameBuildAsGolden =>
    Platform.isMacOS && Abi.current() == Abi.macosArm64;

/// Elsewhere another CPU kernel's last bits flip some of the audio encoder's
/// int8 roundings: as far as a ±1 LSB change of the input moves it (min
/// 0.948 measured).
double get _minNative => _sameBuildAsGolden ? 0.9999 : 0.94;

/// Text and images carry no int8 activations: the text golden's bounds.
double get _minTextNative => _sameBuildAsGolden ? 0.9999 : 0.998;

/// Against Google's wheel: our build is 0.969-0.997 from it, and two runs of
/// the wheel are up to 0.009 apart.
const _minWheel = 0.94;

// ── Helpers ────────────────────────────────────────────────────────────────

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

/// The bytes of an example asset.
Future<Uint8List> _asset(String key) async {
  final data = await rootBundle.load(key);
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<Uint8List> _clip(String file) => _asset('assets/eg2_audio/$file');

Future<Uint8List> _image(String file) => _asset('assets/eg2_vision/$file');

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

/// The cached embedder, closed, so the next `getActiveEmbedder()` builds.
Future<void> _closeActive() async {
  final model = await FlutterEdgeAi.getActiveEmbedder();
  await model.close();
}

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
    final scores = [for (final d in documents) _cos(queries[i], d)];
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

/// [seconds] of a 440 Hz tone as a 16 kHz mono PCM16 WAV.
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

/// A fresh directory for one test's RAG stores.
Future<String> _scratch(String name) async {
  final dir = Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
    'eg2_audio_${name}_${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  return dir.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('EG2 audio', () {
    testWidgets('740m with audio: {text, audio}, the clips reproduce the '
        'golden, the text tower is the 270m\'s, the audio cache lands in the '
        'pass dir; RSS by step', (tester) async {
      await _ensureEg2Audio();
      await _closeActive();
      final baseline = await _residentBytes();
      final loadWatch = Stopwatch()..start();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
      loadWatch.stop();
      expect(model.dimension, 768);
      expect(model.maxInputTokens, 1024);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.audio,
      });

      // The text tower: identical to the 270m's (the text golden).
      final textGolden =
          (jsonDecode(eg2TextGoldenJson) as Map<String, dynamic>)['items']
              as List;
      final first = (textGolden.first as Map).cast<String, dynamic>();
      final text = await model.embed(
        EmbeddingInput.text(first['text'] as String),
        taskType: first['role'] == 'query'
            ? TaskType.retrievalQuery
            : TaskType.retrievalDocument,
      );
      final textCos = _cos(text, _f32(first['vector_f32le'] as String));
      final afterText = await _residentBytes();

      final clips = _group('clips');
      final micros = <int>[];
      var minNative = 1.0, minWheel = 1.0;
      int? afterFirstClip;
      for (final MapEntry(:key, :value) in clips.entries) {
        final clip = (value as Map).cast<String, dynamic>();
        final watch = Stopwatch()..start();
        final vector = await model.embed(
          EmbeddingInput.audio(await _clip(clip['file'] as String)),
          taskType: TaskType.retrievalDocument,
        );
        micros.add(watch.elapsedMicroseconds);
        afterFirstClip ??= await _residentBytes();
        expect(vector, hasLength(768));
        expect(vector.every((v) => v.isFinite), isTrue, reason: key);
        expect(_norm(vector), closeTo(1.0, 1e-3), reason: key);
        minNative = math.min(
          minNative,
          _cos(vector, _f32(clip['vector_native'] as String)),
        );
        minWheel = math.min(
          minWheel,
          _cos(vector, _f32(clip['vector'] as String)),
        );
      }

      final base = await _cacheBase();
      final caches = {
        for (final f in base.listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.xnnpack_cache'))
            f.path.split('.').reversed.elementAt(1): f.lengthSync(),
      };
      _log(
        '740m audio: load ${loadWatch.elapsedMilliseconds} ms; per clip '
        '(2.6-3.6 s of speech) median ${_median(micros) / 1000} ms, max '
        '${micros.reduce(math.max) / 1000} ms; min cos vs our build '
        '${minNative.toStringAsFixed(6)} (need $_minNative), vs the wheel '
        '${minWheel.toStringAsFixed(4)} (need $_minWheel); text tower vs the '
        '270m golden ${textCos.toStringAsFixed(6)}; RSS MiB baseline '
        '${_mib(baseline)} → loaded + text ${_mib(afterText)} → after the '
        'first clip ${_mib(afterFirstClip)}; caches (bytes) $caches',
      );
      expect(minNative, greaterThanOrEqualTo(_minNative));
      expect(minWheel, greaterThanOrEqualTo(_minWheel));
      expect(textCos, greaterThanOrEqualTo(_minTextNative));
      expect(
        caches.keys,
        containsAll([
          'text_encoder',
          'streaming_audio_encoder',
          'audio_adapter',
        ]),
        reason: 'the audio cache is written at create, into the pass dir',
      );
    }, timeout: const Timeout(Duration(minutes: 30)));

    testWidgets('text → audio: every spoken sentence is found by its query, '
        'raw and with the retrieval-query prefix', (tester) async {
      await _ensureEg2Audio();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
      final clips = _group('clips');
      final names = clips.keys.toList();
      final documents = [
        for (final name in names)
          await model.embed(
            EmbeddingInput.audio(
              await _clip((clips[name] as Map)['file'] as String),
            ),
            taskType: TaskType.retrievalDocument,
          ),
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
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('containers: FLAC, 44.1 kHz stereo WAV and MP3 decode; M4A '
        'and Ogg are refused on the calling isolate; a corrupt WAV is '
        'nativeCode 2 and the model keeps working', (tester) async {
      await _ensureEg2Audio();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
      final wav = await model.embed(
        EmbeddingInput.audio(await _clip('kitchen_lights.wav')),
        taskType: TaskType.retrievalDocument,
      );
      final variants = _group('variants');
      final toWav = <String, double>{};
      var minNative = 1.0;
      for (final MapEntry(:key, :value) in variants.entries) {
        final vector = await model.embed(
          EmbeddingInput.audio(await _clip(key)),
          taskType: TaskType.retrievalDocument,
        );
        toWav[key] = _cos(vector, wav);
        minNative = math.min(
          minNative,
          _cos(vector, _f32((value as Map)['vector_native'] as String)),
        );
      }

      for (final (file, format) in [
        ('kitchen_lights.m4a', EncodedMediaFormat.m4a),
        ('kitchen_lights.ogg', EncodedMediaFormat.ogg),
      ]) {
        final clip = await _clip(file);
        final watch = Stopwatch()..start();
        await expectLater(
          model.embed(
            EmbeddingInput.audio(clip),
            taskType: TaskType.retrievalDocument,
          ),
          throwsA(
            isA<EmbeddingFormatNotSupportedException>()
                .having((e) => e.modality, 'modality', EmbeddingModality.audio)
                .having((e) => e.detected, 'detected', format)
                .having((e) => e.accepted, 'accepted', _audioFormats),
          ),
        );
        expect(
          watch.elapsedMilliseconds,
          lessThan(100),
          reason: 'refused before anything is sent',
        );
      }

      await expectLater(
        model.embed(
          EmbeddingInput.audio(await _clip('corrupt_riff.wav')),
          taskType: TaskType.none,
        ),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', 2)
              .having(
                (e) => e.message,
                'message',
                contains('could not decode the audio'),
              ),
        ),
      );
      expect(model.isClosed, isFalse);
      final again = await model.embed(
        EmbeddingInput.audio(await _clip('kitchen_lights.wav')),
        taskType: TaskType.retrievalDocument,
      );
      _log(
        'containers vs the 16 kHz WAV: $toWav; min cos vs our build '
        '${minNative.toStringAsFixed(6)}; after a corrupt WAV '
        '${_cos(again, wav).toStringAsFixed(6)}',
      );
      expect(_cos(again, wav), greaterThan(0.9999));
      expect(minNative, greaterThanOrEqualTo(_minNative));
      // FLAC is the same samples. Mixing down and resampling a 44.1 kHz stereo
      // file and decoding a 48 kbit/s MP3 cost more, by an amount that depends
      // on the CPU (the int8 audio activations, plus decoder and resampler
      // rounding). Measured, cos to the 16 kHz WAV:
      //   device                         MP3     44.1 kHz stereo
      //   macOS (M4 Pro)                 0.9458  0.9617
      //   iPhone 17 Pro                  0.9458  0.9617
      //   QCS8275 (Kryo, Linux arm64)    0.9234  0.9542
      // (the wheel on macOS: 0.97, 0.99). So 0.90 is a floor that catches a
      // decode gone wrong, not CPU drift; retrieval (the text → audio test)
      // is the real check.
      expect(toWav['kitchen_lights.flac'], greaterThan(0.999));
      expect(toWav['kitchen_lights_44k_stereo.wav'], greaterThan(0.90));
      expect(toWav['kitchen_lights.mp3'], greaterThan(0.90));
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('a 60-second clip is EmbeddingInputTooLongException(1024, '
        '1504) — media tokens counted exactly — and 40 s fits', (tester) async {
      await _ensureEg2Audio();
      final model = await FlutterEdgeAi.getActiveEmbedder(supportAudio: true);
      final watch = Stopwatch()..start();
      // 25 tokens per second plus 4: the wheel's count for the same clip.
      await expectLater(
        model.embed(
          EmbeddingInput.audio(_toneWav(60)),
          taskType: TaskType.none,
        ),
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
      expect(vector, hasLength(768));
      _log(
        'audio overflow: 60 s refused in ${watch.elapsedMilliseconds} ms '
        '(1504 tokens, 1024 kept); 40 s embedded in '
        '${fits.elapsedMilliseconds} ms',
      );
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('combined inputs: text+image, text+audio, image+audio and all '
        'three reproduce the golden', (tester) async {
      await _ensureEg2Audio();
      final model = await FlutterEdgeAi.getActiveEmbedder(
        supportImage: true,
        supportAudio: true,
      );
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
        EmbeddingModality.audio,
      });
      final combined = _group('combined');
      final document = TaskType.retrievalDocument.prefix;
      final toNative = <String, double>{};
      final toWheel = <String, double>{};
      final micros = <String, int>{};
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
        micros[key] = watch.elapsedMicroseconds ~/ 1000;
        toNative[key] = _cos(vector, _f32(item['vector_native'] as String));
        toWheel[key] = _cos(vector, _f32(item['vector'] as String));
      }
      _log(
        'combined: vs our build $toNative (need $_minNative); vs the wheel '
        '$toWheel (need $_minWheel); ms $micros',
      );
      for (final MapEntry(:key, :value) in toNative.entries) {
        final bound = (combined[key] as Map)['audio'] == null
            ? _minTextNative
            : _minNative;
        expect(value, greaterThanOrEqualTo(bound), reason: key);
        expect(toWheel[key], greaterThanOrEqualTo(_minWheel), reason: key);
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('a RAG audio index: add the clips, find each by text', (
      tester,
    ) async {
      await _ensureEg2Audio();
      final rag = FlutterEdgeAiRag(
        providers: const [SqliteVectorStoreProvider()],
      );
      final location =
          '${await _scratch('rag')}${Platform.pathSeparator}clips.db';
      final clipsIndex = await rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: location,
          documents: EmbeddingModality.audio,
        ),
        embedder: FlutterEdgeAiActiveEmbedder(
          // Audio vectors do not depend on the vision budget: the text id.
          profileId: _eg2Audio.ragProfileId,
          supportAudio: true,
        ),
      );
      try {
        expect(clipsIndex.documents, EmbeddingModality.audio);
        final clips = _group('clips');
        final addMs = <int>[];
        for (final MapEntry(:key, :value) in clips.entries) {
          final file = (value as Map)['file'] as String;
          final watch = Stopwatch()..start();
          await clipsIndex.add(
            id: key,
            document: EmbeddingInput.audio(await _clip(file)),
            content: 'asset:assets/eg2_audio/$file',
          );
          addMs.add(watch.elapsedMilliseconds);
        }
        await clipsIndex.flush();
        expect((await clipsIndex.stats()).documentCount, clips.length);
        final found = <String>[];
        for (final MapEntry(:key, :value) in clips.entries) {
          final hits = await clipsIndex.search(
            query: EmbeddingInput.text((value as Map)['query'] as String),
            topK: 2,
          );
          found.add(
            '$key: ${[for (final h in hits) '${h.id} ${h.similarity.toStringAsFixed(3)}']}',
          );
          expect(hits.first.id, key);
        }
        _log('rag audio index: add per clip $addMs ms; $found');
      } finally {
        await clipsIndex.dispose();
      }
    }, timeout: const Timeout(Duration(minutes: 20)));

    testWidgets('supportAudio on the 270m and on the 440m is refused from the '
        'bundle, naming the 740m, before any engine or cache exists — and the '
        'embedder the app holds keeps working', (tester) async {
      for (final ensure in [_ensureEg2, _ensureEg2Vision]) {
        await ensure();
        final held = await FlutterEdgeAi.getActiveEmbedder();
        final before = await _cacheTree();
        await expectLater(
          FlutterEdgeAi.getActiveEmbedder(supportAudio: true),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('has no audio encoder'),
                contains('embeddinggemma-2-740m'),
              ),
            ),
          ),
        );
        expect(
          await _cacheTree(),
          before,
          reason: 'refused from the bundle: no engine, so no cache written',
        );
        // Refused in describe(), before core closes the cached embedder: the
        // one the app holds is still open, and still embeds.
        expect(held.isClosed, isFalse);
        expect(
          await held.embed(
            EmbeddingInput.text('still a text model'),
            taskType: TaskType.retrievalQuery,
          ),
          hasLength(768),
        );
        expect(
          identical(await FlutterEdgeAi.getActiveEmbedder(), held),
          isTrue,
        );
      }
    }, timeout: const Timeout(Duration(minutes: 30)));
  });
}

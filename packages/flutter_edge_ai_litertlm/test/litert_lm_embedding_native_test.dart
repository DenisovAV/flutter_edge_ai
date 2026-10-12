// The EmbeddingGemma 2 pass on the REAL libLiteRtLm (native-v0.18.0-e) and
// the real bundles, in the VM — the X1 check of R5 §10.1 at the FFI level:
// text through these Dart bindings reproduces the golden `vector`, which came
// from the same macOS arm64 dylib through Python ctypes.
//
// Opt-in, skipped unless both are present:
// - the host libLiteRtLm (a macOS dev box has it in the hook's download
//   cache after any example build);
// - EG2_270M_LITERTLM=<path to embeddinggemma-2-text-270m.litertlm> (the
//   pinned revision, sha256 2d079ee2…86fb). EG2_440M_LITERTLM adds the
//   vision-bundle case.
//
//   EG2_270M_LITERTLM=… flutter test test/litert_lm_embedding_native_test.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_io.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_embedding_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

const _goldenPath =
    '../flutter_edge_ai/example/integration_test/goldens/eg2_text_golden.json';

String? _dylib() => firstExistingPath(
  hostNativeLibraryCandidates(
    libFileName: hostNativeLibraryFileName('LiteRtLm'),
  ),
);

String? _env(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
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

void main() {
  final dylib = _dylib();
  final bundle270m = _env('EG2_270M_LITERTLM');
  final bundle440m = _env('EG2_440M_LITERTLM');
  final skip = dylib == null
      ? 'no host libLiteRtLm in the download cache'
      : bundle270m == null
      ? 'EG2_270M_LITERTLM is not set'
      : null;

  late Directory cacheBase;
  LiteRtLmEmbeddingBindings bindings() =>
      bindLiteRtLmEmbeddings(DynamicLibrary.open(dylib!), label: dylib);

  LiteRtLmEmbeddingPass pass(
    String modelPath, {
    Set<EmbeddingModality> media = const {},
  }) => LiteRtLmEmbeddingPass(
    LiteRtLmEmbeddingConfig(
      modelPath: modelPath,
      cacheBase: cacheBase.path,
      declaredMedia: media,
    ),
    openBindings: bindings,
  );

  setUp(() {
    cacheBase = Directory.systemTemp.createTempSync('eg2_native_cache_');
  });
  tearDown(() => cacheBase.deleteSync(recursive: true));

  test('the shipped library exports everything the pass calls', () {
    checkLiteRtLmEmbeddingSymbols(
      DynamicLibrary.open(dylib!).providesSymbol,
      library: dylib,
    );
  }, skip: dylib == null ? 'no host libLiteRtLm in the download cache' : null);

  test(
    '270m reproduces the golden vectors (X1), ranks every query\'s '
    'document first, and leaves its weight cache in its own directory',
    () async {
      final golden = jsonDecode(File(_goldenPath).readAsStringSync()) as Map;
      final items = (golden['items'] as List).cast<Map<String, dynamic>>();
      final p = pass(bundle270m!);
      final loadWatch = Stopwatch()..start();
      final info = await p.load();
      loadWatch.stop();
      try {
        expect(info.dimension, 768);
        expect(info.modalities, {EmbeddingModality.text});
        expect(info.maxInputTokens, 1024);

        final vectors = <String, List<double>>{};
        final timings = <int>[];
        var minGolden = 1.0, minSt = 1.0;
        for (final item in items) {
          final taskType = item['role'] == 'query'
              ? TaskType.retrievalQuery
              : TaskType.retrievalDocument;
          expect(taskType.prefix, item['prefix']);
          final watch = Stopwatch()..start();
          final vector = await p.embed(
            EmbeddingInput.text(item['text'] as String),
            taskType,
          );
          timings.add(watch.elapsedMicroseconds);
          final want = (item['vector'] as List)
              .cast<num>()
              .map((v) => v.toDouble())
              .toList();
          final st = (item['vector_st_fp32'] as List)
              .cast<num>()
              .map((v) => v.toDouble())
              .toList();
          final cosGolden = _cos(vector, want);
          final cosSt = _cos(vector, st);
          minGolden = math.min(minGolden, cosGolden);
          minSt = math.min(minSt, cosSt);
          expect(
            cosGolden,
            greaterThanOrEqualTo(0.9999),
            reason: '${item['id']}',
          );
          expect(cosSt, greaterThanOrEqualTo(0.97), reason: '${item['id']}');
          vectors[item['id'] as String] = vector;
        }
        for (var i = 0; i < 6; i++) {
          final query = vectors['q$i']!;
          final scores = [
            for (var j = 0; j < 6; j++) _cos(query, vectors['d$j']!),
          ];
          final best = scores.indexOf(scores.reduce(math.max));
          expect(best, i, reason: 'q$i ranks d$best first: $scores');
        }
        timings.sort();
        // ignore: avoid_print
        print(
          'EG2 270m on ${Platform.operatingSystem}: load '
          '${loadWatch.elapsedMilliseconds} ms; min cos vs golden '
          '$minGolden, vs ST fp32 $minSt; per embed median '
          '${timings[timings.length ~/ 2] / 1000} ms, max '
          '${timings.last / 1000} ms',
        );

        final dir = Directory(p.cacheDir!);
        expect(dir.parent.path, cacheBase.path);
        expect(
          dir.listSync().whereType<File>().any(
            (f) => f.path.endsWith('.xnnpack_cache'),
          ),
          isTrue,
          reason: 'the engine writes its weight cache where the pass told it',
        );
      } finally {
        await p.close();
      }
    },
    skip: skip,
  );

  test('an over-long text is EmbeddingInputTooLongException(1024, null), and '
      'the engine keeps working', () async {
    final p = pass(bundle270m!);
    await p.load();
    try {
      await expectLater(
        p.embed(
          EmbeddingInput.text('lorem ipsum dolor sit amet ' * 2300),
          TaskType.retrievalDocument,
        ),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', isNull),
        ),
      );
      final vector = await p.embed(
        EmbeddingInput.text('still working'),
        TaskType.retrievalQuery,
      );
      expect(vector, hasLength(768));
    } finally {
      await p.close();
    }
  }, skip: skip);

  test('images declared on the 270m: no vision encoder, refused from '
      'ModelInfo', () async {
    final p = pass(bundle270m!, media: {EmbeddingModality.image});
    await expectLater(
      p.load(),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          contains('has no vision encoder'),
        ),
      ),
    );
    await p.close();
    expect(cacheBase.listSync(), isEmpty, reason: 'no engine, no cache');
  }, skip: skip);

  test('an LLM bundle is not an embedder', () async {
    final p = pass('test/ffi/fixtures/gemma3_1b_prefix.litertlm');
    await expectLater(
      p.load(),
      throwsA(
        isA<EmbeddingLoadException>().having(
          (e) => e.message,
          'message',
          contains('is an LLM bundle, not an embedder'),
        ),
      ),
    );
    await p.close();
  }, skip: dylib == null ? 'no host libLiteRtLm in the download cache' : null);

  test(
    '440m: vision present, 1.13.0 still embeds text only; text matches the '
    '270m golden',
    () async {
      final refused = pass(bundle440m!, media: {EmbeddingModality.image});
      await expectLater(
        refused.load(),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            liteRtLmTextOnlyRefusal,
          ),
        ),
      );
      await refused.close();

      final golden = jsonDecode(File(_goldenPath).readAsStringSync()) as Map;
      final item = (golden['items'] as List).first as Map<String, dynamic>;
      final p = pass(bundle440m);
      final info = await p.load();
      try {
        expect(info.modalities, {EmbeddingModality.text});
        final vector = await p.embed(
          EmbeddingInput.text(item['text'] as String),
          TaskType.retrievalQuery,
        );
        final want = (item['vector'] as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList();
        expect(_cos(vector, want), greaterThanOrEqualTo(0.9999));
      } finally {
        await p.close();
      }
    },
    skip: skip ?? (bundle440m == null ? 'EG2_440M_LITERTLM is not set' : null),
  );
}

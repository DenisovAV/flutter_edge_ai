// Baseline benchmark for the legacy DartVectorStoreRepository (sqlite3 +
// local_hnsw) — the same workload used by vector_store_benchmark_test.dart
// against qdrant. Used to produce apples-to-apples comparison numbers for
// the 0.16 release notes.
//
// Run on macOS:
//   cd example && flutter test integration_test/vector_store_dart_benchmark_test.dart -d macos
// Run on Android:
//   flutter test integration_test/vector_store_dart_benchmark_test.dart -d <device-id>
//
// Output: integration_test/benchmarks/qdrant_bench_dart_<platform>.json
// (same shape as the qdrant bench file so a comparison generator can diff).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ignore_for_file: deprecated_member_use
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

const _sizes = <int>[1000, 5000];
const _searchSamples = 100;

const _loremWords = [
  'lorem',
  'ipsum',
  'dolor',
  'sit',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'do',
  'eiusmod',
  'tempor',
  'incididunt',
  'ut',
  'labore',
  'magna',
  'aliqua',
  'enim',
  'ad',
  'minim',
  'veniam',
  'quis',
  'nostrud',
  'exercitation',
  'ullamco',
  'laboris',
  'nisi',
  'aliquip',
  'ex',
  'ea',
  'commodo',
  'consequat',
  'duis',
  'aute',
  'irure',
  'in',
  'reprehenderit',
  'voluptate',
  'velit',
  'esse',
  'cillum',
  'dolore',
  'eu',
  'fugiat',
  'nulla',
  'pariatur',
  'excepteur',
  'sint',
  'occaecat',
  'cupidatat',
  'non',
  'proident',
  'sunt',
  'culpa',
  'qui',
  'officia',
  'deserunt',
  'mollit',
  'anim',
  'id',
  'laborum',
  'curabitur',
  'pretium',
  'tincidunt',
  'lacus',
  'nulla',
  'gravida',
  'orci',
  'a',
  'odio',
  'nullam',
  'varius',
  'turpis',
  'et',
  'commodo',
];

String _chunk(math.Random rng, int wordCount) {
  final words = List.generate(
    wordCount,
    (_) => _loremWords[rng.nextInt(_loremWords.length)],
  );
  return words.join(' ');
}

class _LatencyStats {
  final List<int> samplesUs;
  _LatencyStats(this.samplesUs);

  int get p50 => _percentile(50);
  int get p95 => _percentile(95);
  int get p99 => _percentile(99);

  int _percentile(int p) {
    final sorted = [...samplesUs]..sort();
    final idx = ((sorted.length - 1) * p / 100).round();
    return sorted[idx];
  }

  Map<String, int> toJson() => {
    'p50_us': p50,
    'p95_us': p95,
    'p99_us': p99,
    'count': samplesUs.length,
  };
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Embedding 5000 chunks via EmbeddingGemma on a CPU-only Windows VM
  // takes ~25 min, plus the legacy Dart HNSW takes another ~10 min to
  // upsert 5k. Disable the per-test default timeout (12 min) so the
  // bench can finish on slower targets.
  binding.defaultTestTimeout = const Timeout(Duration(hours: 1));

  // `testWidgets` (rather than plain `test`) is required for long-running
  // integration tests on the Windows device runner — without a
  // WidgetTester-bound test, the runner declares the test "did not
  // complete" after ~3 minutes even though async work is still in flight.
  testWidgets(
    'DartVectorStore baseline — upsert + search at 1k/5k',
    (WidgetTester tester) async {
      // See the qdrant bench for the rationale — long FFI loops deadlock
      // the test runner on Windows desktop unless they run outside the
      // FakeAsync zone via `tester.runAsync(...)`.
      await tester.runAsync(() async {
        await registerTestEngines();
        await FlutterEdgeAi.installEmbedder()
            .modelFromAsset(_modelPath)
            .tokenizerFromAsset(_tokenizerPath)
            .install();
        final embedder = await FlutterEdgeAi.getActiveEmbedder();

        final totalDocs = _sizes.reduce(math.max);
        final rng = math.Random(42);
        final texts = List.generate(totalDocs, (i) {
          final len = 30 + rng.nextInt(50);
          return _chunk(rng, len);
        });
        // ignore: avoid_print
        print('[dart_bench] generated ${texts.length} lorem chunks');

        final sw = Stopwatch()..start();
        final vectors = <List<double>>[];
        for (var i = 0; i < texts.length; i++) {
          vectors.add(await embedder.generateEmbedding(texts[i]));
          if ((i + 1) % 500 == 0) {
            // ignore: avoid_print
            print(
              '[dart_bench] embedded ${i + 1}/${texts.length} '
              '(${sw.elapsed.inSeconds}s elapsed)',
            );
          }
        }
        sw.stop();
        final dim = vectors.first.length;
        // ignore: avoid_print
        print(
          '[dart_bench] embeddings ready: $dim-dim, '
          '${sw.elapsed.inSeconds}s total',
        );

        final categories = ['tech', 'science', 'culture'];
        final results = <Map<String, dynamic>>[];

        for (final size in _sizes) {
          final base = await getApplicationSupportDirectory();
          final dbPath =
              '${base.path}/dart_bench_${size}_${DateTime.now().microsecondsSinceEpoch}.db';

          final repo = SqliteVectorStore();
          await repo.initialize(dbPath);

          // Upsert N points. DartVectorStoreRepository has no batch API — it
          // adds documents one at a time. The single-call overhead is part of
          // the legacy story; don't try to hide it.
          final upsertSw = Stopwatch()..start();
          for (var i = 0; i < size; i++) {
            await repo.addDocument(
              id: 'doc_$i',
              content: texts[i],
              embedding: vectors[i],
              metadata: '{"category":"${categories[i % categories.length]}"}',
            );
          }
          upsertSw.stop();
          final upsertSec = upsertSw.elapsedMicroseconds / 1e6;
          final upsertRate = size / upsertSec;
          // ignore: avoid_print
          print(
            '[dart_bench] N=$size upsert: ${upsertSec.toStringAsFixed(2)}s, '
            '${upsertRate.toStringAsFixed(0)} points/sec',
          );

          final searchSamples = <int>[];
          for (var i = 0; i < _searchSamples; i++) {
            final q = vectors[rng.nextInt(size)];
            final s = Stopwatch()..start();
            await repo.searchSimilar(queryEmbedding: q, topK: 10);
            s.stop();
            searchSamples.add(s.elapsedMicroseconds);
          }
          final searchStats = _LatencyStats(searchSamples);

          // ignore: avoid_print
          print(
            '[dart_bench] N=$size search:   p50=${searchStats.p50}us  '
            'p95=${searchStats.p95}us  p99=${searchStats.p99}us',
          );

          results.add({
            'n': size,
            'upsert': {
              'seconds': upsertSec,
              'points_per_sec': upsertRate.round(),
            },
            'search': searchStats.toJson(),
            // No payload filtering on legacy impl — leaves comparison
            // honest: qdrant has filters, Dart HNSW doesn't.
            'search_with_filter': null,
          });

          await repo.close();
          final f = File(dbPath);
          if (f.existsSync()) f.deleteSync();
        }

        final out = File(
          '${(await getApplicationSupportDirectory()).path}/qdrant_bench_dart_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch}.json',
        );
        out.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'impl': 'DartVectorStoreRepository (sqlite3 + local_hnsw)',
            'platform': Platform.operatingSystem,
            'os_version': Platform.operatingSystemVersion,
            'embedding_dim': dim,
            'corpus_chars_per_doc_avg':
                (texts.fold<int>(0, (s, t) => s + t.length) / texts.length)
                    .round(),
            'timestamp': DateTime.now().toUtc().toIso8601String(),
            'results': results,
          }),
        );
        // ignore: avoid_print
        print('[dart_bench] results written: ${out.path}');
      }); // end of tester.runAsync
    },
    timeout: const Timeout(Duration(minutes: 60)),
  );
}

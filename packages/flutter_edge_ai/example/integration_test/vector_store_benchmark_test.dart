// Benchmark: qdrant-edge vector store performance with realistic embeddings.
//
// Run on macOS:
//   cd example && flutter test integration_test/vector_store_benchmark_test.dart -d macos
// Run on Android (Pixel 8 etc.):
//   flutter test integration_test/vector_store_benchmark_test.dart -d <device-id>
//
// Output: integration_test/benchmarks/qdrant_bench_results.json (one entry
// per run, identified by platform + timestamp).
//
// What we measure (per N in {1000, 5000}):
//   - upsert throughput: total time for `upsertBatch(N)`, points/sec
//   - search latency: 100 single-vector searches, p50/p95/p99 in microseconds
//   - filtered search latency: same, plus a `must` filter on payload
//
// Embeddings are produced by EmbeddingGemma 300M (already in example assets)
// from deterministic lorem-ipsum chunks so the measurement is stable across
// runs.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_edge_ai_qdrant/src/filter_codec.dart';
import 'package:flutter_edge_ai_qdrant/src/point_id_hasher.dart';
import 'package:flutter_edge_ai_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

// Sizes we benchmark at. Kept modest so the test fits in CI timeouts on
// mobile (a Pixel 8 embedding pass over 5k chunks is ~90s by itself).
const _sizes = <int>[1000, 5000];

// Number of search calls per latency sample.
const _searchSamples = 100;

// Lorem-ipsum corpus reused across all sizes; shuffled with a fixed seed
// so each run gets the same text → the same embeddings → stable numbers.
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
  // takes ~25 min. The per-test default timeout (12 min) trips before we
  // get to the qdrant measurements; disable it so the bench can finish.
  binding.defaultTestTimeout = const Timeout(Duration(hours: 1));

  // `testWidgets` (rather than plain `test`) is required for long-running
  // integration tests on the Windows device runner — without a
  // WidgetTester-bound test, the runner declares the test "did not
  // complete" after ~3 minutes even though async work is still in flight.
  testWidgets(
    'qdrant-edge benchmark — upsert + search at 1k/5k',
    (WidgetTester tester) async {
      // `tester.runAsync(...)` runs the body OUTSIDE the test framework's
      // FakeAsync zone. Required for long async loops that call into native
      // FFI (EmbeddingGemma): FakeAsync intercepts every microtask, and on
      // Windows desktop the 5k-iteration loop deadlocks the test runner
      // after ~3 minutes without it. macOS/Android tolerated the leak.
      await tester.runAsync(() async {
        // ---------- 1. Setup: embedding model + corpus + output dir ----------
        await registerTestEngines();
        await FlutterEdgeAi.installEmbedder()
            .modelFromAsset(_modelPath)
            .tokenizerFromAsset(_tokenizerPath)
            .install();
        final embedder = await FlutterEdgeAi.getActiveEmbedder();

        final totalDocs = _sizes.reduce(math.max);
        final rng = math.Random(42); // deterministic
        final texts = List.generate(totalDocs, (i) {
          // Vary length 30-80 words so token usage spans a useful range without
          // pushing past EmbeddingGemma's 256-token window.
          final len = 30 + rng.nextInt(50);
          return _chunk(rng, len);
        });
        // ignore: avoid_print
        print('[bench] generated ${texts.length} lorem chunks');

        // Embed all texts up-front (sequentially — embedding model is single-
        // threaded in our setup) and cache the vectors. Excluded from upsert
        // timing so we measure qdrant, not EmbeddingGemma.
        final sw = Stopwatch()..start();
        final vectors = <List<double>>[];
        for (var i = 0; i < texts.length; i++) {
          vectors.add(await embedder.generateEmbedding(texts[i]));
          if ((i + 1) % 500 == 0) {
            // ignore: avoid_print
            print(
              '[bench] embedded ${i + 1}/${texts.length} '
              '(${sw.elapsed.inSeconds}s elapsed)',
            );
          }
        }
        sw.stop();
        final dim = vectors.first.length;
        // ignore: avoid_print
        print(
          '[bench] embeddings ready: $dim-dim, '
          '${sw.elapsed.inSeconds}s total, ${(texts.length / sw.elapsed.inSeconds).toStringAsFixed(1)} docs/sec',
        );

        // Categories spread evenly so filter tests can find ~33% of corpus.
        final categories = ['tech', 'science', 'culture'];

        // ---------- 2. Per-size benchmark ----------
        final results = <Map<String, dynamic>>[];

        for (final size in _sizes) {
          final base = await getApplicationSupportDirectory();
          final shardDir = Directory(
            '${base.path}/qdrant_bench_${size}_${DateTime.now().microsecondsSinceEpoch}',
          );
          final client = await QdrantEdgeClient.open(
            path: shardDir.path,
            dim: dim,
          );

          // Upsert N points in chunks of 500 (qdrant batch overhead).
          final upsertSw = Stopwatch()..start();
          const chunkSize = 500;
          for (var off = 0; off < size; off += chunkSize) {
            final end = math.min(off + chunkSize, size);
            await client.upsertBatch([
              for (var i = off; i < end; i++)
                (
                  id: PointIdHasher.hash('doc_$i'),
                  vector: vectors[i],
                  payload: {'category': categories[i % categories.length]},
                ),
            ]);
          }
          upsertSw.stop();
          final upsertSec = upsertSw.elapsedMicroseconds / 1e6;
          final upsertRate = size / upsertSec;

          // ignore: avoid_print
          print(
            '[bench] N=$size upsert: ${upsertSec.toStringAsFixed(2)}s, '
            '${upsertRate.toStringAsFixed(0)} points/sec',
          );

          // 100 unfiltered searches — random query is a random stored embedding.
          final searchSamples = <int>[];
          for (var i = 0; i < _searchSamples; i++) {
            final q = vectors[rng.nextInt(size)];
            final s = Stopwatch()..start();
            await client.search(queryVector: q, topK: 10);
            s.stop();
            searchSamples.add(s.elapsedMicroseconds);
          }
          final searchStats = _LatencyStats(searchSamples);

          // 100 filtered searches — same queries, plus a category filter.
          final filterSamples = <int>[];
          final filterJson = FilterCodec.encode(
            const Filter(
              must: [FieldEquals(key: 'category', value: 'science')],
            ),
            FilterSchema(
              fields: [
                FilterField(name: 'category', type: FilterFieldType.string),
              ],
            ),
          );
          for (var i = 0; i < _searchSamples; i++) {
            final q = vectors[rng.nextInt(size)];
            final s = Stopwatch()..start();
            await client.search(
              queryVector: q,
              topK: 10,
              filterJson: filterJson,
            );
            s.stop();
            filterSamples.add(s.elapsedMicroseconds);
          }
          final filterStats = _LatencyStats(filterSamples);

          // ignore: avoid_print
          print(
            '[bench] N=$size search:   p50=${searchStats.p50}us  '
            'p95=${searchStats.p95}us  p99=${searchStats.p99}us',
          );
          // ignore: avoid_print
          print(
            '[bench] N=$size filter:   p50=${filterStats.p50}us  '
            'p95=${filterStats.p95}us  p99=${filterStats.p99}us',
          );

          results.add({
            'n': size,
            'upsert': {
              'seconds': upsertSec,
              'points_per_sec': upsertRate.round(),
            },
            'search': searchStats.toJson(),
            'search_with_filter': filterStats.toJson(),
          });

          await client.close();
          if (shardDir.existsSync()) {
            shardDir.deleteSync(recursive: true);
          }
        }

        // ---------- 3. Write results JSON ----------
        final outDir = Directory('integration_test/benchmarks');
        if (!outDir.existsSync()) {
          // path_provider gives us a writable app-support dir on mobile —
          // integration_test/benchmarks/ doesn't exist on the device. Fall
          // back to ApplicationSupportDirectory and tell the user where it
          // landed so they can `adb pull` or pull via Finder/Xcode.
          final base = await getApplicationSupportDirectory();
          final fallback = Directory('${base.path}/qdrant_bench_results');
          fallback.createSync(recursive: true);
          final out = File(
            '${fallback.path}/'
            'qdrant_bench_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch}.json',
          );
          out.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
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
          print('[bench] results written: ${out.path}');
        } else {
          final out = File(
            '${outDir.path}/qdrant_bench_${Platform.operatingSystem}.json',
          );
          out.writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert({
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
          print('[bench] results written: ${out.path}');
        }
      }); // end of tester.runAsync
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

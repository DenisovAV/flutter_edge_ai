// Parallel benchmark for qdrant-edge AND legacy DartVectorStoreRepository
// using a precomputed embedding cache (see embedding_cache_builder_test.dart).
// Skips the embedding generation entirely, so it runs in minutes even on
// Windows where the 5000-call EmbeddingGemma loop hangs the integration_test
// runner at ~03:23.
//
// For each N in {1000, 5000}:
//   - Fresh qdrant shard + fresh Dart HNSW repo (apples-to-apples to
//     macOS/Android bench methodology — independent shards per size).
//   - Upsert first N cached vectors into each, measure throughput.
//   - 100 unfiltered searches on each, measure p50/p95/p99.
//   - 100 filtered searches on qdrant (FieldEquals category=science).
//
// Run:
//   cd example && flutter test integration_test/vector_store_benchmark_cached_test.dart -d windows
//
// Output: <ApplicationSupportDirectory>/qdrant_bench_cached_<platform>_<ts>.json
//   Same shape as macOS/Android bench files, plus an `impl` field per row.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ignore_for_file: deprecated_member_use
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_qdrant/src/filter_codec.dart';
import 'package:flutter_edge_ai_qdrant/src/point_id_hasher.dart';
import 'package:flutter_edge_ai_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart' as rag;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _totalDocs = 5000;
const _expectedDim = 768;
const _sizes = <int>[1000, 5000];
const _searchSamples = 100;

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
  binding.defaultTestTimeout = const Timeout(Duration(hours: 1));

  testWidgets('qdrant + Dart HNSW benchmark using cached embeddings', (
    WidgetTester tester,
  ) async {
    await tester.runAsync(() async {
      // 1. Load cached embeddings.
      final base = await getApplicationSupportDirectory();
      final cacheFile = File(
        '${base.path}/embeddings_cache_${_totalDocs}_${_expectedDim}d.json',
      );
      if (!cacheFile.existsSync()) {
        fail(
          'Cache file missing: ${cacheFile.path}\n'
          'Run embedding_cache_builder_test.dart first to populate it.',
        );
      }
      final raw =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      final vectors = (raw['vectors'] as List)
          .map((v) => (v as List).cast<num>().map((e) => e.toDouble()).toList())
          .toList();
      // ignore: avoid_print
      print(
        '[bench] loaded ${vectors.length} cached vectors '
        '(dim=${vectors.first.length}) from ${cacheFile.path}',
      );
      expect(vectors.length, equals(_totalDocs));
      expect(vectors.first.length, equals(_expectedDim));

      final categories = ['tech', 'science', 'culture'];
      final rng = math.Random(7); // for picking random query vectors
      final results = <Map<String, dynamic>>[];

      for (final size in _sizes) {
        // ignore: avoid_print
        print('[bench] === N=$size ===');

        // ---------- qdrant ----------
        final qdrantShardDir = Directory(
          '${base.path}/qdrant_bench_cached_${size}_${DateTime.now().microsecondsSinceEpoch}',
        );
        final qdrantClient = await QdrantEdgeClient.open(
          path: qdrantShardDir.path,
          dim: _expectedDim,
        );

        final qdrantUpsertSw = Stopwatch()..start();
        const chunkSize = 500;
        for (var off = 0; off < size; off += chunkSize) {
          final end = math.min(off + chunkSize, size);
          await qdrantClient.upsertBatch([
            for (var i = off; i < end; i++)
              (
                id: PointIdHasher.hash('doc_$i'),
                vector: vectors[i],
                payload: {'category': categories[i % categories.length]},
              ),
          ]);
        }
        qdrantUpsertSw.stop();
        final qdrantUpsertSec = qdrantUpsertSw.elapsedMicroseconds / 1e6;
        final qdrantUpsertRate = size / qdrantUpsertSec;
        // ignore: avoid_print
        print(
          '[bench] qdrant upsert: ${qdrantUpsertSec.toStringAsFixed(2)}s, '
          '${qdrantUpsertRate.toStringAsFixed(0)} points/sec',
        );

        final qdrantSearchSamples = <int>[];
        for (var i = 0; i < _searchSamples; i++) {
          final q = vectors[rng.nextInt(size)];
          final s = Stopwatch()..start();
          await qdrantClient.search(queryVector: q, topK: 10);
          s.stop();
          qdrantSearchSamples.add(s.elapsedMicroseconds);
        }
        final qdrantSearch = _LatencyStats(qdrantSearchSamples);

        final qdrantFilterSamples = <int>[];
        final filterJson = FilterCodec.encode(
          rag.Filter(
            must: [rag.FieldEquals(key: 'category', value: 'science')],
          ),
          rag.FilterSchema(
            fields: [
              rag.FilterField(
                name: 'category',
                type: rag.FilterFieldType.string,
              ),
            ],
          ),
        );
        for (var i = 0; i < _searchSamples; i++) {
          final q = vectors[rng.nextInt(size)];
          final s = Stopwatch()..start();
          await qdrantClient.search(
            queryVector: q,
            topK: 10,
            filterJson: filterJson,
          );
          s.stop();
          qdrantFilterSamples.add(s.elapsedMicroseconds);
        }
        final qdrantFilter = _LatencyStats(qdrantFilterSamples);

        // ignore: avoid_print
        print(
          '[bench] qdrant search: p50=${qdrantSearch.p50}us '
          'p95=${qdrantSearch.p95}us p99=${qdrantSearch.p99}us',
        );
        // ignore: avoid_print
        print(
          '[bench] qdrant filter: p50=${qdrantFilter.p50}us '
          'p95=${qdrantFilter.p95}us p99=${qdrantFilter.p99}us',
        );

        await qdrantClient.close();
        if (qdrantShardDir.existsSync()) {
          qdrantShardDir.deleteSync(recursive: true);
        }

        // ---------- Dart HNSW ----------
        final dartDbPath =
            '${base.path}/dart_bench_cached_${size}_${DateTime.now().microsecondsSinceEpoch}.db';
        final dartRepo = SqliteVectorStore();
        await dartRepo.initialize(dartDbPath);
        await dartRepo.bindEmbeddingProfile(
          rag.EmbeddingProfile(
            id: 'cached-benchmark-embedding-768d-v1',
            dimension: _expectedDim,
          ),
        );

        final dartUpsertSw = Stopwatch()..start();
        for (var i = 0; i < size; i++) {
          await dartRepo.addDocument(
            id: 'doc_$i',
            content: 'doc_$i',
            embedding: vectors[i],
            metadata: '{"category":"${categories[i % categories.length]}"}',
          );
        }
        dartUpsertSw.stop();
        final dartUpsertSec = dartUpsertSw.elapsedMicroseconds / 1e6;
        final dartUpsertRate = size / dartUpsertSec;
        // ignore: avoid_print
        print(
          '[bench] dart   upsert: ${dartUpsertSec.toStringAsFixed(2)}s, '
          '${dartUpsertRate.toStringAsFixed(0)} points/sec',
        );

        final dartSearchSamples = <int>[];
        for (var i = 0; i < _searchSamples; i++) {
          final q = vectors[rng.nextInt(size)];
          final s = Stopwatch()..start();
          await dartRepo.searchSimilar(queryEmbedding: q, topK: 10);
          s.stop();
          dartSearchSamples.add(s.elapsedMicroseconds);
        }
        final dartSearch = _LatencyStats(dartSearchSamples);

        // ignore: avoid_print
        print(
          '[bench] dart   search: p50=${dartSearch.p50}us '
          'p95=${dartSearch.p95}us p99=${dartSearch.p99}us',
        );

        await dartRepo.close();
        final dartDbFile = File(dartDbPath);
        if (dartDbFile.existsSync()) dartDbFile.deleteSync();

        results.add({
          'n': size,
          'qdrant': {
            'upsert': {
              'seconds': qdrantUpsertSec,
              'points_per_sec': qdrantUpsertRate.round(),
            },
            'search': qdrantSearch.toJson(),
            'search_with_filter': qdrantFilter.toJson(),
          },
          'dart_hnsw': {
            'upsert': {
              'seconds': dartUpsertSec,
              'points_per_sec': dartUpsertRate.round(),
            },
            'search': dartSearch.toJson(),
            'search_with_filter': null,
          },
        });
      }

      final corpusAvg = raw['corpus_chars_per_doc_avg'];
      final out = File(
        '${base.path}/qdrant_bench_cached_${Platform.operatingSystem}_${DateTime.now().millisecondsSinceEpoch}.json',
      );
      out.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
          'embedding_dim': _expectedDim,
          'corpus_chars_per_doc_avg': corpusAvg,
          'embedding_source':
              'EmbeddingGemma 300M (cached, seed=42, lorem chunks 30-79 words)',
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'results': results,
        }),
      );
      // ignore: avoid_print
      print('[bench] results written: ${out.path}');
    });
  });
}

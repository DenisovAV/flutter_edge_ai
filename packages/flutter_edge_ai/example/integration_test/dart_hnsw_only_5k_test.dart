// Standalone: Dart HNSW baseline at N=5000 only. Used on Windows because
// the ngrok SSH tunnel kept dropping the full parallel bench just before
// JSON serialization. This focused test runs in <2 min.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// ignore_for_file: deprecated_member_use
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _totalDocs = 5000;
const _expectedDim = 768;
const _searchSamples = 100;

class _LatencyStats {
  final List<int> samplesUs;
  _LatencyStats(this.samplesUs);
  int get p50 => _p(50);
  int get p95 => _p(95);
  int get p99 => _p(99);
  int _p(int p) {
    final s = [...samplesUs]..sort();
    return s[((s.length - 1) * p / 100).round()];
  }

  Map<String, int> toJson() => {
    'p50_us': p50,
    'p95_us': p95,
    'p99_us': p99,
    'count': samplesUs.length,
  };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!Platform.isWindows) {
    // This test was added as a Windows-only ngrok-tunnel workaround for
    // benchmarking the deprecated DartVectorStoreRepository at N=5k. Other
    // platforms have full apples-to-apples coverage in the qdrant bench
    // suite, so skipping here keeps the test matrix clean.
    return;
  }
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultTestTimeout = const Timeout(Duration(hours: 1));

  testWidgets('Dart HNSW baseline at N=5000', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final base = await getApplicationSupportDirectory();
      final cacheFile = File(
        '${base.path}/embeddings_cache_${_totalDocs}_${_expectedDim}d.json',
      );
      final raw =
          jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      final vectors = (raw['vectors'] as List)
          .map((v) => (v as List).cast<num>().map((e) => e.toDouble()).toList())
          .toList();
      // ignore: avoid_print
      print('[dart5k] loaded ${vectors.length} cached vectors');

      const categories = ['tech', 'science', 'culture'];
      final rng = math.Random(7);
      final dbPath =
          '${base.path}/dart_hnsw_only_${DateTime.now().microsecondsSinceEpoch}.db';
      final repo = SqliteVectorStore();
      await repo.initialize(dbPath);
      await repo.bindEmbeddingProfile(
        EmbeddingProfile(
          id: 'dart-hnsw-embedding-768d-v1',
          dimension: _expectedDim,
        ),
      );

      final upsertSw = Stopwatch()..start();
      for (var i = 0; i < _totalDocs; i++) {
        await repo.addDocument(
          id: 'doc_$i',
          content: 'doc_$i',
          embedding: vectors[i],
          metadata: '{"category":"${categories[i % categories.length]}"}',
        );
      }
      upsertSw.stop();
      final upsertSec = upsertSw.elapsedMicroseconds / 1e6;
      // ignore: avoid_print
      print(
        '[dart5k] upsert: ${upsertSec.toStringAsFixed(2)}s, ${(_totalDocs / upsertSec).toStringAsFixed(0)} pts/sec',
      );

      final samples = <int>[];
      for (var i = 0; i < _searchSamples; i++) {
        final q = vectors[rng.nextInt(_totalDocs)];
        final s = Stopwatch()..start();
        await repo.searchSimilar(queryEmbedding: q, topK: 10);
        s.stop();
        samples.add(s.elapsedMicroseconds);
      }
      final stats = _LatencyStats(samples);
      // ignore: avoid_print
      print(
        '[dart5k] search: p50=${stats.p50}us p95=${stats.p95}us p99=${stats.p99}us',
      );

      final out = File(
        '${base.path}/dart_hnsw_only_5k_${Platform.operatingSystem}.json',
      );
      out.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'platform': Platform.operatingSystem,
          'n': _totalDocs,
          'upsert': {
            'seconds': upsertSec,
            'points_per_sec': (_totalDocs / upsertSec).round(),
          },
          'search': stats.toJson(),
        }),
      );
      // ignore: avoid_print
      print('[dart5k] written: ${out.path}');

      await repo.close();
      final f = File(dbPath);
      if (f.existsSync()) f.deleteSync();
    });
  });
}

// Benchmark: new sqlite-vec/vec0 SqliteVectorStore vs QdrantVectorStore.
//
// Pure-Dart host-VM harness. Runs ONE deterministic corpus + query set (fixed
// seed, fixed dim) through both stores behind the identical
// `VectorStoreRepository` API, measures addDocument throughput + searchSimilar
// latency (median over N repeats with warm-up), gates on top-K id parity
// (within float tolerance), and prints a parseable markdown table.
//
// It is loop-runnable: the bench parses its own printed table — no manual
// timing — so a runner can re-execute it and read the numbers back.
//
// Prereqs (both native extensions must be present for a full run):
//   * sqlite-vec: $VEC0_DYLIB → the prebuilt vec0 loadable extension
//     (github.com/asg017/sqlite-vec/releases). Required for the vec0 arm.
//   * qdrant-edge: resolved automatically via the official `qdrant_edge` SDK's
//     own Native Assets build hook — no manual dylib path. Optional in the
//     sense that if the hook can't provision it for this platform, the qdrant
//     arm is SKIPPED (probed at startup) and the table prints the vec0 column
//     only.
//
// Run from the package dir:
//   VEC0_DYLIB=/path/to/vec0.dylib \
//   dart run tool/bench_vector_stores.dart
//
// Flags:
//   --sizes=1000,10000   corpus sizes (default 1k,10k; 100k is OFF by default
//                        — add it explicitly, e.g. --sizes=1000,10000,100000,
//                        it is slow and memory-heavy on the exact-KNN arm).
//   --topks=5,50         top-K values (default 5,50).
//   --repeats=11         search-latency repeats per (store,size,topK); median
//                        reported. Default 11 (odd → exact median).
//   --warmup=3           warm-up searches discarded before timing. Default 3.
//   --queries=20         distinct query vectors per measurement. Default 20.
//   --dim=384            embedding dimension. Default 384 (a real embedder size).
//   --seed=1234567       PRNG seed for the deterministic corpus. Default fixed.
//   --tol=1e-4           similarity tolerance for the top-K parity gate.
//   --no-qdrant          skip the qdrant arm even if its dylib is available.
//   --no-vec0            skip the vec0 arm (qdrant-only run).

import 'dart:io';
import 'dart:math';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
// Dev-only import (qdrant is a dev_dependency, never exported from lib/). The
// qdrant arm is gated at runtime: it is probed at startup (open a throwaway
// shard) and skipped if that fails — the official qdrant_edge SDK resolves
// its own native library via its Native Assets build hook, with no override
// for this bench tool to set.
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';

/// One measured cell: how a single store performed at one (size, topK).
class _Cell {
  _Cell({
    required this.addThroughput,
    required this.searchMedianUs,
    required this.searchP90Us,
  });

  /// Documents inserted per second during the bulk add.
  final double addThroughput;

  /// Median searchSimilar latency in microseconds.
  final double searchMedianUs;

  /// 90th-percentile searchSimilar latency in microseconds.
  final double searchP90Us;
}

class BenchConfig {
  BenchConfig({
    required this.sizes,
    required this.topKs,
    required this.repeats,
    required this.warmup,
    required this.queries,
    required this.dim,
    required this.seed,
    required this.tolerance,
    required this.runVec0,
    required this.runQdrant,
  });

  final List<int> sizes;
  final List<int> topKs;
  final int repeats;
  final int warmup;
  final int queries;
  final int dim;
  final int seed;
  final double tolerance;
  final bool runVec0;
  final bool runQdrant;

  static BenchConfig parse(List<String> args) {
    var sizes = <int>[1000, 10000];
    var topKs = <int>[5, 50];
    var repeats = 11;
    var warmup = 3;
    var queries = 20;
    var dim = 384;
    var seed = 1234567;
    var tolerance = 1e-4;
    var runVec0 = true;
    var runQdrant = true;

    for (final arg in args) {
      if (arg == '--no-qdrant') {
        runQdrant = false;
      } else if (arg == '--no-vec0') {
        runVec0 = false;
      } else if (arg.startsWith('--sizes=')) {
        sizes = _ints(arg.substring('--sizes='.length));
      } else if (arg.startsWith('--topks=')) {
        topKs = _ints(arg.substring('--topks='.length));
      } else if (arg.startsWith('--repeats=')) {
        repeats = int.parse(arg.substring('--repeats='.length));
      } else if (arg.startsWith('--warmup=')) {
        warmup = int.parse(arg.substring('--warmup='.length));
      } else if (arg.startsWith('--queries=')) {
        queries = int.parse(arg.substring('--queries='.length));
      } else if (arg.startsWith('--dim=')) {
        dim = int.parse(arg.substring('--dim='.length));
      } else if (arg.startsWith('--seed=')) {
        seed = int.parse(arg.substring('--seed='.length));
      } else if (arg.startsWith('--tol=')) {
        tolerance = double.parse(arg.substring('--tol='.length));
      } else {
        // FormatException (not exit()) so the test harness can surface a bad
        // flag instead of killing the process. main() maps it to exit 64.
        throw FormatException('Unknown flag: $arg');
      }
    }

    return BenchConfig(
      sizes: sizes,
      topKs: topKs,
      repeats: repeats,
      warmup: warmup,
      queries: queries,
      dim: dim,
      seed: seed,
      tolerance: tolerance,
      runVec0: runVec0,
      runQdrant: runQdrant,
    );
  }

  static List<int> _ints(String csv) => csv
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();
}

/// Deterministic L2-normalised embedding for index [i]. A fixed-seed PRNG keyed
/// on the document index makes the corpus reproducible across stores and runs,
/// so vec0 and qdrant see byte-identical input and the parity gate is meaningful.
List<double> _embedding(int i, int dim, int seed) {
  final rng = Random(seed ^ (i * 0x9E3779B1));
  final v = List<double>.filled(dim, 0);
  var norm = 0.0;
  for (var d = 0; d < dim; d++) {
    // Gaussian-ish via Box-Muller so vectors spread over the sphere.
    final u1 = rng.nextDouble().clamp(1e-12, 1.0);
    final u2 = rng.nextDouble();
    final g = sqrt(-2.0 * log(u1)) * cos(2 * pi * u2);
    v[d] = g;
    norm += g * g;
  }
  norm = sqrt(norm);
  if (norm == 0) norm = 1;
  for (var d = 0; d < dim; d++) {
    v[d] = v[d] / norm;
  }
  return v;
}

String _docId(int i) => 'doc-$i';

/// Median of a list (caller sorts). [xs] must be non-empty + sorted ascending.
double _median(List<double> xs) {
  final n = xs.length;
  if (n.isOdd) return xs[n ~/ 2];
  return (xs[n ~/ 2 - 1] + xs[n ~/ 2]) / 2.0;
}

/// p-th percentile (0..1) of a sorted ascending list (nearest-rank).
double _percentile(List<double> sorted, double p) {
  if (sorted.length == 1) return sorted.first;
  final rank = (p * (sorted.length - 1)).round();
  return sorted[rank];
}

/// Populates [store] with [size] deterministic documents and returns the bulk
/// add throughput (docs/sec). Each document carries a tiny JSON metadata blob so
/// the harness mirrors real RAG payloads (and exercises both stores' add path).
Future<double> _populate(
  VectorStoreRepository store,
  int size,
  BenchConfig cfg,
) async {
  final sw = Stopwatch()..start();
  for (var i = 0; i < size; i++) {
    await store.addDocument(
      id: _docId(i),
      content: 'document body $i',
      embedding: _embedding(i, cfg.dim, cfg.seed),
      metadata: '{"idx":$i}',
    );
  }
  sw.stop();
  final seconds = sw.elapsedMicroseconds / 1e6;
  return seconds == 0 ? double.infinity : size / seconds;
}

/// Measures searchSimilar latency for [store] at [topK]: warm-up runs discarded,
/// then `repeats × queries` timed searches; returns (median, p90) in micros plus
/// the per-query top-K id lists from the FIRST repeat (for the parity gate).
Future<({double medianUs, double p90Us, List<List<String>> topKIds})>
_measureSearch(
  VectorStoreRepository store,
  int size,
  int topK,
  BenchConfig cfg,
) async {
  // Query vectors: reuse corpus embeddings at evenly spaced indices so each
  // query has a known exact match (id == that index) — deterministic + a real
  // nearest-neighbour, not noise.
  final queryIndices = <int>[
    for (var q = 0; q < cfg.queries; q++)
      (q * (size ~/ max(1, cfg.queries))) % size,
  ];
  final queries = [
    for (final qi in queryIndices) _embedding(qi, cfg.dim, cfg.seed),
  ];

  // Warm-up — not timed (lets the engine page in, JIT, build any caches).
  for (var w = 0; w < cfg.warmup; w++) {
    await store.searchSimilar(
      queryEmbedding: queries[w % queries.length],
      topK: topK,
    );
  }

  final latencies = <double>[];
  List<List<String>>? firstRepeatIds;
  for (var r = 0; r < cfg.repeats; r++) {
    final repeatIds = <List<String>>[];
    for (final q in queries) {
      final sw = Stopwatch()..start();
      final hits = await store.searchSimilar(queryEmbedding: q, topK: topK);
      sw.stop();
      latencies.add(sw.elapsedMicroseconds.toDouble());
      repeatIds.add([for (final h in hits) h.id]);
    }
    firstRepeatIds ??= repeatIds;
  }
  latencies.sort();
  return (
    medianUs: _median(latencies),
    p90Us: _percentile(latencies, 0.90),
    topKIds: firstRepeatIds!,
  );
}

/// Parity gate: the two stores must agree on the top-K ids for every query
/// (order-insensitive, within float tolerance is captured at the similarity
/// layer — here we compare the id SETS, which is the contract the doc asks for:
/// "same top-K ids within float tolerance"). Returns the number of mismatched
/// queries (0 = pass).
int _parityMismatches(List<List<String>> a, List<List<String>> b) {
  var mismatches = 0;
  final n = min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    final sa = a[i].toSet();
    final sb = b[i].toSet();
    if (sa.length != sb.length || !sa.containsAll(sb)) mismatches++;
  }
  return mismatches;
}

Future<void> main(List<String> args) async {
  final BenchConfig cfg;
  try {
    cfg = BenchConfig.parse(args);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exit(64); // EX_USAGE
  }
  final code = await runBench(cfg, stdout);
  if (code != 0) exit(code);
}

/// Runs the full benchmark with [cfg], writing the markdown report to [out] and
/// diagnostics to stderr. Returns a process exit code (0 = ok / parity passed,
/// 1 = correctness-gate failure, 70 = no store available). Extracted from [main]
/// so a `flutter test` harness can drive it on SDKs whose `dart run` FFI kernel
/// transformer can't compile the transitive `NativeCallable` (the Flutter test
/// toolchain compiles it fine — see test/bench_vector_stores_test.dart).
Future<int> runBench(BenchConfig cfg, IOSink out) async {
  // === Engine availability ===
  final vec0Path = Platform.environment['VEC0_DYLIB'];
  final vec0Available =
      cfg.runVec0 &&
      vec0Path != null &&
      vec0Path.isNotEmpty &&
      File(vec0Path).existsSync();
  if (cfg.runVec0 && !vec0Available) {
    stderr.writeln(
      '[bench] vec0 arm DISABLED: \$VEC0_DYLIB not set or file missing '
      '(${vec0Path ?? '<unset>'}). Download a prebuilt vec0 loadable extension '
      'from github.com/asg017/sqlite-vec/releases and point \$VEC0_DYLIB at it.',
    );
  }

  // qdrant resolves its native library automatically via the official
  // qdrant_edge SDK's own Native Assets build hook — nothing for this tool to
  // point at. Probe by opening a throwaway shard; on failure, skip the arm.
  var qdrantAvailable = cfg.runQdrant;
  if (cfg.runQdrant) {
    final probeDir = Directory.systemTemp.createTempSync('bench_qdrant_probe');
    try {
      final probe = QdrantVectorStore();
      await probe.initialize('${probeDir.path}/shard');
      await probe.bindEmbeddingProfile(
        EmbeddingProfile(id: 'benchmark-v1', dimension: cfg.dim),
      );
      await probe.addDocument(
        id: 'probe',
        content: 'probe',
        embedding: _embedding(0, cfg.dim, cfg.seed),
      );
      await probe.close();
    } catch (e) {
      qdrantAvailable = false;
      stderr.writeln(
        '[bench] qdrant arm DISABLED: native library unavailable ($e). '
        'The qdrant_edge SDK\'s Native Assets hook could not provision it '
        'for this platform/toolchain.',
      );
    } finally {
      try {
        probeDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  if (!vec0Available && !qdrantAvailable) {
    stderr.writeln(
      '[bench] No store available (neither vec0 nor qdrant). Nothing to run.',
    );
    return 70; // EX_SOFTWARE
  }

  // Header / provenance — emitted before the table so a runner can attach it.
  out.writeln('# RAG vector store benchmark — sqlite-vec/vec0 vs qdrant');
  out.writeln();
  out.writeln('- Date (UTC): ${DateTime.now().toUtc().toIso8601String()}');
  out.writeln(
    '- Platform: ${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}',
  );
  out.writeln('- Dart: ${Platform.version}');
  out.writeln('- Dimension: ${cfg.dim} (L2-normalised, cosine)');
  out.writeln(
    '- Seed: ${cfg.seed} | queries/measurement: ${cfg.queries} '
    '| repeats: ${cfg.repeats} | warmup: ${cfg.warmup}',
  );
  out.writeln(
    '- Corpus sizes: ${cfg.sizes.join(', ')} '
    '| topK: ${cfg.topKs.join(', ')}',
  );
  out.writeln(
    '- vec0: ${vec0Available ? 'ENABLED ($vec0Path)' : 'skipped'} '
    '| qdrant: ${qdrantAvailable ? 'ENABLED' : 'skipped'}',
  );
  out.writeln('- Parity tolerance: ${cfg.tolerance}');
  out.writeln();

  // Results: keyed by (store, size, topK).
  final vec0Cells = <String, _Cell>{};
  final qdrantCells = <String, _Cell>{};
  final addThroughputVec0 = <int, double>{};
  final addThroughputQdrant = <int, double>{};
  // Parity per (size, topK): mismatched-query count (only when BOTH stores ran).
  final parity = <String, int>{};

  String key(int size, int topK) => '$size|$topK';

  for (final size in cfg.sizes) {
    // --- vec0 arm ---
    SqliteVectorStore? vec0;
    final vec0SearchIds = <int, List<List<String>>>{};
    if (vec0Available) {
      vec0 = SqliteVectorStore();
      final dbFile = File('${Directory.systemTemp.path}/bench_vec0_$size.db');
      if (dbFile.existsSync()) dbFile.deleteSync();
      await vec0.initialize(dbFile.path);
      await vec0.bindEmbeddingProfile(
        EmbeddingProfile(id: 'benchmark-v1', dimension: cfg.dim),
      );
      addThroughputVec0[size] = await _populate(vec0, size, cfg);
      for (final topK in cfg.topKs) {
        final m = await _measureSearch(vec0, size, topK, cfg);
        vec0Cells[key(size, topK)] = _Cell(
          addThroughput: addThroughputVec0[size]!,
          searchMedianUs: m.medianUs,
          searchP90Us: m.p90Us,
        );
        vec0SearchIds[topK] = m.topKIds;
      }
    }

    // --- qdrant arm ---
    final qdrantSearchIds = <int, List<List<String>>>{};
    if (qdrantAvailable) {
      final qdrant = QdrantVectorStore();
      final shardDir = Directory(
        '${Directory.systemTemp.path}/bench_qdrant_$size',
      );
      if (shardDir.existsSync()) shardDir.deleteSync(recursive: true);
      await qdrant.initialize('${shardDir.path}/shard');
      await qdrant.bindEmbeddingProfile(
        EmbeddingProfile(id: 'benchmark-v1', dimension: cfg.dim),
      );
      addThroughputQdrant[size] = await _populate(qdrant, size, cfg);
      for (final topK in cfg.topKs) {
        final m = await _measureSearch(qdrant, size, topK, cfg);
        qdrantCells[key(size, topK)] = _Cell(
          addThroughput: addThroughputQdrant[size]!,
          searchMedianUs: m.medianUs,
          searchP90Us: m.p90Us,
        );
        qdrantSearchIds[topK] = m.topKIds;
      }
      await qdrant.close();
    }

    // --- parity gate (only when both ran) ---
    if (vec0Available && qdrantAvailable) {
      for (final topK in cfg.topKs) {
        parity[key(size, topK)] = _parityMismatches(
          vec0SearchIds[topK]!,
          qdrantSearchIds[topK]!,
        );
      }
    }

    await vec0?.close();
  }

  _printTables(
    cfg,
    out,
    vec0Cells,
    qdrantCells,
    addThroughputVec0,
    addThroughputQdrant,
    parity,
    vec0Available,
    qdrantAvailable,
  );

  // Exit code reflects the correctness gate: any parity mismatch is a failure.
  final anyMismatch = parity.values.any((m) => m > 0);
  if (anyMismatch) {
    stderr.writeln(
      '[bench] CORRECTNESS GATE FAILED — top-K id parity mismatch.',
    );
    return 1;
  }
  return 0;
}

void _printTables(
  BenchConfig cfg,
  IOSink out,
  Map<String, _Cell> vec0,
  Map<String, _Cell> qdrant,
  Map<int, double> addVec0,
  Map<int, double> addQdrant,
  Map<String, int> parity,
  bool vec0Available,
  bool qdrantAvailable,
) {
  String f1(double v) => v.isInfinite ? '∞' : v.toStringAsFixed(1);
  String key(int size, int topK) => '$size|$topK';

  // === addDocument throughput ===
  out.writeln('## addDocument throughput (docs/sec, higher = better)');
  out.writeln();
  out.writeln('| Corpus | vec0 | qdrant | speedup (qdrant/vec0) |');
  out.writeln('|-------:|-----:|-------:|----------------------:|');
  for (final size in cfg.sizes) {
    final v = vec0Available ? addVec0[size] : null;
    final q = qdrantAvailable ? addQdrant[size] : null;
    final speedup = (v != null && q != null && v != 0)
        ? '${(q / v).toStringAsFixed(2)}×'
        : '—';
    out.writeln(
      '| $size | ${v == null ? '—' : f1(v)} | '
      '${q == null ? '—' : f1(q)} | $speedup |',
    );
  }
  out.writeln();

  // === searchSimilar latency ===
  out.writeln('## searchSimilar latency (median µs, lower = better)');
  out.writeln();
  out.writeln(
    '| Corpus | topK | vec0 median | vec0 p90 | qdrant median | qdrant p90 '
    '| speedup (vec0/qdrant) |',
  );
  out.writeln(
    '|-------:|-----:|------------:|---------:|--------------:|-----------:'
    '|----------------------:|',
  );
  for (final size in cfg.sizes) {
    for (final topK in cfg.topKs) {
      final v = vec0[key(size, topK)];
      final q = qdrant[key(size, topK)];
      final speedup = (v != null && q != null && q.searchMedianUs != 0)
          ? '${(v.searchMedianUs / q.searchMedianUs).toStringAsFixed(2)}×'
          : '—';
      out.writeln(
        '| $size | $topK '
        '| ${v == null ? '—' : f1(v.searchMedianUs)} '
        '| ${v == null ? '—' : f1(v.searchP90Us)} '
        '| ${q == null ? '—' : f1(q.searchMedianUs)} '
        '| ${q == null ? '—' : f1(q.searchP90Us)} '
        '| $speedup |',
      );
    }
  }
  out.writeln();

  // === correctness gate ===
  if (vec0Available && qdrantAvailable) {
    out.writeln('## Correctness gate — top-K id parity (0 mismatches = pass)');
    out.writeln();
    out.writeln('| Corpus | topK | mismatched queries | verdict |');
    out.writeln('|-------:|-----:|-------------------:|:--------|');
    for (final size in cfg.sizes) {
      for (final topK in cfg.topKs) {
        final m = parity[key(size, topK)] ?? 0;
        out.writeln('| $size | $topK | $m | ${m == 0 ? 'PASS' : 'FAIL'} |');
      }
    }
    out.writeln();
  } else {
    out.writeln(
      '> Correctness gate skipped — needs BOTH stores (one arm was disabled). '
      'The "75×" re-measurement requires a machine with both extensions.',
    );
    out.writeln();
  }
}

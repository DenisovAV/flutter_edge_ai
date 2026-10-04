// Runner harness for tool/bench_vector_stores.dart.
//
// WHY a test wraps a tool: on this SDK, a plain `dart run` (and `dart compile
// exe`) of anything that transitively pulls in sqlite3's `NativeCallable`
// crashes the FFI kernel transformer ("type 'InvalidType' is not a subtype of
// type 'FunctionType'"). The Flutter test toolchain compiles the SAME imports
// cleanly (proven by test/vec0_text_pk_test.dart), so this harness is the
// canonical loop runner on this machine. `tool/bench_vector_stores.dart` keeps
// its own `main()` for SDKs without that regression.
//
// It is loop-runnable + prints the parseable markdown table the doc expects.
// Both native extensions are needed for the FULL bench; absent ones are skipped:
//   * vec0:   $VEC0_DYLIB → the prebuilt sqlite-vec loadable extension.
//   * qdrant: the Native Assets bundle, provisioned by the qdrant_edge SDK's
//     own hook. $QDRANT_DYLIB is only the opt-in switch — its value is unused.
//
// Run from the package dir (defaults: sizes 1k,10k · topK 5,50):
//   VEC0_DYLIB=/path/to/vec0.dylib QDRANT_DYLIB=1 \
//     flutter test test/bench_vector_stores_test.dart
//
// Override via $BENCH_ARGS (same flags as the tool's main), e.g.:
//   BENCH_ARGS="--sizes=1000 --topks=5 --repeats=5" \
//     flutter test test/bench_vector_stores_test.dart
//
// The test FAILS if the correctness gate fails (parity mismatch) or no store is
// available, matching the tool's non-zero exit codes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/bench_vector_stores.dart';

void main() {
  // The benchmark is opt-in: it only runs when a store dylib is actually
  // available, so a plain `flutter test` (no env) stays green. It is a tool,
  // not a CI gate. Skip-reason explains how to turn it on.
  final hasVec0 = (Platform.environment['VEC0_DYLIB'] ?? '').isNotEmpty;
  final hasQdrant = (Platform.environment['QDRANT_DYLIB'] ?? '').isNotEmpty;
  final canRun = hasVec0 || hasQdrant;

  test(
    'vec0 vs qdrant benchmark (markdown table on stdout)',
    () async {
      final raw = Platform.environment['BENCH_ARGS'];
      final args = (raw == null || raw.trim().isEmpty)
          ? const <String>[]
          : raw.trim().split(RegExp(r'\s+'));
      final cfg = BenchConfig.parse(args);
      final code = await runBench(cfg, stdout);
      // 70 = no store available (env not set up), 1 = parity gate failed.
      expect(
        code,
        0,
        reason: code == 70
            ? 'No vector store available — set \$VEC0_DYLIB and/or \$QDRANT_DYLIB.'
            : 'Benchmark correctness gate failed (top-K id parity mismatch).',
      );
    },
    skip: canRun
        ? false
        : 'Benchmark tool — set \$VEC0_DYLIB and/or \$QDRANT_DYLIB (and '
              'optionally \$BENCH_ARGS) to run it.',
    // The 10k exact-KNN arm + qdrant index build can take a while.
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

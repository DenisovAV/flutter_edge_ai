// Golden-vector baseline for the embedder decoupling refactor (embedder
// decoupling plan Task 1 / I0 checkpoint).
//
// Captures a fixed set of embeddings on the PRE-refactor tree
// (`packages/flutter_edge_ai_embeddings` LiteRT-backed) into a checked-in JSON
// golden file, then on every subsequent run asserts the current SDK produces
// bit-for-bit (or ≤1e-6 per-component) identical vectors. This is the only
// test that can catch a silently-added normalization/pooling step on the
// LiteRT path — cosine-similarity tests are scale-invariant and would not
// notice an added L2-normalize.
//
// Capture procedure (must be run on the PRE-refactor tree, deliberately,
// not by CI):
//   git stash -u                     # park the refactor
//   cd packages/flutter_edge_ai/example && flutter pub get
//   flutter test integration_test/embedding_golden_test.dart -d macos
//   # test FAILS (by design) and writes the candidate golden to
//   # integration_test/goldens/embedding_golden.json — inspect it, then:
//   git add integration_test/goldens/embedding_golden.json
//   git stash pop                    # restore the refactor, re-run to assert
//
// A missing golden file is a FAILING test, not a passing "capture mode" —
// see the `fail(...)` call below. This is deliberate: a naive CI run on a
// tree with no committed baseline must never bless its own output as the
// golden. Every run after the file is committed asserts against it.
//
// Known environment blocker (`markTestSkipped` below, NOT a silent pass):
// on at least one dev macOS box, `large_file_handler` 0.5.0's macOS
// asset-copy plugin (`Bundle.main.path(forResource:)`) fails to resolve
// assets nested under `App.framework/Resources/flutter_assets` when the app
// is launched by `flutter test -d macos` — every `.modelFromAsset(...)`
// install throws `PlatformException(ERROR, Failed to copy asset ... 404)`,
// reproducing even on the unrelated, pre-existing `desktop_embedding_test.dart`
// on `main`. This is an environment/tooling issue, not an embedder-refactor
// regression — if it fires, this test skips LOUDLY (visible in the test
// report as skipped, not green) rather than reporting a false pass or an
// unrelated-looking failure. Capture on a box where the plugin resolves
// correctly (or via `flutter run -d macos` interactively).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'inference_test_helpers.dart' show registerTestEngines;

const _modelPath =
    'assets/models/embeddinggemma-300M_seq256_mixed-precision.tflite';
const _tokenizerPath = 'assets/models/sentencepiece.model';

/// Fixed 3-text set, embedded under both task types → 6 golden vectors.
const _texts = [
  'Which planet is known as the Red Planet',
  'The cat sat on the mat',
  'Machine learning is fascinating',
];

const _goldenPath = 'integration_test/goldens/embedding_golden.json';

/// Exact equality is the target; this is only a documented fallback for
/// float noise across recompiles of the same graph (D5 bar).
const _maxAbsDiff = 1e-6;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Embedding golden vectors are byte-identical across the '
      'embedder refactor', (tester) async {
    await registerTestEngines();

    try {
      await FlutterEdgeAi.installEmbedder()
          .modelFromAsset(_modelPath)
          .tokenizerFromAsset(_tokenizerPath)
          .install();
    } on PlatformException catch (e) {
      // See the file header's "Known environment blocker" note — this is a
      // `large_file_handler` macOS asset-resolution failure, not something
      // this test (or the embedder refactor it guards) can fix.
      final msg = e.message ?? '';
      if (e.code == 'ERROR' && msg.contains('Failed to copy asset')) {
        markTestSkipped(
          'large_file_handler macOS asset-copy plugin could not resolve '
          '$_modelPath under `flutter test -d macos` on this box '
          '(PlatformException: $msg) — environment blocker, not an '
          'embedder-refactor regression (reproduces on the unrelated, '
          'pre-existing desktop_embedding_test.dart too). See this file\'s '
          'header. Byte-identity is UNVERIFIED by this run — capture on a '
          'box where the asset resolves.',
        );
        return;
      }
      rethrow;
    }

    final embedder = await FlutterEdgeAi.getActiveEmbedder();

    final captured = <String, List<double>>{};
    try {
      for (final taskType in [
        TaskType.retrievalQuery,
        TaskType.retrievalDocument,
      ]) {
        for (final text in _texts) {
          final key = '${taskType.name}::$text';
          captured[key] = await embedder.generateEmbedding(
            text,
            taskType: taskType,
          );
        }
      }
    } finally {
      await embedder.close();
    }

    final goldenFile = File(_goldenPath);
    if (!goldenFile.existsSync()) {
      // No committed baseline yet: write the candidate golden next to this
      // file (for a human to inspect and commit) but FAIL the test — a
      // missing golden must never silently pass. Without this, a naive CI
      // run on a tree that never had a baseline would bless its own output
      // as "the" golden and this test would stop verifying anything.
      goldenFile.createSync(recursive: true);
      final jsonStr = const JsonEncoder.withIndent('  ').convert(captured);
      goldenFile.writeAsStringSync(jsonStr);
      fail(
        'No committed golden at $_goldenPath — a candidate was written '
        'there from this run. This must be captured from the PRE-refactor '
        'tree, reviewed, and committed deliberately; this test does not '
        'auto-bless it. See the file header for the capture procedure.',
      );
    }

    final Map<String, dynamic> golden = jsonDecode(
      goldenFile.readAsStringSync(),
    );
    expect(
      captured.keys.toSet(),
      golden.keys.toSet(),
      reason: 'golden key set changed — update the golden intentionally',
    );

    for (final key in captured.keys) {
      final actual = captured[key]!;
      final expected = (golden[key] as List)
          .cast<num>()
          .map((n) => n.toDouble())
          .toList();
      expect(actual.length, expected.length, reason: '$key: dimension changed');
      for (var i = 0; i < actual.length; i++) {
        final diff = (actual[i] - expected[i]).abs();
        expect(
          diff,
          lessThanOrEqualTo(_maxAbsDiff),
          reason:
              '$key[$i]: expected ${expected[i]}, got ${actual[i]} '
              '(diff=$diff > $_maxAbsDiff)',
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

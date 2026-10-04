import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/mobile/smart_downloader.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('computeTaskId (#383/#2)', () {
    test('is a deterministic sha256 hex of the split triple', () {
      final id = computeTaskId(
        BaseDirectory.applicationSupport,
        'models',
        'g.task',
      );
      expect(
        id,
        sha256.convert('applicationSupport|models|g.task'.codeUnits).toString(),
      );
      expect(id.length, 64);
    });

    test('each triple component independently changes the id', () {
      const base = BaseDirectory.applicationSupport;
      final baseline = computeTaskId(base, 'models', 'm.task');
      expect(
        computeTaskId(BaseDirectory.applicationDocuments, 'models', 'm.task'),
        isNot(baseline),
        reason: 'baseDirectory feeds the hash',
      );
      expect(
        computeTaskId(base, 'other', 'm.task'),
        isNot(baseline),
        reason: 'directory feeds the hash',
      );
      expect(
        computeTaskId(base, 'models', 'n.task'),
        isNot(baseline),
        reason: 'filename feeds the hash',
      );
    });

    test('id is a total function of the triple — same triple, same id', () {
      // Determinism is the property the reclaim reconciliation relies on: a
      // record recomputes to its own id across runs. url is not an input (a
      // rotated signed URL cannot change it); the absolute-path invariance (R3,
      // iOS container churn) is exercised end-to-end in the device test.
      expect(
        computeTaskId(BaseDirectory.applicationSupport, 'models', 'm.task'),
        computeTaskId(BaseDirectory.applicationSupport, 'models', 'm.task'),
      );
    });
  });
}

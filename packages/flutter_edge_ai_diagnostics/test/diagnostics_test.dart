import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // `flutter test` runs on the host (Linux, macOS or Windows), which is
  // exactly the case this package refuses.
  group('on a host platform', () {
    test('isSupported is false', () {
      expect(FlutterEdgeAiDiagnostics.isSupported, isFalse);
    });

    test('memorySnapshot throws instead of returning nulls', () {
      expect(
        FlutterEdgeAiDiagnostics.memorySnapshot(),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('MemoryReadException', () {
    test('toString carries the message and the cause', () {
      expect(
        const MemoryReadException('could not read /proc/meminfo').toString(),
        'MemoryReadException: could not read /proc/meminfo',
      );
      expect(
        MemoryReadException('x', cause: StateError('io')).toString(),
        allOf(contains('MemoryReadException: x'), contains('io')),
      );
    });
  });

  group('MemorySnapshot', () {
    final at = DateTime.utc(2026, 9, 25);

    test('equality covers every field', () {
      final a = MemorySnapshot(
        anonymousBytes: 1,
        availableBytes: 2,
        takenAt: at,
      );
      expect(
        a,
        MemorySnapshot(anonymousBytes: 1, availableBytes: 2, takenAt: at),
      );
      expect(
        a,
        isNot(
          MemorySnapshot(anonymousBytes: 1, availableBytes: 3, takenAt: at),
        ),
      );
      expect(
        a,
        isNot(
          MemorySnapshot(anonymousBytes: null, availableBytes: 2, takenAt: at),
        ),
      );
    });

    test('toString shows nulls as null, not zero', () {
      final s = MemorySnapshot(
        anonymousBytes: null,
        availableBytes: 7,
        takenAt: at,
      ).toString();
      expect(s, contains('anonymousBytes: null'));
      expect(s, contains('availableBytes: 7'));
    });
  });
}

import 'dart:io' show Platform;

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // `flutter test` runs on the host. On Windows that is exactly the case this
  // package refuses; macOS and Linux hosts are supported platforms (Linux is
  // covered by the host tests below and in proc_memory_test.dart).
  final supportedHost = Platform.isMacOS || Platform.isLinux;

  group('on an unsupported host platform', skip: supportedHost, () {
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

  group('on a Linux host', skip: !Platform.isLinux, () {
    test('isSupported is true', () {
      expect(FlutterEdgeAiDiagnostics.isSupported, isTrue);
    });

    test('memorySnapshot reads /proc: the values Linux reports', () async {
      final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
      expect(snapshot.anonymousBytes, greaterThan(0));
      expect(snapshot.fileBackedBytes, greaterThan(0));
      expect(snapshot.availableBytes, greaterThan(0));
      // The kernel keeps no anonymous-only peak.
      expect(snapshot.anonymousPeakBytes, isNull);
    });

    test('gpuMemory is null, not an error and not a kgsl read', () async {
      // ignore: experimental_member_use
      expect(await FlutterEdgeAiDiagnostics.gpuMemory(), isNull);
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

    test('equality covers anonymousPeakBytes', () {
      final a = MemorySnapshot(
        anonymousBytes: 1,
        availableBytes: 2,
        anonymousPeakBytes: 9,
        takenAt: at,
      );
      expect(
        a,
        MemorySnapshot(
          anonymousBytes: 1,
          availableBytes: 2,
          anonymousPeakBytes: 9,
          takenAt: at,
        ),
      );
      expect(
        a,
        isNot(
          MemorySnapshot(anonymousBytes: 1, availableBytes: 2, takenAt: at),
        ),
      );
    });

    test('equality covers fileBackedBytes', () {
      final a = MemorySnapshot(
        anonymousBytes: 1,
        availableBytes: 2,
        fileBackedBytes: 3,
        takenAt: at,
      );
      expect(
        a,
        MemorySnapshot(
          anonymousBytes: 1,
          availableBytes: 2,
          fileBackedBytes: 3,
          takenAt: at,
        ),
      );
      expect(
        a,
        isNot(
          MemorySnapshot(anonymousBytes: 1, availableBytes: 2, takenAt: at),
        ),
      );
      expect(
        a.hashCode,
        isNot(
          MemorySnapshot(
            anonymousBytes: 1,
            availableBytes: 2,
            takenAt: at,
          ).hashCode,
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
      expect(s, contains('fileBackedBytes: null'));
      expect(s, contains('anonymousPeakBytes: null'));
    });
  });
}

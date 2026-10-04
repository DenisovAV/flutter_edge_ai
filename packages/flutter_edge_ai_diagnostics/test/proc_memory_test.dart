import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;
import 'package:flutter_edge_ai_diagnostics/src/android/proc_memory.dart';
import 'package:flutter_test/flutter_test.dart';

// Trimmed from a real /proc/self/smaps_rollup (Linux 7.0). The first line is
// the rollup header, which carries no size and must be skipped.
const _smapsRollup = '''
00400000-ffffffffff601000 ---p 00000000 00:00 0                          [rollup]
Rss:                7416 kB
Pss:                2911 kB
Pss_Anon:           1880 kB
Pss_File:            999 kB
Private_Dirty:      1880 kB
Anonymous:          1880 kB
Swap:                 64 kB
SwapPss:              32 kB
''';

// Trimmed from a real /proc/meminfo. HugePages_* lines have no unit and must
// not be parsed as kB.
const _meminfo = '''
MemTotal:       16249012 kB
MemFree:         2011344 kB
MemAvailable:    9126572 kB
Active(anon):    3120476 kB
HugePages_Total:       0
HugePages_Free:        0
Hugepagesize:       2048 kB
''';

void main() {
  group('parseProcKbFields', () {
    test('converts kB lines to bytes and skips lines without a unit', () {
      final fields = parseProcKbFields(_meminfo);
      expect(fields['MemAvailable'], 9126572 * 1024);
      expect(fields['Active(anon)'], 3120476 * 1024);
      expect(fields['Hugepagesize'], 2048 * 1024);
      expect(fields.containsKey('HugePages_Total'), isFalse);
    });

    test('skips the smaps_rollup header line', () {
      final fields = parseProcKbFields(_smapsRollup);
      expect(fields.length, 8);
      expect(fields['Rss'], 7416 * 1024);
    });
  });

  group('anonymousBytesFromSmapsRollup', () {
    test('is Private_Dirty + SwapPss', () {
      expect(anonymousBytesFromSmapsRollup(_smapsRollup), (1880 + 32) * 1024);
    });

    test('is null when SwapPss is missing, not Private_Dirty alone', () {
      final text = _smapsRollup.replaceAll(RegExp(r'SwapPss:.*\n'), '');
      expect(anonymousBytesFromSmapsRollup(text), isNull);
    });

    test('is null when Private_Dirty is missing', () {
      final text = _smapsRollup.replaceAll(RegExp(r'Private_Dirty:.*\n'), '');
      expect(anonymousBytesFromSmapsRollup(text), isNull);
    });

    test('is null for empty input', () {
      expect(anonymousBytesFromSmapsRollup(''), isNull);
    });
  });

  group('availableBytesFromMeminfo', () {
    test('is MemAvailable', () {
      expect(availableBytesFromMeminfo(_meminfo), 9126572 * 1024);
    });

    test('is null on a kernel without MemAvailable', () {
      final text = _meminfo.replaceAll(RegExp(r'MemAvailable:.*\n'), '');
      expect(availableBytesFromMeminfo(text), isNull);
    });
  });

  group('readProcMemorySnapshot', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('diag_proc_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads both files', () {
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(_smapsRollup);
      final meminfo = File('${dir.path}/meminfo')..writeAsStringSync(_meminfo);

      final snapshot = readProcMemorySnapshot(
        smapsRollupPath: rollup.path,
        meminfoPath: meminfo.path,
      );

      expect(snapshot.anonymousBytes, (1880 + 32) * 1024);
      expect(snapshot.availableBytes, 9126572 * 1024);
    });

    File meminfoFixture() =>
        File('${dir.path}/meminfo')..writeAsStringSync(_meminfo);

    test('an absent smaps_rollup (kernel < 4.14) is the documented null', () {
      final snapshot = readProcMemorySnapshot(
        smapsRollupPath: '${dir.path}/absent_rollup',
        meminfoPath: meminfoFixture().path,
      );

      expect(snapshot.anonymousBytes, isNull);
      expect(snapshot.availableBytes, 9126572 * 1024);
    });

    test('an absent meminfo is a failed read, not a null', () {
      expect(
        () => readProcMemorySnapshot(
          smapsRollupPath: '${dir.path}/absent_rollup',
          meminfoPath: '${dir.path}/absent_meminfo',
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('smaps_rollup without its fields is a failed read', () {
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(
          _smapsRollup.replaceAll(RegExp(r'SwapPss:.*\n'), ''),
        );
      expect(
        () => readProcMemorySnapshot(
          smapsRollupPath: rollup.path,
          meminfoPath: meminfoFixture().path,
        ),
        throwsA(
          isA<MemoryReadException>().having(
            (e) => e.message,
            'message',
            contains('Private_Dirty and SwapPss'),
          ),
        ),
      );
    });

    test('meminfo without MemAvailable is a failed read', () {
      final meminfo = File('${dir.path}/meminfo')
        ..writeAsStringSync(
          _meminfo.replaceAll(RegExp(r'MemAvailable:.*\n'), ''),
        );
      expect(
        () => readProcMemorySnapshot(
          smapsRollupPath: '${dir.path}/absent_rollup',
          meminfoPath: meminfo.path,
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('a permission error is a failed read, not a null', () {
      if (Platform.isWindows) {
        markTestSkipped('chmod has no effect on Windows');
        return;
      }
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(_smapsRollup);
      Process.runSync('chmod', ['000', rollup.path]);
      try {
        rollup.readAsStringSync();
        markTestSkipped('running as root: chmod 000 does not deny reads');
        return;
      } on FileSystemException {
        // Denied, as intended.
      }

      expect(
        () => readProcMemorySnapshot(
          smapsRollupPath: rollup.path,
          meminfoPath: meminfoFixture().path,
        ),
        throwsA(
          isA<MemoryReadException>().having(
            (e) => e.cause,
            'cause',
            isA<FileSystemException>(),
          ),
        ),
      );
    });
  });

  // Android's /proc files come from the same Linux kernel code, so on a Linux
  // host this runs the Android path against a real kernel rather than a
  // fixture. Skipped elsewhere (macOS CI has no /proc).
  final hasProc =
      Platform.isLinux && File('/proc/self/smaps_rollup').existsSync();

  group(
    'real /proc on this Linux host',
    () {
      test('both values are present and positive', () {
        final snapshot = readProcMemorySnapshot();
        expect(snapshot.anonymousBytes, isNotNull);
        expect(snapshot.anonymousBytes, greaterThan(0));
        expect(snapshot.availableBytes, isNotNull);
        expect(snapshot.availableBytes, greaterThan(0));
      });

      test('anonymousBytes rises by what the process actually allocates', () {
        const size = 128 * 1024 * 1024;
        final before = readProcMemorySnapshot().anonymousBytes!;

        // Zeroed pages are not resident until written, so touch every one.
        final block = Uint8List(size)..fillRange(0, size, 1);
        final after = readProcMemorySnapshot().anonymousBytes!;

        // Keep `block` reachable until after the second read.
        expect(block[size - 1], 1);
        expect(after - before, greaterThanOrEqualTo(size * 3 ~/ 4));
      });
    },
    skip: hasProc ? false : 'needs a Linux /proc/self/smaps_rollup',
  );
}

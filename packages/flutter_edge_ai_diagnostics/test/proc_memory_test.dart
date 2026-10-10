import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart'
    show MemoryReadException;
import 'package:flutter_edge_ai_diagnostics/src/android/proc_memory.dart';
import 'package:ffi/ffi.dart' show malloc;
import 'package:flutter_test/flutter_test.dart';

// Adapted from /proc/self/smaps_rollup (Linux 7.0), with synthetic clean
// values for the sum tests. The header carries no size and must be skipped.
const _smapsRollup = '''
00400000-ffffffffff601000 ---p 00000000 00:00 0                          [rollup]
Rss:                7416 kB
Pss:                2911 kB
Pss_Anon:           1880 kB
Pss_File:            999 kB
Shared_Clean:       3000 kB
Private_Clean:       500 kB
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
      expect(fields.length, 10);
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

  group('fileBackedBytesFromSmapsRollup', () {
    test('is Private_Clean + Shared_Clean', () {
      expect(fileBackedBytesFromSmapsRollup(_smapsRollup), (3000 + 500) * 1024);
    });

    test('is null when either clean field is missing', () {
      for (final field in ['Shared_Clean', 'Private_Clean']) {
        final text = _smapsRollup.replaceAll(RegExp('$field:.*\\n'), '');
        expect(fileBackedBytesFromSmapsRollup(text), isNull, reason: field);
      }
      expect(fileBackedBytesFromSmapsRollup(''), isNull);
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

    test('reads both files', () async {
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(_smapsRollup);
      final meminfo = File('${dir.path}/meminfo')..writeAsStringSync(_meminfo);

      final snapshot = await readProcMemorySnapshot(
        smapsRollupPath: rollup.path,
        meminfoPath: meminfo.path,
      );

      expect(snapshot.anonymousBytes, (1880 + 32) * 1024);
      expect(snapshot.fileBackedBytes, (3000 + 500) * 1024);
      expect(snapshot.availableBytes, 9126572 * 1024);
    });

    File meminfoFixture() =>
        File('${dir.path}/meminfo')..writeAsStringSync(_meminfo);

    test(
      'an absent smaps_rollup gives null for both process counters',
      () async {
        final snapshot = await readProcMemorySnapshot(
          smapsRollupPath: '${dir.path}/absent_rollup',
          meminfoPath: meminfoFixture().path,
        );

        expect(snapshot.anonymousBytes, isNull);
        expect(snapshot.fileBackedBytes, isNull);
        expect(snapshot.availableBytes, 9126572 * 1024);
      },
    );

    test('an absent meminfo is a failed read, not a null', () async {
      await expectLater(
        readProcMemorySnapshot(
          smapsRollupPath: '${dir.path}/absent_rollup',
          meminfoPath: '${dir.path}/absent_meminfo',
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('smaps_rollup without its fields is a failed read', () async {
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(
          _smapsRollup.replaceAll(RegExp(r'SwapPss:.*\n'), ''),
        );
      await expectLater(
        readProcMemorySnapshot(
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

    test('smaps_rollup without the clean fields is a failed read', () async {
      final rollup = File('${dir.path}/smaps_rollup')
        ..writeAsStringSync(
          _smapsRollup.replaceAll(RegExp(r'Shared_Clean:.*\n'), ''),
        );
      await expectLater(
        readProcMemorySnapshot(
          smapsRollupPath: rollup.path,
          meminfoPath: meminfoFixture().path,
        ),
        throwsA(
          isA<MemoryReadException>().having(
            (e) => e.message,
            'message',
            contains('Private_Clean and Shared_Clean'),
          ),
        ),
      );
    });

    test('meminfo without MemAvailable is a failed read', () async {
      final meminfo = File('${dir.path}/meminfo')
        ..writeAsStringSync(
          _meminfo.replaceAll(RegExp(r'MemAvailable:.*\n'), ''),
        );
      await expectLater(
        readProcMemorySnapshot(
          smapsRollupPath: '${dir.path}/absent_rollup',
          meminfoPath: meminfo.path,
        ),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('the read does not block the calling isolate', () async {
      if (Platform.isWindows) {
        markTestSkipped('no FIFOs on Windows');
        return;
      }
      // A FIFO has no data until a writer shows up, so a blocking read stalls
      // for as long as the writer waits.
      final fifo = '${dir.path}/smaps_rollup';
      expect(Process.runSync('mkfifo', [fifo]).exitCode, 0);
      final fixture = File('${dir.path}/rollup_fixture')
        ..writeAsStringSync(_smapsRollup);
      final writer = await Process.start('sh', [
        '-c',
        'sleep 0.5; cat "${fixture.path}" > "$fifo"',
      ]);

      final started = Stopwatch()..start();
      final reading = readProcMemorySnapshot(
        smapsRollupPath: fifo,
        meminfoPath: meminfoFixture().path,
      );
      final returned = started.elapsedMilliseconds;
      final snapshot = await reading;
      await writer.exitCode;

      expect(
        returned,
        lessThan(100),
        reason: 'the call must hand back a Future',
      );
      expect(started.elapsedMilliseconds, greaterThanOrEqualTo(400));
      expect(snapshot.anonymousBytes, (1880 + 32) * 1024);
    });

    test('a permission error is a failed read, not a null', () async {
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

      await expectLater(
        readProcMemorySnapshot(
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

  group('real /proc on this Linux host', () {
    test('all three values are present and positive', () async {
      final snapshot = await readProcMemorySnapshot();
      expect(snapshot.anonymousBytes, isNotNull);
      expect(snapshot.anonymousBytes, greaterThan(0));
      expect(snapshot.fileBackedBytes, isNotNull);
      expect(snapshot.fileBackedBytes, greaterThan(0));
      expect(snapshot.availableBytes, isNotNull);
      expect(snapshot.availableBytes, greaterThan(0));
    });

    test('fileBackedBytes rises when a file is mapped and read, '
        'and anonymousBytes does not', () async {
      const size = 64 * 1024 * 1024;
      final libc = DynamicLibrary.process();
      final open = libc
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Int32),
            int Function(Pointer<Uint8>, int)
          >('open');
      final mmap = libc
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Void>,
              IntPtr,
              Int32,
              Int32,
              Int32,
              Int64,
            ),
            Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int)
          >('mmap');
      final munmap = libc
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, IntPtr),
            int Function(Pointer<Uint8>, int)
          >('munmap');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

      // /tmp may be tmpfs: its shmem pages stay dirty even after a flush.
      // Keep the mapped file on the checkout's filesystem instead.
      final scratch = Directory('.dart_tool')..createSync(recursive: true);
      final dir = scratch.createTempSync('diag_mmap_');
      final file = File('${dir.path}/weights');
      int? fd;
      Pointer<Uint8>? map;
      try {
        final out = file.openSync(mode: FileMode.write);
        try {
          // Small chunks avoid leaving a 64 MiB list for the GC to free
          // during the later memory readings.
          final chunk = Uint8List(1024 * 1024)..fillRange(0, 1024 * 1024, 7);
          for (var i = 0; i < size ~/ chunk.length; i++) {
            out.writeFromSync(chunk);
          }
          // With one mapping, unflushed file pages count as Private_Dirty
          // (inside anonymousBytes). Flush so the read sees clean pages.
          out.flushSync();
        } finally {
          out.closeSync();
        }

        final path = '${file.path}\u0000'.codeUnits;
        final cPath = malloc<Uint8>(path.length);
        try {
          cPath.asTypedList(path.length).setAll(0, path);
          fd = open(cPath, 0); // O_RDONLY
        } finally {
          malloc.free(cPath);
        }
        expect(fd, greaterThanOrEqualTo(0));

        final before = await readProcMemorySnapshot();
        final mapped = mmap(
          nullptr,
          size,
          1,
          2,
          fd,
          0,
        ); // PROT_READ, MAP_PRIVATE
        expect(
          mapped,
          isNot(Pointer<Uint8>.fromAddress(-1)),
          reason: 'mmap returned MAP_FAILED',
        );
        map = mapped;
        var sum = 0;
        for (var i = 0; i < size; i += 4096) {
          sum += map[i]; // touch every page so it is resident
        }
        final after = await readProcMemorySnapshot();

        expect(sum, isPositive);
        expect(
          after.fileBackedBytes! - before.fileBackedBytes!,
          greaterThanOrEqualTo(size * 3 ~/ 4),
        );
        expect(
          after.anonymousBytes! - before.anonymousBytes!,
          lessThan(size ~/ 4),
          reason: 'a flushed read-only file mapping has no dirty private pages',
        );
      } finally {
        if (map != null) munmap(map, size);
        if (fd != null && fd >= 0) close(fd);
        dir.deleteSync(recursive: true);
      }
    });

    test(
      'anonymousBytes rises by what the process actually allocates',
      () async {
        const size = 128 * 1024 * 1024;
        final before = (await readProcMemorySnapshot()).anonymousBytes!;

        // Zeroed pages are not resident until written, so touch every one.
        final block = Uint8List(size)..fillRange(0, size, 1);
        final after = (await readProcMemorySnapshot()).anonymousBytes!;

        // Keep `block` reachable until after the second read.
        expect(block[size - 1], 1);
        expect(after - before, greaterThanOrEqualTo(size * 3 ~/ 4));
      },
    );
  }, skip: hasProc ? false : 'needs a Linux /proc/self/smaps_rollup');
}

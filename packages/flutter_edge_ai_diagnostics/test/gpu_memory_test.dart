import 'dart:io';

import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_diagnostics/src/android/proc_memory.dart';
import 'package:flutter_test/flutter_test.dart';

String _mapping(
  String path, {
  int dirty = 0,
  int privateClean = 0,
  int sharedClean = 0,
  String start = '7a00000000-7a00400000',
  String unit = 'kB',
}) =>
    '$start rw-s 00000000 00:05 1234 $path\n'
    'Size:               4096 kB\n'
    'Rss:                9999 kB\n'
    'Pss:                8888 kB\n'
    'Shared_Clean:  $sharedClean $unit\n'
    'Shared_Dirty:         7 kB\n'
    'Private_Clean: $privateClean kB\n'
    'Private_Dirty: $dirty kB\n'
    'VmFlags: rd wr sh mr mw me ms\n';

// The Rss and Pss lines above are deliberately larger than any sum the parser
// should report: a real kernel has Pss <= Rss, but a fixture where both exceed
// the private and clean fields is the one that catches a parser that sums the
// wrong line.
String _plain(String path) =>
    '55d0000000-55d0001000 r-xp 00000000 fd:01 99 $path\n'
    'Private_Dirty: 4000 kB\nPrivate_Clean: 4000 kB\nShared_Clean: 4000 kB\n';

const _kib = 1024; // a kB field is this many bytes

void main() {
  group('kgslTotalsFromSmaps', () {
    test(
      'sums Private_Dirty and the two clean fields of the kgsl mappings',
      () {
        final text =
            _plain('/system/lib64/libc.so') +
            _mapping(
              '/dev/kgsl-3d0',
              dirty: 100,
              privateClean: 800,
              sharedClean: 5,
            ) +
            _mapping(
              '/dev/kgsl-3d0',
              dirty: 20,
              privateClean: 30,
              sharedClean: 0,
            ) +
            _plain('/data/model.litertlm');
        final totals = kgslTotalsFromSmaps(text)!;
        expect(totals.privateDirtyBytes, 120 * _kib);
        expect(totals.cleanBytes, 835 * _kib);
      },
    );

    test('matches kgsl-3d0 the way AOSP does, on every kernel', () {
      for (final path in [
        '/dev/kgsl-3d0',
        '/dev/kgsl-3d0 (deleted)',
        '/kgsl-3d0',
        '/kgsl-3d0 (deleted)',
      ]) {
        final totals = kgslTotalsFromSmaps(_mapping(path, dirty: 1));
        expect(totals?.privateDirtyBytes, _kib, reason: path);
      }
    });

    test('is null when no mapping is a GPU mapping', () {
      expect(
        kgslTotalsFromSmaps(
          _plain('/dev/ashmem') + _plain('/dev/mali0') + _plain('[anon:kgsl]'),
        ),
        isNull,
      );
    });

    test('a header that starts with a-f is still a header', () {
      final text =
          _mapping('/dev/kgsl-3d0', dirty: 1, start: 'ab00000000-ab00400000') +
          _mapping('/dev/kgsl-3d0', dirty: 2, start: 'ff00000000-ff00400000');
      expect(kgslTotalsFromSmaps(text)!.privateDirtyBytes, 3 * _kib);
    });

    test('a last line without a newline still counts', () {
      final text = _mapping('/dev/kgsl-3d0', dirty: 5).trimRight();
      expect(text.endsWith('\n'), isFalse);
      expect(kgslTotalsFromSmaps(text)!.privateDirtyBytes, 5 * _kib);
    });

    test('a header with a carriage return in its path does not hide the next '
        'mapping from the end of the GPU one', () {
      final text =
          _mapping('/dev/kgsl-3d0', dirty: 16) +
          _mapping('/odd\rname', dirty: 4000, privateClean: 4000);
      expect(kgslTotalsFromSmaps(text)!.privateDirtyBytes, 16 * _kib);
      expect(kgslTotalsFromSmaps(text)!.cleanBytes, 0);
    });

    test('a GPU mapping without Private_Dirty throws', () {
      final text = _mapping(
        '/dev/kgsl-3d0',
      ).replaceAll(RegExp(r'Private_Dirty:.*\n'), '');
      expect(() => kgslTotalsFromSmaps(text), throwsFormatException);
    });

    String without(String text, String field) =>
        text.replaceAll(RegExp('$field:.*\\n'), '');

    test('a GPU mapping without Private_Clean or Shared_Clean throws', () {
      for (final field in ['Private_Clean', 'Shared_Clean']) {
        expect(
          () => kgslTotalsFromSmaps(without(_mapping('/dev/kgsl-3d0'), field)),
          throwsFormatException,
          reason: field,
        );
      }
    });

    test('an incomplete GPU mapping in the middle of the file throws', () {
      final text =
          without(_mapping('/dev/kgsl-3d0'), 'Shared_Clean') +
          _plain('/system/lib64/libc.so');
      expect(() => kgslTotalsFromSmaps(text), throwsFormatException);
    });

    test('a complete GPU mapping does not complete the next one', () {
      final text =
          _mapping('/dev/kgsl-3d0', dirty: 1) +
          without(
            _mapping('/dev/kgsl-3d0', start: 'ab00000000-ab00400000'),
            'Shared_Clean',
          );
      expect(() => kgslTotalsFromSmaps(text), throwsFormatException);
    });

    test('a repeated field in one GPU mapping throws instead of adding up', () {
      final text = _mapping(
        '/dev/kgsl-3d0',
        dirty: 1,
      ).replaceFirst('VmFlags', 'Private_Dirty: 5 kB\nVmFlags');
      expect(() => kgslTotalsFromSmaps(text), throwsFormatException);
    });

    test('the error names the mapping it was in', () {
      try {
        kgslTotalsFromSmaps(
          without(_mapping('/dev/kgsl-3d0'), 'Private_Dirty'),
        );
        fail('should throw');
      } on FormatException catch (e) {
        expect(e.message, contains('7a00000000-7a00400000'));
      }
    });

    test('a GPU mapping with a field in the wrong unit throws', () {
      expect(
        () => kgslTotalsFromSmaps(_mapping('/dev/kgsl-3d0', unit: 'KB')),
        throwsFormatException,
      );
    });

    test('a line that looks like a header and is not throws', () {
      expect(
        () => kgslTotalsFromSmaps(
          '${_mapping('/dev/kgsl-3d0')}deadbeef this is not a header\n',
        ),
        throwsFormatException,
      );
    });

    test('text with no mapping header at all throws, it is not "no GPU"', () {
      expect(() => kgslTotalsFromSmaps(''), throwsFormatException);
      expect(
        () => kgslTotalsFromSmaps('Rss: 1 kB\nPss: 1 kB\n'),
        throwsFormatException,
      );
    });
  });

  group('readGpuMemoryReading', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('diag_gpu_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File smaps(List<int> bytes) =>
        File('${dir.path}/smaps')..writeAsBytesSync(bytes);

    test('names each number by the bucket it overlaps', () async {
      final file = smaps(
        _mapping(
          '/dev/kgsl-3d0',
          dirty: 100,
          privateClean: 800,
          sharedClean: 5,
        ).codeUnits,
      );
      final reading = await readGpuMemoryReading(smapsPath: file.path);
      expect(reading!.source, GpuMemorySource.adrenoKgslMappings);
      expect(reading.inAnonymousBytes, 100 * _kib);
      expect(reading.inFileBackedBytes, 805 * _kib);
      expect(reading.outsideSnapshotBytes, isNull);
    });

    test(
      'a byte that is not UTF-8 in an unrelated path does not fail it',
      () async {
        final bytes = [
          ...'55d0000000-55d0001000 r--p 00000000 fd:01 7 /data/'.codeUnits,
          0xFF,
          0xFE,
          ...'\nPrivate_Dirty: 1 kB\nPrivate_Clean: 1 kB\nShared_Clean: 1 kB\n'
              .codeUnits,
          ..._mapping('/dev/kgsl-3d0', dirty: 7).codeUnits,
        ];
        final reading = await readGpuMemoryReading(
          smapsPath: smaps(bytes).path,
        );
        expect(reading!.inAnonymousBytes, 7 * _kib);
      },
    );

    test('is null on a device without the GPU node (no reader)', () async {
      final file = smaps(_plain('/dev/ashmem').codeUnits);
      expect(
        await readGpuMemoryReading(
          smapsPath: file.path,
          gpuNodePath: '${dir.path}/no-kgsl-3d0',
        ),
        isNull,
      );
    });

    test(
      'is a zero reading when the node exists and nothing is mapped',
      () async {
        final node = File('${dir.path}/kgsl-3d0')..writeAsStringSync('');
        final file = smaps(_plain('/dev/ashmem').codeUnits);
        final reading = await readGpuMemoryReading(
          smapsPath: file.path,
          gpuNodePath: node.path,
        );
        expect(reading, isNotNull);
        expect(reading!.inAnonymousBytes, 0);
        expect(reading.inFileBackedBytes, 0);
        expect(reading.outsideSnapshotBytes, isNull);
      },
    );

    test(
      'a mapping wins over the node: the numbers are the mapping\'s',
      () async {
        final file = smaps(_mapping('/dev/kgsl-3d0', dirty: 3).codeUnits);
        final reading = await readGpuMemoryReading(
          smapsPath: file.path,
          gpuNodePath: '${dir.path}/no-kgsl-3d0',
        );
        expect(reading!.inAnonymousBytes, 3 * _kib);
      },
    );

    test('an absent smaps is a failed read: it exists on every kernel', () {
      expect(
        readGpuMemoryReading(smapsPath: '${dir.path}/nope'),
        throwsA(isA<MemoryReadException>()),
      );
    });

    test('a malformed smaps is a failed read, not a number', () async {
      final file = smaps(_mapping('/dev/kgsl-3d0', unit: 'KB').codeUnits);
      expect(
        readGpuMemoryReading(smapsPath: file.path),
        throwsA(isA<MemoryReadException>()),
      );
    });
  });

  test('real /proc/self/smaps parses (this host maps no GPU)', () async {
    expect(await readGpuMemoryReading(), isNull);
  }, skip: File('/proc/self/smaps').existsSync() ? false : 'needs /proc');

  group('GpuMemoryReading', () {
    final at = DateTime.utc(2026, 10, 17);
    GpuMemoryReading make({int dirty = 1, int? outside}) => GpuMemoryReading(
      source: GpuMemorySource.adrenoKgslMappings,
      inAnonymousBytes: dirty,
      inFileBackedBytes: 2,
      outsideSnapshotBytes: outside,
      takenAt: at,
    );

    test('equality and hashCode cover every field', () {
      expect(make(), make());
      expect(make().hashCode, make().hashCode);
      expect(make(), isNot(make(dirty: 3)));
      expect(make(), isNot(make(outside: 4)));
      expect(make().hashCode, isNot(make(dirty: 3).hashCode));
      expect(make().hashCode, isNot(make(outside: 4).hashCode));
    });

    test('toString names the fields', () {
      expect(make().toString(), contains('inFileBackedBytes: 2'));
    });
  });

  group(
    'gpuMemory',
    skip: Platform.isMacOS || Platform.isLinux || Platform.isWindows,
    () {
      test('throws off Android, iOS, macOS, Linux and Windows like '
          'memorySnapshot', () {
        expect(
          // ignore: experimental_member_use
          FlutterEdgeAiDiagnostics.gpuMemory(),
          throwsA(isA<UnsupportedError>()),
        );
      });
    },
  );
}

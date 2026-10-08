import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../hook/src/qnn_runtime.dart';

/// A minimal zip writer, just enough to feed the reader: each entry stored or
/// raw-deflated, CRCs left zero (the reader trusts the archive-wide SHA256).
Uint8List _zip(Map<String, List<int>> entries, {bool deflate = true}) {
  final body = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final e in entries.entries) {
    final name = utf8.encode(e.key);
    final payload = deflate ? ZLibEncoder(raw: true).convert(e.value) : e.value;
    final offset = body.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, payload.length, Endian.little)
      ..setUint32(22, e.value.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    body
      ..add(local.buffer.asUint8List())
      ..add(name)
      ..add(payload);
    final cd = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, payload.length, Endian.little)
      ..setUint32(24, e.value.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(name);
    count++;
  }
  final cdOffset = body.length;
  final cdBytes = central.takeBytes();
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  return (BytesBuilder()
        ..add(body.takeBytes())
        ..add(cdBytes)
        ..add(eocd.buffer.asUint8List()))
      .takeBytes();
}

/// An ELF with a program-header table of entries given as
/// (offset, vaddr, align). Nothing but the headers is meaningful.
Uint8List _elf({
  required bool is64,
  required List<(int, int, int)> loads,
  int machine = emHexagon,
  int type = 1,
  int data = 1,
  int? cls,
  int? phentsize,
}) {
  final phoff = is64 ? 0x40 : 0x34;
  final entsize = phentsize ?? (is64 ? 0x38 : 0x20);
  final bytes = Uint8List(phoff + entsize * loads.length + 0x10);
  final d = ByteData.sublistView(bytes);
  bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, cls ?? (is64 ? 2 : 1), data]);
  d.setUint16(0x12, machine, Endian.little);
  if (is64) {
    d
      ..setUint64(0x20, phoff, Endian.little)
      ..setUint16(0x36, entsize, Endian.little)
      ..setUint16(0x38, loads.length, Endian.little);
  } else {
    d
      ..setUint32(0x1C, phoff, Endian.little)
      ..setUint16(0x2A, entsize, Endian.little)
      ..setUint16(0x2C, loads.length, Endian.little);
  }
  for (var i = 0; i < loads.length; i++) {
    final o = phoff + i * entsize;
    final (off, va, al) = loads[i];
    d.setUint32(o, type, Endian.little);
    if (is64) {
      d
        ..setUint64(o + 0x08, off, Endian.little)
        ..setUint64(o + 0x10, va, Endian.little)
        ..setUint64(o + 0x30, al, Endian.little);
    } else {
      d
        ..setUint32(o + 0x04, off, Endian.little)
        ..setUint32(o + 0x08, va, Endian.little)
        ..setUint32(o + 0x1C, al, Endian.little);
    }
  }
  return bytes;
}

int _align(Uint8List elf, int index, {required bool is64}) {
  final d = ByteData.sublistView(elf);
  final o = (is64 ? 0x40 : 0x34) + index * (is64 ? 0x38 : 0x20);
  return is64
      ? d.getUint64(o + 0x30, Endian.little)
      : d.getUint32(o + 0x1C, Endian.little);
}

/// A synthetic qnn-runtime AAR: 4 KB-aligned Hexagon Skels, 16 KB-aligned
/// arm64 everything else, plus Qualcomm's notice files.
Uint8List _fakeAar() => _zip({
  for (final name in qnnRuntimeLibs)
    'jni/arm64-v8a/${androidLibFileName(name)}': name.endsWith('Skel')
        ? _elf(
            is64: false,
            loads: [(0x0, 0x0, 0x1000), (0x8000, 0x10000, 0x1000)],
          )
        : _elf(is64: true, machine: emAarch64, loads: [(0x0, 0x0, 0x4000)]),
  'jni/arm64-v8a/libQnnHtpPrepare.so': List.filled(64, 7),
  'LICENSE.pdf': utf8.encode('%PDF licence'),
  'NOTICE.txt': utf8.encode('notices'),
});

void main() {
  group('readBoolUserDefine', () {
    test('absent is off', () {
      expect(readBoolUserDefine(null, 'qualcomm_npu'), isFalse);
    });

    test('pubspec bools and command-line strings', () {
      expect(readBoolUserDefine(true, 'qualcomm_npu'), isTrue);
      expect(readBoolUserDefine(false, 'qualcomm_npu'), isFalse);
      expect(readBoolUserDefine('true', 'qualcomm_npu'), isTrue);
      expect(readBoolUserDefine('false', 'qualcomm_npu'), isFalse);
    });

    test('a typo fails instead of quietly meaning off', () {
      expect(
        () => readBoolUserDefine('yes', 'qualcomm_npu'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('flutter_edge_ai_litertlm.qualcomm_npu'),
          ),
        ),
      );
      expect(
        () => readBoolUserDefine(1, 'qualcomm_npu'),
        throwsFormatException,
      );
    });
  });

  test('AAR URL tolerates a trailing slash on the mirror', () {
    const want =
        'https://mirror.example/m2/com/qualcomm/qti/qnn-runtime/'
        '$qnnRuntimeVersion/qnn-runtime-$qnnRuntimeVersion.aar';
    expect(qnnRuntimeAarUrl('https://mirror.example/m2').toString(), want);
    expect(qnnRuntimeAarUrl('https://mirror.example/m2/').toString(), want);
  });

  group('zip reader', () {
    final a = List<int>.generate(5000, (i) => i % 251);
    final b = 'hexagon'.codeUnits;

    for (final deflate in [true, false]) {
      test(
        'returns the wanted entries (${deflate ? 'deflate' : 'stored'})',
        () {
          final zip = _zip({
            'jni/arm64-v8a/libA.so': a,
            'jni/arm64-v8a/libB.so': b,
            'classes.jar': [1, 2, 3],
          }, deflate: deflate);
          final got = extractZipEntries(zip, {
            'jni/arm64-v8a/libA.so',
            'jni/arm64-v8a/libB.so',
          });
          expect(got.keys, hasLength(2));
          expect(got['jni/arm64-v8a/libA.so'], a);
          expect(got['jni/arm64-v8a/libB.so'], b);
        },
      );
    }

    test('reads the same entries from a file', () {
      final dir = Directory.systemTemp.createTempSync('qnn_zip_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/x.aar')
        ..writeAsBytesSync(_zip({'a': a, 'b': b}));
      final got = extractZipEntriesFromFile(f, {'a', 'b'});
      expect(got['a'], a);
      expect(got['b'], b);
    });

    test('a missing entry throws rather than returning a partial map', () {
      expect(
        () => extractZipEntries(_zip({'a': a}), {'a', 'libQnnHtp.so'}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('libQnnHtp.so'),
          ),
        ),
      );
    });

    test('not a zip', () {
      expect(
        () => extractZipEntries(Uint8List(100), {'x'}),
        throwsFormatException,
      );
    });
  });

  group('raiseLoadAlignmentTo16K', () {
    for (final is64 in [false, true]) {
      final kind = is64 ? 'ELF64' : 'ELF32';

      test('$kind: 4 KB loads are raised to 16 KB', () {
        final elf = _elf(
          is64: is64,
          loads: [(0x0, 0x0, 0x1000), (0x8000, 0x10000, 0x1000)],
        );
        expect(raiseLoadAlignmentTo16K(elf), isTrue);
        expect(_align(elf, 0, is64: is64), 0x4000);
        expect(_align(elf, 1, is64: is64), 0x4000);
      });

      test('$kind: already 16 KB is left alone', () {
        final elf = _elf(is64: is64, loads: [(0x0, 0x0, 0x4000)]);
        final before = Uint8List.fromList(elf);
        expect(raiseLoadAlignmentTo16K(elf), isFalse);
        expect(elf, before);
      });

      test(
        '$kind: offset/vaddr not congruent mod 16K is refused untouched',
        () {
          final elf = _elf(is64: is64, loads: [(0x1000, 0x2000, 0x1000)]);
          final before = Uint8List.fromList(elf);
          expect(() => raiseLoadAlignmentTo16K(elf), throwsFormatException);
          expect(elf, before);
        },
      );
    }

    final refusals = <String, Uint8List>{
      'not an ELF': Uint8List(0x80),
      'unknown class': _elf(is64: false, cls: 3, loads: [(0, 0, 0x1000)]),
      'big-endian': _elf(is64: false, data: 2, loads: [(0, 0, 0x1000)]),
      'wrong machine': _elf(
        is64: false,
        machine: emAarch64,
        loads: [(0, 0, 0x1000)],
      ),
      'short program-header entries': _elf(
        is64: false,
        phentsize: 0x10,
        loads: [(0, 0, 0x1000)],
      ),
      'no PT_LOAD': _elf(is64: false, type: 2, loads: [(0, 0, 0x1000)]),
      'non-power-of-two align': _elf(is64: false, loads: [(0, 0, 0x3000)]),
    };
    refusals.forEach((what, elf) {
      test('refuses: $what', () {
        final before = Uint8List.fromList(elf);
        expect(() => raiseLoadAlignmentTo16K(elf), throwsFormatException);
        expect(elf, before);
      });
    });

    test('a program-header table past the end of the file is refused', () {
      final elf = _elf(is64: false, loads: [(0, 0, 0x1000)]);
      ByteData.sublistView(elf).setUint16(0x2C, 500, Endian.little);
      expect(() => raiseLoadAlignmentTo16K(elf), throwsFormatException);
    });
  });

  group('prepareQnnLibrary', () {
    test('patches a Skel', () {
      final out = prepareQnnLibrary(
        'libQnnHtpV79Skel.so',
        _elf(is64: false, loads: [(0x0, 0x0, 0x1000)]),
      );
      expect(_align(out, 0, is64: false), 0x4000);
    });

    test('never patches an arm64 library: 4 KB fails the build', () {
      expect(
        () => prepareQnnLibrary(
          'libQnnHtp.so',
          _elf(is64: true, machine: emAarch64, loads: [(0x0, 0x0, 0x1000)]),
        ),
        throwsFormatException,
      );
    });

    test('an arm64 library already at 16 KB passes unchanged', () {
      final elf = _elf(is64: true, machine: emAarch64, loads: [(0, 0, 0x4000)]);
      expect(prepareQnnLibrary('libQnnSystem.so', elf), elf);
    });
  });

  group('cache', () {
    late Directory root;
    late File aar;

    setUp(() {
      root = Directory.systemTemp.createTempSync('qnn_cache_');
      aar = File('${root.path}/in.aar')..writeAsBytesSync(_fakeAar());
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('promotes the ten libraries, patched, with notices and a marker', () {
      final cacheRoot = Directory('${root.path}/cache');
      final entry = promoteQnnCache(cacheRoot, aar);
      expect(entry.path, endsWith(qnnCacheEntryName()));
      expect(isCompleteQnnCache(entry), isTrue);
      for (final f in qnnLibFileNames) {
        expect(File('${entry.path}/$f').existsSync(), isTrue, reason: f);
      }
      final skel = File('${entry.path}/libQnnHtpV75Skel.so').readAsBytesSync();
      expect(_align(skel, 0, is64: false), 0x4000);
      expect(File('${entry.path}/libQnnHtpPrepare.so').existsSync(), isFalse);
      // Registered as hook dependencies: written during this build, they must
      // still not read as "modified during build" to hooks_runner.
      final buildStart = DateTime.now().subtract(const Duration(minutes: 1));
      for (final f in qnnLibFileNames) {
        expect(
          File('${entry.path}/$f').lastModifiedSync().isBefore(buildStart),
          isTrue,
          reason: f,
        );
      }
      expect(File('${entry.path}/NOTICE.txt').readAsStringSync(), 'notices');
      expect(File('${entry.path}/LICENSE.pdf').existsSync(), isTrue);
      expect(
        cacheRoot.listSync().where((e) => e.path.contains('.tmp-')),
        isEmpty,
        reason: 'no temp directory may be left behind',
      );
    });

    test('a second promotion reuses the complete entry', () {
      final cacheRoot = Directory('${root.path}/cache');
      final first = promoteQnnCache(cacheRoot, aar);
      final stamp = File('${first.path}/libQnnHtp.so').lastModifiedSync();
      final second = promoteQnnCache(cacheRoot, aar);
      expect(second.path, first.path);
      expect(File('${second.path}/libQnnHtp.so').lastModifiedSync(), stamp);
    });

    test('an incomplete entry (a crash mid-write) is replaced', () {
      final cacheRoot = Directory('${root.path}/cache');
      final stale = Directory('${cacheRoot.path}/${qnnCacheEntryName()}')
        ..createSync(recursive: true);
      File('${stale.path}/libQnnHtp.so').writeAsBytesSync([1, 2, 3]);
      expect(isCompleteQnnCache(stale), isFalse);
      final entry = promoteQnnCache(cacheRoot, aar);
      expect(isCompleteQnnCache(entry), isTrue);
    });

    test('a truncated file invalidates the entry', () {
      final entry = promoteQnnCache(Directory('${root.path}/cache'), aar);
      File('${entry.path}/libQnnSystem.so').writeAsBytesSync([0]);
      expect(isCompleteQnnCache(entry), isFalse);
    });

    test('temp dirs of a killed build go once old; young ones stay', () {
      final cacheRoot = Directory('${root.path}/cache')..createSync();
      final download = cacheRoot.createTempSync(qnnDownloadTempPrefix);
      final prepare = cacheRoot.createTempSync(qnnPrepareTempPrefix);
      final entry = Directory('${cacheRoot.path}/${qnnCacheEntryName()}')
        ..createSync();

      removeStaleQnnTemps(cacheRoot);
      expect(download.existsSync(), isTrue, reason: 'may be in progress');
      expect(prepare.existsSync(), isTrue, reason: 'may be in progress');

      removeStaleQnnTemps(
        cacheRoot,
        now: DateTime.now().add(qnnStaleTempAge * 2),
      );
      expect(download.existsSync(), isFalse);
      expect(prepare.existsSync(), isFalse);
      expect(entry.existsSync(), isTrue, reason: 'entries are never swept');
    });
  });
}

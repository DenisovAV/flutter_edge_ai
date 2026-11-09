import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_onnx/src/hook/elf_page_align.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 64-bit little-endian ELF header with the given PT_LOAD alignments.
Uint8List _elf(List<int> loadAligns, {List<int> otherAligns = const []}) {
  const phoff = 0x40, phentsize = 56;
  final count = loadAligns.length + otherAligns.length;
  final out = Uint8List(phoff + phentsize * count);
  final d = ByteData.sublistView(out);
  out.setRange(0, 4, [0x7f, 0x45, 0x4c, 0x46]);
  out[4] = 2;
  out[5] = 1;
  d.setUint64(0x20, phoff, Endian.little);
  d.setUint16(0x36, phentsize, Endian.little);
  d.setUint16(0x38, count, Endian.little);
  var i = 0;
  for (final a in loadAligns) {
    d.setUint32(phoff + phentsize * i, 1, Endian.little);
    d.setUint64(phoff + phentsize * i + 48, a, Endian.little);
    i++;
  }
  for (final a in otherAligns) {
    d.setUint32(phoff + phentsize * i, 2, Endian.little); // PT_DYNAMIC
    d.setUint64(phoff + phentsize * i + 48, a, Endian.little);
    i++;
  }
  return out;
}

void main() {
  test('reads the smallest PT_LOAD alignment', () {
    expect(smallestLoadAlign(_elf([0x4000, 0x1000, 0x4000])), 0x1000);
    expect(smallestLoadAlign(_elf([0x4000, 0x4000])), 0x4000);
  });

  test('other segments do not count', () {
    expect(smallestLoadAlign(_elf([0x4000], otherAligns: [8])), 0x4000);
    expect(smallestLoadAlign(_elf([], otherAligns: [8])), isNull);
  });

  test('refuses anything that is not a 64-bit little-endian ELF', () {
    expect(() => smallestLoadAlign(Uint8List(10)), throwsFormatException);
    final elf32 = _elf([0x4000])..[4] = 1;
    expect(() => smallestLoadAlign(elf32), throwsFormatException);
  });

  group('requireAndroidPageAlign', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('elf_align'));
    tearDown(() => dir.deleteSync(recursive: true));

    File write(String name, Uint8List bytes) =>
        File('${dir.path}/$name')..writeAsBytesSync(bytes);

    test('accepts a 16 KB library', () {
      requireAndroidPageAlign(write('ok.so', _elf([0x4000, 0x4000])));
    });

    test('refuses a 4 KB library, naming it and the alignment', () {
      expect(
        () => requireAndroidPageAlign(write('libmat.so', _elf([0x1000]))),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('libmat.so'), contains('0x1000'), contains('16 KB')),
          ),
        ),
      );
    });

    test('refuses a file that is not an ELF, by name', () {
      expect(
        () => requireAndroidPageAlign(write('x.so', Uint8List(100))),
        throwsA(isA<StateError>()),
      );
    });
  });

  test('the Microsoft 0.17.0 libmat.so would have been refused', () {
    // jni/arm64-v8a/libmat.so in onnxruntime-genai-android-0.17.0.aar:
    // readelf -lW shows p_align 0x1000 on all three PT_LOAD segments.
    expect(smallestLoadAlign(_elf([0x1000, 0x1000, 0x1000])), lessThan(0x4000));
  });
}

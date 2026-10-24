import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai_litertlm/src/hook/mediatek_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/hook/qnn_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zip_fixture.dart';

/// An arm64 ELF64 whose only meaningful content is one PT_LOAD of [align].
Uint8List _arm64Elf({required int align}) {
  final bytes = Uint8List(0x40 + 0x38 + 0x10);
  final d = ByteData.sublistView(bytes);
  bytes.setAll(0, [0x7f, 0x45, 0x4c, 0x46, 2, 1]);
  d
    ..setUint16(0x12, emAarch64, Endian.little)
    ..setUint64(0x20, 0x40, Endian.little)
    ..setUint16(0x36, 0x38, Endian.little)
    ..setUint16(0x38, 1, Endian.little)
    ..setUint32(0x40, 1, Endian.little)
    ..setUint64(0x40 + 0x30, align, Endian.little);
  return bytes;
}

/// A synthetic litert-npu-runtime-mediatek AAR: the dispatch, the compiler
/// plugin this package leaves out, and Google's notice files.
Uint8List _fakeAar({int dispatchAlign = 0x4000}) => buildZip({
  'jni/arm64-v8a/libLiteRtDispatch_MediaTek.so': _arm64Elf(
    align: dispatchAlign,
  ),
  'jni/arm64-v8a/libLiteRtCompilerPlugin_MediaTek.so': _arm64Elf(align: 0x4000),
  'LICENSE': utf8.encode('Apache License 2.0'),
  'THIRD_PARTY_NOTICE.txt': utf8.encode('notices'),
});

void main() {
  test('the AAR is Google Maven\'s, and a mirror may end with a slash', () {
    expect(
      mediatekRuntimeAarUrl(mediatekDefaultMavenBase).toString(),
      'https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/'
      'litert-npu-runtime-mediatek/2.3.0/'
      'litert-npu-runtime-mediatek-2.3.0.aar',
    );
    expect(
      mediatekRuntimeAarUrl('https://mirror.example.com/maven/'),
      mediatekRuntimeAarUrl('https://mirror.example.com/maven'),
    );
  });

  test('only the dispatch is taken from the AAR', () {
    expect(mediatekLibFileNames, ['libLiteRtDispatch_MediaTek.so']);
    expect(mediatekNpuLibs, [mediatekDispatchLib]);
  });

  group('cache', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('mtk_cache_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('promotes the dispatch with Google\'s notices, never the compiler '
        'plugin', () {
      final aar = File('${root.path}/in.aar')..writeAsBytesSync(_fakeAar());
      final cacheRoot = Directory('${root.path}/cache');
      final entry = promoteMediatekCache(cacheRoot, aar);

      expect(entry.path, endsWith(mediatekCacheEntryName()));
      expect(
        isCompleteQnnCache(entry, fileNames: mediatekLibFileNames),
        isTrue,
      );
      expect(
        File('${entry.path}/libLiteRtDispatch_MediaTek.so').existsSync(),
        isTrue,
      );
      expect(
        File('${entry.path}/libLiteRtCompilerPlugin_MediaTek.so').existsSync(),
        isFalse,
      );
      expect(File('${entry.path}/LICENSE').readAsStringSync(), contains('2.0'));
      expect(
        File('${entry.path}/THIRD_PARTY_NOTICE.txt').readAsStringSync(),
        'notices',
      );
      // A second promotion reuses the complete entry.
      expect(promoteMediatekCache(cacheRoot, aar).path, entry.path);
    });

    test('a dispatch Google Play would reject is refused, and nothing is '
        'cached', () {
      final aar = File('${root.path}/in.aar')
        ..writeAsBytesSync(_fakeAar(dispatchAlign: 0x1000));
      final cacheRoot = Directory('${root.path}/cache');
      expect(
        () => promoteMediatekCache(cacheRoot, aar),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('not 16 KB-aligned'),
          ),
        ),
      );
      expect(
        Directory('${cacheRoot.path}/${mediatekCacheEntryName()}').existsSync(),
        isFalse,
      );
    });
  });
}

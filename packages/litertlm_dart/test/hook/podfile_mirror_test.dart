// The macOS companions mirrored for the Podfile stager into the flat cache
// of flutter_edge_ai_litertlm 1.20.x and before. That cache holds every
// platform's files under one version marker, which an older hook trusts.
import 'dart:io';

import 'package:litertlm_dart/src/hook/podfile_mirror.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('podfile_mirror'));
  tearDown(() => root.deleteSync(recursive: true));

  test('copies the companions, removes the old libLiteRtLm, and leaves the '
      "flat cache's version marker alone", () {
    final prebuilt = Directory('${root.path}/prebuilt')..createSync();
    File('${prebuilt.path}/libCompanion.dylib').writeAsStringSync('new');
    final flat = Directory('${root.path}/flutter_gemma/native');
    final legacy = Directory('${flat.path}/macos_arm64')
      ..createSync(recursive: true);
    File('${legacy.path}/libLiteRtLm.dylib').writeAsStringSync('old');
    File('${legacy.path}/libCompanion.dylib').writeAsStringSync('old');
    final android = Directory('${flat.path}/android_arm64')..createSync();
    File('${android.path}/libLiteRtLm.so').writeAsStringSync('-b');
    final marker = File('${flat.path}/.flutter_gemma_native_version')
      ..writeAsStringSync(
        '{"version":"0.19.1-b","owner":"flutter_gemma_litertlm"}',
      );

    final copies = mirrorForPodfileStager(
      companionFiles: ['libCompanion.dylib', 'libAbsent.dylib'],
      legacyMainFile: 'libLiteRtLm.dylib',
      prebuiltDir: prebuilt.uri,
      legacyDir: legacy,
    );

    expect(copies, [File('${legacy.path}/libCompanion.dylib').uri]);
    expect(File('${legacy.path}/libCompanion.dylib').readAsStringSync(), 'new');
    expect(File('${legacy.path}/libLiteRtLm.dylib').existsSync(), isFalse);
    // Rewritten, it would tell an older hook that android_arm64's -b files
    // are current, and it would bundle them.
    expect(
      marker.readAsStringSync(),
      '{"version":"0.19.1-b","owner":"flutter_gemma_litertlm"}',
    );
    expect(File('${android.path}/libLiteRtLm.so').readAsStringSync(), '-b');
  });

  test('writes no marker into a flat cache that has none', () {
    final prebuilt = Directory('${root.path}/prebuilt')..createSync();
    final legacy = Directory('${root.path}/flutter_gemma/native/macos_arm64');
    mirrorForPodfileStager(
      companionFiles: const [],
      legacyMainFile: 'libLiteRtLm.dylib',
      prebuiltDir: prebuilt.uri,
      legacyDir: legacy,
    );
    expect(
      File('${legacy.parent.path}/.flutter_gemma_native_version').existsSync(),
      isFalse,
    );
  });
}

import 'package:flutter_edge_ai_litertlm/src/hook/unsupported_target.dart';
import 'package:flutter_test/flutter_test.dart';

String? _notice(String dirName) => missingArchiveNotice(
  packageName: 'flutter_edge_ai_litertlm',
  dirName: dirName,
  archiveName: 'litertlm-$dirName.tar.gz',
);

void main() {
  test(
    'Windows ARM64 gets the notice, with the cause, the options and #326',
    () {
      final notice = _notice('windows_arm64')!;
      expect(notice, startsWith('[flutter_edge_ai_litertlm] '));
      expect(notice, contains('litertlm-windows_arm64.tar.gz'));
      expect(notice, contains('MediaPipe has no desktop engine'));
      expect(notice, contains('flutter_edge_ai_onnx'));
      expect(notice, contains('not run on ARM64 hardware'));
      expect(notice, contains('x64'));
      expect(notice, contains('issues/326'));
    },
  );

  test('the slices of ordinary builds stay silent', () {
    // android-x64 is in `flutter build apk`'s default targets and macOS release
    // builds are universal: an arm64 half works, so no red error for the app.
    for (final dirName in ['android_x86_64', 'macos_x86_64']) {
      expect(_notice(dirName), isNull, reason: dirName);
    }
  });

  test('targets that do ship an archive never get it', () {
    for (final dirName in [
      'android_arm64',
      'ios_arm64',
      'ios_sim_arm64',
      'linux_x86_64',
      'linux_arm64',
      'macos_arm64',
      'windows_x86_64',
    ]) {
      expect(_notice(dirName), isNull, reason: dirName);
    }
  });
}

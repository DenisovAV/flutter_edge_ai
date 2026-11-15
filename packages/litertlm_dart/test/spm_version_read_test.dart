// package_macos_spm_companions.sh stamps each companion framework with the
// native version it reads from runtime/native_release.dart; its sed must find
// the constant there.

import 'dart:io';

import 'package:litertlm_dart/src/runtime/native_release.dart';
import 'package:test/test.dart';

void main() {
  test('the SPM packaging script reads the version the hook uses', () {
    final script = File(
      'native/litert_lm/package_macos_spm_companions.sh',
    ).readAsStringSync();
    final sed = RegExp(
      r'HOOK_VERSION="\$\((sed -n "[^"]+") ',
    ).firstMatch(script);
    expect(sed, isNotNull, reason: 'the version read in the script');
    expect(script, contains('lib/src/runtime/native_release.dart'));
    final result = Process.runSync('sh', [
      '-c',
      '${sed!.group(1)} lib/src/runtime/native_release.dart',
    ]);
    expect((result.stdout as String).trim(), liteRtLmNativeVersion);
  });
}

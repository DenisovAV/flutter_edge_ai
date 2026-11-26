// `hooks: user_defines: litertlm_dart: macos_companions:`, obsolete since
// litertlm_dart 0.20.0: the hook warns once, naming it, and never refuses.
import 'dart:io';

import 'package:litertlm_dart/src/hook/macos_companions.dart';
import 'package:test/test.dart';

void main() {
  test('unset says nothing', () {
    expect(obsoleteMacOSCompanionsWarning(null), isNull);
  });

  test('any value, the two old ones and a wrong one alike, is a warning that '
      'names the define, never a refusal', () {
    for (final value in <Object>['code_assets', 'frameworks', 'x', true, 1]) {
      final warning = obsoleteMacOSCompanionsWarning(value);
      expect(
        warning,
        allOf(
          contains('hooks.user_defines.litertlm_dart.macos_companions'),
          contains('"$value"'),
          contains('obsolete and ignored since litertlm_dart 0.20.0'),
          contains('Remove it'),
        ),
        reason: '$value',
      );
    }
  });

  test('the hook says it on a macOS target only, once per run', () {
    final notice = ObsoleteMacOSCompanionsNotice();
    expect(notice.take('code_assets', macOSTarget: false), isNull);
    expect(notice.take(null, macOSTarget: true), isNull);
    expect(
      notice.take('code_assets', macOSTarget: true),
      obsoleteMacOSCompanionsWarning('code_assets'),
    );
    expect(notice.take('code_assets', macOSTarget: true), isNull);
    final hook = File('hook/build.dart').readAsStringSync();
    expect(hook, contains('macOSTarget: os == OS.macOS'));
  });
}

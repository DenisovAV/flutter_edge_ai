// `hooks: user_defines: litertlm_dart: macos_companions:`, obsolete since
// litertlm_dart 0.20.0: the hook warns once, naming it, and never refuses.
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
}

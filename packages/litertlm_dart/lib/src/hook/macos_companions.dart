// `hooks: user_defines: litertlm_dart: macos_companions:`, obsolete since
// litertlm_dart 0.20.0.
//
// Up to 0.19.1+4 the define chose how Google's prebuilt Gemma constraint
// provider reached a program on macOS: as a Flutter app's framework (unset) or
// as a code asset of a plain Dart program (`code_assets`). From
// native-v0.20.0 the tool-call constraints are built with LLGuidance
// (patch_c_api.sh section 29) and LiteRtLm links no companion library, so
// there is nothing left to choose: the hook bundles the same files for both,
// and a plain Dart program on macOS needs no define. A pubspec that still sets
// it builds as before, with one warning that names it: on a macOS target only
// (the only one it ever applied to), once per hook run.

/// The obsolete `user_defines` key.
const macOSCompanionsDefine = 'macos_companions';

/// The warning for [value], the define's value; null when it is unset.
String? obsoleteMacOSCompanionsWarning(Object? value) => value == null
    ? null
    : '[litertlm_dart] hooks.user_defines.litertlm_dart.$macOSCompanionsDefine '
          '("$value") is obsolete and ignored since litertlm_dart 0.20.0: '
          'LiteRT-LM links no companion library on macOS any more, so a plain '
          'Dart program needs no define. Remove it from your pubspec.yaml.';

/// Says [obsoleteMacOSCompanionsWarning] at most once, and only for a macOS
/// target: one per hook run, however many times the hook asks.
final class ObsoleteMacOSCompanionsNotice {
  bool _said = false;

  /// The warning to print for [value] on a build for [macOSTarget], or null
  /// when there is nothing to say (unset, another target, already said).
  String? take(Object? value, {required bool macOSTarget}) {
    if (_said || !macOSTarget) return null;
    final warning = obsoleteMacOSCompanionsWarning(value);
    if (warning != null) _said = true;
    return warning;
  }
}

// How the hook ships LiteRT-LM's macOS companion libraries, chosen by
// `hooks: user_defines: litertlm_dart: macos_companions:`.
//
// Unset, as always: for a Flutter app, which gets the companions as
// frameworks (its Swift package or the Podfile block, #689), with LiteRtLm
// pointed at them. `code_assets`, for a plain Dart program (`dart run`,
// `dart test`, `dart build cli`): the constraint provider is a code asset
// under a short file name, LiteRtLm keeps its own reference (the Dart SDK
// rewrites it), and the Metal accelerator is not bundled (libLiteRtLm's
// statically linked one serves the GPU). The hook cannot tell a
// Flutter build from a plain Dart one, so the program says which it is.
//
// `dart run` and `dart test` give each code asset its absolute path as its
// install name: in a temporary directory since Dart 3.14, in the root
// package's `.dart_tool/lib/` before. Google's prebuilt provider has
// little Mach-O header room for it, so a long temporary directory fails the
// Dart SDK's install_name_tool step; [dartJitInstallNameRefusal] says so first.

import 'dart:convert';

import '../runtime/macos_companions.dart';

export '../runtime/macho.dart' show machOHeaderSlack;

/// Where the macOS companions go.
enum MacOSCompanions {
  /// A Flutter app's frameworks (the default).
  frameworks,

  /// A plain Dart program's code assets.
  codeAssets,
}

/// The mode [value], the define's value, chooses. Anything but unset,
/// [macOSCompanionsFrameworks] and [macOSCompanionsCodeAssets] is a
/// [FormatException] naming the define.
MacOSCompanions readMacOSCompanionsDefine(Object? value) => switch (value) {
  null || macOSCompanionsFrameworks => MacOSCompanions.frameworks,
  macOSCompanionsCodeAssets => MacOSCompanions.codeAssets,
  _ => throw FormatException(
    'hooks.user_defines.litertlm_dart.$macOSCompanionsDefine must be '
    '$macOSCompanionsCodeAssets (for a plain Dart program: dart run, dart '
    'test, dart build cli), or $macOSCompanionsFrameworks or unset (for a '
    'Flutter app), got ${value.runtimeType} "$value"',
  ),
};

/// The size of an `LC_ID_DYLIB` naming [installName]: 24 bytes, the name and
/// its NUL, rounded up to 8.
int dylibIdCommandSize(String installName) =>
    (24 + utf8.encode(installName).length + 1 + 7) & ~7;

/// Whether the Dart SDK of [platformVersion] (`Platform.version` of the hook
/// process, which the invoking SDK runs) copies the code assets of `dart run`
/// and `dart test` into a fresh temporary directory: 3.14 and later. Before,
/// it copies them into the root package's `.dart_tool/lib/` (measured with
/// Dart 3.12.0 and 3.13.7).
bool dartJitUsesTempDir(String platformVersion) {
  final match = RegExp(r'^(\d+)\.(\d+)\.').firstMatch(platformVersion);
  if (match == null) return true;
  final major = int.parse(match[1]!);
  final minor = int.parse(match[2]!);
  return major > 3 || (major == 3 && minor >= 14);
}

/// The root package's directory (the one holding `.dart_tool/`) of a hook
/// whose shared output directory is [outputDirectoryShared]
/// (`<root>/.dart_tool/hooks_runner/shared/...`); null for another layout.
String? dartToolOwnerOf(Uri outputDirectoryShared) {
  final segments = outputDirectoryShared.pathSegments;
  for (var i = segments.length - 2; i >= 0; i--) {
    if (segments[i] == '.dart_tool' && segments[i + 1] == 'hooks_runner') {
      final path = outputDirectoryShared
          .replace(pathSegments: [...segments.take(i), ''])
          .toFilePath();
      // toFilePath ends a directory with the platform's separator.
      return path.length > 1 && (path.endsWith('/') || path.endsWith(r'\'))
          ? path.substring(0, path.length - 1)
          : path;
    }
  }
  return null;
}

/// Where `dart run` and `dart test` put the code assets, as the directory
/// the provider's install name is written under.
sealed class DartJitAssetDir {
  const DartJitAssetDir();

  /// The directory's path, with `XXXXXX` for a random part.
  String get path;

  /// [path] with its variable part [length] characters long.
  String withLength(int length);

  /// How long the variable part is now.
  int get length;

  /// What to do when it is too long.
  String get advice;

  /// What is too long.
  String get what;
}

/// Dart 3.14 and later: `<temp>/dart_native_assets_XXXXXX/lib` (the SDK's
/// `Directory.systemTemp.createTemp('dart_native_assets_')`, symbolic links
/// resolved).
final class DartJitTempDir extends DartJitAssetDir {
  const DartJitTempDir(this.resolvedTempDir);

  final String resolvedTempDir;

  String get _base => resolvedTempDir.endsWith('/')
      ? resolvedTempDir.substring(0, resolvedTempDir.length - 1)
      : resolvedTempDir;

  @override
  String get path => '$_base/dart_native_assets_XXXXXX/lib';

  @override
  String withLength(int length) => DartJitTempDir('x' * length).path;

  @override
  int get length => _base.length;

  @override
  String get what => 'the temporary directory $_base';

  @override
  String get advice => 'Run with a shorter one, e.g. TMPDIR=/tmp dart run.';
}

/// Dart 3.12 and 3.13: `<root package>/.dart_tool/lib`.
final class DartJitProjectDir extends DartJitAssetDir {
  const DartJitProjectDir(this.projectRoot);

  final String projectRoot;

  @override
  String get path => '$projectRoot/.dart_tool/lib';

  @override
  String withLength(int length) => DartJitProjectDir('x' * length).path;

  @override
  int get length => projectRoot.length;

  @override
  String get what => "the package's directory $projectRoot";

  @override
  String get advice =>
      'Move the package to a shorter path, or use Dart 3.14 or later, which '
      'puts them in the temporary directory.';
}

/// Why `dart run` / `dart test` cannot bundle the provider whose header has
/// [slack] free bytes and whose install name is [currentId] into [dir];
/// null when it fits.
String? dartJitInstallNameRefusal({
  required DartJitAssetDir dir,
  required int slack,
  required String currentId,
}) {
  int growth(String assetDir) =>
      dylibIdCommandSize('$assetDir/$macOSConstraintProviderAssetFile') -
      dylibIdCommandSize(currentId);
  if (growth(dir.path) <= slack) return null;
  // The longest that fits, for the message.
  var longest = dir.length;
  while (longest > 0 && growth(dir.withLength(longest)) > slack) {
    longest--;
  }
  return 'litertlm_dart: ${dir.what} (${dir.length} characters) is too long '
      'for dart run and dart test on macOS: they write each code asset\'s '
      'path under it into the library, and Google\'s prebuilt '
      'libGemmaModelConstraintProvider has room for $longest characters at '
      'most there. ${dir.advice} (This check is for dart run and dart test; '
      'dart build cli is not affected, and a Flutter app must not set '
      'macos_companions at all.)';
}

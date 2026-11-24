// How the hook ships LiteRT-LM's macOS companion libraries, chosen by
// `hooks: user_defines: litertlm_dart: macos_companions:`.
//
// Unset, as always: for a Flutter app, which gets the companions as
// frameworks (its Swift package or the Podfile block, #689), with LiteRtLm
// pointed at them. `code_assets`, for a plain Dart program (`dart run`,
// `dart test`, `dart build cli`): the constraint provider is a code asset
// under a short file name, LiteRtLm keeps its own reference (the Dart SDK
// rewrites it), and the Metal accelerator is not bundled (a plain Dart
// program runs on the CPU only in this release). The hook cannot tell a
// Flutter build from a plain Dart one, so the program says which it is.
//
// `dart run` and `dart test` give each code asset its absolute path in a
// temporary directory as its install name. Google's prebuilt provider has
// little Mach-O header room for it, so a long temporary directory fails the
// Dart SDK's install_name_tool step; [dartRunTempDirRefusal] says so first.

import 'dart:convert';
import 'dart:typed_data';

import '../runtime/macos_companions.dart';

/// Where the macOS companions go.
enum MacOSCompanions {
  /// A Flutter app's frameworks (the default).
  frameworks,

  /// A plain Dart program's code assets.
  codeAssets,
}

/// The mode [value], the define's value, chooses. Anything but unset and
/// [macOSCompanionsCodeAssets] is a [FormatException] naming the define.
MacOSCompanions readMacOSCompanionsDefine(Object? value) => switch (value) {
  null => MacOSCompanions.frameworks,
  macOSCompanionsCodeAssets => MacOSCompanions.codeAssets,
  _ => throw FormatException(
    'hooks.user_defines.litertlm_dart.$macOSCompanionsDefine must be '
    '$macOSCompanionsCodeAssets (for a plain Dart program: dart run, dart '
    'test, dart build cli) or unset (for a Flutter app), got '
    '${value.runtimeType} "$value"',
  ),
};

/// The free bytes between a 64-bit Mach-O file's load commands and its first
/// section: how much install_name_tool can grow them. Throws a
/// [FormatException] for anything else (a fat or 32-bit file).
int machOHeaderSlack(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  if (bytes.length < 32 || data.getUint32(0, Endian.little) != 0xfeedfacf) {
    throw const FormatException('not a 64-bit little-endian Mach-O file');
  }
  final ncmds = data.getUint32(16, Endian.little);
  final sizeofcmds = data.getUint32(20, Endian.little);
  const headerSize = 32;
  const lcSegment64 = 0x19;
  var firstSection = bytes.length;
  var at = headerSize;
  for (var i = 0; i < ncmds; i++) {
    if (at + 8 > bytes.length) {
      throw const FormatException('load commands run past the file');
    }
    final cmd = data.getUint32(at, Endian.little);
    final cmdsize = data.getUint32(at + 4, Endian.little);
    if (cmdsize < 8) throw const FormatException('a load command of size 0');
    if (cmd == lcSegment64) {
      final nsects = data.getUint32(at + 64, Endian.little);
      for (var s = 0; s < nsects; s++) {
        // section_64: offset at byte 48 of its 80.
        final offset = data.getUint32(at + 72 + s * 80 + 48, Endian.little);
        if (offset != 0 && offset < firstSection) firstSection = offset;
      }
    }
    at += cmdsize;
  }
  return firstSection - headerSize - sizeofcmds;
}

/// The size of an `LC_ID_DYLIB` naming [installName]: 24 bytes, the name and
/// its NUL, rounded up to 8.
int dylibIdCommandSize(String installName) =>
    (24 + utf8.encode(installName).length + 1 + 7) & ~7;

/// The install name `dart run` and `dart test` give the provider:
/// `<temp>/dart_native_assets_XXXXXX/lib/<file>` (the SDK's
/// `Directory.systemTemp.createTemp('dart_native_assets_')`, symbolic links
/// resolved).
String dartRunInstallName(String resolvedTempDir) {
  final base = resolvedTempDir.endsWith('/')
      ? resolvedTempDir.substring(0, resolvedTempDir.length - 1)
      : resolvedTempDir;
  return '$base/dart_native_assets_XXXXXX/lib/'
      '$macOSConstraintProviderAssetFile';
}

/// Why `dart run` / `dart test` cannot bundle the provider whose header has
/// [slack] free bytes and whose install name is [currentId], with the
/// temporary directory [resolvedTempDir]; null when it fits.
String? dartRunTempDirRefusal({
  required String resolvedTempDir,
  required int slack,
  required String currentId,
}) {
  final growth =
      dylibIdCommandSize(dartRunInstallName(resolvedTempDir)) -
      dylibIdCommandSize(currentId);
  if (growth <= slack) return null;
  // The longest directory that fits, for the message.
  var longest = resolvedTempDir.length;
  while (longest > 0 &&
      dylibIdCommandSize(dartRunInstallName('x' * longest)) -
              dylibIdCommandSize(currentId) >
          slack) {
    longest--;
  }
  return 'litertlm_dart: the temporary directory $resolvedTempDir '
      '(${resolvedTempDir.length} characters) is too long for dart run and '
      'dart test on macOS: they write each code asset\'s path under it into '
      'the library, and Google\'s prebuilt libGemmaModelConstraintProvider '
      'has room for a directory of $longest characters at most. Run with a '
      'shorter one, e.g. TMPDIR=/tmp dart run. (dart build cli is not '
      'affected.)';
}

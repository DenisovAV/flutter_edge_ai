// Opens LiteRT-LM on macOS and, when it does not load, says why and what fixes
// it (#689).
//
// dyld's own error names the cause, but in words that do not say what to do:
// "Library not loaded: @rpath/GemmaModelConstraintProvider.framework/…" is
// what an app shows when LiteRT-LM's companion libraries are not in it (with
// Swift Package Manager off, the macos/Podfile block copies them; with it on,
// the plugin's Swift package does). The LLM and EmbeddingGemma 2 paths open the
// framework with [openMacOSLiteRtLm], the `.tflite` path (embeddings, speech)
// with [openMacOSLiteRtLmForTflite]. Both build their message here, so every
// path says the same thing, and dyld's text is kept.
//
// A plain Dart program (`dart run`, `dart test`, `dart build cli`) has no
// app: there LiteRtLm and its companion are code assets, in the directory
// [nativeAssetDir] finds, when the program's pubspec sets
// `hooks: user_defines: litertlm_dart: macos_companions: code_assets`. Without
// it the hook bundles them for a Flutter app, and the failure names the
// define.
//
// Package-private.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../runtime/macos_companions.dart';
import 'native_asset_dir.dart';

/// The macOS LiteRT-LM framework, as Native Assets bundles it in an app.
const macOSLiteRtLmFramework = 'LiteRtLm.framework/LiteRtLm';

/// The file names of LiteRtLm and StreamProxy among a plain Dart program's
/// code assets on macOS.
const macOSLiteRtLmAssetFile = 'libLiteRtLm.dylib';
const macOSStreamProxyAssetFile = 'libStreamProxy.dylib';

/// In a plain Dart program on macOS, the directory of its code assets when
/// the build hook bundled LiteRT-LM's companion there (`macos_companions:
/// code_assets`); null otherwise.
///
/// Told by what LiteRtLm itself links, not by which files are there: Dart
/// 3.12 and 3.13 copy `dart run`'s assets into `.dart_tool/lib/` and never
/// empty it, so a companion from an earlier build with the define stays
/// beside a LiteRtLm built without it, which links the companion's
/// framework. [assetDir] and [linkedBy] (the dylibs a library links, null
/// when it cannot be read) are for tests; by default the answer is read once
/// per isolate.
String? macOSCodeAssetDir({
  String? Function()? assetDir,
  List<String>? Function(String path)? linkedBy,
}) {
  if (assetDir == null && linkedBy == null) return _macOSCodeAssetDirOnce;
  final dir = assetDir != null ? assetDir() : nativeAssetDir;
  if (dir == null) return null;
  final linked = (linkedBy ?? machOLinkedDylibsOf)(
    '$dir/$macOSLiteRtLmAssetFile',
  );
  return linked != null && linksConstraintProviderCodeAsset(linked)
      ? dir
      : null;
}

final String? _macOSCodeAssetDirOnce = macOSCodeAssetDir(
  assetDir: () => nativeAssetDir,
);

/// Whether a LiteRtLm that links [dylibs] links the constraint provider as
/// a code asset: by its asset file name, as the Dart SDK rewrote it
/// (`<dir>/libLtGmcp.dylib` for `dart run`, `@rpath/lib/libLtGmcp.dylib` for
/// `dart build cli`), not as a Flutter app's framework.
bool linksConstraintProviderCodeAsset(List<String> dylibs) =>
    dylibs.any((d) => d.endsWith('/$macOSConstraintProviderAssetFile'));

/// The install names of the dylibs the 64-bit Mach-O file at [path] links
/// (`LC_LOAD_DYLIB`, weak and re-exported ones); null when it cannot be read
/// as one. Reads the header only.
List<String>? machOLinkedDylibsOf(String path) {
  final RandomAccessFile file;
  try {
    file = File(path).openSync();
  } on FileSystemException {
    return null;
  }
  try {
    final head = file.readSync(32);
    if (head.length < 32) return null;
    final sizeofcmds = ByteData.sublistView(head).getUint32(20, Endian.little);
    file.setPositionSync(0);
    return machOLinkedDylibs(file.readSync(32 + sizeofcmds));
  } on FileSystemException {
    return null;
  } finally {
    file.closeSync();
  }
}

/// The install names [bytes] (the start of a 64-bit little-endian Mach-O
/// file, its load commands included) links; null when it is not one.
List<String>? machOLinkedDylibs(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.little) != 0xfeedfacf) return null;
  final ncmds = data.getUint32(16, Endian.little);
  const lcLoadDylib = 0xc;
  const lcLoadWeakDylib = 0x80000018;
  const lcReexportDylib = 0x8000001f;
  final names = <String>[];
  var at = 32;
  for (var i = 0; i < ncmds; i++) {
    if (at + 8 > bytes.length) return null;
    final cmd = data.getUint32(at, Endian.little);
    final size = data.getUint32(at + 4, Endian.little);
    if (size < 8 || at + size > bytes.length) return null;
    if (cmd == lcLoadDylib ||
        cmd == lcLoadWeakDylib ||
        cmd == lcReexportDylib) {
      final offset = data.getUint32(at + 8, Endian.little);
      var end = at + offset;
      while (end < at + size && bytes[end] != 0) {
        end++;
      }
      names.add(String.fromCharCodes(bytes.sublist(at + offset, end)));
    }
    at += size;
  }
  return names;
}

/// The message for a plain Dart program on macOS whose build did not bundle
/// LiteRT-LM's companion as a code asset: it names the define that does.
String macOSPlainDartLoadErrorMessage() =>
    'litertlm_dart: LiteRT-LM did not load in this Dart program on macOS: '
    'its build bundled the companion library for a Flutter app. Outside '
    'Flutter (dart run, dart test, dart build cli) set, in the pubspec.yaml '
    'of the package you run (of the workspace root in a pub workspace):\n'
    '\n'
    'hooks:\n'
    '  user_defines:\n'
    '    litertlm_dart:\n'
    '      $macOSCompanionsDefine: $macOSCompanionsCodeAssets\n'
    '\n'
    'and run it again. `dart compile exe` runs no build hooks and cannot '
    'bundle LiteRT-LM; use `dart build cli`.';

/// The message for a code asset that is there and did not load.
String macOSCodeAssetLoadErrorMessage(String path, String dyldText) {
  final String fix = switch (diagnoseMacOSLoadError(dyldText)) {
    MacOSLoadCause.wrongArchitecture =>
      'LiteRT-LM ships for Apple silicon (arm64) only; it does not run on an '
          'Intel Mac or in an x86_64 (Rosetta) process.',
    MacOSLoadCause.blockedByPolicy =>
      'macOS refused the library by system policy (quarantine or '
          'notarization).',
    _ =>
      'Build the program again; if it still fails, please open an issue at '
          'https://github.com/DenisovAV/flutter_edge_ai/issues with the text '
          'below.',
  };
  return 'litertlm_dart: LiteRT-LM did not load from $path, where this Dart '
      "program's build put it. $fix\n"
      'dyld: $dyldText';
}

/// Why LiteRT-LM did not load on macOS, read from dyld's error text.
enum MacOSLoadCause {
  /// A companion library LiteRtLm links is not in the app.
  missingCompanion,

  /// The process is not arm64 (an Intel Mac, or Rosetta).
  wrongArchitecture,

  /// macOS refused the library by system policy (quarantine, notarization).
  blockedByPolicy,

  /// macOS library validation refused the library.
  libraryValidation,

  /// LiteRtLm.framework itself is not in the app.
  notBundled,

  /// Anything else.
  unknown,
}

/// Reads the cause from [dyldText], the error `DynamicLibrary.open` reports.
///
/// The phrases are dyld's, measured on macOS 26.5, except the policy and code
/// signature ones, which are Apple's documented text (every library
/// validation refusal says "not valid for use in process"). The order matters: a companion
/// that is refused or built for another architecture is also "Library not
/// loaded", and dyld lists "(no such file)" for the paths it tried on the way
/// in almost every failure, so [MacOSLoadCause.notBundled] needs the app's own
/// Frameworks path to be the one that is missing.
MacOSLoadCause diagnoseMacOSLoadError(String dyldText) {
  if (dyldText.contains('incompatible architecture')) {
    return MacOSLoadCause.wrongArchitecture;
  }
  if (dyldText.contains('disallowed by system policy')) {
    return MacOSLoadCause.blockedByPolicy;
  }
  if (dyldText.contains('not valid for use in process')) {
    return MacOSLoadCause.libraryValidation;
  }
  if (dyldText.contains('Library not loaded') &&
      dyldText.contains('GemmaModelConstraintProvider')) {
    return MacOSLoadCause.missingCompanion;
  }
  if (dyldText.contains(
    "Contents/Frameworks/$macOSLiteRtLmFramework' (no such file",
  )) {
    return MacOSLoadCause.notBundled;
  }
  return MacOSLoadCause.unknown;
}

/// The message for a failed load in a macOS app: what broke, the cause and
/// its fix, then dyld's own text.
String macOSLoadErrorMessage(String dyldText) {
  final String fix = switch (diagnoseMacOSLoadError(dyldText)) {
    MacOSLoadCause.missingCompanion =>
      "LiteRT-LM's companion libraries are not in the app: "
          'GemmaModelConstraintProvider.framework and '
          'LiteRtLmMetalAccelerator.framework must be embedded in its '
          'Frameworks (xcframework zips on the native-v* release this build '
          'uses); the build hook does not embed them yet. Where a Swift '
          "package embeds them (Swift Package Manager on, Flutter's "
          'default), this is a stale build: run `flutter clean` and build '
          'again. With `enable-swift-package-manager: false`, the '
          'post_install block in macos/Podfile copies them: replace the '
          'existing post_install block with the one from '
          'https://flutteredge.ai/docs/desktop#macos (a second post_install '
          'block fails `pod install`), keeping any lines of your own inside '
          'it, then run `flutter clean` and build again.',
    MacOSLoadCause.wrongArchitecture =>
      'LiteRT-LM ships for Apple silicon (arm64) only; it does not run on an '
          'Intel Mac or in an x86_64 (Rosetta) process.',
    MacOSLoadCause.blockedByPolicy =>
      'macOS refused the library by system policy: the app or the library is '
          'quarantined or not notarized. Notarize the app; for a local test '
          'build, remove the quarantine attribute with '
          '`xattr -dr com.apple.quarantine` on the app.',
    MacOSLoadCause.libraryValidation =>
      'macOS library validation refused the library. Sign the app and its '
          'frameworks with the same team, or add the '
          'com.apple.security.cs.disable-library-validation entitlement.',
    MacOSLoadCause.notBundled =>
      'LiteRtLm.framework is not in the app. Run `flutter clean` and build '
          "again; litertlm_dart's build hook bundles it.",
    MacOSLoadCause.unknown =>
      'Run `flutter clean` and build again. If it still fails, please open an '
          'issue at https://github.com/DenisovAV/flutter_edge_ai/issues with the '
          'text below.',
  };
  return 'litertlm_dart: LiteRT-LM did not load on macOS, so no '
      'LiteRT feature works in this app (LLM, embeddings, speech). $fix\n'
      'dyld: $dyldText';
}

/// dyld's text from what `DynamicLibrary.open` threw.
String dyldErrorText(Object error) =>
    error is ArgumentError ? '${error.message ?? error}' : '$error';

/// Opens LiteRtLm.framework in a macOS app, for the LLM and EmbeddingGemma 2;
/// in a plain Dart program ([outsideFlutter]) the code asset in
/// [codeAssetDir] ([macOSCodeAssetDir]).
///
/// A failure is an [ArgumentError], as from `DynamicLibrary.open`, so the
/// backend fallback (which retries on an [Exception] only) does not turn it
/// into a CPU attempt. Its message is [macOSLoadErrorMessage] in an app; in a
/// plain Dart program [macOSPlainDartLoadErrorMessage] when there is no code
/// asset to open, [macOSCodeAssetLoadErrorMessage] when it did not load.
/// [open], [outsideFlutter] and [codeAssetDir] are for tests.
DynamicLibrary openMacOSLiteRtLm({
  DynamicLibrary Function(String path)? open,
  bool outsideFlutter = liteRtLmOutsideFlutter,
  String? Function()? codeAssetDir,
}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
  if (outsideFlutter) {
    final dir = (codeAssetDir ?? macOSCodeAssetDir)();
    if (dir == null) throw ArgumentError(macOSPlainDartLoadErrorMessage());
    final path = '$dir/$macOSLiteRtLmAssetFile';
    try {
      return opener(path);
    } on ArgumentError catch (error, stackTrace) {
      Error.throwWithStackTrace(
        ArgumentError(
          macOSCodeAssetLoadErrorMessage(path, dyldErrorText(error)),
        ),
        stackTrace,
      );
    }
  }
  try {
    return opener(macOSLiteRtLmFramework);
  } on ArgumentError catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ArgumentError(macOSLoadErrorMessage(dyldErrorText(error))),
      stackTrace,
    );
  }
}

/// Opens libLiteRtLm on macOS for the `.tflite` path (embeddings, speech).
///
/// LiteRtLm.framework first. Inside an app that is the only place it may come
/// from: a copy from the build cache or a dev checkout may be any version, and
/// makes an app that is broken for its users work on the developer's Mac.
/// Outside one (the macOS host test suites) the copies [devCandidates] names
/// are tried next, the build hook's cache among them.
///
/// A dev copy that loads but fails [isOwnBuild] is skipped like one that does
/// not load, and named in the failure. The framework is returned without it:
/// the caller refuses a foreign framework itself, so it is never skipped for
/// a dev copy.
///
/// A failure is an [UnsupportedError]: inside an app its message is
/// [macOSLoadErrorMessage]; outside one it names each copy that exists with
/// dyld's reason, because there the framework is never present and its error
/// says nothing. Any other error goes through unchanged.
///
/// In a plain Dart program ([outsideFlutter]) whose build bundled the
/// companion as a code asset, the code asset is opened, and nothing else is
/// tried ([openMacOSLiteRtLm]); without one the order above runs, and its
/// failure also names the define that bundles it. [executable], [open],
/// [exists], [outsideFlutter] and [codeAssetDir] are for tests.
DynamicLibrary openMacOSLiteRtLmForTflite({
  required List<String> Function() devCandidates,
  bool Function(DynamicLibrary library)? isOwnBuild,
  String? executable,
  DynamicLibrary Function(String path)? open,
  bool Function(String path)? exists,
  bool outsideFlutter = liteRtLmOutsideFlutter,
  String? Function()? codeAssetDir,
}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
  if (outsideFlutter) {
    final dir = (codeAssetDir ?? macOSCodeAssetDir)();
    if (dir != null) {
      try {
        return openMacOSLiteRtLm(
          open: opener,
          outsideFlutter: true,
          codeAssetDir: () => dir,
        );
      } on ArgumentError catch (error) {
        throw UnsupportedError('${error.message}');
      }
    }
  }
  final String bundledError;
  try {
    return opener(macOSLiteRtLmFramework);
  } on ArgumentError catch (error) {
    bundledError = dyldErrorText(error);
  }
  if ((executable ?? Platform.resolvedExecutable).contains(
    '.app/Contents/MacOS/',
  )) {
    throw UnsupportedError(macOSLoadErrorMessage(bundledError));
  }

  final bool Function(String path) fileExists =
      exists ?? (path) => File(path).existsSync();
  final missing = <String>[];
  final failed = <String>[];
  for (final path in devCandidates()) {
    if (!fileExists(path)) {
      missing.add(path);
      continue;
    }
    final DynamicLibrary library;
    try {
      library = opener(path);
    } on ArgumentError catch (error) {
      // Keep going: a copy that exists but does not load (wrong arch, a
      // missing companion, a stale build) must not hide a later one that
      // does, the build hook's cache included.
      failed.add('$path: ${dyldErrorText(error)}');
      continue;
    }
    if (isOwnBuild != null && !isOwnBuild(library)) {
      failed.add(
        '$path: loads, but is not a litertlm_dart build on '
        'LiteRT-LM C API 1.x',
      );
      continue;
    }
    return library;
  }
  throw UnsupportedError(
    'litertlm_dart: LiteRT-LM did not load. Outside an app it is loaded from '
    "a local prebuilt or from litertlm_dart's build hook cache, which a build "
    'or a test run of a package that depends on it fills. '
    '${failed.isEmpty ? 'No copy exists.' : 'These copies did not load:\n${failed.join('\n')}'}'
    '${missing.isEmpty ? '' : '\nNot found: ${missing.join(', ')}'}'
    '\n$macOSLiteRtLmFramework: $bundledError'
    '${outsideFlutter ? '\n\n${macOSPlainDartLoadErrorMessage()}' : ''}',
  );
}

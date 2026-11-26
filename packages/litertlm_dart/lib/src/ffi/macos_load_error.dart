// Opens LiteRT-LM on macOS and, when it does not load, says why and what fixes
// it (#689).
//
// dyld's own error names the cause, but in words that do not say what to do.
// The LLM and EmbeddingGemma 2 paths open the framework with
// [openMacOSLiteRtLm], the `.tflite` path (embeddings, speech) with
// [openMacOSLiteRtLmForTflite]. Both build their message here, so every path
// says the same thing, and dyld's text is kept.
//
// A plain Dart program (`dart run`, `dart test`, `dart build cli`) has no
// app: there LiteRtLm is a code asset, in the directory [nativeAssetLookup]
// finds. From native-v0.20.0 LiteRtLm links no companion library on macOS
// (the Gemma constraint provider is gone, patch_c_api.sh section 29; the
// Metal accelerator is linked in), so a plain Dart program needs no define
// and a Flutter app's build bundles the same files.
//
// Package-private.

import 'dart:ffi';
import 'dart:io';

import 'package:meta/meta.dart' show visibleForTesting;

import '../runtime/macho.dart';
import 'native_asset_dir.dart';

/// The macOS LiteRT-LM framework, as Native Assets bundles it in an app.
const macOSLiteRtLmFramework = 'LiteRtLm.framework/LiteRtLm';

/// The file names of LiteRtLm and StreamProxy among a plain Dart program's
/// code assets on macOS ([codeAssetFileName]).
final macOSLiteRtLmAssetFile = codeAssetFileName('LiteRtLm', os: 'macos');
final macOSStreamProxyAssetFile = codeAssetFileName('StreamProxy', os: 'macos');

/// What a plain Dart program on macOS has to load LiteRT-LM from.
sealed class MacOSCodeAssets {
  const MacOSCodeAssets();
}

/// No code assets of this package ([lookup] says why: `dart compile exe`,
/// a StreamProxy that did not load, another copy).
final class MacOSNoCodeAssets extends MacOSCodeAssets {
  const MacOSNoCodeAssets(this.lookup);
  final NativeAssetLookup lookup;
}

/// The code assets in [dir], LiteRtLm among them.
final class MacOSPlainDartAssets extends MacOSCodeAssets {
  const MacOSPlainDartAssets(this.dir);
  final String dir;
}

/// The LiteRtLm in [dir] links Google's Gemma constraint provider
/// ([provider], its install name there): a build of a native release before
/// native-v0.20.0, which shipped the provider beside it. This release ships
/// none, so it would not load.
final class MacOSOlderBuildAssets extends MacOSCodeAssets {
  const MacOSOlderBuildAssets(this.dir, this.provider);
  final String dir;
  final String provider;
}

/// LiteRtLm in [dir] could not be read to tell ([reason]).
final class MacOSUnreadableAssets extends MacOSCodeAssets {
  const MacOSUnreadableAssets(this.dir, this.reason);
  final String dir;
  final String reason;
}

/// What this plain Dart program has ([macOSCodeAssets]), read once per
/// isolate.
MacOSCodeAssets get macOSCodeAssetsHere => _macOSCodeAssetsOnce;

final MacOSCodeAssets _macOSCodeAssetsOnce = macOSCodeAssets();

/// What a plain Dart program on macOS has to load LiteRT-LM from. A LiteRtLm
/// that links the Gemma constraint provider (any form: Google's
/// `@rpath/libGemmaModelConstraintProvider.dylib`, a Flutter app's
/// framework, the `libLtGmcp.dylib` code asset of litertlm_dart 0.19.1+4) is
/// told apart, because Dart 3.12 and 3.13 copy `dart run`'s assets into
/// `.dart_tool/lib/` and an older build can stay there. [lookup] and
/// [linkedBy] (the dylibs a file links; throws a [FormatException] or a
/// [FileSystemException] when it cannot tell) are for tests.
MacOSCodeAssets macOSCodeAssets({
  NativeAssetLookup Function()? lookup,
  List<String> Function(String path)? linkedBy,
}) {
  final found = (lookup ?? () => nativeAssetLookup)();
  if (found is! NativeAssetsFound) return MacOSNoCodeAssets(found);
  final dir = found.dir;
  final List<String> linked;
  try {
    linked = (linkedBy ?? machOLinkedDylibsOf)('$dir/$macOSLiteRtLmAssetFile');
  } on FormatException catch (e) {
    return MacOSUnreadableAssets(dir, e.message);
  } on FileSystemException catch (e) {
    return MacOSUnreadableAssets(dir, '${e.message}: ${e.osError ?? e.path}');
  }
  for (final dylib in linked) {
    if (linksConstraintProvider(dylib)) {
      return MacOSOlderBuildAssets(dir, dylib);
    }
  }
  return MacOSPlainDartAssets(dir);
}

/// Whether [installName], one dylib a LiteRtLm links, is the Gemma constraint
/// provider in any of the forms a release before native-v0.20.0 gave it.
bool linksConstraintProvider(String installName) =>
    installName.contains('GemmaModelConstraintProvider') ||
    installName.endsWith('/libLtGmcp.dylib') ||
    installName.contains('/LtGmcp.framework/');

/// What a plain Dart program is told when [assets] has nothing to load
/// LiteRT-LM from; null for [MacOSPlainDartAssets].
String? macOSCodeAssetsRefusal(MacOSCodeAssets assets) => switch (assets) {
  MacOSPlainDartAssets() => null,
  MacOSNoCodeAssets(:final lookup) => plainDartAssetsMessage(lookup),
  MacOSOlderBuildAssets(:final dir, :final provider) =>
    'litertlm_dart: $dir/$macOSLiteRtLmAssetFile, where this Dart '
        "program's build put LiteRT-LM, links Google's Gemma constraint "
        'provider ($provider): it is a build of a native release before '
        'native-v0.20.0, and this release ships no provider. Build the '
        'program again.',
  MacOSUnreadableAssets(:final dir, :final reason) =>
    'litertlm_dart: $dir/$macOSLiteRtLmAssetFile, where this Dart '
        "program's build put LiteRT-LM, is not one this release can tell "
        'the build of ($reason). Build the program again.',
};

/// The install names of the dylibs the 64-bit Mach-O file at [path] links
/// ([machOLinkedDylibs]), reading its header and load commands only. Throws
/// a [FileSystemException] when it cannot be read, a [FormatException] when
/// it is not a well-formed 64-bit Mach-O.
List<String> machOLinkedDylibsOf(String path) {
  final file = File(path).openSync();
  try {
    final length = machOHeaderAndCommandsLength(file.readSync(machOHeaderSize));
    file.setPositionSync(0);
    return machOLinkedDylibs(file.readSync(length));
  } finally {
    file.closeSync();
  }
}

/// The path the macOS opener opened LiteRtLm by, for the own-build check's
/// message: the code asset's full path in a plain Dart program, else the
/// framework.
String macOSLiteRtLmOpenedPath({
  bool outsideFlutter = liteRtLmOutsideFlutter,
}) => switch (outsideFlutter ? macOSCodeAssetsHere : null) {
  MacOSPlainDartAssets(:final dir) => '$dir/$macOSLiteRtLmAssetFile',
  _ => macOSLiteRtLmFramework,
};

/// Lets this package's own macOS host tests, when the program has no code
/// asset of LiteRtLm to open, open the `.tflite` path's host copies (the
/// hook's cache, a local prebuilt) as a Flutter test does. Off in every
/// program: there a copy from the cache works on the developer's Mac only.
@visibleForTesting
bool debugUseHostLiteRtLmCopies = false;

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
/// validation refusal says "not valid for use in process"). The order
/// matters: dyld lists "(no such file)" for the paths it tried on the way in
/// almost every failure, so [MacOSLoadCause.notBundled] needs the app's own
/// Frameworks path to be the one that is missing. LiteRtLm links no companion
/// library from native-v0.20.0; a "Library not loaded" naming one (a stale
/// build of an older release) is [MacOSLoadCause.unknown], whose advice is a
/// clean build.
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
/// in a plain Dart program ([outsideFlutter]) the code asset [codeAssets]
/// names ([macOSCodeAssetsHere]).
///
/// A failure is an [ArgumentError], as from `DynamicLibrary.open`, so the
/// backend fallback (which retries on an [Exception] only) does not turn it
/// into a CPU attempt. Its message is [macOSLoadErrorMessage] in an app; in a
/// plain Dart program [macOSCodeAssetsRefusal] when there is no code asset to
/// open, [macOSCodeAssetLoadErrorMessage] when it did not load. [open],
/// [outsideFlutter] and [codeAssets] are for tests.
DynamicLibrary openMacOSLiteRtLm({
  DynamicLibrary Function(String path)? open,
  bool outsideFlutter = liteRtLmOutsideFlutter,
  MacOSCodeAssets Function()? codeAssets,
}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
  if (outsideFlutter) {
    final assets = (codeAssets ?? () => macOSCodeAssetsHere)();
    final dir = switch (assets) {
      MacOSPlainDartAssets(:final dir) => dir,
      _ => throw ArgumentError(macOSCodeAssetsRefusal(assets)),
    };
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
/// In a plain Dart program ([outsideFlutter]) the code asset is opened when
/// there is one, and nothing else is tried ([openMacOSLiteRtLm]); without one
/// it is refused naming why ([macOSCodeAssetsRefusal]), and the order above
/// runs only for this package's own host tests ([allowHostCopies]).
/// [executable], [open], [exists], [outsideFlutter], [codeAssets] and
/// [allowHostCopies] are for tests.
DynamicLibrary openMacOSLiteRtLmForTflite({
  required List<String> Function() devCandidates,
  bool Function(DynamicLibrary library)? isOwnBuild,
  String? executable,
  DynamicLibrary Function(String path)? open,
  bool Function(String path)? exists,
  bool outsideFlutter = liteRtLmOutsideFlutter,
  MacOSCodeAssets Function()? codeAssets,
  bool? allowHostCopies,
}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
  String? plainDartRefusal;
  if (outsideFlutter) {
    final assets = (codeAssets ?? () => macOSCodeAssetsHere)();
    if (assets is MacOSPlainDartAssets) {
      try {
        return openMacOSLiteRtLm(
          open: opener,
          outsideFlutter: true,
          codeAssets: () => assets,
        );
      } on ArgumentError catch (error, stack) {
        Error.throwWithStackTrace(UnsupportedError('${error.message}'), stack);
      }
    }
    plainDartRefusal = macOSCodeAssetsRefusal(assets);
    if (!(allowHostCopies ?? debugUseHostLiteRtLmCopies)) {
      throw UnsupportedError(plainDartRefusal!);
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
      // stale build) must not hide a later one that does, the build hook's
      // cache included.
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
    '${plainDartRefusal == null ? '' : '\n\n$plainDartRefusal'}',
  );
}

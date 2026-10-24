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
// Package-private.

import 'dart:ffi';
import 'dart:io';

/// The macOS LiteRT-LM framework, as Native Assets bundles it in an app.
const macOSLiteRtLmFramework = 'LiteRtLm.framework/LiteRtLm';

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
      "LiteRT-LM's companion libraries are not in the app. With Swift Package "
          "Manager on (Flutter's default), flutter_edge_ai_litertlm's Swift "
          'package embeds them: run `flutter clean` and build again. With '
          '`enable-swift-package-manager: false`, the post_install block in '
          'macos/Podfile copies them: replace the post_install block with the '
          'one from https://flutteredge.ai/docs/desktop#macos, keeping any '
          'lines of your own inside it, then run `flutter clean` and build '
          'again.',
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
          'again; the flutter_edge_ai_litertlm build hook bundles it.',
    MacOSLoadCause.unknown =>
      'Run `flutter clean` and build again. If it still fails, please open an '
          'issue at https://github.com/DenisovAV/flutter_edge_ai/issues with the '
          'text below.',
  };
  return 'flutter_edge_ai_litertlm: LiteRT-LM did not load on macOS, so no '
      'LiteRT feature works in this app (LLM, embeddings, speech). $fix\n'
      'dyld: $dyldText';
}

/// dyld's text from what `DynamicLibrary.open` threw.
String dyldErrorText(Object error) =>
    error is ArgumentError ? '${error.message ?? error}' : '$error';

/// Opens LiteRtLm.framework in a macOS app, for the LLM and EmbeddingGemma 2.
///
/// A failure is an [ArgumentError], as from `DynamicLibrary.open`, so the
/// backend fallback (which retries on an [Exception] only) does not turn it
/// into a CPU attempt. Its message is [macOSLoadErrorMessage]. [open] is for
/// tests.
DynamicLibrary openMacOSLiteRtLm({DynamicLibrary Function(String path)? open}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
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
/// A failure is an [UnsupportedError]: inside an app its message is
/// [macOSLoadErrorMessage]; outside one it names each copy that exists with
/// dyld's reason, because there the framework is never present and its error
/// says nothing. Any other error goes through unchanged. [executable],
/// [open] and [exists] are for tests.
DynamicLibrary openMacOSLiteRtLmForTflite({
  required List<String> Function() devCandidates,
  String? executable,
  DynamicLibrary Function(String path)? open,
  bool Function(String path)? exists,
}) {
  final DynamicLibrary Function(String path) opener =
      open ?? DynamicLibrary.open;
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
    try {
      return opener(path);
    } on ArgumentError catch (error) {
      // Keep going: a copy that exists but does not load (wrong arch, a
      // missing companion, a stale build) must not hide a later one that
      // does, the build hook's cache included.
      failed.add('$path: ${dyldErrorText(error)}');
    }
  }
  throw UnsupportedError(
    'flutter_edge_ai_litertlm: LiteRT-LM did not load. Outside an app it is '
    'loaded from a local prebuilt or from the flutter_edge_ai_litertlm build '
    "hook's cache, which a build or `flutter test` of a package that depends "
    'on it fills. '
    '${failed.isEmpty ? 'No copy exists.' : 'These copies did not load:\n${failed.join('\n')}'}'
    '${missing.isEmpty ? '' : '\nNot found: ${missing.join(', ')}'}'
    '\n$macOSLiteRtLmFramework: $bundledError',
  );
}

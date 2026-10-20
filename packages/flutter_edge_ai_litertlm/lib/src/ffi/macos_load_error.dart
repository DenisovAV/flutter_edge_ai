// Says why libLiteRtLm did not load in a macOS app, and what fixes it (#689).
//
// dyld's own error names the cause, but in words that do not say what to do:
// "Library not loaded: @rpath/libGemmaModelConstraintProvider.dylib" is what a
// Swift Package Manager app shows, because nothing copies LiteRT-LM's
// companion libraries into it. Every macOS open of LiteRtLm.framework goes
// through this file, so the LLM, the EmbeddingGemma 2 pass and the `.tflite`
// path (embeddings, speech) say the same thing, and dyld's text is kept.
//
// Package-private.

import 'dart:ffi';

/// The macOS LiteRT-LM framework, as Native Assets bundles it in an app.
const macOSLiteRtLmFramework = 'LiteRtLm.framework/LiteRtLm';

/// Why LiteRT-LM did not load on macOS, read from dyld's error text.
enum MacOSLoadCause {
  /// A companion library LiteRtLm links is not in the app.
  missingCompanion,

  /// The process is not arm64 (an Intel Mac, or Rosetta).
  wrongArchitecture,

  /// macOS library validation refused the library.
  libraryValidation,

  /// LiteRtLm.framework itself is not in the app.
  notBundled,

  /// Anything else.
  unknown,
}

/// Reads the cause from [dyldText], the error `DynamicLibrary.open` reports.
///
/// The phrases are dyld's (measured on macOS 26.5, except the Team ID one,
/// which is Apple's documented text). Architecture is checked before
/// [MacOSLoadCause.notBundled] because its text also lists paths that do not
/// exist.
MacOSLoadCause diagnoseMacOSLoadError(String dyldText) {
  if (dyldText.contains('Library not loaded') &&
      dyldText.contains('GemmaModelConstraintProvider')) {
    return MacOSLoadCause.missingCompanion;
  }
  if (dyldText.contains('incompatible architecture')) {
    return MacOSLoadCause.wrongArchitecture;
  }
  if (dyldText.contains('different Team IDs') ||
      dyldText.contains('not valid for use in process')) {
    return MacOSLoadCause.libraryValidation;
  }
  if (!dyldText.contains('Library not loaded') &&
      dyldText.contains("$macOSLiteRtLmFramework' (no such file")) {
    return MacOSLoadCause.notBundled;
  }
  return MacOSLoadCause.unknown;
}

/// The message for a failed macOS load: what broke, the cause and its fix,
/// then dyld's own text.
String macOSLoadErrorMessage(String dyldText) {
  final String fix = switch (diagnoseMacOSLoadError(dyldText)) {
    MacOSLoadCause.missingCompanion =>
      'Flutter 3.44 and later build macOS apps with Swift Package Manager, '
          "and nothing copied LiteRT-LM's companion libraries into the app "
          '(https://github.com/DenisovAV/flutter_edge_ai/issues/689). Until '
          'that is fixed, set `enable-swift-package-manager: false` under '
          "`flutter: config:` in the app's pubspec.yaml, run `flutter pub get`, "
          'paste the post_install block from '
          'https://flutteredge.ai/docs/desktop#macos into macos/Podfile, and '
          'build again. An app that already has a macos/Podfile keeps Swift '
          'Package Manager on and only needs the block.',
    MacOSLoadCause.wrongArchitecture =>
      'LiteRT-LM ships for Apple silicon (arm64) only; it does not run on an '
          'Intel Mac or in an x86_64 (Rosetta) process.',
    MacOSLoadCause.libraryValidation =>
      'macOS library validation refused the library. Sign the app and its '
          'frameworks with the same team, or add the '
          'com.apple.security.cs.disable-library-validation entitlement.',
    MacOSLoadCause.notBundled =>
      'LiteRtLm.framework is not in the app. Run `flutter clean` and build '
          'again; the flutter_edge_ai_litertlm build hook bundles it.',
    MacOSLoadCause.unknown =>
      'If the text below does not say why, please open an issue at '
          'https://github.com/DenisovAV/flutter_edge_ai/issues with it.',
  };
  return 'flutter_edge_ai_litertlm: LiteRT-LM did not load on macOS, so no '
      'LiteRT feature works in this app (LLM, embeddings, speech). $fix\n'
      'dyld: $dyldText';
}

/// dyld's text from what `DynamicLibrary.open` threw.
String dyldErrorText(Object error) =>
    error is ArgumentError ? '${error.message}' : '$error';

/// Opens LiteRtLm.framework in a macOS app.
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

/// Whether [executable] runs from inside a macOS `.app` bundle.
///
/// Inside one, LiteRT-LM must come from the bundle: a copy from the build
/// cache or a dev checkout may be any version, and makes an app that is broken
/// for its users work on the developer's Mac.
bool isInsideMacOSAppBundle(String executable) =>
    executable.contains('.app/Contents/MacOS/');

/// The copies of libLiteRtLm to try when LiteRtLm.framework did not load:
/// none inside an app ([isInsideMacOSAppBundle]), [devCandidates] outside one
/// (the macOS host test suites load the hook's cache copy this way).
List<String> macOSFallbackCandidates({
  required String executable,
  required List<String> Function() devCandidates,
}) => isInsideMacOSAppBundle(executable) ? const <String>[] : devCandidates();

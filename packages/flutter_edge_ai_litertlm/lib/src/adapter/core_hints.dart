// litertlm_dart words its errors in its own API (`Backend.cpu()`,
// `visionBackend: null`): an app on flutter_edge_ai sets neither. Where the
// adapter hands such an error on, it adds one line in core's terms
// ([withCoreHint]); the runtime's own text is kept as it is.

import 'package:litertlm_dart/internal.dart'
    show
        EmbedderEngineException,
        EmbedderInputTooLongException,
        EmbedderLoadException,
        LiteRtLmBundleException,
        LiteRtLmEngineCreateException,
        NpuDispatchUnavailableException;
import 'package:litertlm_dart/litertlm_dart.dart' show LiteRtLmNativeException;

import '../litert_lm_load_errors.dart';

final _backend = RegExp(r'Backend\.(cpu|gpu|npu)\(\)');

/// The line in core's terms for [message], a litertlm_dart error text; null
/// when it names nothing of litertlm_dart's API that core words otherwise.
String? coreHintFor(String message) {
  final hints = <String>[];
  final backends = {
    for (final match in _backend.allMatches(message)) match.group(1)!,
  };
  if (backends.isNotEmpty) {
    hints.add(
      'preferredBackend: '
      '${backends.map((b) => 'PreferredBackend.$b').join(' or ')}, or none',
    );
  }
  final encoders = [
    if (message.contains('visionBackend: null')) 'supportImage',
    if (message.contains('audioBackend: null')) 'supportAudio',
  ];
  if (encoders.isNotEmpty) hints.add('without ${encoders.join(' or ')}');
  if (message.contains('arm64-v8a Android device')) {
    hints.add('a MediaPipe `.task` model still runs text on this ABI');
  }
  if (message.contains('LiteRtLmLog.nativeLevel')) {
    hints.add('LiteRtLmEngine(nativeLogLevel: LiteRtLmLogLevel.verbose)');
  }
  if (message.contains("companion libraries are not in the app")) {
    // With Swift Package Manager on, the Swift package brings them, so a
    // missing one is a stale build (#689); Flutter's generated Podfile has a
    // post_install already, and a second one fails `pod install`.
    hints.add(
      "with Swift Package Manager on (Flutter's default), "
      "flutter_edge_ai_litertlm's Swift package embeds them: run `flutter "
      'clean` and build again; with `enable-swift-package-manager: false`, '
      'replace the post_install block in macos/Podfile with the one from '
      'https://flutteredge.ai/docs/desktop#macos, keeping any lines of your '
      'own inside it, then run `flutter clean` and build again',
    );
  }
  if (hints.isEmpty) return null;
  return 'In flutter_edge_ai: ${hints.join('; ')}.';
}

/// [message] with its line in core's terms ([coreHintFor]) after it.
String withCoreHint(String message) {
  final hint = coreHintFor(message);
  return hint == null ? message : '$message\n$hint';
}

/// [error] with its message in core's terms too, as the same type; any other
/// error as it is.
Object withCoreHintError(Object error) => switch (error) {
  BackendInitException(:final attempts) => BackendInitException(
    attempts: [
      for (final attempt in attempts)
        BackendInitAttemptFailure(
          backend: attempt.backend,
          error: withCoreHintError(attempt.error),
          stackTrace: attempt.stackTrace,
        ),
    ],
  ),
  LiteRtLmBundleException(:final problem, :final message, :final path)
      when coreHintFor(message) != null =>
    LiteRtLmBundleException(problem, withCoreHint(message), path: path),
  LiteRtLmEngineCreateException(
    :final message,
    :final nativeCode,
    :final nativeMessage,
  )
      when coreHintFor(message) != null =>
    LiteRtLmEngineCreateException(
      withCoreHint(message),
      nativeCode: nativeCode,
      nativeMessage: nativeMessage,
    ),
  NpuDispatchUnavailableException(:final message)
      when coreHintFor(message) != null =>
    NpuDispatchUnavailableException(withCoreHint(message)),
  LiteRtLmNativeException(:final message) when coreHintFor(message) != null =>
    LiteRtLmNativeException(withCoreHint(message)),
  EmbedderLoadException(:final message, :final nativeCode, :final cause)
      when coreHintFor(message) != null =>
    EmbedderLoadException(
      withCoreHint(message),
      nativeCode: nativeCode,
      cause: cause,
    ),
  EmbedderEngineException(:final message, :final nativeCode, :final cause)
      when coreHintFor(message) != null =>
    EmbedderEngineException(
      withCoreHint(message),
      nativeCode: nativeCode,
      cause: cause,
    ),
  UnsupportedError(:final message?) when coreHintFor(message) != null =>
    UnsupportedError(withCoreHint(message)),
  ArgumentError(:final message, :final name)
      when message is String && coreHintFor(message) != null =>
    ArgumentError(withCoreHint(message), name),
  EmbedderInputTooLongException() => error,
  _ => error,
};

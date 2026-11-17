// The runtime's load failures an app catches. The Flutter adapter re-exports
// both unchanged (litert_lm_load_errors.dart), so `on X catch` keeps working.

import 'errors.dart';

/// The NPU cannot be reached on this device: no dispatch stack in the build,
/// no Qualcomm FastRPC or DSP on the device, or a dispatch directory that
/// could not be prepared. [message] says which.
final class NpuDispatchUnavailableException extends LiteRtLmException {
  const NpuDispatchUnavailableException(super.message);

  @override
  String toString() => 'NpuDispatchUnavailableException: $message';
}

/// LiteRT-LM's `engine_settings_create` or `engine_create` returned NULL for a
/// backend.
final class LiteRtLmEngineCreateException extends LiteRtLmException {
  const LiteRtLmEngineCreateException(
    super.message, {
    this.nativeCode,
    this.nativeMessage,
  });

  /// What failed and, when known, what to try.

  /// The status code LiteRT-LM reported for the failed settings create or
  /// engine create (its C API's last error), or null when it reported none.
  final int? nativeCode;

  /// LiteRT-LM's own message for the failed create, e.g. "Main backend
  /// constraint mismatch. Model requires one of [npu] but Main backend is
  /// gpu", or null when it reported none.
  final String? nativeMessage;

  @override
  String toString() => 'LiteRtLmEngineCreateException: $message';
}

/// libLiteRtLm, or a library it needs, did not load, or it is not a build
/// this release drives (another C API, a library that is not this package's
/// patched build). [message] says which and how to fix it.
final class LiteRtLmLibraryException extends LiteRtLmException {
  const LiteRtLmLibraryException(super.message);

  @override
  String toString() => 'LiteRtLmLibraryException: $message';
}

/// An error thrown while libLiteRtLm, or a library it needs, loads or is
/// checked: what `Engine.create` reports as a [LiteRtLmLibraryException].
/// Each keeps the type the load threw (the Flutter adapter's backend fallback
/// tells an Exception from an Error), so this marks it instead of replacing
/// it.
abstract interface class LibraryLoadFailure {
  /// What failed and how to fix it.
  String get loadMessage;
}

final class LibraryLoadArgumentError extends ArgumentError
    implements LibraryLoadFailure {
  LibraryLoadArgumentError(String super.message);

  @override
  String get loadMessage => '$message';

  @override
  String toString() => '$message';
}

final class LibraryLoadStateError extends StateError
    implements LibraryLoadFailure {
  LibraryLoadStateError(super.message);

  @override
  String get loadMessage => message;
}

final class LibraryLoadUnsupportedError extends UnsupportedError
    implements LibraryLoadFailure {
  LibraryLoadUnsupportedError(super.message);

  @override
  String get loadMessage => message ?? '';
}

final class LibraryLoadFailedException
    implements Exception, LibraryLoadFailure {
  const LibraryLoadFailedException(this.loadMessage);

  @override
  final String loadMessage;

  @override
  String toString() => loadMessage;
}

/// [error], thrown while a library loaded, marked as a [LibraryLoadFailure]
/// of the same kind; anything else (an [Error] that is no load failure) as it
/// is.
Object markLibraryLoadFailure(Object error) => switch (error) {
  LibraryLoadFailure() => error,
  ArgumentError(:final message) => LibraryLoadArgumentError('$message'),
  StateError(:final message) => LibraryLoadStateError(message),
  UnsupportedError(:final message) => LibraryLoadUnsupportedError(
    message ?? '$error',
  ),
  Exception() => LibraryLoadFailedException('$error'),
  _ => error,
};

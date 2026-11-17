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

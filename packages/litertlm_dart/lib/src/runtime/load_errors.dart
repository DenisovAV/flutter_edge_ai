// The runtime's load failures an app catches. The Flutter adapter re-exports
// both unchanged (litert_lm_load_errors.dart), so `on X catch` keeps working.

/// The NPU cannot be reached on this device: no dispatch stack in the build,
/// no Qualcomm FastRPC or DSP on the device, or a dispatch directory that
/// could not be prepared. [message] says which.
class NpuDispatchUnavailableException implements Exception {
  const NpuDispatchUnavailableException(this.message);

  final String message;

  @override
  String toString() => 'NpuDispatchUnavailableException: $message';
}

/// LiteRT-LM's `engine_settings_create` or `engine_create` returned NULL for a
/// backend.
class LiteRtLmEngineCreateException implements Exception {
  const LiteRtLmEngineCreateException(
    this.message, {
    this.nativeCode,
    this.nativeMessage,
  });

  /// What failed and, when known, what to try.
  final String message;

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

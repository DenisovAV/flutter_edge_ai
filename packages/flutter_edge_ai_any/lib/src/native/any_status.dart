// The status codes of any_shim.h and the exception a failed call raises.
// Pure Dart (no dart:ffi), so the provider logic and the in-memory fake
// share them with the FFI wrapper, and the web build compiles them.

/// The status codes of any_shim.h, by value.
enum AnyShimStatus {
  ok(0),
  invalidArgument(1),
  notFound(2),
  deleted(3),
  closed(4),
  timeout(5),
  refused(6),
  internal(7),
  panic(8),
  conflict(9),
  corrupt(10),
  keyMismatch(11),
  busy(12),
  pending(13),
  keyMissing(14),
  io(15);

  const AnyShimStatus(this.code);
  final int code;

  /// A code this enum does not know (a newer library) maps to [internal]
  /// for branching; the raw value stays on [AnyShimException.code].
  static AnyShimStatus of(int code) =>
      code >= 0 && code < values.length ? values[code] : AnyShimStatus.internal;
}

/// A call that returned a status other than ANY_SHIM_OK.
///
/// Sendable between isolates (plain fields only): the worker isolates throw
/// it and the caller's isolate receives the same object.
class AnyShimException implements Exception {
  AnyShimException(this.operation, this.code, this.message);

  /// The C function that failed, e.g. `any_shim_object_patch`.
  final String operation;

  /// The raw status code.
  final int code;

  /// The library's message; for people, not for branching.
  final String message;

  AnyShimStatus get status => AnyShimStatus.of(code);

  @override
  String toString() =>
      'AnyShimException($operation: ${status.name} [$code]): $message';
}

/// The library does not implement the ABI these bindings were written for.
class AnyShimAbiException implements Exception {
  AnyShimAbiException(this.found, this.expected);
  final int found;
  final int expected;

  @override
  String toString() =>
      'AnyShimAbiException: libany_shim implements ABI $found, these '
      'bindings need $expected';
}

/// One `any_shim_op_wait` slice: still running, or finished with its
/// result (the op handle is released then).
final class OpPoll {
  const OpPoll.pending() : done = false, result = null;
  const OpPoll.done(Map<String, Object?> this.result) : done = true;

  final bool done;
  final Map<String, Object?>? result;
}

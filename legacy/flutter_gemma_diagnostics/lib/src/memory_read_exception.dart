/// Thrown when the OS should have answered a memory query and did not.
///
/// This is the counterpart to a null field. A null means the value does not
/// exist on this platform or OS version; this exception means it should exist
/// and the read failed (a kernel error, a permission error, or a file that
/// lacks a field it always carries). Turning those into null would report a
/// broken read as a documented gap.
final class MemoryReadException implements Exception {
  /// Creates the exception. [cause] is the underlying error, if any.
  const MemoryReadException(this.message, {this.cause});

  /// What was being read, and what went wrong.
  final String message;

  /// The underlying error, when there is one.
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'MemoryReadException: $message'
      : 'MemoryReadException: $message ($cause)';
}

// LiteRT-LM C API 1.0: every call that can fail returns a LiteRtLmStatusCode
// (absl's canonical codes, `c/error_reporter.h`) and writes its result through
// an out-parameter. These helpers make one call, check its status and read the
// out-parameter, for the inference client and the EmbeddingGemma 2 pass alike.
//
// A non-OK status throws [LiteRtLmCallException] with LiteRT-LM's thread-local
// last error, read on the thread the call ran on. A setter that fails does so
// only on an argument it refuses (a NULL handle, a value out of range): that is
// a bug here, never a condition to carry on past, so setters are checked too.

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// `kLiteRtLmStatusOk`.
const liteRtLmStatusOk = 0;

/// `kLiteRtLmStatusResourceExhausted`: §23's `context_full` carries it.
const liteRtLmStatusResourceExhausted = 8;

const _statusNames = [
  'OK',
  'CANCELLED',
  'UNKNOWN',
  'INVALID_ARGUMENT',
  'DEADLINE_EXCEEDED',
  'NOT_FOUND',
  'ALREADY_EXISTS',
  'PERMISSION_DENIED',
  'RESOURCE_EXHAUSTED',
  'FAILED_PRECONDITION',
  'ABORTED',
  'OUT_OF_RANGE',
  'UNIMPLEMENTED',
  'INTERNAL',
  'UNAVAILABLE',
  'DATA_LOSS',
  'UNAUTHENTICATED',
];

/// The absl name of a LiteRtLmStatusCode, or `status <code>` for one the C API
/// does not define.
String liteRtLmStatusName(int code) => code >= 0 && code < _statusNames.length
    ? _statusNames[code]
    : 'status $code';

/// A C API call returned a status other than OK, or OK with no result.
final class LiteRtLmCallException implements Exception {
  const LiteRtLmCallException(this.call, this.code, [this.message]);

  /// The C function that failed.
  final String call;

  /// The LiteRtLmStatusCode it returned (0 for an OK with a NULL result).
  final int code;

  /// LiteRT-LM's last error for the call, when it set one.
  final String? message;

  @override
  String toString() {
    final status = code == liteRtLmStatusOk
        ? 'returned OK with no result'
        : 'failed with ${liteRtLmStatusName(code)}';
    return 'LiteRtLmCallException: $call $status'
        '${message == null ? '' : ': $message'}';
  }
}

/// Reads LiteRT-LM's thread-local last error on the calling thread.
typedef LiteRtLmLastError = String? Function();

/// Decodes a NUL-terminated native error message without throwing on
/// malformed bytes: a native failure must not surface as a complaint about its
/// encoding. Bounded by [maxBytes], as an error message is short and a broken
/// one might lack its NUL.
String decodeLiteRtLmString(Pointer<Char> ptr, {int maxBytes = 64 * 1024}) {
  final bytes = ptr.cast<Uint8>();
  var length = 0;
  while (length < maxBytes && bytes[length] != 0) {
    length++;
  }
  return utf8.decode(bytes.asTypedList(length), allowMalformed: true);
}

/// The last error behind [getMessage] (`litert_lm_get_last_error_message`),
/// or null when it is empty.
String? lastErrorFrom(Pointer<Char> Function() getMessage) {
  final ptr = getMessage();
  if (ptr == nullptr) return null;
  final message = decodeLiteRtLmString(ptr);
  return message.isEmpty ? null : message;
}

/// Throws [LiteRtLmCallException] when [code] is not OK.
void checkLiteRtLmStatus(String call, int code, LiteRtLmLastError lastError) {
  if (code != liteRtLmStatusOk) {
    throw LiteRtLmCallException(call, code, lastError());
  }
}

/// Calls a constructor (`…_create(…, T** out)`) and returns what it made.
/// OK with a NULL result is a failure too.
Pointer<T> createLiteRtLm<T extends NativeType>(
  String call,
  int Function(Pointer<Pointer<T>> out) create,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Pointer<Void>>();
  try {
    final code = create(out.cast());
    final made = out.value.cast<T>();
    if (code != liteRtLmStatusOk || made == nullptr) {
      throw LiteRtLmCallException(call, code, lastError());
    }
    return made;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with a `size_t*` out-parameter.
int readLiteRtLmSize(
  String call,
  int Function(Pointer<Size> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Size>();
  try {
    checkLiteRtLmStatus(call, get(out), lastError);
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with an `int*` out-parameter.
int readLiteRtLmInt(
  String call,
  int Function(Pointer<Int> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Int>();
  try {
    checkLiteRtLmStatus(call, get(out), lastError);
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with a `double*` out-parameter.
double readLiteRtLmDouble(
  String call,
  int Function(Pointer<Double> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Double>();
  try {
    checkLiteRtLmStatus(call, get(out), lastError);
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with a `float*` out-parameter.
double readLiteRtLmFloat(
  String call,
  int Function(Pointer<Float> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Float>();
  try {
    checkLiteRtLmStatus(call, get(out), lastError);
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with a `bool*` out-parameter.
bool readLiteRtLmBool(
  String call,
  int Function(Pointer<Bool> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Bool>();
  try {
    checkLiteRtLmStatus(call, get(out), lastError);
    return out.value;
  } finally {
    calloc.free(out);
  }
}

/// Calls a getter with a `T**` out-parameter that hands back memory the
/// object owns (a string, an array). OK with NULL returns NULL: whether that
/// is a failure is the caller's to say.
Pointer<T> readLiteRtLmPointer<T extends NativeType>(
  String call,
  int Function(Pointer<Pointer<T>> out) get,
  LiteRtLmLastError lastError,
) {
  final out = calloc<Pointer<Void>>();
  try {
    checkLiteRtLmStatus(call, get(out.cast()), lastError);
    return out.value.cast<T>();
  } finally {
    calloc.free(out);
  }
}

/// Checks a setter's status. A setter refuses only an argument (a NULL
/// handle, a value out of range), so a non-OK status is a bug in this
/// package: a [StateError], which no backend fallback (`on Exception`) takes
/// for a reason to try another backend.
void checkLiteRtLmSetter(String call, int code, LiteRtLmLastError lastError) {
  if (code != liteRtLmStatusOk) {
    throw StateError(LiteRtLmCallException(call, code, lastError()).toString());
  }
}

// Why `litert_lm_conversation_send_message_stream` refused to start a
// generation. Its return value is an `absl::StatusCode`; the reason is in
// LiteRT-LM's thread-local last error and, without this, only in its log.

/// The `absl::StatusCode` names, by value.
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

/// The message for a send that [code] refused to start.
///
/// [nativeMessage] is LiteRT-LM's last error, read on the thread that made
/// the call; null when the library does not export it or left none.
/// [npu] is whether the engine runs on the NPU, and [laterMessage] whether an
/// earlier send on this conversation started: on the NPU that combination is
/// usually a history the executor cannot roll back to.
String streamStartFailureMessage({
  required int code,
  required String? nativeMessage,
  required bool npu,
  required bool laterMessage,
}) {
  final name = code >= 0 && code < _statusNames.length
      ? _statusNames[code]
      : null;
  final reason = nativeMessage == null || nativeMessage.trim().isEmpty
      ? null
      : nativeMessage.trim();
  final buffer = StringBuffer(
    'Failed to start streaming (code: $code${name == null ? '' : ', $name'})',
  );
  buffer.write(reason == null ? '.' : ': $reason');
  if (npu && laterMessage) {
    buffer.write(
      ' On the NPU, a failure on a later message usually means the '
      "conversation's history no longer matches the tokens it decoded: the NPU "
      'executor can roll back only one token. Start a new conversation.',
    );
  }
  if (reason == null) {
    buffer.write(
      ' LiteRT-LM reported no reason here; '
      'LiteRtLmEngine(nativeLogLevel: LiteRtLmLogLevel.verbose) shows its log.',
    );
  }
  return buffer.toString();
}

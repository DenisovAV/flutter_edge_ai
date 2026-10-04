import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

/// Debug-only logging owned by the SQLite provider package.
///
/// Provider packages must not reach into Flutter Edge AI core internals just
/// to share a logger. Keep this deliberately small and release-silent.
void sqliteLog(String message) {
  if (!kDebugMode) return;
  debugPrint(message.replaceAll('\uFFFD', 'U+FFFD'));
}

import 'package:flutter/foundation.dart';

/// Verbosity for flutter_gemma's internal logs.
///
/// - [none] — silence the plugin entirely.
/// - [info] — lifecycle, errors, non-PII diagnostics (default in debug).
/// - [verbose] — adds model output / prompts / conversation history.
enum GemmaLogLevel { none, info, verbose }

/// Active log level. Top-level (Dart-canonical for process-global logger
/// state) so [gemmaLog] reads it without importing the public facade.
///
/// NOTE: top-level mutables are per-isolate in Dart — a spawned isolate gets
/// its own copy initialized to [GemmaLogLevel.info]. Isolate entry points must
/// set this from data passed at spawn (see the embedding worker).
GemmaLogLevel gemmaLogLevel = GemmaLogLevel.info;

/// Internal log entry point. Every plugin log routes through here.
///
/// - Release builds: silent regardless of level. `kDebugMode` is a compile-time
///   `false`, so the body is dead-code-eliminated. (Callers that interpolate a
///   large/hot variable must still guard the CALL SITE with `if (kDebugMode)`
///   to avoid building the string in release.)
/// - Debug builds: prints when [level] <= [gemmaLogLevel], after sanitizing
///   U+FFFD so it can't crash `flutter run` (issue #306).
void gemmaLog(String message, {GemmaLogLevel level = GemmaLogLevel.info}) {
  if (!kDebugMode) return;
  if (gemmaLogLevel == GemmaLogLevel.none) return;
  if (level.index > gemmaLogLevel.index) return;
  debugPrint(sanitizeForLog(message));
}

/// Rewrites U+FFFD (the replacement character) and unpaired UTF-16 surrogates
/// to the literal text `U+FFFD`.
///
/// Both encode to the bytes `0xEF 0xBF 0xBD` on stdout, which `flutter run`'s
/// reader treats as malformed output and aborts on (issue #306). A lone
/// surrogate appears when a `substring`/chunk boundary splits an emoji or other
/// astral character mid-pair.
String sanitizeForLog(String text) {
  var needsWork = false;
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    if (u == 0xFFFD || (u >= 0xD800 && u <= 0xDFFF)) {
      needsWork = true;
      break;
    }
  }
  if (!needsWork) return text;

  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final u = text.codeUnitAt(i);
    if (u == 0xFFFD) {
      out.write('U+FFFD');
    } else if (u >= 0xD800 && u <= 0xDBFF) {
      final hasLow =
          i + 1 < text.length &&
          text.codeUnitAt(i + 1) >= 0xDC00 &&
          text.codeUnitAt(i + 1) <= 0xDFFF;
      if (hasLow) {
        out.writeCharCode(u);
        out.writeCharCode(text.codeUnitAt(i + 1));
        i++;
      } else {
        out.write('U+FFFD');
      }
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      out.write('U+FFFD');
    } else {
      out.writeCharCode(u);
    }
  }
  return out.toString();
}

// The runtime side's debug log, behind one settable sink: lib/src/ffi,
// lib/src/bundle and the EmbeddingGemma 2 pass log through [runtimeLog], and
// nothing here imports Flutter or core. Not exported.
//
// A top-level is per isolate, so a spawned isolate starts from the
// initializers: the default sink, which prints, filtered by
// [runtimeLogLevel]. The client and the scorer hand each isolate they spawn
// [currentRuntimeLogLevel] of the spawner, so it logs at the caller's level.
// The Flutter adapter (`adapter/runtime_log_binding.dart`) points the sink of
// the isolate the app runs on at core's `edgeAiLog`, and the level source at
// core's `edgeAiLogLevel`.

import 'build_mode.dart';

/// How much [runtimeLog] lets through: nothing, [info] messages, or [info]
/// and [verbose] ones (model output, prompts, native log contents).
enum RuntimeLogLevel { none, info, verbose }

/// Where [runtimeLog] sends a message. [verbose] marks model output, prompts
/// and native log contents; everything else is info.
typedef RuntimeLogSink = void Function(String message, {bool verbose});

/// The level of this isolate's default sink. Set from the spawner's
/// [currentRuntimeLogLevel] in each isolate the runtime spawns.
RuntimeLogLevel runtimeLogLevel = RuntimeLogLevel.info;

/// Where [currentRuntimeLogLevel] reads the level from, when not
/// [runtimeLogLevel]: the adapter points it at core's `edgeAiLogLevel`.
RuntimeLogLevel Function()? runtimeLogLevelSource;

/// The level this isolate logs at now, to hand to an isolate it spawns.
RuntimeLogLevel currentRuntimeLogLevel() =>
    runtimeLogLevelSource?.call() ?? runtimeLogLevel;

void _printSink(String message, {bool verbose = false}) {
  final level = currentRuntimeLogLevel();
  if (level == RuntimeLogLevel.none) return;
  if (verbose && level != RuntimeLogLevel.verbose) return;
  print(sanitizeForLog(message));
}

/// The sink [runtimeLog] writes to in this isolate; [print], filtered by
/// [currentRuntimeLogLevel], unless replaced.
RuntimeLogSink runtimeLogSink = _printSink;

/// Logs [message] through [runtimeLogSink], in debug builds only: the
/// constant check lets a release build drop the call and its message.
void runtimeLog(String message, {bool verbose = false}) {
  if (!isDebugBuild) return;
  runtimeLogSink(message, verbose: verbose);
}

/// Restores [runtimeLogSink] and [runtimeLogLevelSource] to the defaults.
void resetRuntimeLogSink() {
  runtimeLogSink = _printSink;
  runtimeLogLevelSource = null;
}

/// [text] with every lone UTF-16 surrogate and U+FFFD written as `U+FFFD`, so
/// a log line cut inside a character prints. A copy of core's
/// `sanitizeForLog`, which the runtime cannot import.
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

// Where litertlm_dart's own log lines go, and how much LiteRT-LM's native
// log says: one place for both.

import '../runtime/litert_lm_log_level.dart';
import '../runtime/runtime_log.dart';
import 'engine.dart' show liteRtLmNativeLogLevel;

/// litertlm_dart's log: its own lines (load decisions, timings, recoveries)
/// and the level of LiteRT-LM's native log.
abstract final class LiteRtLmLog {
  /// How much of litertlm_dart's own log is written: [LiteRtLmLogLevel.silent]
  /// nothing, [LiteRtLmLogLevel.verbose] also prompts, model output and the
  /// native log's contents, any other level the rest. Applies to the isolates
  /// the runtime spawns from then on.
  static LiteRtLmLogLevel get level => switch (runtimeLogLevel) {
    RuntimeLogLevel.none => LiteRtLmLogLevel.silent,
    RuntimeLogLevel.info => LiteRtLmLogLevel.info,
    RuntimeLogLevel.verbose => LiteRtLmLogLevel.verbose,
  };

  static set level(LiteRtLmLogLevel level) => runtimeLogLevel = switch (level) {
    LiteRtLmLogLevel.silent => RuntimeLogLevel.none,
    LiteRtLmLogLevel.verbose ||
    LiteRtLmLogLevel.debug => RuntimeLogLevel.verbose,
    _ => RuntimeLogLevel.info,
  };

  /// Where litertlm_dart's lines go on this isolate; `print` by default.
  static RuntimeLogSink get sink => runtimeLogSink;
  static set sink(RuntimeLogSink sink) => runtimeLogSink = sink;

  /// The minimum severity of LiteRT-LM's native log, set before every engine
  /// from then on (Kotlin's `Engine.setNativeMinLogSeverity`). Process-wide;
  /// null leaves the process's level as it is.
  static LiteRtLmLogLevel? get nativeLevel => liteRtLmNativeLogLevel;
  static set nativeLevel(LiteRtLmLogLevel? level) =>
      liteRtLmNativeLogLevel = level;
}

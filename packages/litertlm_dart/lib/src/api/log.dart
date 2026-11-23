// Where litertlm_dart's own log lines go, and how much LiteRT-LM's native
// log says: one place for both.

import '../runtime/litert_lm_log_level.dart';
import '../runtime/runtime_log.dart';

/// litertlm_dart's log: its own lines (load decisions, timings, recoveries)
/// and the level of LiteRT-LM's native log.
abstract final class LiteRtLmLog {
  /// How much of litertlm_dart's own log is written. Its lines are
  /// informational (load decisions, timings, recoveries), so
  /// [LiteRtLmLogLevel.debug] and [LiteRtLmLogLevel.info] write them, a level
  /// above info and [LiteRtLmLogLevel.silent] write none, and only
  /// [LiteRtLmLogLevel.verbose] adds prompts, model output and the native
  /// log's contents. Reads back what was set; unset, the level in force.
  /// Applies to this isolate and to the isolates litertlm_dart spawns from
  /// then on, and flutter_edge_ai_litertlm does not replace it there; an
  /// isolate another package spawns (core's embedding worker) logs at that
  /// package's level.
  static LiteRtLmLogLevel get level =>
      _level ??
      switch (currentRuntimeLogLevel()) {
        RuntimeLogLevel.none => LiteRtLmLogLevel.silent,
        RuntimeLogLevel.info => LiteRtLmLogLevel.info,
        RuntimeLogLevel.verbose => LiteRtLmLogLevel.verbose,
      };

  static set level(LiteRtLmLogLevel level) {
    _level = level;
    runtimeLogLevelSetByApp = true;
    runtimeLogLevelSource = null;
    runtimeLogLevel = switch (level) {
      LiteRtLmLogLevel.verbose => RuntimeLogLevel.verbose,
      LiteRtLmLogLevel.debug || LiteRtLmLogLevel.info => RuntimeLogLevel.info,
      LiteRtLmLogLevel.warning ||
      LiteRtLmLogLevel.error ||
      LiteRtLmLogLevel.fatal ||
      LiteRtLmLogLevel.silent => RuntimeLogLevel.none,
    };
  }

  static LiteRtLmLogLevel? _level;

  /// Where litertlm_dart's lines go on this isolate; `print` by default. Not
  /// replaced by flutter_edge_ai_litertlm once set.
  static RuntimeLogSink get sink => runtimeLogSink;
  static set sink(RuntimeLogSink sink) {
    runtimeLogSinkSetByApp = true;
    runtimeLogSink = sink;
  }

  /// The minimum severity of LiteRT-LM's native log, set before every engine
  /// from then on (Kotlin's `Engine.setNativeMinLogSeverity`). Process-wide;
  /// null leaves the process's level as it is. Native only: the web runtime
  /// (`@litert-lm/core`) has no such setting, so there it is kept and read
  /// back, and changes nothing.
  static LiteRtLmLogLevel? get nativeLevel => liteRtLmNativeLogLevel;
  static set nativeLevel(LiteRtLmLogLevel? level) =>
      liteRtLmNativeLogLevel = level;
}

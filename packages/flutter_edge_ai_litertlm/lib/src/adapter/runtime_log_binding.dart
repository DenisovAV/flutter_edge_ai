// Ties the runtime's log (lib/src/runtime/runtime_log.dart) to core: in the
// isolate this runs on, runtime messages go through `edgeAiLog`, and the level
// the runtime hands to the isolates it spawns is the app's `edgeAiLogLevel`.
// A top-level is per isolate, so each adapter entry point calls it on the
// isolate it runs on (the app's, and core's embedding worker); the isolates
// the runtime itself spawns log through the default sink at the level they
// were handed.

import 'package:flutter_edge_ai/engine.dart'
    show EdgeAiLogLevel, edgeAiLog, edgeAiLogLevel;

import 'package:litertlm_dart/internal_io.dart' hide ActivationDataType;

void _edgeAiLogSink(String message, {bool verbose = false}) => edgeAiLog(
  message,
  level: verbose ? EdgeAiLogLevel.verbose : EdgeAiLogLevel.info,
);

RuntimeLogLevel _coreLevel() => switch (edgeAiLogLevel) {
  EdgeAiLogLevel.none => RuntimeLogLevel.none,
  EdgeAiLogLevel.info => RuntimeLogLevel.info,
  EdgeAiLogLevel.verbose => RuntimeLogLevel.verbose,
};

/// Points this isolate's runtime log at core's `edgeAiLog` and
/// `edgeAiLogLevel`. Idempotent.
void bindRuntimeLogToCore() {
  runtimeLogSink = _edgeAiLogSink;
  runtimeLogLevelSource = _coreLevel;
}

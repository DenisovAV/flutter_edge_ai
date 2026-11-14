// The runtime side's debug log, behind one settable sink: lib/src/ffi,
// lib/src/bundle and the EmbeddingGemma 2 pass log through [runtimeLog]
// instead of calling core's `edgeAiLog` directly, so that the sink, not each
// file, is what ties them to core. Not exported.
//
// The default is core's `edgeAiLog` (debug builds only, under the app's
// `edgeAiLogLevel`). It is the initializer, not something the adapter sets,
// because a top-level is per isolate: a spawned isolate starts from the
// initializer, and the client's and the scorer's isolates must log as they
// did before.

import 'package:flutter_edge_ai/engine.dart' show EdgeAiLogLevel, edgeAiLog;

import 'build_mode.dart';

/// Where [runtimeLog] sends a message. [verbose] marks model output, prompts
/// and native log contents (`EdgeAiLogLevel.verbose`); everything else is
/// `EdgeAiLogLevel.info`.
typedef RuntimeLogSink = void Function(String message, {bool verbose});

void _edgeAiLogSink(String message, {bool verbose = false}) => edgeAiLog(
  message,
  level: verbose ? EdgeAiLogLevel.verbose : EdgeAiLogLevel.info,
);

/// The sink [runtimeLog] writes to in this isolate; core's `edgeAiLog` unless
/// replaced.
RuntimeLogSink runtimeLogSink = _edgeAiLogSink;

/// Logs [message] through [runtimeLogSink], in debug builds only: the
/// constant check lets a release build drop the call and its message, as
/// `edgeAiLog`'s own `kDebugMode` check did when it was called directly.
void runtimeLog(String message, {bool verbose = false}) {
  if (!isDebugBuild) return;
  runtimeLogSink(message, verbose: verbose);
}

/// Restores [runtimeLogSink] to core's `edgeAiLog`.
void resetRuntimeLogSink() => runtimeLogSink = _edgeAiLogSink;

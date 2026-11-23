// What LiteRT-LM's Kotlin `benchmark()` reports, shared by both arms: the web
// arm's `benchmark` refuses, the native one fills it.

import 'package:meta/meta.dart' show experimental, immutable;

import '../runtime/types.dart' show ActivationDataType;
import 'backend.dart';

/// What one `benchmark` run measured: LiteRT-LM's record of its last prefill
/// and last decode, as the Kotlin API's `BenchmarkInfo` reports them, and
/// what the engine ran with.
@experimental
@immutable
final class LlmBenchmarkResult {
  const LlmBenchmarkResult({
    required this.initTime,
    required this.createTime,
    required this.timeToFirstToken,
    required this.prefillTokenCount,
    required this.decodeTokenCount,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
    required this.maxNumTokens,
    required this.backend,
    required this.activationDataType,
  });

  /// The engine's load as LiteRT-LM timed it (its `total_init_time`), the
  /// number Gallery reports; [Duration.zero] when it reported none. It can
  /// exceed [createTime]: LiteRT-LM counts init phases that end after the
  /// engine is returned (Gemma 4 E2B on a Mac CPU, empty cache directory:
  /// 1.6 s, with [createTime] 1.0 s).
  final Duration initTime;

  /// `Engine.create` measured in Dart from its turn among the process's
  /// creates (not the wait behind another one): the bundle read, the load
  /// plan, the isolate the engine is made on and `litert_lm_engine_create`.
  final Duration createTime;

  /// LiteRT-LM's `GetTimeToFirstToken`: the duration of the session's first
  /// prefill turn plus its first decode turn's duration divided by that
  /// turn's tokens (LiteRT-LM v0.19.1 `runtime/engine/io_types.cc`). The
  /// prompt template, tokenization and the Dart stream are not in it.
  final Duration timeToFirstToken;

  /// The tokens of the last prefill and the last decode: the counts asked
  /// for, unless the runtime did otherwise.
  final int prefillTokenCount;
  final int decodeTokenCount;

  /// 0 when the turn had no measurable duration.
  final double prefillTokensPerSecond;
  final double decodeTokensPerSecond;

  /// The context window (KV cache) the engine ran with, as LiteRT-LM reports
  /// it: the one asked for, the bundle's own when none was, or a compiled
  /// model's fixed cache. 0 when it reported none.
  final int maxNumTokens;

  /// The text model's backend: the engine is created on it or not at all.
  /// Whether a GPU delegate took every op of the graph is in LiteRT-LM's
  /// native log, not here.
  final Backend backend;

  /// The activation type sent to the GPU executor; null when the bundle's
  /// own was left, and on the CPU and the NPU.
  final ActivationDataType? activationDataType;

  @override
  String toString() =>
      'LlmBenchmarkResult(init: ${initTime.inMilliseconds} ms, '
      'create: ${createTime.inMilliseconds} ms, '
      'ttft: ${timeToFirstToken.inMilliseconds} ms, '
      'prefill: $prefillTokenCount tokens at '
      '${prefillTokensPerSecond.toStringAsFixed(1)} tok/s, '
      'decode: $decodeTokenCount tokens at '
      '${decodeTokensPerSecond.toStringAsFixed(1)} tok/s, '
      'maxNumTokens: $maxNumTokens, backend: $backend, '
      'activation: ${activationDataType?.name})';
}

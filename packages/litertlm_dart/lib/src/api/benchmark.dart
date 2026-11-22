// LiteRT-LM's Kotlin `benchmark()`: one engine in the runtime's benchmark
// mode, one conversation, one message, the native record of that turn.

import 'package:meta/meta.dart' show experimental, immutable;

import '../ffi/litert_lm_client.dart' show NativeBenchmark;
import '../runtime/types.dart' show ActivationDataType;
import 'backend.dart';
import 'config.dart';
import 'conversation.dart';
import 'engine.dart';
import 'message.dart';

/// What one [benchmark] run measured: LiteRT-LM's record of its last prefill
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
  /// engine is returned (a cold Gemma 4 E2B on a Mac CPU: 4.05 s, with
  /// [createTime] 3.2 s).
  final Duration initTime;

  /// [Engine.create] measured in Dart: the bundle read, the load plan, the
  /// isolate the engine is made on and `litert_lm_engine_create`.
  final Duration createTime;

  /// From the message's send to its first token, as LiteRT-LM timed it.
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

/// Benchmarks the `.litertlm` model at [modelPath] on [backend], as
/// LiteRT-LM's Kotlin `benchmark()` does: creates an engine in the runtime's
/// benchmark mode, sends [prompt] once in a new conversation, and closes the
/// engine.
///
/// In that mode the prompt's last text is cut or padded with token 0 to
/// exactly [prefillTokens] tokens, and the reply runs exactly [decodeTokens]
/// tokens, past the end of the turn: the default `'How are you'` padded to
/// 256 and 256 decoded tokens is what AI Edge Gallery's benchmark measures.
/// The reply's text means nothing.
///
/// Each call loads the model anew, so the first call in a process with an
/// empty [cacheDir] times a cold load and the next ones a load from the
/// caches. [maxNumTokens] null leaves the context window to LiteRT-LM (the
/// bundle's own), which [LlmBenchmarkResult.maxNumTokens] reports; it changes
/// prefill and decode speed, so compare runs with the same window.
/// [samplerConfig] null uses the model's own sampler.
///
/// Throws what [Engine.create] throws, an [ArgumentError] for a count below
/// 1, and a [StateError] when LiteRT-LM reports no prefill or no decode.
@experimental
Future<LlmBenchmarkResult> benchmark({
  required String modelPath,
  required Backend backend,
  Backend? visionBackend,
  Backend? audioBackend,
  int prefillTokens = 256,
  int decodeTokens = 256,
  String prompt = 'How are you',
  int? maxNumTokens,
  String? cacheDir,
  SamplerConfig? samplerConfig,
}) async {
  if (prefillTokens < 1) {
    throw ArgumentError.value(prefillTokens, 'prefillTokens', 'must be 1+');
  }
  if (decodeTokens < 1) {
    throw ArgumentError.value(decodeTokens, 'decodeTokens', 'must be 1+');
  }
  if (maxNumTokens != null && maxNumTokens < 1) {
    throw ArgumentError.value(maxNumTokens, 'maxNumTokens', 'must be 1+');
  }
  final create = Stopwatch()..start();
  final engine = await createBenchmarkEngine(
    EngineConfig(
      modelPath: modelPath,
      backend: backend,
      visionBackend: visionBackend,
      audioBackend: audioBackend,
      maxNumTokens: maxNumTokens,
      cacheDir: cacheDir,
    ),
    (prefill: prefillTokens, decode: decodeTokens),
  );
  create.stop();
  try {
    final conversation = await engine.createConversation(
      ConversationConfig(samplerConfig: samplerConfig),
    );
    try {
      await conversation.sendMessage(Message.user(prompt));
      return llmBenchmarkResultOf(
        conversationNativeBenchmark(conversation),
        createTime: create.elapsed,
        engine: engine,
      );
    } finally {
      await conversation.close();
    }
  } finally {
    await engine.close();
  }
}

/// The [LlmBenchmarkResult] of the native record [turns] of a benchmark run
/// on [engine]; a [StateError] when it has no prefill or no decode.
LlmBenchmarkResult llmBenchmarkResultOf(
  NativeBenchmark? turns, {
  required Duration createTime,
  required Engine engine,
}) {
  if (turns == null) {
    throw StateError('LiteRT-LM returned no benchmark record for the run');
  }
  if (turns.prefill.isEmpty || turns.decode.isEmpty) {
    throw StateError(
      'LiteRT-LM recorded ${turns.prefill.length} prefill and '
      '${turns.decode.length} decode turns for the run; one of each is '
      'expected',
    );
  }
  Duration seconds(double s) =>
      s > 0 ? Duration(microseconds: (s * 1e6).round()) : Duration.zero;
  final prefill = turns.prefill.last;
  final decode = turns.decode.last;
  return LlmBenchmarkResult(
    initTime: seconds(turns.initSeconds),
    createTime: createTime,
    timeToFirstToken: seconds(turns.timeToFirstTokenSeconds),
    prefillTokenCount: prefill.tokens,
    decodeTokenCount: decode.tokens,
    prefillTokensPerSecond: prefill.tokensPerSecond,
    decodeTokensPerSecond: decode.tokensPerSecond,
    maxNumTokens: turns.maxNumTokens,
    backend: engine.backend,
    activationDataType: engine.activationDataType,
  );
}

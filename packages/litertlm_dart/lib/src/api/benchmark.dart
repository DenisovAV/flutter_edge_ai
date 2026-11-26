// LiteRT-LM's Kotlin `benchmark()`: one engine in the runtime's benchmark
// mode, one conversation, one message, the native record of that turn.

import 'package:meta/meta.dart' show experimental;

import '../runtime/conversation_handle.dart' show NativeBenchmark;
import 'backend.dart';
import 'benchmark_result.dart';
import 'config.dart';
import 'conversation.dart';
import 'engine.dart';
import 'message.dart';

export 'benchmark_result.dart';

/// Benchmarks the `.litertlm` model at [modelPath] on [backend], as
/// LiteRT-LM's Kotlin and Swift `benchmark()` do: creates an engine in the
/// runtime's benchmark mode, sends [prompt] (Swift's parameter; Kotlin takes
/// `contents`) once in a new conversation, and closes the engine.
///
/// In that mode the prompt's last text is cut or padded with token 0 to
/// exactly [prefillTokens] tokens, and the reply runs exactly [decodeTokens]
/// tokens, past the end of the turn. The defaults are the Kotlin API's: the
/// prompt `'How are you'`, 256 and 256, which AI Edge Gallery's benchmark
/// screen also starts from (it passes no contents). The reply's text means
/// nothing.
///
/// Each call loads the model anew. Whether a load is cold is decided by the
/// cache files LiteRT-LM finds (weights, compiled GPU programs), not by the
/// process: with [cacheDir] null they are written beside the model and kept
/// across processes and app runs. For a cold load, pass a new empty
/// directory (the first call in it is cold, the next ones warm), or
/// `':nocache'`, LiteRT-LM's value for writing none. [maxNumTokens] null
/// leaves the context window to LiteRT-LM (the bundle's own), which
/// [LlmBenchmarkResult.maxNumTokens] reports; it changes prefill and decode
/// speed, so compare runs with the same window.
/// [samplerConfig] null uses the model's own sampler; [speculativeDecoding]
/// null leaves LiteRT-LM's (off).
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
  SpeculativeDecodingConfig? speculativeDecoding,
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
  final (:engine, :createTime) = await createBenchmarkEngine(
    EngineConfig(
      modelPath: modelPath,
      backend: backend,
      visionBackend: visionBackend,
      audioBackend: audioBackend,
      maxNumTokens: maxNumTokens,
      cacheDir: cacheDir,
      speculativeDecoding: speculativeDecoding,
    ),
    (prefill: prefillTokens, decode: decodeTokens),
  );
  try {
    final conversation = await engine.createConversation(
      ConversationConfig(samplerConfig: samplerConfig),
    );
    try {
      await conversation.sendMessage(Message.user(prompt));
      return llmBenchmarkResultOf(
        conversationNativeBenchmark(conversation),
        createTime: createTime,
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

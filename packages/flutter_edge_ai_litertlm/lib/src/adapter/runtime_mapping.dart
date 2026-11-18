// Core's types to the runtime's (lib/src/runtime/types.dart) and back, at the
// one boundary the Flutter adapter has with the LiteRT-LM runtime. The runtime
// throws its own exceptions where core's would name a core type; [mapRuntimeError]
// turns each into the exception an app has always caught.

import 'package:flutter_edge_ai/engine.dart';

import '../runtime/errors.dart';
import '../runtime/types.dart';

extension PreferredBackendToRuntime on PreferredBackend {
  Backend get toRuntime => switch (this) {
    PreferredBackend.cpu => Backend.cpu,
    PreferredBackend.gpu => Backend.gpu,
    PreferredBackend.npu => Backend.npu,
  };
}

extension BackendToCore on Backend {
  PreferredBackend get toCore => switch (this) {
    Backend.cpu => PreferredBackend.cpu,
    Backend.gpu => PreferredBackend.gpu,
    Backend.npu => PreferredBackend.npu,
  };
}

extension ActivationDataTypeToRuntime on ActivationDataType {
  ActivationType get toRuntime => switch (this) {
    ActivationDataType.float32 => ActivationType.float32,
    ActivationDataType.float16 => ActivationType.float16,
  };
}

extension ActivationTypeToCore on ActivationType {
  ActivationDataType get toCore => switch (this) {
    ActivationType.float32 => ActivationDataType.float32,
    ActivationType.float16 => ActivationDataType.float16,
  };
}

extension ResolvedSamplingToRuntime on ResolvedSampling {
  Sampler get toRuntime => Sampler(
    temperature: temperature,
    topK: topK,
    topP: topP,
    randomSeed: randomSeed,
  );
}

extension BundleSamplerToCore on BundleSampler {
  SamplingParams get toCore => SamplingParams(
    temperature: temperature,
    topK: topK,
    topP: topP,
    randomSeed: randomSeed,
  );
}

extension MultimodalOrderToRuntime on MultimodalOrder {
  MediaOrder get toRuntime =>
      MediaOrder(images: images.toRuntime, audio: audio.toRuntime);
}

extension MediaPositionToRuntime on MediaPosition {
  MediaSide get toRuntime => switch (this) {
    MediaPosition.beforeText => MediaSide.beforeText,
    MediaPosition.afterText => MediaSide.afterText,
  };
}

extension TurnMetricsToCore on TurnMetrics {
  SessionMetrics get toCore => SessionMetrics(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    totalTokens: totalTokens,
    timeToFirstTokenMs: timeToFirstTokenMs,
    tokensPerSecond: tokensPerSecond,
    initTimeMs: initTimeMs,
  );
}

extension ScoringRunToCore on ScoringRun {
  // The decider SPI is @experimental.
  // ignore: experimental_member_use
  OptionScoringRun get toCore => OptionScoringRun(
    tokenScores: tokenScores,
    prefillTime: prefillTime,
    scoreTime: scoreTime,
  );
}

/// Core's [CancelToken] as the runtime's [CancelSignal].
final class CancelTokenSignal implements CancelSignal {
  CancelTokenSignal(this._token);

  final CancelToken _token;

  @override
  bool get isCancelled => _token.isCancelled;

  @override
  Future<void> get whenCancelled => _token.whenCancelled;
}

/// The core exception for a runtime one, or [error] itself.
Object mapRuntimeError(Object error) => switch (error) {
  // ignore: experimental_member_use
  ScoringCancelledException(:final message) => DeciderCancelledException(
    message,
  ),
  ConstraintUnsupportedException(:final message) =>
    ResponseFormatUnsupportedException(message),
  _ => error,
};

/// [stream] with each runtime error replaced by its core exception
/// ([mapRuntimeError]).
Stream<T> mapRuntimeErrors<T>(Stream<T> stream) => stream.handleError(
  (Object e, StackTrace st) =>
      Error.throwWithStackTrace(mapRuntimeError(e), st),
);

/// Runs [body], rethrowing a runtime error as its core exception
/// ([mapRuntimeError]).
Future<T> withCoreErrors<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e, st) {
    final mapped = mapRuntimeError(e);
    if (identical(mapped, e)) rethrow;
    Error.throwWithStackTrace(mapped, st);
  }
}

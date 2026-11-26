// The runtime's own small vocabulary: values the LiteRT-LM runtime (lib/src/ffi,
// lib/src/bundle, lib/src/runtime) takes and returns, so that it never names a
// core type. The Flutter adapter maps core's types to these and back
// (lib/src/adapter/runtime_mapping.dart). Names differ from core's on purpose:
// an adapter file imports both without `hide` or a prefix.

import 'package:meta/meta.dart' show immutable;

/// Where LiteRT-LM runs a model's main graph, or one of its encoders. Its
/// [name] is LiteRT-LM's wire name (`cpu`, `gpu`, `npu`).
enum BackendKind { cpu, gpu, npu }

/// The numeric type of a model's activations: LiteRT-LM's
/// `ActivationDataType` (C API `LiteRtLmActivationDataType`), Kotlin's
/// `ActivationDataType` (FLOAT32, FLOAT16, INT16, INT8; Config.kt) and Swift's
/// (`.float32`, `.float16`, `.int16`, `.int8`; Config.swift).
///
/// Support depends on the model and the backend, as upstream says: most
/// models run [float16] and [float32] on the GPU, and a type the model or
/// backend does not support may fail the engine's create, which is
/// LiteRT-LM's own error (`LiteRtLmEngineCreateException`). Only the GPU
/// executor reads it. Measured on macOS arm64 with native-v0.20.0: on the
/// CPU every type gives the float32 reply; on Metal LiteRT-LM 0.20.0
/// accepts [int16] and [int8] for Gemma 4 E2B and FunctionGemma 270M,
/// creates the engine, and decodes nonsense with both: those bundles are
/// float models, so `Engine.create` refuses [int16] and [int8] on the GPU for
/// a Gemma 4 or FunctionGemma bundle (an `ArgumentError` naming the reason).
enum ActivationDataType {
  float32,
  float16,

  /// 16-bit integer activations.
  int16,

  /// 8-bit integer activations.
  int8,
}

/// The sampler sent to LiteRT-LM, every value set.
@immutable
final class Sampler {
  const Sampler({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.randomSeed,
  }) : assert(temperature >= 0 && temperature < double.infinity),
       assert(topK >= 1),
       assert(topP > 0 && topP <= 1);

  final double temperature;
  final int topK;
  final double topP;
  final int randomSeed;

  @override
  bool operator ==(Object other) =>
      other is Sampler &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(temperature, topK, topP, randomSeed);

  @override
  String toString() =>
      'Sampler(temperature: $temperature, topK: $topK, topP: $topP, '
      'randomSeed: $randomSeed)';
}

/// The sampler a `.litertlm` file declares: each value null when the file
/// does not set it.
@immutable
final class BundleSampler {
  const BundleSampler({
    this.temperature,
    this.topK,
    this.topP,
    this.randomSeed,
  });

  final double? temperature;
  final int? topK;
  final double? topP;
  final int? randomSeed;

  /// True when the file sets nothing.
  bool get isEmpty =>
      temperature == null && topK == null && topP == null && randomSeed == null;

  /// Throws an [ArgumentError] for a value no engine can sample with, as
  /// core's `SamplingParams.validate` does.
  void validate() {
    final t = temperature;
    if (t != null && !(t >= 0 && t.isFinite)) {
      throw ArgumentError.value(t, 'temperature', 'must be 0 or more');
    }
    final k = topK;
    if (k != null && k < 1) {
      throw ArgumentError.value(k, 'topK', 'must be 1 or more');
    }
    final p = topP;
    if (p != null && !(p > 0 && p <= 1)) {
      throw ArgumentError.value(p, 'topP', 'must be above 0 and at most 1');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BundleSampler &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(temperature, topK, topP, randomSeed);

  @override
  String toString() =>
      'BundleSampler(temperature: $temperature, topK: $topK, topP: $topP, '
      'randomSeed: $randomSeed)';
}

/// Which side of a message's text a kind of media goes.
enum MediaSide { beforeText, afterText }

/// Where a message's images and audio go relative to its text.
@immutable
final class MediaOrder {
  const MediaOrder({
    this.images = MediaSide.beforeText,
    this.audio = MediaSide.beforeText,
  });

  final MediaSide images;
  final MediaSide audio;

  /// Images, then audio, then text.
  static const imagesAudioText = MediaOrder();

  @override
  bool operator ==(Object other) =>
      other is MediaOrder && other.images == images && other.audio == audio;

  @override
  int get hashCode => Object.hash(images, audio);

  @override
  String toString() =>
      'MediaOrder(images: ${images.name}, audio: ${audio.name})';
}

/// What LiteRT-LM's benchmark reports about a conversation: its tokens over
/// every turn so far, the last decode's speed, the first token's latency and
/// the engine's load time. LiteRT-LM's Kotlin/Swift `BenchmarkInfo`, summed
/// over the conversation rather than its last turn.
@immutable
final class BenchmarkInfo {
  const BenchmarkInfo({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.totalTokens = 0,
    this.timeToFirstTokenMs,
    this.tokensPerSecond,
    this.initTimeMs,
  });

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final double? timeToFirstTokenMs;
  final double? tokensPerSecond;
  final double? initTimeMs;

  @override
  String toString() =>
      'BenchmarkInfo(inputTokens: $inputTokens, outputTokens: $outputTokens, '
      'totalTokens: $totalTokens, ttft: $timeToFirstTokenMs, '
      'tps: $tokensPerSecond, init: $initTimeMs)';
}

/// What one option-scoring run returned.
@immutable
final class ScoringRun {
  /// [tokenScores] is copied.
  ScoringRun({
    required List<List<double>> tokenScores,
    required this.prefillTime,
    required this.scoreTime,
  }) : tokenScores = List.unmodifiable([
         for (final scores in tokenScores) List<double>.unmodifiable(scores),
       ]);

  /// For each target, the natural-log probability of each of its tokens.
  /// Unmodifiable.
  final List<List<double>> tokenScores;

  /// Time spent on the prompt's prefill.
  final Duration prefillTime;

  /// Time spent scoring the targets.
  final Duration scoreTime;
}

/// A cancel the runtime can check and wait for. The adapter passes core's
/// `CancelToken` through it.
abstract interface class CancelSignal {
  bool get isCancelled;

  /// Completes when the signal is cancelled; never completes otherwise.
  Future<void> get whenCancelled;
}

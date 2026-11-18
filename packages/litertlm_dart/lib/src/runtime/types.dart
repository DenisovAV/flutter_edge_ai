// The runtime's own small vocabulary: values the LiteRT-LM runtime (lib/src/ffi,
// lib/src/bundle, lib/src/runtime) takes and returns, so that it never names a
// core type. The Flutter adapter maps core's types to these and back
// (lib/src/adapter/runtime_mapping.dart). Names differ from core's on purpose:
// an adapter file imports both without `hide` or a prefix.

import 'package:meta/meta.dart' show immutable;

/// Where LiteRT-LM runs a model's main graph, or one of its encoders. Its
/// [name] is LiteRT-LM's wire name (`cpu`, `gpu`, `npu`).
enum Backend { cpu, gpu, npu }

/// The numeric type of a GPU model's activations, LiteRT-LM's
/// `ActivationDataType` without I16/I8.
enum ActivationType { float32, float16 }

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

/// What LiteRT-LM reports about a conversation's turns.
@immutable
final class TurnMetrics {
  const TurnMetrics({
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
      'TurnMetrics(inputTokens: $inputTokens, outputTokens: $outputTokens, '
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

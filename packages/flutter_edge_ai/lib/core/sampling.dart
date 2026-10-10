import 'package:meta/meta.dart';

import 'model.dart';

/// Sampling parameters for a session, as the caller asked for them.
///
/// A null field is unset. An engine resolves each unset field on its own, in
/// this order:
///
/// 1. what the model file ships, when the engine can read it (a `.litertlm`
///    bundle's sampler, an ONNX model's `genai_config.json`);
/// 2. the model family's published defaults, [SamplingParams.forModelType];
/// 3. [SamplingParams.fallback].
///
/// [resolve] implements that order for engines that pick the values in Dart.
@immutable
final class SamplingParams {
  const SamplingParams({
    this.temperature,
    this.topK,
    this.topP,
    this.randomSeed,
  });

  final double? temperature;
  final int? topK;
  final double? topP;
  final int? randomSeed;

  /// True when the caller set nothing.
  bool get isEmpty =>
      temperature == null && topK == null && topP == null && randomSeed == null;

  /// Greedy decoding, the same for every engine: a top-k of 1 or a
  /// temperature of 0.
  bool get isGreedy => topK == 1 || temperature == 0;

  /// True when this asks for sampling, a temperature above 0 or a top-p with
  /// no temperature of 0, but sets no top-k: a top-k of 1 from the model or
  /// its family would then silently turn it into greedy decoding.
  bool get needsSamplingTopK =>
      topK == null && temperature != 0 && (temperature != null || topP != null);

  /// Throws an [ArgumentError] for a set value no engine can sample with.
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

  /// This, with every unset field taken from [other].
  SamplingParams orElse(SamplingParams other) => SamplingParams(
    temperature: temperature ?? other.temperature,
    topK: topK ?? other.topK,
    topP: topP ?? other.topP,
    randomSeed: randomSeed ?? other.randomSeed,
  );

  /// The defaults the family's publisher recommends, from each model's
  /// `generation_config.json` or model card. [thinking] picks between the two
  /// sets the Qwen families publish.
  ///
  /// Empty for [ModelType.general], whose models have nothing in common.
  /// Where a publisher sets no `top_k`, 50 is used, the value Hugging Face
  /// transformers applies when sampling.
  static SamplingParams forModelType(
    ModelType modelType, {
    bool thinking = false,
  }) => switch (modelType) {
    // google/gemma-3-*-it, gemma-3n-*-it, gemma-4-*-it, functiongemma-270m-it.
    ModelType.gemmaIt || ModelType.gemma4 || ModelType.functionGemma => _gemma,
    // deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B.
    ModelType.deepSeek => const SamplingParams(
      temperature: 0.6,
      topK: 50,
      topP: 0.95,
    ),
    // Qwen2.5 and Qwen3-2507 (Instruct and Thinking), and the original Qwen3.
    ModelType.qwen || ModelType.qwen3 => thinking ? _qwenThinking : _qwen,
    // Qwen3.5 4B, Qwen3.6 and Qwen3.8.
    ModelType.qwen35 =>
      thinking
          ? const SamplingParams(temperature: 1.0, topK: 20, topP: 0.95)
          : _qwen,
    // Llama 3.2 Instruct.
    ModelType.llama => const SamplingParams(
      temperature: 0.6,
      topK: 50,
      topP: 0.9,
    ),
    // Phi-4-mini-instruct and Hammer 2.1: the publishers' examples decode
    // greedily.
    ModelType.phi || ModelType.hammer => _greedy,
    ModelType.general => const SamplingParams(),
  };

  /// Used for whatever neither the caller, the model file nor the family set.
  static const fallback = SamplingParams(
    temperature: 0.8,
    topK: 40,
    topP: 0.95,
    randomSeed: 1,
  );

  /// [explicit], then [modelDefaults], then [forModelType], then [fallback].
  ///
  /// [modelDefaults] is what the model file ships, for an engine that can read
  /// it; leave it empty otherwise.
  ///
  /// When [explicit] [needsSamplingTopK], a greedy layer below ([isGreedy]) is
  /// skipped whole rather than lending its top-k of 1. When [explicit] itself
  /// is greedy, the result has top-k 1 whatever the layers say, so a
  /// temperature of 0 is greedy on every engine: some pick their sampler from
  /// top-k alone (MediaPipe samples a temperature of 0 at 1.0). Throws an
  /// [ArgumentError] when [explicit] fails [validate].
  static ResolvedSampling resolve(
    SamplingParams explicit, {
    required ModelType modelType,
    bool thinking = false,
    SamplingParams modelDefaults = const SamplingParams(),
  }) {
    explicit.validate();
    final wantsSampling = explicit.needsSamplingTopK;
    var s = explicit;
    for (final layer in [
      modelDefaults,
      forModelType(modelType, thinking: thinking),
      fallback,
    ]) {
      if (wantsSampling && layer.isGreedy) continue;
      s = s.orElse(layer);
    }
    return ResolvedSampling(
      temperature: s.temperature!,
      topK: explicit.isGreedy ? 1 : s.topK!,
      topP: s.topP!,
      randomSeed: s.randomSeed!,
    );
  }

  static const _gemma = SamplingParams(temperature: 1.0, topK: 64, topP: 0.95);
  static const _qwen = SamplingParams(temperature: 0.7, topK: 20, topP: 0.8);
  static const _qwenThinking = SamplingParams(
    temperature: 0.6,
    topK: 20,
    topP: 0.95,
  );
  static const _greedy = SamplingParams(temperature: 1.0, topK: 1, topP: 1.0);

  @override
  bool operator ==(Object other) =>
      other is SamplingParams &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(temperature, topK, topP, randomSeed);

  @override
  String toString() =>
      'SamplingParams(temperature: $temperature, topK: $topK, '
      'topP: $topP, randomSeed: $randomSeed)';
}

/// Sampling parameters with every field set: what an engine sends.
@immutable
final class ResolvedSampling {
  const ResolvedSampling({
    required this.temperature,
    required this.topK,
    required this.topP,
    required this.randomSeed,
  });

  final double temperature;
  final int topK;
  final double topP;
  final int randomSeed;

  @override
  bool operator ==(Object other) =>
      other is ResolvedSampling &&
      other.temperature == temperature &&
      other.topK == topK &&
      other.topP == topP &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(temperature, topK, topP, randomSeed);

  @override
  String toString() =>
      'ResolvedSampling(temperature: $temperature, topK: $topK, '
      'topP: $topP, randomSeed: $randomSeed)';
}

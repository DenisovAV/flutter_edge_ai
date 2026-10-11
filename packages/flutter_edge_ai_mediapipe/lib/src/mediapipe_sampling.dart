import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';

/// MediaPipe's own default top-k (tasks-genai 0.10.33).
///
/// Not a ceiling: `LlmInferenceOptions.maxTopK`, which this plugin leaves at
/// 40, does not cap a session's top-k. On Android, CPU and GPU (Mali and
/// Adreno), a session asking for 64 samples beyond the top 40 (Firebase Test
/// Lab, 2026-10-11). iOS and web are not measured.
const mediaPipeDefaultTopK = 40;

/// [SamplingParams.resolve] for a `.task` model, which ships no sampler.
///
/// A top-k the caller did not set is held to [mediaPipeDefaultTopK]: the
/// Gemma family default of 64 is above it, and above 40 is measured on
/// Android only. A top-k the caller set reaches MediaPipe unchanged. Greedy decoding is sent with a temperature of 1.0 rather than
/// 0: MediaPipe picks greedy from the top-k alone, and its GPU sampler
/// divides by the temperature regardless.
ResolvedSampling resolveMediaPipeSampling(
  SamplingParams explicit, {
  required ModelType modelType,
  bool thinking = false,
}) {
  final s = SamplingParams.resolve(
    explicit,
    modelType: modelType,
    thinking: thinking,
  );
  final topK = explicit.topK == null && s.topK > mediaPipeDefaultTopK
      ? mediaPipeDefaultTopK
      : s.topK;
  final temperature = topK == 1 && s.temperature == 0 ? 1.0 : s.temperature;
  if (topK == s.topK && temperature == s.temperature) return s;
  return ResolvedSampling(
    temperature: temperature,
    topK: topK,
    topP: s.topP,
    randomSeed: s.randomSeed,
  );
}

import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';

/// MediaPipe's top-k ceiling, `LlmInferenceOptions.maxTopK`: 40 unless the
/// engine is built with another (tasks-genai 0.10.33's options builder sets
/// 40, and this plugin never raises it). 40 is also MediaPipe's default top-k.
const mediaPipeMaxTopK = 40;

/// [SamplingParams.resolve] for a `.task` model, which ships no sampler.
///
/// A top-k the caller did not set is held to [mediaPipeMaxTopK]: the Gemma
/// family default of 64 is above it. A top-k the caller set reaches MediaPipe
/// unchanged.
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
  if (explicit.topK != null || s.topK <= mediaPipeMaxTopK) return s;
  return ResolvedSampling(
    temperature: s.temperature,
    topK: mediaPipeMaxTopK,
    topP: s.topP,
    randomSeed: s.randomSeed,
  );
}

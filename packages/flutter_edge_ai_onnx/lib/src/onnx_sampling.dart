import 'package:flutter_edge_ai/core/model.dart';
import 'package:flutter_edge_ai/core/sampling.dart';

/// [sampling] with a top-k added when it asks for sampling without one
/// ([SamplingParams.needsSamplingTopK]) and the model's `genai_config.json`
/// holds `top_k` at 1, as ORT-GenAI's model builder writes it
/// (microsoft/Phi-3-mini-4k-instruct-onnx ships `"top_k": 1`). ORT-GenAI
/// decodes greedily while top_k is 1, so the temperature would do nothing.
/// The top-k added is the one [SamplingParams.resolve] picks.
SamplingParams withSamplingTopK(
  SamplingParams sampling, {
  required ModelType modelType,
  int? configTopK,
}) {
  if (!sampling.needsSamplingTopK || configTopK == null || configTopK > 1) {
    return sampling;
  }
  return SamplingParams(
    temperature: sampling.temperature,
    topK: SamplingParams.resolve(sampling, modelType: modelType).topK,
    topP: sampling.topP,
    randomSeed: sampling.randomSeed,
  );
}

/// The generation search options for the sampling the caller set, named as
/// ORT-GenAI and Transformers.js name them.
///
/// Empty when the caller set nothing, so the model's own `genai_config.json`
/// (or `generation_config.json` on web) decides. A set temperature, top-k or
/// top-p also switches sampling on, since both runtimes ignore them while
/// `do_sample` is false, which is the ORT-GenAI default. `temperature: 0` and
/// `topK: 1` mean greedy decoding: ORT-GenAI divides by the temperature when
/// it samples, so 0 is never sent.
Map<String, Object> onnxSearchOptions(SamplingParams sampling) {
  final samples =
      sampling.temperature != null ||
      sampling.topK != null ||
      sampling.topP != null;
  final greedy = sampling.isGreedy;
  return {
    if (samples) 'do_sample': !greedy,
    if (samples && !greedy) ...{
      if (sampling.temperature case final t?) 'temperature': t,
      if (sampling.topK case final k?) 'top_k': k,
      if (sampling.topP case final p?) 'top_p': p,
    },
    if (sampling.randomSeed case final seed?) 'random_seed': seed,
  };
}

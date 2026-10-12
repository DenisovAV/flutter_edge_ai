import 'package:flutter_edge_ai/engine.dart';

/// `SamplerType.TOP_P` in `@litert-lm/core`.
const samplerTypeTopP = 2;

/// The `SessionConfig` a web `.litertlm` conversation is created with, as the
/// map that is handed to `@litert-lm/core`: `{samplerParams, maxOutputTokens?}`.
///
/// The sampler goes with an explicit `type`. Without one the config stays
/// TYPE_UNSPECIFIED and the engine replaces the whole sampler with the
/// bundle's, or with greedy when the bundle has none, so the values were
/// silently ignored.
///
/// `maxOutputTokens` has been in `SessionConfig` since at least 0.14.0.
/// Upstream counts thinking tokens against the same budget on models that
/// emit them, matching the native FFI behaviour. Vision and audio modality are
/// never set: with either flag on, `createConversation` throws, because the
/// web engine has no vision or audio executor.
///
/// Kept free of `dart:js_interop` so the VM tests can check it.
Map<String, Object> webSessionConfig(
  ResolvedSampling sampling, {
  int? maxOutputTokens,
}) => {
  'samplerParams': <String, Object>{
    'type': samplerTypeTopP,
    'temperature': sampling.temperature,
    'k': sampling.topK,
    'p': sampling.topP,
    'seed': sampling.randomSeed,
  },
  'maxOutputTokens': ?maxOutputTokens,
};

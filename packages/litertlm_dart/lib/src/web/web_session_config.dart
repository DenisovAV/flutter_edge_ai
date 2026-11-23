// The SessionConfig a web conversation is created with. Pure Dart, so the VM
// tests check it.

import '../runtime/types.dart' show Sampler;

/// `SamplerType.TOP_P` in `@litert-lm/core`.
const samplerTypeTopP = 2;

/// The `SessionConfig` a web conversation is created with, as the map that is
/// handed to `@litert-lm/core`: `{samplerParams, maxOutputTokens?}`.
///
/// The sampler goes with an explicit `type`. Without one the config stays
/// TYPE_UNSPECIFIED and the engine replaces the whole sampler with the
/// bundle's, or with greedy when the bundle has none, so the values were
/// silently ignored.
///
/// `maxOutputTokens` has been in `SessionConfig` since at least 0.14.0.
/// Upstream counts thinking tokens against the same budget on models that
/// emit them, matching the native FFI behaviour. Vision and audio are the
/// engine's (its `visionBackend` and `audioBackend`), not the session's.
Map<String, Object> webSessionConfig(
  Sampler sampling, {
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

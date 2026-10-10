import 'package:flutter_edge_ai/core/sampling.dart';

/// LiteRT-LM builds an engine's sampler at its first generation and keeps it
/// for every later conversation (google-ai-edge/LiteRT-LM#2080), so a later
/// session that asks for another sampler does not get it. This records the
/// first and says what a later generation should report.
final class EngineSamplerLatch {
  ResolvedSampling? _fixed;
  bool _fixedExplicit = false;
  bool _warned = false;

  /// Call on every generation with its conversation's [sampling] and whether
  /// the caller set any of it. Returns null when there is nothing to say;
  /// otherwise the message, with `warn` true for a release warning — once per
  /// engine, when the caller chose either sampler — and false for the verbose
  /// log, when both are defaults (a Qwen session with thinking on after one
  /// with it off).
  ({String message, bool warn})? onGeneration(
    ResolvedSampling sampling, {
    required bool explicit,
  }) {
    final fixed = _fixed;
    if (fixed == null) {
      _fixed = sampling;
      _fixedExplicit = explicit;
      return null;
    }
    if (fixed == sampling) return null;
    final message =
        'this session asks for $sampling, but LiteRT-LM keeps the sampler of '
        "the engine's first generation, $fixed, for every later conversation "
        '(google-ai-edge/LiteRT-LM#2080). Close and reload the model to change '
        'it.';
    if (!explicit && !_fixedExplicit) return (message: message, warn: false);
    if (_warned) return null;
    _warned = true;
    return (message: message, warn: true);
  }

  /// Forgets the engine's sampler: a new engine builds its own.
  void reset() {
    _fixed = null;
    _fixedExplicit = false;
    _warned = false;
  }
}

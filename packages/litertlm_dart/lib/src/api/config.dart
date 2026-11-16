// The configurations of LiteRT-LM's Kotlin and Swift APIs (EngineConfig,
// ConversationConfig, SamplerConfig, ThinkingConfig, the per-message penalty
// configs, ResponseFormat), as immutable Dart values: collections are copied
// in the constructor, so none of them has a const constructor.

import 'dart:convert' show jsonEncode;

import 'package:meta/meta.dart' show immutable;

import '../runtime/types.dart' show ActivationDataType, BundleSampler, Sampler;
import 'backend.dart';
import 'message.dart';

/// How the next token is drawn: LiteRT-LM's Kotlin/Swift `SamplerConfig`.
///
/// Every field is set, as there. A conversation that names none uses the
/// sampler the model file carries, field by field, else 0.8 / 40 / 0.95 /
/// seed 1.
@immutable
final class SamplerConfig {
  /// Throws [ArgumentError] for a value no engine samples with: a negative or
  /// non-finite [temperature], a [topK] below 1, a [topP] outside (0, 1].
  SamplerConfig({
    required this.topK,
    required this.topP,
    required this.temperature,
    this.seed = 0,
  }) {
    if (topK < 1) throw ArgumentError.value(topK, 'topK', 'must be 1 or more');
    if (!(topP > 0 && topP <= 1)) {
      throw ArgumentError.value(topP, 'topP', 'must be above 0 and at most 1');
    }
    if (!(temperature >= 0 && temperature.isFinite)) {
      throw ArgumentError.value(
        temperature,
        'temperature',
        'must be 0 or more',
      );
    }
  }

  final int topK;
  final double topP;
  final double temperature;
  final int seed;

  @override
  bool operator ==(Object other) =>
      other is SamplerConfig &&
      other.topK == topK &&
      other.topP == topP &&
      other.temperature == temperature &&
      other.seed == seed;

  @override
  int get hashCode => Object.hash(topK, topP, temperature, seed);

  @override
  String toString() =>
      'SamplerConfig(topK: $topK, topP: $topP, temperature: $temperature, '
      'seed: $seed)';
}

/// The sampler native gets for [config], or for the model file's [bundle]
/// sampler completed with 0.8 / 40 / 0.95 / seed 1 when [config] is null.
Sampler samplerFor(SamplerConfig? config, BundleSampler bundle) =>
    config != null
    ? Sampler(
        temperature: config.temperature,
        topK: config.topK,
        topP: config.topP,
        randomSeed: config.seed,
      )
    : Sampler(
        temperature: bundle.temperature ?? 0.8,
        topK: bundle.topK ?? 40,
        topP: bundle.topP ?? 0.95,
        randomSeed: bundle.randomSeed ?? 1,
      );

/// The most a thinking token budget may be: LiteRT-LM's `int` field.
const maxThinkingTokenBudget = 0x7fffffff;

/// Whether the model thinks before it answers, and how long it may:
/// LiteRT-LM's `ThinkingConfig`.
@immutable
final class ThinkingConfig {
  /// [thinkingTokenBudget] caps the tokens one generation spends thinking,
  /// with thinking on; null sets no cap. LiteRT-LM caps the first channel the
  /// bundle declares (`thought` on the Gemma 4 bundles); a bundle that
  /// declares none is not capped, which the engine says once. The
  /// thinking counts towards `maxOutputTokens`. Throws [ArgumentError] for a
  /// budget outside 1..[maxThinkingTokenBudget].
  ThinkingConfig({this.enableThinking = true, this.thinkingTokenBudget}) {
    final budget = thinkingTokenBudget;
    if (budget != null && (budget < 1 || budget > maxThinkingTokenBudget)) {
      throw ArgumentError.value(
        budget,
        'thinkingTokenBudget',
        'must be between 1 and $maxThinkingTokenBudget',
      );
    }
  }

  final bool enableThinking;
  final int? thinkingTokenBudget;

  @override
  bool operator ==(Object other) =>
      other is ThinkingConfig &&
      other.enableThinking == enableThinking &&
      other.thinkingTokenBudget == thinkingTokenBudget;

  @override
  int get hashCode => Object.hash(enableThinking, thinkingTokenBudget);

  @override
  String toString() =>
      'ThinkingConfig(enableThinking: $enableThinking, '
      'thinkingTokenBudget: $thinkingTokenBudget)';
}

/// Penalties on tokens already generated: LiteRT-LM's
/// `RepetitionPenaltyConfig`. A null field leaves LiteRT-LM's default.
@immutable
final class RepetitionPenaltyConfig {
  /// Throws [ArgumentError] for a [repetitionPenalty] below 1 or a negative
  /// [windowSize], as Kotlin's does.
  RepetitionPenaltyConfig({
    this.repetitionPenalty,
    this.presencePenalty,
    this.frequencyPenalty,
    this.windowSize,
  }) {
    final r = repetitionPenalty;
    if (r != null && !(r >= 1 && r.isFinite)) {
      throw ArgumentError.value(r, 'repetitionPenalty', 'must be 1 or more');
    }
    final w = windowSize;
    if (w != null && w < 0) {
      throw ArgumentError.value(w, 'windowSize', 'must be 0 or more');
    }
  }

  final double? repetitionPenalty;
  final double? presencePenalty;
  final double? frequencyPenalty;
  final int? windowSize;
}

/// No n-gram of [noRepeatNgramSize] tokens repeats within [windowSize]:
/// LiteRT-LM's `NoRepeatNgramConfig`.
@immutable
final class NoRepeatNgramConfig {
  /// Throws [ArgumentError] for a negative value.
  NoRepeatNgramConfig({this.noRepeatNgramSize, this.windowSize}) {
    for (final (name, value) in [
      ('noRepeatNgramSize', noRepeatNgramSize),
      ('windowSize', windowSize),
    ]) {
      if (value != null && value < 0) {
        throw ArgumentError.value(value, name, 'must be 0 or more');
      }
    }
  }

  final int? noRepeatNgramSize;
  final int? windowSize;
}

/// The shape a reply must have, enforced while it is decoded (LLGuidance):
/// LiteRT-LM's `ResponseFormat`.
@immutable
sealed class ResponseFormat {
  const ResponseFormat._();

  /// A reply that is JSON matching [schema] (a JSON Schema object).
  factory ResponseFormat.json(Map<String, Object?> schema) = JsonResponseFormat;

  /// A reply that matches [pattern] (LLGuidance's regex syntax).
  factory ResponseFormat.regex(String pattern) = RegexResponseFormat;
}

/// [ResponseFormat.json].
final class JsonResponseFormat extends ResponseFormat {
  JsonResponseFormat(Map<String, Object?> schema)
    : schema = Map.unmodifiable(schema),
      schemaJson = jsonEncode(schema),
      super._();

  /// The JSON Schema.
  final Map<String, Object?> schema;

  /// [schema] as the JSON native gets, encoded once.
  final String schemaJson;
}

/// [ResponseFormat.regex].
final class RegexResponseFormat extends ResponseFormat {
  RegexResponseFormat(this.pattern) : super._() {
    if (pattern.isEmpty) {
      throw ArgumentError.value(pattern, 'pattern', 'must not be empty');
    }
  }

  final String pattern;
}

/// What an [Engine] loads, and on what: LiteRT-LM's `EngineConfig`.
@immutable
final class EngineConfig {
  EngineConfig({
    required this.modelPath,
    Backend? backend,
    this.visionBackend,
    this.audioBackend,
    this.maxNumTokens,
    this.maxNumImages,
    this.cacheDir,
    this.activationDataType,
    this.speculativeDecoding,
  }) : backend = backend ?? const Backend.cpu();

  /// The `.litertlm` file.
  final String modelPath;

  /// Where the text model runs.
  final Backend backend;

  /// Where the vision encoder runs; null loads none, as in Kotlin and Swift.
  /// `BundleInfo.declaredVisionBackend` is what the file asks for.
  final Backend? visionBackend;

  /// Where the audio encoder runs; null loads none.
  final Backend? audioBackend;

  /// The context window: the prompt, the history and every reply, the KV
  /// cache's length. Not the reply length (that is `maxOutputTokens`). On the
  /// CPU and the GPU a value below 1024 is raised to 1024 (the cache length
  /// those bundles bake); null is 2048.
  final int? maxNumTokens;

  /// The most images one message may carry; null is 1 with a vision encoder.
  final int? maxNumImages;

  /// Where LiteRT-LM keeps its caches (compiled programs, weight caches).
  final String? cacheDir;

  /// The GPU executor's activation type; null lets the engine choose (the
  /// bundle's own, or float32 where float16 is known to break).
  final ActivationDataType? activationDataType;

  /// Speculative decoding (MTP); null is LiteRT-LM's default (off).
  final SpeculativeDecodingMode? speculativeDecoding;
}

/// One conversation's setup: LiteRT-LM's `ConversationConfig`.
@immutable
final class ConversationConfig {
  ConversationConfig({
    this.systemInstruction,
    List<Message> initialMessages = const [],
    List<Tool> tools = const [],
    this.samplerConfig,
    this.maxOutputTokens,
    this.thinkingConfig,
    this.responseFormat,
    this.speculativeDecoding,
    Map<String, Object?> extraContext = const {},
  }) : initialMessages = List.unmodifiable(initialMessages),
       tools = List.unmodifiable(tools),
       extraContext = Map.unmodifiable(extraContext) {
    final cap = maxOutputTokens;
    if (cap != null && cap < 1) {
      throw ArgumentError.value(cap, 'maxOutputTokens', 'must be 1 or more');
    }
  }

  /// The system prompt.
  final String? systemInstruction;

  /// History the conversation starts from.
  final List<Message> initialMessages;

  /// The functions the model may call. LiteRT-LM renders them into the
  /// prompt and returns calls as `Message.toolCalls`; the caller runs them
  /// and answers with `Message.tool`.
  final List<Tool> tools;

  /// The caller's sampler; null takes the model file's sampler, field by
  /// field, then 0.8 / 40 / 0.95 / seed 1. Set, it is the caller's choice:
  /// when it differs from the sampler the engine's first generation fixed
  /// (LiteRT-LM#2080), the conversation says so once.
  final SamplerConfig? samplerConfig;

  /// The most tokens a reply may have, thinking included.
  final int? maxOutputTokens;

  /// Thinking for every message; `sendMessage` can override it per message.
  final ThinkingConfig? thinkingConfig;

  /// The shape every reply must have.
  final ResponseFormat? responseFormat;

  /// Speculative decoding for this conversation; null is the engine's.
  final SpeculativeDecodingMode? speculativeDecoding;

  /// Variables for the model's prompt template.
  final Map<String, Object?> extraContext;
}

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
/// seed 1. On the web the file's sampler cannot be read: 0.8 / 40 / 0.95 /
/// seed 1, said once per engine.
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

/// Which tools the model may or must call for one message: Kotlin's and
/// Swift's `ToolChoice`, OpenAI's `tool_choice`. Passed to
/// `Conversation.sendMessage`/`sendMessageStream`, it applies to that
/// message's first round only; the rounds that answer tool results run
/// [auto], so [required] cannot loop.
@immutable
sealed class ToolChoice {
  const ToolChoice();

  /// The model decides whether to call a tool (the default).
  static const ToolChoice auto = ToolChoiceAuto();

  /// The model answers without calling a tool.
  static const ToolChoice none = ToolChoiceNone();

  /// The model calls at least one tool.
  static const ToolChoice required = ToolChoiceRequired();

  /// The model calls the tool [name].
  const factory ToolChoice.forcedFunction(String name) =
      ToolChoiceForcedFunction;

  /// The model may call only the tools [names]; with [required] it must call
  /// one of them.
  const factory ToolChoice.allowedTools(List<String> names, {bool required}) =
      ToolChoiceAllowedTools;
}

/// [ToolChoice.auto].
final class ToolChoiceAuto extends ToolChoice {
  const ToolChoiceAuto();

  @override
  String toString() => 'ToolChoice.auto';
}

/// [ToolChoice.none].
final class ToolChoiceNone extends ToolChoice {
  const ToolChoiceNone();

  @override
  String toString() => 'ToolChoice.none';
}

/// [ToolChoice.required].
final class ToolChoiceRequired extends ToolChoice {
  const ToolChoiceRequired();

  @override
  String toString() => 'ToolChoice.required';
}

/// [ToolChoice.forcedFunction].
final class ToolChoiceForcedFunction extends ToolChoice {
  const ToolChoiceForcedFunction(this.name);

  /// The tool the model calls.
  final String name;

  @override
  String toString() => 'ToolChoice.forcedFunction($name)';
}

/// [ToolChoice.allowedTools].
final class ToolChoiceAllowedTools extends ToolChoice {
  const ToolChoiceAllowedTools(this.names, {this.required = false});

  /// The tools the model may call.
  final List<String> names;

  /// Whether it must call one of them; false lets it answer without a tool.
  final bool required;

  @override
  String toString() =>
      'ToolChoice.allowedTools($names${required ? ', required: true' : ''})';
}

/// What an `Engine` loads, and on what: LiteRT-LM's `EngineConfig`.
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
    List<String>? selectedSignatures,
    this.loraRank,
    this.audioLoraRank,
  }) : backend = backend ?? const Backend.cpu(),
       selectedSignatures = selectedSignatures == null
           ? null
           : List.unmodifiable(selectedSignatures) {
    final selected = this.selectedSignatures;
    if (selected != null &&
        (selected.isEmpty || selected.any((name) => name.isEmpty))) {
      throw ArgumentError.value(
        selectedSignatures,
        'selectedSignatures',
        'must name at least one signature, none of them empty',
      );
    }
    for (final (name, rank) in [
      ('loraRank', loraRank),
      ('audioLoraRank', audioLoraRank),
    ]) {
      if (rank != null && rank < 0) {
        throw ArgumentError.value(rank, name, 'must be 0 or more');
      }
    }
  }

  /// The `.litertlm` file. On the web: a URL the page can fetch (`blob:`,
  /// `https:`) of a build the web runtime loads, such as Gemma 4's GPU
  /// export.
  final String modelPath;

  /// Where the text model runs; [Backend.cpu] when unset. On the web pass
  /// [Backend.gpu]: on the WebAssembly CPU path Gemma 4's GPU export fails
  /// its first send (see the README, "On the web").
  final Backend backend;

  /// Where the vision encoder runs; null loads none, as in Kotlin and Swift.
  /// `BundleInfo.declaredVisionBackend` is what the file asks for. On the
  /// web the GPU or the CPU (see the README, "On the web").
  final Backend? visionBackend;

  /// Where the audio encoder runs; null loads none. On the web the CPU or the
  /// GPU.
  final Backend? audioBackend;

  /// The context window: the prompt, the history and every reply, the KV
  /// cache's length. Not the reply length (that is `maxOutputTokens`). On the
  /// CPU and the GPU a value below 1024 is raised to 1024 (the cache length
  /// those bundles bake); null leaves it to LiteRT-LM (the bundle's own, else
  /// 4096). On the web it is passed through as given, with no floor.
  final int? maxNumTokens;

  /// The most images one message may carry; null is 1 with a vision encoder.
  /// On the web the most images of a whole conversation, whose space the
  /// model reserves up front.
  final int? maxNumImages;

  /// Where LiteRT-LM keeps its caches (compiled programs, weight caches).
  /// Refused on the web, which keeps none.
  final String? cacheDir;

  /// The GPU executor's activation type; null lets the engine choose (the
  /// bundle's own, or float32 where float16 is known to break). Refused on
  /// the web, whose runtime takes none.
  final ActivationDataType? activationDataType;

  /// Speculative decoding (MTP); null is LiteRT-LM's default (off).
  final SpeculativeDecodingConfig? speculativeDecoding;

  /// The main model's signatures to compile and run, for example
  /// `['prefill_1024', 'decode']`; null runs every signature. Keep at least
  /// one prefill signature and `decode`, and `verify` with speculative
  /// decoding. Each name is checked against the model before the engine is
  /// created: one the model does not have is an [ArgumentError]. Refused on
  /// the web, whose runtime takes none.
  final List<String>? selectedSignatures;

  /// The rank of the text LoRA weights, as Swift's `EngineConfig.loraRank`;
  /// null or 0 sets none. LoRA itself needs no rank: a conversation's
  /// [ConversationConfig.loraConfig] works without one on the CPU and the GPU,
  /// whose LoRA rank is read from the model's LoRA inputs. Above 0 it is
  /// passed as Swift passes it, with `set_lora_rank` and
  /// `set_supported_lora_ranks([rank])`; LiteRT-LM keeps the supported ranks
  /// only for its GPU_ARTISAN backend, which this package does not offer, and
  /// logs an ERROR line ("supported_lora_ranks is only supported for
  /// GpuArtisanConfig. The provided lora ranks will be ignored.") on every
  /// other backend each time an engine is created with a rank. Refused on the
  /// web.
  final int? loraRank;

  /// The rank of the audio encoder's LoRA weights, as Swift's
  /// `EngineConfig.audioLoraRank`; null or 0 sets none. Passed like
  /// [loraRank], with the audio setters. Refused on the web.
  final int? audioLoraRank;
}

/// A conversation's LoRA adapters, as Kotlin's `LoraConfig`: `.tflite` LoRA
/// weights for the text model ([loraPath]) and for the audio encoder
/// ([audioLoraPath]) of a bundle that has one.
///
/// The model must be exported with LoRA input signatures (LiteRT-LM's LoRA
/// Colab, step 3): a bundle whose `decode` signature has no LoRA inputs is
/// refused, because LiteRT-LM would take the adapter and leave it without
/// effect. A conversation without a [LoraConfig] on such a model runs the base
/// weights (its LoRA inputs bound to zeros). Native only: refused on the web
/// and on an NPU.
@immutable
final class LoraConfig {
  /// At least one of the two paths; an empty path is refused.
  LoraConfig({this.loraPath, this.audioLoraPath}) {
    if (loraPath == null && audioLoraPath == null) {
      throw ArgumentError('A LoraConfig needs loraPath or audioLoraPath.');
    }
    for (final (name, path) in [
      ('loraPath', loraPath),
      ('audioLoraPath', audioLoraPath),
    ]) {
      if (path != null && path.isEmpty) {
        throw ArgumentError.value(path, name, 'must not be empty');
      }
    }
  }

  /// The text model's LoRA weights (`.tflite`).
  final String? loraPath;

  /// The audio encoder's LoRA weights (`.tflite`).
  final String? audioLoraPath;

  @override
  bool operator ==(Object other) =>
      other is LoraConfig &&
      other.loraPath == loraPath &&
      other.audioLoraPath == audioLoraPath;

  @override
  int get hashCode => Object.hash(loraPath, audioLoraPath);

  @override
  String toString() =>
      'LoraConfig(loraPath: $loraPath, audioLoraPath: $audioLoraPath)';
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
    this.automaticToolCalling = true,
    this.loraConfig,
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
  /// prompt and returns calls as `Message.toolCalls`. A tool with
  /// `Tool.execute` is run by the conversation itself while
  /// [automaticToolCalling] is on; the calls of a tool without it reach the
  /// caller, who runs them and answers with `Message.tool`.
  final List<Tool> tools;

  /// The caller's sampler; null takes the model file's sampler, field by
  /// field, then 0.8 / 40 / 0.95 / seed 1. Natively each conversation's
  /// sampler is its own on the CPU and the GPU; the NPU decodes greedily. On
  /// the web the engine's first generation fixes the sampler
  /// (LiteRT-LM#2080), and a set one that differs is said once; the file's
  /// sampler cannot be read there, so null is 0.8 / 40 / 0.95 / seed 1.
  final SamplerConfig? samplerConfig;

  /// The most tokens a reply may have, thinking included.
  final int? maxOutputTokens;

  /// Thinking for every message; `sendMessage` can override it per message.
  final ThinkingConfig? thinkingConfig;

  /// The shape every reply must have.
  final ResponseFormat? responseFormat;

  /// Speculative decoding for this conversation; null is the engine's.
  final SpeculativeDecodingConfig? speculativeDecoding;

  /// This conversation's LoRA adapters, as Kotlin's
  /// `ConversationConfig.loraConfig`; null runs the base weights. Checked
  /// before the conversation is created: a file that does not exist, a model
  /// without LoRA inputs, an NPU engine and the web are refused. A
  /// conversation with an adapter always has its own native conversation,
  /// also where conversations otherwise share one.
  final LoraConfig? loraConfig;

  /// Variables for the model's prompt template.
  final Map<String, Object?> extraContext;

  /// Whether the conversation runs the model's tool calls itself, as
  /// Kotlin's and Swift's `automaticToolCalling` (default true).
  ///
  /// When a reply calls tools and no call names a declared tool without
  /// `Tool.execute`, the conversation runs the calls in order, sends their
  /// results back as one `Message.tool`, and streams the model's next reply
  /// as part of the same message: the reply ends with the first answer that
  /// calls no tool. A call to a name no tool declares does not stop this: it
  /// is answered with `Error: Tool not found: <name>`. After 25 rounds of
  /// calls in one message (Kotlin's and Swift's limit) the send fails with a
  /// `TurnFailedException`.
  ///
  /// A reply that calls a declared tool without `Tool.execute` is returned to
  /// the caller with nothing run, as when this is false; so is every call
  /// while no tool has `execute`.
  ///
  /// A stop while the tools run (`Conversation.cancel`) ends the reply with
  /// their calls: those calls have run, only their results were not sent to
  /// the model, so do not run them again blindly.
  ///
  /// With a [responseFormat] (native only: the web refuses one), as in
  /// Kotlin and Swift, a message that is not a tool response is sent without
  /// the format while some tool has `execute` (the model must be free to call
  /// it); the replies to tool responses keep it.
  final bool automaticToolCalling;
}

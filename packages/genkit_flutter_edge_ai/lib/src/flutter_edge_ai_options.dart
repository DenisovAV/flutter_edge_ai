import 'package:schemantic/schemantic.dart';

part 'flutter_edge_ai_options.g.dart';

/// Configuration options for flutter_edge_ai model inference.
///
/// These options map to flutter_edge_ai's `createChat` and `getActiveModel`
/// parameters.
@Schema(description: 'Configuration options for flutter_edge_ai inference')
abstract class $FlutterEdgeAiModelOptions {
  /// The model's context window in tokens: prompt, history and reply
  /// together, passed to `getActiveModel(maxTokens:)`. Defaults to 1024. It
  /// does not limit the reply; [maxOutputTokens] does.
  @IntegerField(minimum: 1)
  int? get maxTokens;

  /// Cap on the tokens generated for one reply, passed to
  /// `createChat(maxOutputTokens:)`. `.litertlm` models honour it; MediaPipe
  /// ignores it.
  @IntegerField(minimum: 1)
  int? get maxOutputTokens;

  /// Sampling temperature. Higher values increase randomness. Unset, the
  /// model's own sampler or its family's default applies.
  @DoubleField(minimum: 0)
  double? get temperature;

  /// Top-K sampling parameter; 1 is greedy decoding. Unset, the model's own
  /// sampler or its family's default applies.
  @IntegerField(minimum: 1)
  int? get topK;

  /// Top-P (nucleus) sampling parameter. Unset, the model's own sampler or
  /// its family's default applies.
  @DoubleField(exclusiveMinimum: 0, maximum: 1)
  double? get topP;

  /// Whether the model supports image input (multimodal).
  bool? get supportImage;

  /// Whether the model supports audio input (Gemma 3n E4B).
  bool? get supportAudio;

  /// Whether to show the model's reasoning (Gemma 4, Qwen3, DeepSeek, any
  /// bundle with a thought channel). Off, it is requested off where the model
  /// can switch it off, and hidden either way.
  bool? get enableThinking;

  /// Random seed for sampling. Unset, 1; ONNX leaves it to the model config.
  int? get randomSeed;

  /// Tool choice mode. Defaults to 'auto'. Genkit's own `toolChoice` on the
  /// request takes precedence.
  @StringField(enumValues: ['auto', 'required', 'none'])
  String? get toolChoice;

  /// System-level instruction passed natively to flutter_edge_ai's createChat().
  /// If set, takes priority over any system-role messages in the Genkit request.
  /// If not set, system messages from the request are extracted and used instead.
  String? get systemInstruction;

  /// Maximum buffer size (in tokens) for accumulating streamed function-call
  /// arguments before parsing. Increase when models emit long function-call
  /// argument payloads. When null, flutter_edge_ai uses its built-in default.
  @IntegerField(minimum: 1)
  int? get maxFunctionBufferLength;

  /// Multi-Token Prediction (speculative decoding) toggle for Gemma 4 E2B/E4B
  /// (LiteRT-LM v0.11.0+). `null` honors the model's default; `true`/`false`
  /// forces on/off. Ignored by models without an embedded MTP drafter.
  bool? get enableSpeculativeDecoding;

  /// Hardware backend for the text decoder. Null uses the engine default.
  @StringField(enumValues: ['cpu', 'gpu', 'npu'])
  String? get preferredBackend;

  /// Backend for the vision encoder. Null defaults to CPU (the Metal/WebGPU
  /// delegates can't prepare its ops). Ignored by MediaPipe.
  @StringField(enumValues: ['cpu', 'gpu', 'npu'])
  String? get preferredVisionBackend;

  /// Backend for the audio encoder. Null defaults to CPU; set 'gpu' for
  /// faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
  @StringField(enumValues: ['cpu', 'gpu', 'npu'])
  String? get preferredAudioBackend;
}

/// Configuration options for flutter_edge_ai embedding generation.
@Schema(description: 'Configuration options for flutter_edge_ai embeddings')
abstract class $FlutterEdgeAiEmbedConfig {
  /// Preferred hardware backend hint.
  @StringField(enumValues: ['cpu', 'gpu', 'npu'])
  String? get preferredBackend;

  /// What the text is embedded for: 'retrievalQuery' (the default) for a
  /// search query, 'retrievalDocument' for a document to index. EmbeddingGemma
  /// prefixes each differently, so index documents with 'retrievalDocument'.
  @StringField(enumValues: ['retrievalQuery', 'retrievalDocument'])
  String? get taskType;
}

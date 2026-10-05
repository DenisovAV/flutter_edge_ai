import 'package:schemantic/schemantic.dart';

part 'flutter_gemma_options.g.dart';

/// Configuration options for flutter_gemma model inference.
///
/// These options map to flutter_gemma's `createChat` and `getActiveModel`
/// parameters.
@Schema(description: 'Configuration options for flutter_gemma inference')
abstract class $FlutterGemmaModelOptions {
  /// Maximum number of tokens to generate. Defaults to 1024.
  int? get maxTokens;

  /// Sampling temperature. Higher values increase randomness. Defaults to 0.8.
  double? get temperature;

  /// Top-K sampling parameter. Defaults to 1.
  int? get topK;

  /// Top-P (nucleus) sampling parameter.
  double? get topP;

  /// Whether the model supports image input (multimodal).
  bool? get supportImage;

  /// Whether the model supports audio input (Gemma 3n E4B).
  bool? get supportAudio;

  /// Whether to enable thinking mode (DeepSeek-style reasoning).
  bool? get isThinking;

  /// Random seed for deterministic output. Defaults to 1.
  int? get randomSeed;

  /// Tool choice mode: 'auto', 'required', or 'none'. Defaults to 'auto'.
  String? get toolChoice;

  /// System-level instruction passed natively to flutter_gemma's createChat().
  /// If set, takes priority over any system-role messages in the Genkit request.
  /// If not set, system messages from the request are extracted and used instead.
  String? get systemInstruction;

  /// Maximum buffer size (in tokens) for accumulating streamed function-call
  /// arguments before parsing. Increase when models emit long function-call
  /// argument payloads. When null, flutter_gemma uses its built-in default.
  int? get maxFunctionBufferLength;

  /// Multi-Token Prediction (speculative decoding) toggle for Gemma 4 E2B/E4B
  /// (LiteRT-LM v0.11.0+). `null` honors the model's default; `true`/`false`
  /// forces on/off. Ignored by models without an embedded MTP drafter.
  bool? get enableSpeculativeDecoding;

  /// Hardware backend for the text decoder ('cpu', 'gpu', 'npu'). Null uses the engine default.
  String? get preferredBackend;

  /// Backend for the vision encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU
  /// (the Metal/WebGPU delegates can't prepare its ops). Ignored by MediaPipe.
  String? get preferredVisionBackend;

  /// Backend for the audio encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU;
  /// set 'gpu' for faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
  String? get preferredAudioBackend;
}

/// Configuration options for flutter_gemma embedding generation.
@Schema(description: 'Configuration options for flutter_gemma embeddings')
abstract class $FlutterGemmaEmbedConfig {
  /// Preferred hardware backend hint ('cpu', 'gpu', 'npu').
  String? get preferredBackend;
}

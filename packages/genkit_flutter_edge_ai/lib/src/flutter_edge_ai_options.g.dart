// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flutter_edge_ai_options.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

/// Configuration options for flutter_edge_ai model inference.
///
/// These options map to flutter_edge_ai's `createChat` and `getActiveModel`
/// parameters.
base class FlutterEdgeAiModelOptions {
  /// Creates a [FlutterEdgeAiModelOptions] from a JSON map.
  factory FlutterEdgeAiModelOptions.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  FlutterEdgeAiModelOptions._(this._json);

  FlutterEdgeAiModelOptions({
    int? maxTokens,
    double? temperature,
    int? topK,
    double? topP,
    bool? supportImage,
    bool? supportAudio,
    bool? enableThinking,
    int? randomSeed,
    String? toolChoice,
    String? systemInstruction,
    int? maxFunctionBufferLength,
    bool? enableSpeculativeDecoding,
    String? preferredBackend,
    String? preferredVisionBackend,
    String? preferredAudioBackend,
  }) {
    _json = {
      'maxTokens': ?maxTokens,
      'temperature': ?temperature,
      'topK': ?topK,
      'topP': ?topP,
      'supportImage': ?supportImage,
      'supportAudio': ?supportAudio,
      'enableThinking': ?enableThinking,
      'randomSeed': ?randomSeed,
      'toolChoice': ?toolChoice,
      'systemInstruction': ?systemInstruction,
      'maxFunctionBufferLength': ?maxFunctionBufferLength,
      'enableSpeculativeDecoding': ?enableSpeculativeDecoding,
      'preferredBackend': ?preferredBackend,
      'preferredVisionBackend': ?preferredVisionBackend,
      'preferredAudioBackend': ?preferredAudioBackend,
    };
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [FlutterEdgeAiModelOptions].
  static const SchemanticType<FlutterEdgeAiModelOptions> $schema =
      _FlutterEdgeAiModelOptionsTypeFactory();

  /// Maximum number of tokens to generate. Defaults to 1024.
  int? get maxTokens {
    return _json['maxTokens'] as int?;
  }

  /// Maximum number of tokens to generate. Defaults to 1024.
  set maxTokens(int? value) {
    if (value == null) {
      _json.remove('maxTokens');
    } else {
      _json['maxTokens'] = value;
    }
  }

  /// Sampling temperature. Higher values increase randomness. Defaults to 0.8.
  double? get temperature {
    return (_json['temperature'] as num?)?.toDouble();
  }

  /// Sampling temperature. Higher values increase randomness. Defaults to 0.8.
  set temperature(double? value) {
    if (value == null) {
      _json.remove('temperature');
    } else {
      _json['temperature'] = value;
    }
  }

  /// Top-K sampling parameter. Defaults to 1.
  int? get topK {
    return _json['topK'] as int?;
  }

  /// Top-K sampling parameter. Defaults to 1.
  set topK(int? value) {
    if (value == null) {
      _json.remove('topK');
    } else {
      _json['topK'] = value;
    }
  }

  /// Top-P (nucleus) sampling parameter.
  double? get topP {
    return (_json['topP'] as num?)?.toDouble();
  }

  /// Top-P (nucleus) sampling parameter.
  set topP(double? value) {
    if (value == null) {
      _json.remove('topP');
    } else {
      _json['topP'] = value;
    }
  }

  /// Whether the model supports image input (multimodal).
  bool? get supportImage {
    return _json['supportImage'] as bool?;
  }

  /// Whether the model supports image input (multimodal).
  set supportImage(bool? value) {
    if (value == null) {
      _json.remove('supportImage');
    } else {
      _json['supportImage'] = value;
    }
  }

  /// Whether the model supports audio input (Gemma 3n E4B).
  bool? get supportAudio {
    return _json['supportAudio'] as bool?;
  }

  /// Whether the model supports audio input (Gemma 3n E4B).
  set supportAudio(bool? value) {
    if (value == null) {
      _json.remove('supportAudio');
    } else {
      _json['supportAudio'] = value;
    }
  }

  /// Whether to show the model's reasoning (Gemma 4, Qwen3, DeepSeek, any
  /// bundle with a thought channel). Off, it is requested off where the model
  /// can switch it off, and hidden either way.
  bool? get enableThinking {
    return _json['enableThinking'] as bool?;
  }

  /// Whether to show the model's reasoning (Gemma 4, Qwen3, DeepSeek, any
  /// bundle with a thought channel). Off, it is requested off where the model
  /// can switch it off, and hidden either way.
  set enableThinking(bool? value) {
    if (value == null) {
      _json.remove('enableThinking');
    } else {
      _json['enableThinking'] = value;
    }
  }

  /// Random seed for deterministic output. Defaults to 1.
  int? get randomSeed {
    return _json['randomSeed'] as int?;
  }

  /// Random seed for deterministic output. Defaults to 1.
  set randomSeed(int? value) {
    if (value == null) {
      _json.remove('randomSeed');
    } else {
      _json['randomSeed'] = value;
    }
  }

  /// Tool choice mode: 'auto', 'required', or 'none'. Defaults to 'auto'.
  String? get toolChoice {
    return _json['toolChoice'] as String?;
  }

  /// Tool choice mode: 'auto', 'required', or 'none'. Defaults to 'auto'.
  set toolChoice(String? value) {
    if (value == null) {
      _json.remove('toolChoice');
    } else {
      _json['toolChoice'] = value;
    }
  }

  /// System-level instruction passed natively to flutter_edge_ai's createChat().
  /// If set, takes priority over any system-role messages in the Genkit request.
  /// If not set, system messages from the request are extracted and used instead.
  String? get systemInstruction {
    return _json['systemInstruction'] as String?;
  }

  /// System-level instruction passed natively to flutter_edge_ai's createChat().
  /// If set, takes priority over any system-role messages in the Genkit request.
  /// If not set, system messages from the request are extracted and used instead.
  set systemInstruction(String? value) {
    if (value == null) {
      _json.remove('systemInstruction');
    } else {
      _json['systemInstruction'] = value;
    }
  }

  /// Maximum buffer size (in tokens) for accumulating streamed function-call
  /// arguments before parsing. Increase when models emit long function-call
  /// argument payloads. When null, flutter_edge_ai uses its built-in default.
  int? get maxFunctionBufferLength {
    return _json['maxFunctionBufferLength'] as int?;
  }

  /// Maximum buffer size (in tokens) for accumulating streamed function-call
  /// arguments before parsing. Increase when models emit long function-call
  /// argument payloads. When null, flutter_edge_ai uses its built-in default.
  set maxFunctionBufferLength(int? value) {
    if (value == null) {
      _json.remove('maxFunctionBufferLength');
    } else {
      _json['maxFunctionBufferLength'] = value;
    }
  }

  /// Multi-Token Prediction (speculative decoding) toggle for Gemma 4 E2B/E4B
  /// (LiteRT-LM v0.11.0+). `null` honors the model's default; `true`/`false`
  /// forces on/off. Ignored by models without an embedded MTP drafter.
  bool? get enableSpeculativeDecoding {
    return _json['enableSpeculativeDecoding'] as bool?;
  }

  /// Multi-Token Prediction (speculative decoding) toggle for Gemma 4 E2B/E4B
  /// (LiteRT-LM v0.11.0+). `null` honors the model's default; `true`/`false`
  /// forces on/off. Ignored by models without an embedded MTP drafter.
  set enableSpeculativeDecoding(bool? value) {
    if (value == null) {
      _json.remove('enableSpeculativeDecoding');
    } else {
      _json['enableSpeculativeDecoding'] = value;
    }
  }

  /// Hardware backend for the text decoder ('cpu', 'gpu', 'npu'). Null uses the engine default.
  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

  /// Hardware backend for the text decoder ('cpu', 'gpu', 'npu'). Null uses the engine default.
  set preferredBackend(String? value) {
    if (value == null) {
      _json.remove('preferredBackend');
    } else {
      _json['preferredBackend'] = value;
    }
  }

  /// Backend for the vision encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU
  /// (the Metal/WebGPU delegates can't prepare its ops). Ignored by MediaPipe.
  String? get preferredVisionBackend {
    return _json['preferredVisionBackend'] as String?;
  }

  /// Backend for the vision encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU
  /// (the Metal/WebGPU delegates can't prepare its ops). Ignored by MediaPipe.
  set preferredVisionBackend(String? value) {
    if (value == null) {
      _json.remove('preferredVisionBackend');
    } else {
      _json['preferredVisionBackend'] = value;
    }
  }

  /// Backend for the audio encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU;
  /// set 'gpu' for faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
  String? get preferredAudioBackend {
    return _json['preferredAudioBackend'] as String?;
  }

  /// Backend for the audio encoder ('cpu', 'gpu', 'npu'). Null defaults to CPU;
  /// set 'gpu' for faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
  set preferredAudioBackend(String? value) {
    if (value == null) {
      _json.remove('preferredAudioBackend');
    } else {
      _json['preferredAudioBackend'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [FlutterEdgeAiModelOptions] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _FlutterEdgeAiModelOptionsTypeFactory
    extends SchemanticType<FlutterEdgeAiModelOptions> {
  const _FlutterEdgeAiModelOptionsTypeFactory();

  @override
  FlutterEdgeAiModelOptions parse(Object? json) {
    return FlutterEdgeAiModelOptions._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'FlutterEdgeAiModelOptions',
    definition: $Schema
        .object(
          properties: {
            'maxTokens': $Schema.integer(),
            'temperature': $Schema.number(),
            'topK': $Schema.integer(),
            'topP': $Schema.number(),
            'supportImage': $Schema.boolean(),
            'supportAudio': $Schema.boolean(),
            'enableThinking': $Schema.boolean(),
            'randomSeed': $Schema.integer(),
            'toolChoice': $Schema.string(),
            'systemInstruction': $Schema.string(),
            'maxFunctionBufferLength': $Schema.integer(),
            'enableSpeculativeDecoding': $Schema.boolean(),
            'preferredBackend': $Schema.string(),
            'preferredVisionBackend': $Schema.string(),
            'preferredAudioBackend': $Schema.string(),
          },
          description: 'Configuration options for flutter_edge_ai inference',
        )
        .value,
    dependencies: [],
  );
}

/// Configuration options for flutter_edge_ai embedding generation.
base class FlutterEdgeAiEmbedConfig {
  /// Creates a [FlutterEdgeAiEmbedConfig] from a JSON map.
  factory FlutterEdgeAiEmbedConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  FlutterEdgeAiEmbedConfig._(this._json);

  FlutterEdgeAiEmbedConfig({String? preferredBackend}) {
    _json = {'preferredBackend': ?preferredBackend};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [FlutterEdgeAiEmbedConfig].
  static const SchemanticType<FlutterEdgeAiEmbedConfig> $schema =
      _FlutterEdgeAiEmbedConfigTypeFactory();

  /// Preferred hardware backend hint ('cpu', 'gpu', 'npu').
  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

  /// Preferred hardware backend hint ('cpu', 'gpu', 'npu').
  set preferredBackend(String? value) {
    if (value == null) {
      _json.remove('preferredBackend');
    } else {
      _json['preferredBackend'] = value;
    }
  }

  @override
  String toString() {
    return _json.toString();
  }

  /// Serializes this [FlutterEdgeAiEmbedConfig] to a JSON map.
  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _FlutterEdgeAiEmbedConfigTypeFactory
    extends SchemanticType<FlutterEdgeAiEmbedConfig> {
  const _FlutterEdgeAiEmbedConfigTypeFactory();

  @override
  FlutterEdgeAiEmbedConfig parse(Object? json) {
    return FlutterEdgeAiEmbedConfig._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'FlutterEdgeAiEmbedConfig',
    definition: $Schema
        .object(
          properties: {'preferredBackend': $Schema.string()},
          description: 'Configuration options for flutter_edge_ai embeddings',
        )
        .value,
    dependencies: [],
  );
}

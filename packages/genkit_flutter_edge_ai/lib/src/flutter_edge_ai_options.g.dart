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
    int? maxOutputTokens,
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
      'maxOutputTokens': ?maxOutputTokens,
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

  /// The model's context window in tokens: prompt, history and reply
  /// together, passed to `getActiveModel(maxTokens:)`. Defaults to 1024. It
  /// does not limit the reply; [maxOutputTokens] does.
  int? get maxTokens {
    return (_json['maxTokens'] as num?)?.toInt();
  }

  /// The model's context window in tokens: prompt, history and reply
  /// together, passed to `getActiveModel(maxTokens:)`. Defaults to 1024. It
  /// does not limit the reply; [maxOutputTokens] does.
  set maxTokens(int? value) {
    if (value == null) {
      _json.remove('maxTokens');
    } else {
      _json['maxTokens'] = value;
    }
  }

  /// Cap on the tokens generated for one reply, passed to
  /// `createChat(maxOutputTokens:)`. `.litertlm` models honour it; MediaPipe
  /// ignores it.
  int? get maxOutputTokens {
    return (_json['maxOutputTokens'] as num?)?.toInt();
  }

  /// Cap on the tokens generated for one reply, passed to
  /// `createChat(maxOutputTokens:)`. `.litertlm` models honour it; MediaPipe
  /// ignores it.
  set maxOutputTokens(int? value) {
    if (value == null) {
      _json.remove('maxOutputTokens');
    } else {
      _json['maxOutputTokens'] = value;
    }
  }

  /// Sampling temperature. Higher values increase randomness. Unset, the
  /// model's own sampler or its family's default applies.
  double? get temperature {
    return (_json['temperature'] as num?)?.toDouble();
  }

  /// Sampling temperature. Higher values increase randomness. Unset, the
  /// model's own sampler or its family's default applies.
  set temperature(double? value) {
    if (value == null) {
      _json.remove('temperature');
    } else {
      _json['temperature'] = value;
    }
  }

  /// Top-K sampling parameter; 1 is greedy decoding. Unset, the model's own
  /// sampler or its family's default applies.
  int? get topK {
    return (_json['topK'] as num?)?.toInt();
  }

  /// Top-K sampling parameter; 1 is greedy decoding. Unset, the model's own
  /// sampler or its family's default applies.
  set topK(int? value) {
    if (value == null) {
      _json.remove('topK');
    } else {
      _json['topK'] = value;
    }
  }

  /// Top-P (nucleus) sampling parameter. Unset, the model's own sampler or
  /// its family's default applies.
  double? get topP {
    return (_json['topP'] as num?)?.toDouble();
  }

  /// Top-P (nucleus) sampling parameter. Unset, the model's own sampler or
  /// its family's default applies.
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

  /// Random seed for sampling. Unset, 1; ONNX leaves it to the model config.
  int? get randomSeed {
    return (_json['randomSeed'] as num?)?.toInt();
  }

  /// Random seed for sampling. Unset, 1; ONNX leaves it to the model config.
  set randomSeed(int? value) {
    if (value == null) {
      _json.remove('randomSeed');
    } else {
      _json['randomSeed'] = value;
    }
  }

  /// Tool choice mode. Defaults to 'auto'. Genkit's own `toolChoice` on the
  /// request takes precedence.
  String? get toolChoice {
    return _json['toolChoice'] as String?;
  }

  /// Tool choice mode. Defaults to 'auto'. Genkit's own `toolChoice` on the
  /// request takes precedence.
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
    return (_json['maxFunctionBufferLength'] as num?)?.toInt();
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

  /// Hardware backend for the text decoder. Null uses the engine default.
  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

  /// Hardware backend for the text decoder. Null uses the engine default.
  set preferredBackend(String? value) {
    if (value == null) {
      _json.remove('preferredBackend');
    } else {
      _json['preferredBackend'] = value;
    }
  }

  /// Backend for the vision encoder. Null defaults to CPU (the Metal/WebGPU
  /// delegates can't prepare its ops). Ignored by MediaPipe.
  String? get preferredVisionBackend {
    return _json['preferredVisionBackend'] as String?;
  }

  /// Backend for the vision encoder. Null defaults to CPU (the Metal/WebGPU
  /// delegates can't prepare its ops). Ignored by MediaPipe.
  set preferredVisionBackend(String? value) {
    if (value == null) {
      _json.remove('preferredVisionBackend');
    } else {
      _json['preferredVisionBackend'] = value;
    }
  }

  /// Backend for the audio encoder. Null defaults to CPU; set 'gpu' for
  /// faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
  String? get preferredAudioBackend {
    return _json['preferredAudioBackend'] as String?;
  }

  /// Backend for the audio encoder. Null defaults to CPU; set 'gpu' for
  /// faster audio (Gemma 3n ~2x on Metal). Ignored by MediaPipe.
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
    definition: <String, Object?>{
      'type': 'object',
      'description': 'Configuration options for flutter_edge_ai inference',
      'properties': <String, Object?>{
        'maxTokens': <String, Object?>{'type': 'integer', 'minimum': 1},
        'maxOutputTokens': <String, Object?>{'type': 'integer', 'minimum': 1},
        'temperature': <String, Object?>{'type': 'number', 'minimum': 0},
        'topK': <String, Object?>{'type': 'integer', 'minimum': 1},
        'topP': <String, Object?>{
          'type': 'number',
          'maximum': 1,
          'exclusiveMinimum': 0,
        },
        'supportImage': <String, Object?>{'type': 'boolean'},
        'supportAudio': <String, Object?>{'type': 'boolean'},
        'enableThinking': <String, Object?>{'type': 'boolean'},
        'randomSeed': <String, Object?>{'type': 'integer'},
        'toolChoice': <String, Object?>{
          'type': 'string',
          'enum': ['auto', 'required', 'none'],
        },
        'systemInstruction': <String, Object?>{'type': 'string'},
        'maxFunctionBufferLength': <String, Object?>{
          'type': 'integer',
          'minimum': 1,
        },
        'enableSpeculativeDecoding': <String, Object?>{'type': 'boolean'},
        'preferredBackend': <String, Object?>{
          'type': 'string',
          'enum': ['cpu', 'gpu', 'npu'],
        },
        'preferredVisionBackend': <String, Object?>{
          'type': 'string',
          'enum': ['cpu', 'gpu', 'npu'],
        },
        'preferredAudioBackend': <String, Object?>{
          'type': 'string',
          'enum': ['cpu', 'gpu', 'npu'],
        },
      },
    },
    dependencies: [],
  );
}

/// Configuration options for flutter_edge_ai embedding generation.
base class FlutterEdgeAiEmbedConfig {
  /// Creates a [FlutterEdgeAiEmbedConfig] from a JSON map.
  factory FlutterEdgeAiEmbedConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  FlutterEdgeAiEmbedConfig._(this._json);

  FlutterEdgeAiEmbedConfig({String? preferredBackend, String? taskType}) {
    _json = {'preferredBackend': ?preferredBackend, 'taskType': ?taskType};
  }

  late final Map<String, dynamic> _json;

  /// The JSON schema and type descriptor for [FlutterEdgeAiEmbedConfig].
  static const SchemanticType<FlutterEdgeAiEmbedConfig> $schema =
      _FlutterEdgeAiEmbedConfigTypeFactory();

  /// Preferred hardware backend hint.
  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

  /// Preferred hardware backend hint.
  set preferredBackend(String? value) {
    if (value == null) {
      _json.remove('preferredBackend');
    } else {
      _json['preferredBackend'] = value;
    }
  }

  /// What the text is embedded for: 'retrievalQuery' (the default) for a
  /// search query, 'retrievalDocument' for a document to index. EmbeddingGemma
  /// prefixes each differently, so index documents with 'retrievalDocument'.
  String? get taskType {
    return _json['taskType'] as String?;
  }

  /// What the text is embedded for: 'retrievalQuery' (the default) for a
  /// search query, 'retrievalDocument' for a document to index. EmbeddingGemma
  /// prefixes each differently, so index documents with 'retrievalDocument'.
  set taskType(String? value) {
    if (value == null) {
      _json.remove('taskType');
    } else {
      _json['taskType'] = value;
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
    definition: <String, Object?>{
      'type': 'object',
      'description': 'Configuration options for flutter_edge_ai embeddings',
      'properties': <String, Object?>{
        'preferredBackend': <String, Object?>{
          'type': 'string',
          'enum': ['cpu', 'gpu', 'npu'],
        },
        'taskType': <String, Object?>{
          'type': 'string',
          'enum': ['retrievalQuery', 'retrievalDocument'],
        },
      },
    },
    dependencies: [],
  );
}

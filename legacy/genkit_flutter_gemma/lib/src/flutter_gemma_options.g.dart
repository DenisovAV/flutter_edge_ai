// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'flutter_gemma_options.dart';

// **************************************************************************
// SchemaGenerator
// **************************************************************************

base class FlutterGemmaModelOptions {
  factory FlutterGemmaModelOptions.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  FlutterGemmaModelOptions._(this._json);

  FlutterGemmaModelOptions({
    int? maxTokens,
    double? temperature,
    int? topK,
    double? topP,
    bool? supportImage,
    bool? supportAudio,
    bool? isThinking,
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
      'isThinking': ?isThinking,
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

  static const SchemanticType<FlutterGemmaModelOptions> $schema =
      _FlutterGemmaModelOptionsTypeFactory();

  int? get maxTokens {
    return _json['maxTokens'] as int?;
  }

  set maxTokens(int? value) {
    if (value == null) {
      _json.remove('maxTokens');
    } else {
      _json['maxTokens'] = value;
    }
  }

  double? get temperature {
    return (_json['temperature'] as num?)?.toDouble();
  }

  set temperature(double? value) {
    if (value == null) {
      _json.remove('temperature');
    } else {
      _json['temperature'] = value;
    }
  }

  int? get topK {
    return _json['topK'] as int?;
  }

  set topK(int? value) {
    if (value == null) {
      _json.remove('topK');
    } else {
      _json['topK'] = value;
    }
  }

  double? get topP {
    return (_json['topP'] as num?)?.toDouble();
  }

  set topP(double? value) {
    if (value == null) {
      _json.remove('topP');
    } else {
      _json['topP'] = value;
    }
  }

  bool? get supportImage {
    return _json['supportImage'] as bool?;
  }

  set supportImage(bool? value) {
    if (value == null) {
      _json.remove('supportImage');
    } else {
      _json['supportImage'] = value;
    }
  }

  bool? get supportAudio {
    return _json['supportAudio'] as bool?;
  }

  set supportAudio(bool? value) {
    if (value == null) {
      _json.remove('supportAudio');
    } else {
      _json['supportAudio'] = value;
    }
  }

  bool? get isThinking {
    return _json['isThinking'] as bool?;
  }

  set isThinking(bool? value) {
    if (value == null) {
      _json.remove('isThinking');
    } else {
      _json['isThinking'] = value;
    }
  }

  int? get randomSeed {
    return _json['randomSeed'] as int?;
  }

  set randomSeed(int? value) {
    if (value == null) {
      _json.remove('randomSeed');
    } else {
      _json['randomSeed'] = value;
    }
  }

  String? get toolChoice {
    return _json['toolChoice'] as String?;
  }

  set toolChoice(String? value) {
    if (value == null) {
      _json.remove('toolChoice');
    } else {
      _json['toolChoice'] = value;
    }
  }

  String? get systemInstruction {
    return _json['systemInstruction'] as String?;
  }

  set systemInstruction(String? value) {
    if (value == null) {
      _json.remove('systemInstruction');
    } else {
      _json['systemInstruction'] = value;
    }
  }

  int? get maxFunctionBufferLength {
    return _json['maxFunctionBufferLength'] as int?;
  }

  set maxFunctionBufferLength(int? value) {
    if (value == null) {
      _json.remove('maxFunctionBufferLength');
    } else {
      _json['maxFunctionBufferLength'] = value;
    }
  }

  bool? get enableSpeculativeDecoding {
    return _json['enableSpeculativeDecoding'] as bool?;
  }

  set enableSpeculativeDecoding(bool? value) {
    if (value == null) {
      _json.remove('enableSpeculativeDecoding');
    } else {
      _json['enableSpeculativeDecoding'] = value;
    }
  }

  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

  set preferredBackend(String? value) {
    if (value == null) {
      _json.remove('preferredBackend');
    } else {
      _json['preferredBackend'] = value;
    }
  }

  String? get preferredVisionBackend {
    return _json['preferredVisionBackend'] as String?;
  }

  set preferredVisionBackend(String? value) {
    if (value == null) {
      _json.remove('preferredVisionBackend');
    } else {
      _json['preferredVisionBackend'] = value;
    }
  }

  String? get preferredAudioBackend {
    return _json['preferredAudioBackend'] as String?;
  }

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

  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _FlutterGemmaModelOptionsTypeFactory
    extends SchemanticType<FlutterGemmaModelOptions> {
  const _FlutterGemmaModelOptionsTypeFactory();

  @override
  FlutterGemmaModelOptions parse(Object? json) {
    return FlutterGemmaModelOptions._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'FlutterGemmaModelOptions',
    definition: $Schema
        .object(
          properties: {
            'maxTokens': $Schema.integer(),
            'temperature': $Schema.number(),
            'topK': $Schema.integer(),
            'topP': $Schema.number(),
            'supportImage': $Schema.boolean(),
            'supportAudio': $Schema.boolean(),
            'isThinking': $Schema.boolean(),
            'randomSeed': $Schema.integer(),
            'toolChoice': $Schema.string(),
            'systemInstruction': $Schema.string(),
            'maxFunctionBufferLength': $Schema.integer(),
            'enableSpeculativeDecoding': $Schema.boolean(),
            'preferredBackend': $Schema.string(),
            'preferredVisionBackend': $Schema.string(),
            'preferredAudioBackend': $Schema.string(),
          },
          required: [],
          description: 'Configuration options for flutter_gemma inference',
        )
        .value,
    dependencies: [],
  );
}

base class FlutterGemmaEmbedConfig {
  factory FlutterGemmaEmbedConfig.fromJson(Map<String, dynamic> json) =>
      $schema.parse(json);

  FlutterGemmaEmbedConfig._(this._json);

  FlutterGemmaEmbedConfig({String? preferredBackend}) {
    _json = {'preferredBackend': ?preferredBackend};
  }

  late final Map<String, dynamic> _json;

  static const SchemanticType<FlutterGemmaEmbedConfig> $schema =
      _FlutterGemmaEmbedConfigTypeFactory();

  String? get preferredBackend {
    return _json['preferredBackend'] as String?;
  }

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

  Map<String, dynamic> toJson() {
    return _json;
  }
}

base class _FlutterGemmaEmbedConfigTypeFactory
    extends SchemanticType<FlutterGemmaEmbedConfig> {
  const _FlutterGemmaEmbedConfigTypeFactory();

  @override
  FlutterGemmaEmbedConfig parse(Object? json) {
    return FlutterGemmaEmbedConfig._(json as Map<String, dynamic>);
  }

  @override
  JsonSchemaMetadata get schemaMetadata => JsonSchemaMetadata(
    name: 'FlutterGemmaEmbedConfig',
    definition: $Schema
        .object(
          properties: {'preferredBackend': $Schema.string()},
          required: [],
          description: 'Configuration options for flutter_gemma embeddings',
        )
        .value,
    dependencies: [],
  );
}

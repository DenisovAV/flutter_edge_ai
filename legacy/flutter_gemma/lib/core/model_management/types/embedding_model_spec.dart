part of '../model_specs.dart';

/// Model file for embedding models (.bin files)
class EmbeddingModelFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  EmbeddingModelFile({required ModelSource source, required String filename})
    : _source = source,
      _filename = filename;

  /// Creates EmbeddingModelFile from ModelSource
  factory EmbeddingModelFile.fromSource(ModelSource source) {
    final filename = InferenceModelFile._extractFilenameFromSource(source);
    return EmbeddingModelFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.embeddingModelFile;

  @override
  bool get isRequired => true;
}

/// Tokenizer file for embedding models (.json files)
class EmbeddingTokenizerFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  EmbeddingTokenizerFile({
    required ModelSource source,
    required String filename,
  }) : _source = source,
       _filename = filename;

  /// Creates EmbeddingTokenizerFile from ModelSource, namespaced by
  /// [modelId] (the owning EmbeddingModelSpec's own model-file basename,
  /// without extension) — this is what keeps embeddinggemma's and Gecko's
  /// tokenizers distinct even though both are literally named
  /// `sentencepiece.model`.
  factory EmbeddingTokenizerFile.fromSource(
    ModelSource source, {
    required String modelId,
  }) {
    final basename = InferenceModelFile._extractFilenameFromSource(source);
    final filename = FileNameUtils.namespaced(modelId, basename);
    return EmbeddingTokenizerFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.embeddingTokenizerFile;

  @override
  bool get isRequired => true;
}

/// Specification for embedding models (model.bin + tokenizer.json)
class EmbeddingModelSpec extends ModelSpec {
  final String _name;
  final ModelSource _modelSource;
  final ModelSource _tokenizerSource;
  final ModelReplacePolicy _replacePolicy;

  EmbeddingModelSpec({
    required String name,
    required ModelSource modelSource,
    required ModelSource tokenizerSource,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) : _name = name,
       _modelSource = modelSource,
       _tokenizerSource = tokenizerSource,
       _replacePolicy = replacePolicy;

  /// Legacy compatibility constructor for String URLs
  factory EmbeddingModelSpec.fromLegacyUrl({
    required String name,
    required String modelUrl,
    required String tokenizerUrl,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) {
    return EmbeddingModelSpec(
      name: name,
      modelSource: InferenceModelSpec._urlToSource(modelUrl),
      tokenizerSource: InferenceModelSpec._urlToSource(tokenizerUrl),
      replacePolicy: replacePolicy,
    );
  }

  @override
  ModelManagementType get type => ModelManagementType.embedding;

  @override
  String get name => _name;

  @override
  ModelReplacePolicy get replacePolicy => _replacePolicy;

  @override
  List<ModelFile> get files {
    final modelFile = EmbeddingModelFile.fromSource(_modelSource);
    final modelId = FileNameUtils.getBaseName(modelFile.filename);
    return [
      modelFile,
      EmbeddingTokenizerFile.fromSource(_tokenizerSource, modelId: modelId),
    ];
  }

  /// Modern type-safe getters
  ModelSource get modelSource => _modelSource;
  ModelSource get tokenizerSource => _tokenizerSource;

  /// Legacy getters for backward compatibility (WEB PLATFORM ONLY)
  @Deprecated('Use modelSource instead. Web platform compatibility only.')
  String get modelUrl => InferenceModelSpec._sourceToUrl(_modelSource);

  @Deprecated('Use tokenizerSource instead. Web platform compatibility only.')
  String get tokenizerUrl => InferenceModelSpec._sourceToUrl(_tokenizerSource);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! EmbeddingModelSpec) return false;

    return _name == other._name &&
        _modelSource == other._modelSource &&
        _tokenizerSource == other._tokenizerSource &&
        _replacePolicy == other._replacePolicy;
  }

  @override
  int get hashCode {
    return Object.hash(_name, _modelSource, _tokenizerSource, _replacePolicy);
  }
}

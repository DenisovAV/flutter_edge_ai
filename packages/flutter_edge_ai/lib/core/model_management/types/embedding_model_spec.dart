part of '../model_specs.dart';

String? _validateEmbeddingFilename(String? filename, String parameterName) {
  if (filename == null) return null;
  return FileNameUtils.validatePortableFileNameSegment(
    filename,
    parameterName: parameterName,
  );
}

void _rejectEmbeddingFilenameCollision(EmbeddingModelSpec spec) {
  final files = spec.files;
  if (files[0].filename == files[1].filename) {
    throw ArgumentError.value(
      files[1].filename,
      'tokenizerFilename',
      'must differ from the resolved model filename',
    );
  }
}

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
  final String? _modelFilename;
  final String? _tokenizerFilename;
  final ModelReplacePolicy _replacePolicy;

  /// [modelFilename] and [tokenizerFilename] optionally pin the exact install
  /// identities independently from source URL basenames. Use them for
  /// immutable/versioned artifacts. Each must be a plain basename; when
  /// omitted, the historical source-derived namespacing behavior is retained.
  EmbeddingModelSpec({
    required String name,
    required ModelSource modelSource,
    required ModelSource tokenizerSource,
    String? modelFilename,
    String? tokenizerFilename,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) : _name = name,
       _modelSource = modelSource,
       _tokenizerSource = tokenizerSource,
       _modelFilename = _validateEmbeddingFilename(
         modelFilename,
         'modelFilename',
       ),
       _tokenizerFilename = _validateEmbeddingFilename(
         tokenizerFilename,
         'tokenizerFilename',
       ),
       _replacePolicy = replacePolicy {
    _rejectEmbeddingFilenameCollision(this);
  }

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
    final modelFile = _modelFilename == null
        ? EmbeddingModelFile.fromSource(_modelSource)
        : EmbeddingModelFile(source: _modelSource, filename: _modelFilename);
    final modelId = FileNameUtils.getBaseName(modelFile.filename);
    return [
      modelFile,
      if (_tokenizerFilename == null)
        EmbeddingTokenizerFile.fromSource(_tokenizerSource, modelId: modelId)
      else
        EmbeddingTokenizerFile(
          source: _tokenizerSource,
          filename: _tokenizerFilename,
        ),
    ];
  }

  /// Modern type-safe getters
  ModelSource get modelSource => _modelSource;
  ModelSource get tokenizerSource => _tokenizerSource;
  String? get modelFilename => _modelFilename;
  String? get tokenizerFilename => _tokenizerFilename;

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
        _modelFilename == other._modelFilename &&
        _tokenizerFilename == other._tokenizerFilename &&
        _replacePolicy == other._replacePolicy;
  }

  @override
  int get hashCode {
    return Object.hash(
      _name,
      _modelSource,
      _tokenizerSource,
      _modelFilename,
      _tokenizerFilename,
      _replacePolicy,
    );
  }
}

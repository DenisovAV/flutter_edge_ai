part of '../model_specs.dart';

String? _validateEmbeddingFilename(String? filename, String parameterName) {
  if (filename == null) return null;
  return FileNameUtils.validatePortableFileNameSegment(
    filename,
    parameterName: parameterName,
  );
}

/// The invariants every construction path gets (R5 §5.1): the builder,
/// `ensureModelReadyFromSpec`, identity restore, the managers and direct
/// construction all go through the constructor.
void _checkEmbeddingSpec(EmbeddingModelSpec spec) {
  if (spec._tokenizerSource == null && spec._tokenizerFilename != null) {
    throw ArgumentError.value(
      spec._tokenizerFilename,
      'tokenizerFilename',
      'names a tokenizer file, but no tokenizerSource was given',
    );
  }
  final files = spec.files;
  final modelFilename = files[0].filename;
  if (isSelfContainedEmbeddingFilename(modelFilename)) {
    if (spec._tokenizerSource != null) {
      throw ArgumentError.value(
        spec._tokenizerSource,
        'tokenizerSource',
        "'$modelFilename' is self-contained and carries its own "
            'tokenizer; do not pass one',
      );
    }
    return;
  }
  if (spec._tokenizerSource == null) {
    throw ArgumentError.value(
      null,
      'tokenizerSource',
      "'$modelFilename' needs a tokenizer (only .litertlm and .gguf containers carry "
          'its own)',
    );
  }
  if (modelFilename == files[1].filename) {
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

/// Specification for an embedding model: a model file plus its tokenizer
/// (`.tflite`, `.onnx`, …), or a single `.litertlm` or `.gguf` file that carries its
/// own tokenizer ([isSelfContained]).
final class EmbeddingModelSpec extends ModelSpec {
  final String _name;
  final ModelSource _modelSource;
  final ModelSource? _tokenizerSource;
  final String? _modelFilename;
  final String? _tokenizerFilename;
  final ModelReplacePolicy _replacePolicy;

  /// [modelFilename] and [tokenizerFilename] optionally pin the exact install
  /// identities independently from source URL basenames. Use them for
  /// immutable/versioned artifacts. Each must be a plain basename; when
  /// omitted, the historical source-derived namespacing behavior is retained.
  ///
  /// Throws [ArgumentError] when the resolved model filename is a `.litertlm` or `.gguf`
  /// container (ASCII case-insensitive) and a tokenizer is given — the bundle
  /// carries its own — or is anything else and no tokenizer is given; when
  /// [tokenizerFilename] is given without [tokenizerSource]; and when the
  /// model and the tokenizer resolve to the same filename.
  EmbeddingModelSpec({
    required String name,
    required ModelSource modelSource,
    ModelSource? tokenizerSource,
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
    _checkEmbeddingSpec(this);
  }

  @override
  ModelManagementType get type => ModelManagementType.embedding;

  @override
  String get name => _name;

  @override
  ModelReplacePolicy get replacePolicy => _replacePolicy;

  /// `[model]` for a self-contained spec, else `[model, tokenizer]` — in that
  /// order.
  @override
  List<ModelFile> get files {
    final modelFile = _modelFilename == null
        ? EmbeddingModelFile.fromSource(_modelSource)
        : EmbeddingModelFile(source: _modelSource, filename: _modelFilename);
    final tokenizerSource = _tokenizerSource;
    if (tokenizerSource == null) return [modelFile];
    final modelId = FileNameUtils.getBaseName(modelFile.filename);
    return [
      modelFile,
      if (_tokenizerFilename == null)
        EmbeddingTokenizerFile.fromSource(tokenizerSource, modelId: modelId)
      else
        EmbeddingTokenizerFile(
          source: tokenizerSource,
          filename: _tokenizerFilename,
        ),
    ];
  }

  /// Where the model comes from.
  ModelSource get modelSource => _modelSource;

  /// Where the tokenizer comes from; null for a self-contained spec.
  ModelSource? get tokenizerSource => _tokenizerSource;

  /// The pinned model install filename, when one was given.
  String? get modelFilename => _modelFilename;

  /// The pinned tokenizer install filename, when one was given.
  String? get tokenizerFilename => _tokenizerFilename;

  /// True exactly when there is no separate tokenizer file
  /// (`tokenizerSource == null`). This means a `.litertlm` or `.gguf` container.
  /// Which engine runs it is each engine's own business.
  bool get isSelfContained => _tokenizerSource == null;

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

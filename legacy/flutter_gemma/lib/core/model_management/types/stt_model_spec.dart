part of '../model_specs.dart';

/// Speech-to-text model families supported by the pluggable STT backends.
/// Only [moonshine] has a shipped [SttModelProfile]/pipeline
/// (`flutter_gemma_speech`); the others are follow-ons that need a log-mel
/// frontend.
enum SttModelType { moonshine, whisper, parakeet }

/// Model file for STT models (.tflite files)
class SttModelFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  SttModelFile({required ModelSource source, required String filename})
    : _source = source,
      _filename = filename;

  /// Creates SttModelFile from ModelSource
  factory SttModelFile.fromSource(ModelSource source) {
    final filename = InferenceModelFile._extractFilenameFromSource(source);
    return SttModelFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.sttModelFile;

  @override
  bool get isRequired => true;
}

/// Tokenizer file for STT models (tokenizer.json)
class SttTokenizerFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  SttTokenizerFile({required ModelSource source, required String filename})
    : _source = source,
      _filename = filename;

  /// Creates SttTokenizerFile from ModelSource, namespaced by [modelId]
  /// (the owning SttModelSpec's own model-file basename, without
  /// extension) — this is what keeps moonshine's, whisper's, and
  /// parakeet's tokenizers distinct even though all three are literally
  /// named `tokenizer.json`.
  factory SttTokenizerFile.fromSource(
    ModelSource source, {
    required String modelId,
  }) {
    final basename = InferenceModelFile._extractFilenameFromSource(source);
    final filename = FileNameUtils.namespaced(modelId, basename);
    return SttTokenizerFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.sttTokenizerFile;

  @override
  bool get isRequired => true;
}

/// Specification for STT models (model.tflite + tokenizer.json).
///
/// Model is SELECTABLE like inference models: [sttModelType] is carried on
/// the spec (mirrors [InferenceModelSpec.modelType]) so a single generic
/// backend can dispatch to the right runtime profile instead of hardcoding
/// one model.
class SttModelSpec extends ModelSpec {
  final String _name;
  final ModelSource _modelSource;
  final ModelSource _tokenizerSource;
  final SttModelType _sttModelType;
  final ModelReplacePolicy _replacePolicy;

  SttModelSpec({
    required String name,
    required ModelSource modelSource,
    required ModelSource tokenizerSource,
    required SttModelType sttModelType,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) : _name = name,
       _modelSource = modelSource,
       _tokenizerSource = tokenizerSource,
       _sttModelType = sttModelType,
       _replacePolicy = replacePolicy;

  @override
  ModelManagementType get type => ModelManagementType.stt;

  @override
  String get name => _name;

  @override
  ModelReplacePolicy get replacePolicy => _replacePolicy;

  @override
  List<ModelFile> get files {
    final modelFile = SttModelFile.fromSource(_modelSource);
    final modelId = FileNameUtils.getBaseName(modelFile.filename);
    return [
      modelFile,
      SttTokenizerFile.fromSource(_tokenizerSource, modelId: modelId),
    ];
  }

  /// Modern type-safe getters
  ModelSource get modelSource => _modelSource;
  ModelSource get tokenizerSource => _tokenizerSource;
  SttModelType get sttModelType => _sttModelType;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SttModelSpec) return false;

    return _name == other._name &&
        _modelSource == other._modelSource &&
        _tokenizerSource == other._tokenizerSource &&
        _sttModelType == other._sttModelType &&
        _replacePolicy == other._replacePolicy;
  }

  @override
  int get hashCode {
    return Object.hash(
      _name,
      _modelSource,
      _tokenizerSource,
      _sttModelType,
      _replacePolicy,
    );
  }
}

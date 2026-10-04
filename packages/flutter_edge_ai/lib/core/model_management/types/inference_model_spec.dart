part of '../model_specs.dart';

/// Model file for inference models (.bin, .task files)
class InferenceModelFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  InferenceModelFile({required ModelSource source, required String filename})
    : _source = source,
      _filename = filename;

  /// Creates InferenceModelFile from ModelSource
  factory InferenceModelFile.fromSource(ModelSource source) {
    final filename = _extractFilenameFromSource(source);
    return InferenceModelFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.installedModelFileName;

  @override
  bool get isRequired => true;

  static String _extractFilenameFromSource(ModelSource source) {
    return switch (source) {
      NetworkSource(:final url) => Uri.parse(url).pathSegments.last,
      AssetSource(:final path) => path.split(RegExp(r'[/\\]')).last,
      BundledSource(:final resourceName) => resourceName,
      FileSource(:final path) => path.split(RegExp(r'[/\\]')).last,
    };
  }
}

/// Model file for LoRA weights. A COMPANION of the inference model — its
/// filename gets the modelId__ prefix so a LoRA adapter travels with the
/// exact base model it was fine-tuned for (mirrors the tokenizer/aux
/// namespacing used by embedding/STT/TTS companions).
class LoraModelFile extends ModelFile {
  final ModelSource _source;
  final String _filename;

  LoraModelFile({required ModelSource source, required String filename})
    : _source = source,
      _filename = filename;

  /// Creates LoraModelFile from ModelSource, namespaced by [modelId] — the
  /// owning InferenceModelSpec's own model-file basename (without
  /// extension).
  factory LoraModelFile.fromSource(
    ModelSource source, {
    required String modelId,
  }) {
    final basename = InferenceModelFile._extractFilenameFromSource(source);
    final filename = FileNameUtils.namespaced(modelId, basename);
    return LoraModelFile(source: source, filename: filename);
  }

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => PreferencesKeys.installedLoraFileName;

  @override
  bool get isRequired => false;
}

/// One file of a DIRECTORY inference model (ORT-GenAI): the model is a set of
/// files that must live together in a per-model subdirectory with their BARE
/// leaf names (`genai_config.json` references its siblings by bare name and the
/// native loader is handed the directory). [filename] is the EXPLICIT install
/// identity `<modelId>/<bareLeaf>` (a real subpath) — NEVER derived from
/// [source], so the on-disk id and the repository key always agree (a
/// `FileSource`-derived basename would drop the subdir and break the repo
/// lookup on every restore). The PRIMARY file (`genai_config.json`) uses
/// [PreferencesKeys.installedModelFileName] as its [prefsKey] so the
/// persist-identity + `modelFilePaths.values.first` both find it; siblings use
/// their bare leaf name so each maps to a distinct `getModelFilePaths` entry.
class DirectoryBundleFile extends ModelFile {
  final ModelSource _source;
  final String _filename;
  final String _prefsKey;

  // Private: every member MUST come through [DirectoryBundleFile.member] so the
  // `<modelId>/<bareLeaf>` filename and the primary-vs-sibling prefsKey rule are
  // never bypassed (a raw ctor could key a sibling on installedModelFileName —
  // two files fighting for the persist-identity slot).
  DirectoryBundleFile._({
    required ModelSource source,
    required String filename,
    required String prefsKey,
  }) : _source = source,
       _filename = filename,
       _prefsKey = prefsKey;

  /// Builds one bundle member from its [modelId] (the subdirectory), its BARE
  /// leaf [bareName], and the bundle's [primaryName] (the file the engine loads
  /// from — for ORT-GenAI, `genai_config.json`). The primary gets
  /// [PreferencesKeys.installedModelFileName] as its key so persist-identity and
  /// `getModelFilePaths.values.first` find it; every sibling keys on its bare
  /// name so each maps to a distinct path entry. Used by both the install path
  /// and the restore path, so the key rule lives in one place.
  factory DirectoryBundleFile.member({
    required String modelId,
    required String bareName,
    required String primaryName,
    required ModelSource source,
  }) => DirectoryBundleFile._(
    source: source,
    filename: '$modelId/$bareName',
    prefsKey: bareName == primaryName
        ? PreferencesKeys.installedModelFileName
        : bareName,
  );

  @override
  ModelSource get source => _source;

  @override
  String get filename => _filename;

  @override
  String get prefsKey => _prefsKey;

  @override
  bool get isRequired => true;

  /// Directory members (`.onnx_data`, `genai_config.json`, tokenizer json/vocab)
  /// aren't in `FileNameUtils.supportedExtensions`, so the extension heuristic
  /// would wrongly impose the 1 MB default on small config files. We only assert
  /// "a non-empty file landed"; real size/sha verification is a follow-up
  /// (`ResolvedHfFile.sha256`/`sizeBytes` are carried but not yet checked).
  @override
  int? get minimumSizeBytes => 1;
}

/// Specification for inference models (main model + optional LoRA)
class InferenceModelSpec extends ModelSpec {
  final String _name;
  final ModelSource _modelSource;
  final ModelSource? _loraSource;
  final ModelReplacePolicy _replacePolicy;
  final ModelType _modelType;
  final ModelFileType _fileType;

  /// For a DIRECTORY model (ORT-GenAI): the full set of files, primary
  /// (`genai_config.json`) FIRST. Null for a single-file model — [files] then
  /// returns the ordinary `[model, lora?]`, byte-for-byte unchanged. When
  /// non-null [modelSource] is the primary file's source (so single-file
  /// consumers of [modelSource] still see the entry the engine loads from).
  final List<DirectoryBundleFile>? _directoryFiles;

  InferenceModelSpec({
    required String name,
    required ModelSource modelSource,
    ModelSource? loraSource,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
    List<DirectoryBundleFile>? directoryFiles,
  }) : _name = name,
       _modelSource = modelSource,
       _loraSource = loraSource,
       _replacePolicy = replacePolicy,
       _modelType = modelType,
       _fileType = fileType,
       // Defensive copy: every other facet of this immutable spec is protected,
       // so the bundle must not stay aliased to a list the caller can mutate.
       _directoryFiles = directoryFiles == null
           ? null
           : List<DirectoryBundleFile>.unmodifiable(directoryFiles) {
    // Enforced in RELEASE too — an `assert` is compiled out, so a mis-built
    // directory spec would otherwise surface far downstream as
    // "Bad state: No element" on `files.first`, not here. The install path
    // rejects these earlier; this guards direct construction of the public ctor.
    final bundle = _directoryFiles;
    if (bundle != null) {
      if (loraSource != null) {
        throw ArgumentError.value(
          loraSource,
          'loraSource',
          'directory (ORT-GenAI) models do not support LoRA',
        );
      }
      if (bundle.isEmpty) {
        throw ArgumentError.value(
          directoryFiles,
          'directoryFiles',
          'a directory model needs at least one file (primary first)',
        );
      }
      if (modelSource != bundle.first.source) {
        throw ArgumentError.value(
          modelSource,
          'modelSource',
          'must be the primary (first) directory file source',
        );
      }
    }
  }

  /// Legacy compatibility constructor for String URLs
  factory InferenceModelSpec.fromLegacyUrl({
    required String name,
    required String modelUrl,
    String? loraUrl,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
    ModelType modelType = ModelType.general,
    ModelFileType fileType = ModelFileType.task,
  }) {
    return InferenceModelSpec(
      name: name,
      modelSource: _urlToSource(modelUrl),
      loraSource: loraUrl != null ? _urlToSource(loraUrl) : null,
      replacePolicy: replacePolicy,
      modelType: modelType,
      fileType: fileType,
    );
  }

  @override
  ModelManagementType get type => ModelManagementType.inference;

  @override
  String get name => _name;

  @override
  ModelReplacePolicy get replacePolicy => _replacePolicy;

  @override
  List<ModelFile> get files {
    // Directory (ORT-GenAI) model: the explicit bundle IS the file list, in
    // order (primary first). LoRA is not supported for directory models.
    final bundle = _directoryFiles;
    if (bundle != null) return List<ModelFile>.unmodifiable(bundle);

    final modelFile = InferenceModelFile.fromSource(_modelSource);
    final result = <ModelFile>[modelFile];

    if (_loraSource != null) {
      final modelId = FileNameUtils.getBaseName(modelFile.filename);
      result.add(LoraModelFile.fromSource(_loraSource, modelId: modelId));
    }

    return result;
  }

  /// The directory bundle for an ORT-GenAI model, or null for a single-file
  /// model. Exposed so the restore path can tell a directory model apart.
  List<DirectoryBundleFile>? get directoryFiles => _directoryFiles;

  /// Modern type-safe getters
  ModelSource get modelSource => _modelSource;
  ModelSource? get loraSource => _loraSource;
  ModelType get modelType => _modelType;
  ModelFileType get fileType => _fileType;

  /// Legacy getters for backward compatibility (WEB PLATFORM ONLY)
  @Deprecated('Use modelSource instead. Web platform compatibility only.')
  String get modelUrl => _sourceToUrl(_modelSource);

  @Deprecated('Use loraSource instead. Web platform compatibility only.')
  String? get loraUrl => _loraSource != null ? _sourceToUrl(_loraSource) : null;

  /// Converts ModelSource to legacy URL string (for web platform compatibility)
  static String _sourceToUrl(ModelSource source) {
    return switch (source) {
      NetworkSource(:final url) => url,
      AssetSource(:final path) => 'asset://$path',
      BundledSource(:final resourceName) => 'native://$resourceName',
      FileSource(:final path) => 'file://$path',
    };
  }

  /// Converts legacy URL string to ModelSource (for fromLegacyUrl constructor)
  static ModelSource _urlToSource(String url) {
    if (url.startsWith('https://') || url.startsWith('http://')) {
      return ModelSource.network(url);
    } else if (url.startsWith('asset://')) {
      return ModelSource.asset(url.replaceFirst('asset://', ''));
    } else if (url.startsWith('native://')) {
      return ModelSource.bundled(url.replaceFirst('native://', ''));
    } else if (url.startsWith('file://')) {
      return ModelSource.file(url.replaceFirst('file://', ''));
    } else {
      // Schemeless = asset for backward compatibility
      return ModelSource.asset(url);
    }
  }

  /// Value signature of the directory bundle (ordered member filenames), or
  /// null for a single-file model. Folded into [==]/[hashCode] so two directory
  /// specs with the same name/source/type but DIFFERENT members are not treated
  /// as equal — install-validity depends on every member.
  String? get _directoryFilesKey =>
      _directoryFiles?.map((f) => f.filename).join('|');

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! InferenceModelSpec) return false;

    return _name == other._name &&
        _modelSource == other._modelSource &&
        _loraSource == other._loraSource &&
        _replacePolicy == other._replacePolicy &&
        _modelType == other._modelType &&
        _fileType == other._fileType &&
        _directoryFilesKey == other._directoryFilesKey;
  }

  @override
  int get hashCode {
    return Object.hash(
      _name,
      _modelSource,
      _loraSource,
      _replacePolicy,
      _modelType,
      _fileType,
      _directoryFilesKey,
    );
  }
}

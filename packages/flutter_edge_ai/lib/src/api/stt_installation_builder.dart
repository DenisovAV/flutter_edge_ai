import 'package:flutter_edge_ai/src/api/bundle_progress.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/model_management/model_activation.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;

/// Fluent builder for STT (speech-to-text) model installation
///
/// Provides type-safe API for installing STT models (requires model + tokenizer).
/// Automatically sets the installed model as the active STT model.
///
/// The model is SELECTABLE like inference models: [ofType] is required so the
/// installed [SttModelSpec] carries an [SttModelType] (mirrors
/// [InferenceModelSpec.modelType]) — a single generic backend can then dispatch
/// to the right runtime profile instead of hardcoding one model.
///
/// Usage:
/// ```dart
/// await FlutterEdgeAi.installStt()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.json', token: 'hf_...')
///   .ofType(SttModelType.moonshine)
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
/// ```
class SttInstallationBuilder {
  ModelSource? _modelSource;
  ModelSource? _tokenizerSource;
  SttModelType? _sttModelType;
  void Function(int progress)? _onModelProgress;
  void Function(int progress)? _onTokenizerProgress;
  void Function(int progress)? _onProgress;
  CancelToken? _cancelToken;

  /// What each network file must be once installed.
  FileExpectation _modelExpected = const FileExpectation();
  FileExpectation _tokenizerExpected = const FileExpectation();

  /// The catalog variant this builder installs ([fromCatalog]).
  SttVariant? _catalogVariant;

  /// Install a model registry build: its pinned model and tokenizer URLs,
  /// its type and sizes. The sizes are checked before the model becomes
  /// active (not on the web), and [withProgress] weights by them without asking the network.
  ///
  /// An STT model's files are installed under their URL's file names, so
  /// [install] throws [ArgumentError] for a variant that names them
  /// otherwise, and [UnsupportedError] for one whose `backendsHere` is empty;
  /// both before anything downloads. When an active model of any kind reads
  /// a file of the same name from another source, [install] throws
  /// [StateError] before the download (not on the web), naming that model
  /// and the call that uninstalls it: uninstall it first.
  SttInstallationBuilder fromCatalog(SttVariant variant, {String? token}) {
    modelFromNetwork(
      variant.model.url,
      token: token,
      expectedSize: variant.model.sizeBytes,
    );
    tokenizerFromNetwork(
      variant.tokenizer.url,
      token: token,
      expectedSize: variant.tokenizer.sizeBytes,
    );
    ofType(variant.type);
    _catalogVariant = variant;
    return this;
  }

  // === Model source setters ===

  /// Set model source from network URL (HTTP/HTTPS)
  ///
  /// [expectedSize]: the file's size in bytes once downloaded, checked on
  /// every install before the model becomes active, a file installed earlier
  /// included. A file of another size is deleted with its record and
  /// [install] throws [ModelValidationException]; a negative size throws
  /// [ArgumentError] here. With it set, [install] throws [StateError] before
  /// the download when an active model of any kind reads a file of this
  /// name: uninstall that model first. On the web neither is checked.
  SttInstallationBuilder modelFromNetwork(
    String url, {
    String? token,
    int? expectedSize,
  }) {
    // Checked first: a refused value leaves the builder as it was.
    final expected = FileExpectation.checked(size: expectedSize);
    _modelSource = ModelSource.network(url, authToken: token);
    _catalogVariant = null;
    _modelExpected = expected;
    return this;
  }

  /// Set model source from Flutter asset
  SttInstallationBuilder modelFromAsset(String path) {
    _modelSource = ModelSource.asset(path);
    _catalogVariant = null;
    _modelExpected = const FileExpectation();
    return this;
  }

  /// Set model source from bundled native resource
  SttInstallationBuilder modelFromBundled(String resourceName) {
    _modelSource = ModelSource.bundled(resourceName);
    _catalogVariant = null;
    _modelExpected = const FileExpectation();
    return this;
  }

  /// Set model source from external file path
  SttInstallationBuilder modelFromFile(String path) {
    _modelSource = ModelSource.file(path);
    _catalogVariant = null;
    _modelExpected = const FileExpectation();
    return this;
  }

  // === Tokenizer source setters ===

  /// Set tokenizer source from network URL (HTTP/HTTPS).
  ///
  /// [token] optional auth token for the URL (e.g. HuggingFace).
  ///
  /// [expectedSize] as for [modelFromNetwork].
  SttInstallationBuilder tokenizerFromNetwork(
    String url, {
    String? token,
    int? expectedSize,
  }) {
    // Checked first: a refused value leaves the builder as it was.
    final expected = FileExpectation.checked(size: expectedSize);
    _tokenizerSource = ModelSource.network(url, authToken: token);
    _catalogVariant = null;
    _tokenizerExpected = expected;
    return this;
  }

  /// Set tokenizer source from a Flutter asset.
  SttInstallationBuilder tokenizerFromAsset(String path) {
    _tokenizerSource = ModelSource.asset(path);
    _catalogVariant = null;
    _tokenizerExpected = const FileExpectation();
    return this;
  }

  /// Set tokenizer source from a bundled native resource.
  SttInstallationBuilder tokenizerFromBundled(String resourceName) {
    _tokenizerSource = ModelSource.bundled(resourceName);
    _catalogVariant = null;
    _tokenizerExpected = const FileExpectation();
    return this;
  }

  /// Set tokenizer source from an external file path.
  SttInstallationBuilder tokenizerFromFile(String path) {
    _tokenizerSource = ModelSource.file(path);
    _catalogVariant = null;
    _tokenizerExpected = const FileExpectation();
    return this;
  }

  // === Model family selection ===

  /// Set the STT model family ([SttModelType]) this install represents.
  ///
  /// Required — mirrors [InferenceModelSpec.modelType]. Carried on the
  /// installed [SttModelSpec] so a single generic backend can select the
  /// right [SttModelProfile] runtime pipeline instead of hardcoding one model.
  SttInstallationBuilder ofType(SttModelType sttModelType) {
    if (_catalogVariant?.type != sttModelType) _catalogVariant = null;
    _sttModelType = sttModelType;
    return this;
  }

  // === Progress callbacks ===

  /// Progress of the whole install, 0 to 100, by bytes across the model and
  /// its tokenizer, as `TtsInstallationBuilder.withProgress` counts: sizes
  /// read before the first download (a HEAD request per network file unless
  /// its `expectedSize` is set, none on the web; the disk for files installed
  /// already), files
  /// installed already counted from the start, every file the same weight
  /// when a size is unknown. Values only rise, and a successful install ends
  /// with 100 once the model is active.
  SttInstallationBuilder withProgress(void Function(int progress) onProgress) {
    _onProgress = onProgress;
    return this;
  }

  /// Add model file progress callback
  SttInstallationBuilder withModelProgress(
    void Function(int progress) onProgress,
  ) {
    _onModelProgress = onProgress;
    return this;
  }

  /// Add tokenizer file progress callback
  SttInstallationBuilder withTokenizerProgress(
    void Function(int progress) onProgress,
  ) {
    _onTokenizerProgress = onProgress;
    return this;
  }

  /// Set cancellation token for this installation
  ///
  /// The same token will be used for both model and tokenizer downloads.
  SttInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active STT model
  ///
  /// Returns [SttInstallation] with details about the installed model.
  ///
  /// Throws:
  /// - [StateError] if model or tokenizer source not configured, or [ofType]
  ///   was not called, and, before the download, when a file with an
  ///   `expectedSize` would replace one an active model of any kind reads
  /// - [UnsupportedError] or [ArgumentError] for a [fromCatalog] variant that
  ///   cannot be installed here (see [fromCatalog]); [UnsupportedError] on
  ///   the web for a file over 2 GiB in the default storage
  /// - [ModelValidationException] if a file is not its `expectedSize` once
  ///   installed (what the install wrote is then deleted with its record)
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - a file already installed from the same
  /// source is skipped and the spec is just (re-)set as active. One installed
  /// from another source is installed again: a download from another URL —
  /// compared without its query and token, so a version told apart only by
  /// the query is not —, or a file the app picked from another path. On
  /// Android, iOS and desktop core's earlier copy of it is deleted once the
  /// new file is active (or at the next start), never a file the app
  /// installed with `fromFile`; a download that would land on such a file
  /// throws a [ModelStorageException] instead.
  Future<SttInstallation> install() async {
    // Check cancellation before starting
    _cancelToken?.throwIfCancelled();
    if (_catalogVariant case final variant?) {
      checkCatalogVariant(variant);
      // Core keeps STT files under their URL's file names.
      for (final file in variant.files) {
        final urlName = InferenceModelFile.fromSource(
          ModelSource.network(file.url),
        ).filename;
        if (urlName != file.installFilename) {
          throw ArgumentError.value(
            variant,
            'variant',
            '${variant.id} installs "${file.installFilename}", but an STT '
                'model\'s file is installed under its URL\'s file name '
                '"$urlName"',
          );
        }
      }
    }

    if (_modelSource == null || _tokenizerSource == null) {
      throw StateError(
        'Both model and tokenizer required. Use modelFromNetwork() and tokenizerFromNetwork().',
      );
    }

    final sttModelType = _sttModelType;
    if (sttModelType == null) {
      throw StateError(
        'ofType(SttModelType) is required. Use e.g. ofType(SttModelType.moonshine) '
        'so the STT backend knows which runtime profile to use.',
      );
    }

    final effectiveTokenizerSource = _tokenizerSource!;

    // Create spec
    final modelFile = SttModelFile.fromSource(_modelSource!);
    final spec = SttModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: _modelSource!,
      tokenizerSource: effectiveTokenizerSource,
      sttModelType: sttModelType,
      replacePolicy: ModelReplacePolicy.keep,
    );

    // What each file must be, by its index in spec.files (model, tokenizer).
    final expectations = [_modelExpected, _tokenizerExpected];
    final expected = {
      for (final (i, file) in spec.files.indexed)
        file.filename: expectations[i],
    };
    refuseTooLargeForWebCache(expected);
    final manager = FlutterEdgeAiPlugin.instance.modelManager;
    final steps = await planInstall(spec.files);
    final activeBefore = activeModelsOf(manager);
    refuseReplacingActive(steps, expected, activeBefore);
    final progress = await startBundleProgress(
      _onProgress,
      steps,
      known: {
        for (final (i, file) in spec.files.indexed)
          if (expectations[i].size case final size?) file.prefsKey: size,
      },
      cancelToken: _cancelToken,
      bundle: spec.name,
    );
    final perFile = [_onModelProgress, _onTokenizerProgress];

    // The model, then its tokenizer, each by its own record (see
    // install_rule.dart).
    final release = await installPlanned(
      steps,
      modelType: repo.ModelType.stt,
      cancelToken: _cancelToken,
      progress: [
        for (var i = 0; i < spec.files.length; i++)
          if (perFile[i] == null && progress == null)
            null
          else
            (int percent) {
              perFile[i]?.call(percent);
              progress?.report(i, percent);
            },
      ],
      onFileDone: (i) => progress?.report(i, 100),
    );

    // AUTO-SET as active STT model (even if already installed)
    _cancelToken?.throwIfCancelled();
    await verifyInstalledFiles(spec, expected, active: activeBefore);
    _cancelToken?.throwIfCancelled();
    await activateInstalledModel(manager, spec);
    await release.run(manager, spec);
    progress?.complete();

    edgeAiLog('✅ STT model installed and set as active: ${spec.name}');

    return SttInstallation(spec: spec);
  }
}

/// Result of STT model installation
class SttInstallation {
  final SttModelSpec spec;

  SttInstallation({required this.spec});

  /// Model ID (filename without extension)
  String get modelId => spec.name;
}

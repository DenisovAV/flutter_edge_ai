import 'package:flutter_edge_ai/src/api/bundle_progress.dart';
import 'package:flutter_edge_ai/src/api/install_expectations.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_edge_ai/src/model_management/model_activation.dart';
import 'package:flutter_edge_ai/src/registry/embedding_registry.dart';
import 'package:flutter_edge_ai/src/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/src/utils/file_name_utils.dart';
import 'package:flutter_edge_ai/src/model_management/install_rule.dart';
import 'package:flutter_edge_ai/src/utils/file_names.dart'
    show isSelfContainedEmbeddingFilename;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart' as repo;

/// Said once per isolate when an embedder is installed before any embedding
/// backend is registered (see [EmbeddingInstallationBuilder.install]).
bool _noBackendNoticed = false;

/// Fluent builder for embedding model installation
///
/// Installs a model plus its tokenizer (`.tflite`, `.onnx`, …), or a single
/// `.litertlm` or `.gguf` container, which carries its own tokenizer. Automatically sets
/// the installed model as the active embedding model.
///
/// Usage:
/// ```dart
/// await FlutterEdgeAi.installEmbedder()
///   .modelFromNetwork('https://example.com/model.tflite', token: 'hf_...')
///   .tokenizerFromNetwork('https://example.com/tokenizer.model', token: 'hf_...')
///   .withModelProgress((p) => print('Model: $p%'))
///   .withTokenizerProgress((p) => print('Tokenizer: $p%'))
///   .install();
///
/// // A .litertlm embedder installs alone:
/// await FlutterEdgeAi.installEmbedder()
///   .modelFromNetwork('https://example.com/embedder.litertlm')
///   .install();
/// ```
class EmbeddingInstallationBuilder {
  ModelSource? _modelSource;
  ModelSource? _tokenizerSource;
  String? _modelFilename;
  String? _tokenizerFilename;
  // 0.15.2: per-platform tokenizer source dropped — same `.model` (or
  // `.json`) works on every native platform via dart_sentencepiece_tokenizer.
  void Function(int progress)? _onModelProgress;
  void Function(int progress)? _onTokenizerProgress;
  void Function(int progress)? _onProgress;
  CancelToken? _cancelToken;

  /// What each network file must be once installed.
  FileExpectation _modelExpected = const FileExpectation();
  FileExpectation _tokenizerExpected = const FileExpectation();

  /// The catalog variant this builder installs ([fromCatalog]).
  EmbedderVariant? _catalogVariant;

  // Deferred Hugging Face resolution ([fromHuggingFace]): resolved in
  // [install], which is async. Every other source setter clears [_hfRepo], and
  // [fromHuggingFace] clears every other source, so the last call wins.
  String? _hfRepo;
  ModelFileType? _hfFileType;
  String? _hfToken;

  /// Install a model registry build: its pinned model and tokenizer URLs,
  /// install names and sizes, and the profile its vectors belong to. The
  /// sizes are checked before the model becomes active (not on the web),
  /// and [withProgress] weights by them without asking the network.
  ///
  /// When an active model of any kind reads a file of the same name from
  /// another source (an older pin), [install] throws [StateError] before
  /// the download (not on the web), naming that model and the call that
  /// uninstalls it: uninstall it first.
  ///
  /// [install] throws [UnsupportedError] before anything downloads for a
  /// variant whose `backendsHere` is empty (it does not run in this runtime).
  /// [token] is used for both files; without it, the token passed to
  /// `FlutterEdgeAi.initialize` is used for huggingface.co.
  EmbeddingInstallationBuilder fromCatalog(
    EmbedderVariant variant, {
    String? token,
  }) {
    // Both files' values first: a refused one leaves the builder as it was.
    for (final file in [variant.model, ?variant.tokenizer]) {
      FileExpectation.checked(size: file.sizeBytes);
      _validateFilename(file.installFilename);
    }
    modelFromNetwork(
      variant.model.url,
      token: token,
      filename: variant.model.installFilename,
      expectedSize: variant.model.sizeBytes,
    );
    if (variant.tokenizer case final tokenizer?) {
      tokenizerFromNetwork(
        tokenizer.url,
        token: token,
        filename: tokenizer.installFilename,
        expectedSize: tokenizer.sizeBytes,
      );
    } else {
      _tokenizerSource = null;
      _tokenizerFilename = null;
      _tokenizerExpected = const FileExpectation();
    }
    _catalogVariant = variant;
    return this;
  }

  /// Install the embedder a Hugging Face repo's deployment metadata names,
  /// through the embedding resolver registered for [fileType]
  /// (`FlutterEdgeAi.resolveHuggingFace(repo, type:
  /// ModelManagementType.embedding, fileType: fileType)`), at [install]:
  /// resolution is asynchronous.
  ///
  /// The resolver's model file, and its tokenizer when it names one
  /// (`ResolvedHfModel.tokenizerFile`), are downloaded from its pinned URLs
  /// under the names the resolver gives them (`ResolvedHfFile.name`). A
  /// resolution with no `files` is a single file, installed under the leaf
  /// of `ResolvedHfModel.file` — often a generic `model.onnx` or
  /// `model.litertlm` — so a resolver should return `files` with names
  /// unique to the model: two models installed under one name are one file.
  /// The sizes the resolver gives (`ResolvedHfFile.sizeBytes`, or
  /// `ResolvedHfModel.sizeBytes` for a single file) are checked as a
  /// [fromCatalog] variant's are. Its runtime defaults come back on
  /// [EmbeddingInstallation.runtime]: pass them as
  /// `getActiveEmbedder(defaults:)`. Its advisory notes come back on
  /// [EmbeddingInstallation.notes].
  ///
  /// [install] throws [StateError] when no embedding resolver handles
  /// [fileType], when the resolver names a model family (embedders have
  /// none), when its `file` is not among its `files`, or when it names no
  /// tokenizer for a model that needs one, and [UnsupportedError] for a
  /// resolution that is a model
  /// directory (`ResolvedHfModel.directoryName`, or files beyond the model
  /// and its tokenizer): embedder directories are not supported yet. A
  /// cancel token set with [withCancelToken] cannot interrupt the resolution
  /// itself; it is checked right after it, before anything downloads.
  ///
  /// [token] is used for the resolution and both downloads; without it, the
  /// token passed to `FlutterEdgeAi.initialize` is used for huggingface.co.
  /// This clears every source set before, a [fromCatalog] variant included,
  /// and any later source setter clears it.
  EmbeddingInstallationBuilder fromHuggingFace(
    String repo, {
    required ModelFileType fileType,
    String? token,
  }) {
    if (repo.trim().isEmpty) {
      throw ArgumentError.value(repo, 'repo', 'must be a non-empty "org/name"');
    }
    _modelSource = null;
    _modelFilename = null;
    _modelExpected = const FileExpectation();
    _tokenizerSource = null;
    _tokenizerFilename = null;
    _tokenizerExpected = const FileExpectation();
    _catalogVariant = null;
    _hfRepo = repo;
    _hfFileType = fileType;
    _hfToken = token;
    return this;
  }

  // === Model source setters ===

  /// Set model source from network URL (HTTP/HTTPS).
  ///
  /// [filename] pins the installed/cache identity instead of deriving it from
  /// the URL basename. Prefer a revision-qualified basename for mutable hosts.
  ///
  /// [expectedSize]: the file's size in bytes once downloaded, checked on
  /// every install before the model becomes active, a file installed earlier
  /// included. A file of another size is deleted with its record and
  /// [install] throws [ModelValidationException]; a negative size throws
  /// [ArgumentError] here. With it set, [install] throws [StateError] before
  /// the download when it would replace a file of this name that an active
  /// model of any kind reads (one not installed yet, or installed from
  /// another source): uninstall that model first. On the web neither is
  /// checked.
  EmbeddingInstallationBuilder modelFromNetwork(
    String url, {
    String? token,
    String? filename,
    int? expectedSize,
  }) {
    // Checked first: a refused value leaves the builder as it was.
    final expected = FileExpectation.checked(size: expectedSize);
    final name = _validateFilename(filename);
    _modelSource = ModelSource.network(url, authToken: token);
    _catalogVariant = null;
    _hfRepo = null;
    _modelFilename = name;
    _modelExpected = expected;
    return this;
  }

  /// Set model source from Flutter asset
  EmbeddingInstallationBuilder modelFromAsset(String path, {String? filename}) {
    final name = _validateFilename(filename);
    _modelSource = ModelSource.asset(path);
    _catalogVariant = null;
    _hfRepo = null;
    _modelExpected = const FileExpectation();
    _modelFilename = name;
    return this;
  }

  /// Set model source from bundled native resource
  EmbeddingInstallationBuilder modelFromBundled(
    String resourceName, {
    String? filename,
  }) {
    final name = _validateFilename(filename);
    _modelSource = ModelSource.bundled(resourceName);
    _catalogVariant = null;
    _hfRepo = null;
    _modelExpected = const FileExpectation();
    _modelFilename = name;
    return this;
  }

  /// Set model source from external file path
  EmbeddingInstallationBuilder modelFromFile(String path, {String? filename}) {
    final name = _validateFilename(filename);
    _modelSource = ModelSource.file(path);
    _catalogVariant = null;
    _hfRepo = null;
    _modelExpected = const FileExpectation();
    _modelFilename = name;
    return this;
  }

  // === Tokenizer source setters ===
  //
  // 0.15.2: tokenizer is the same `.model` (or exported `.json`) on every
  // native platform — `dart_sentencepiece_tokenizer` loads both directly,
  // so the per-platform `iosPath`/`iosToken` parameters previously needed
  // for iOS are gone.

  /// Set tokenizer source from network URL (HTTP/HTTPS).
  ///
  /// [token] optional auth token for the URL (e.g. HuggingFace).
  /// [filename] pins the installed/cache identity; it must already be unique
  /// to the owning embedding profile because explicit names bypass automatic
  /// tokenizer namespacing. [expectedSize] as for
  /// [modelFromNetwork].
  EmbeddingInstallationBuilder tokenizerFromNetwork(
    String url, {
    String? token,
    String? filename,
    int? expectedSize,
  }) {
    // Checked first: a refused value leaves the builder as it was.
    final expected = FileExpectation.checked(size: expectedSize);
    final name = _validateFilename(filename);
    _tokenizerSource = ModelSource.network(url, authToken: token);
    _catalogVariant = null;
    _hfRepo = null;
    _tokenizerFilename = name;
    _tokenizerExpected = expected;
    return this;
  }

  /// Set tokenizer source from a Flutter asset.
  EmbeddingInstallationBuilder tokenizerFromAsset(
    String path, {
    String? filename,
  }) {
    final name = _validateFilename(filename);
    _tokenizerSource = ModelSource.asset(path);
    _catalogVariant = null;
    _hfRepo = null;
    _tokenizerExpected = const FileExpectation();
    _tokenizerFilename = name;
    return this;
  }

  /// Set tokenizer source from a bundled native resource.
  EmbeddingInstallationBuilder tokenizerFromBundled(
    String resourceName, {
    String? filename,
  }) {
    final name = _validateFilename(filename);
    _tokenizerSource = ModelSource.bundled(resourceName);
    _catalogVariant = null;
    _hfRepo = null;
    _tokenizerExpected = const FileExpectation();
    _tokenizerFilename = name;
    return this;
  }

  /// Set tokenizer source from an external file path.
  EmbeddingInstallationBuilder tokenizerFromFile(
    String path, {
    String? filename,
  }) {
    final name = _validateFilename(filename);
    _tokenizerSource = ModelSource.file(path);
    _catalogVariant = null;
    _hfRepo = null;
    _tokenizerExpected = const FileExpectation();
    _tokenizerFilename = name;
    return this;
  }

  static String? _validateFilename(String? filename) {
    if (filename == null) return null;
    return FileNameUtils.validatePortableFileNameSegment(filename);
  }

  // === Progress callbacks ===

  /// Add model file progress callback
  EmbeddingInstallationBuilder withModelProgress(
    void Function(int progress) onProgress,
  ) {
    _onModelProgress = onProgress;
    return this;
  }

  /// Add tokenizer file progress callback
  EmbeddingInstallationBuilder withTokenizerProgress(
    void Function(int progress) onProgress,
  ) {
    _onTokenizerProgress = onProgress;
    return this;
  }

  /// Progress of the whole install, 0 to 100, by bytes across the model and
  /// its tokenizer, as `TtsInstallationBuilder.withProgress` counts: sizes
  /// read before the first download (a HEAD request per network file unless
  /// its `expectedSize` is set, none on the web; the disk for files installed
  /// already), files
  /// installed already counted from the start, every file the same weight
  /// when a size is unknown. Values only rise, and a successful install ends
  /// with 100 once the model is active.
  EmbeddingInstallationBuilder withProgress(
    void Function(int progress) onProgress,
  ) {
    _onProgress = onProgress;
    return this;
  }

  /// Set cancellation token for this installation
  ///
  /// The same token will be used for both model and tokenizer downloads.
  ///
  /// Example:
  /// ```dart
  /// final cancelToken = CancelToken();
  ///
  /// final future = FlutterEdgeAi.installEmbedder()
  ///   .modelFromNetwork(modelUrl)
  ///   .tokenizerFromNetwork(tokenizerUrl)
  ///   .withCancelToken(cancelToken)
  ///   .install();
  ///
  /// // Cancel from elsewhere
  /// cancelToken.cancel('User cancelled');
  /// ```
  EmbeddingInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active embedding model
  ///
  /// Returns [EmbeddingInstallation] with details about installed model.
  ///
  /// Throws, before anything is downloaded:
  /// - [DownloadCancelledException] if the cancel token is already cancelled
  /// - [StateError] if no model source is set, or no tokenizer source for a
  ///   model that needs one (anything but a `.litertlm` or `.gguf` container)
  /// - [ArgumentError] if a tokenizer is set for a self-contained container, which
  ///   carries its own
  /// - [UnsupportedError] if embedding backends are registered and none of
  ///   them can run the model on this platform — so an embedder that cannot
  ///   run here is refused before a download of hundreds of megabytes. With no
  ///   backend registered yet the install goes ahead (the app may register
  ///   one later) and says so once in the debug log.
  ///
  /// - for [fromHuggingFace] (the resolution needs the network, and comes
  ///   before the other checks): [StateError] when no embedding resolver
  ///   handles the repo, it names a model family, its `tokenizerFile` is not
  ///   among its `files` or is its `file`, its model `file` is not among its
  ///   `files`, or it names no tokenizer for a model that needs one;
  ///   [UnsupportedError] for a model directory; [ArgumentError] for a file
  ///   name that is not a single path segment, a negative size, or a
  ///   tokenizer given with a self-contained `.litertlm` or `.gguf` model
  /// - [UnsupportedError] for a [fromCatalog] variant that does not run here,
  ///   and on the web for a file over 2 GiB unless the app uses
  ///   `WebStorageMode.streaming`
  /// - [StateError] when a file with an `expectedSize` would replace one an
  ///   active model of any kind reads (not on the web)
  ///
  /// and later [DownloadCancelledException] if cancelled via the cancel token,
  /// [ModelValidationException] if a file is not its `expectedSize` once
  /// installed (the first such file is then deleted with its record, unless
  /// an active model reads it), or
  /// an [Exception] on installation failure.
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
  Future<EmbeddingInstallation> install() async {
    // Check cancellation before starting
    _cancelToken?.throwIfCancelled();
    if (_catalogVariant case final variant?) checkCatalogVariant(variant);

    // install() only READS builder state: a Hugging Face resolution goes into
    // these locals, never back into the fields.
    var modelSource = _modelSource;
    var modelFilename = _modelFilename;
    var tokenizerSource = _tokenizerSource;
    var tokenizerFilename = _tokenizerFilename;
    var modelExpected = _modelExpected;
    var tokenizerExpected = _tokenizerExpected;
    ModelRuntimeDefaults? runtime;
    List<String> notes = const [];
    if (_hfRepo case final repo?) {
      final r = await FlutterEdgeAi.resolveHuggingFace(
        repo,
        type: ModelManagementType.embedding,
        fileType: _hfFileType,
        token: _hfToken,
      );
      // The resolution itself takes no cancel token: stop before downloading.
      _cancelToken?.throwIfCancelled();
      final flat = _flatEmbedderFiles(repo, r, fileType: _hfFileType);
      // The resolver's sizes, checked as fromCatalog's are; a file it gives
      // no size for has nothing to check. Negative sizes are refused here,
      // before anything downloads.
      modelExpected = FileExpectation.checked(size: flat.model.sizeBytes);
      tokenizerExpected = FileExpectation.checked(
        size: flat.tokenizer?.sizeBytes,
      );
      modelSource = ModelSource.network(flat.model.url, authToken: _hfToken);
      modelFilename = _validateFilename(flat.model.name);
      tokenizerSource = switch (flat.tokenizer) {
        final t? => ModelSource.network(t.url, authToken: _hfToken),
        null => null,
      };
      tokenizerFilename = _validateFilename(flat.tokenizer?.name);
      runtime = r.runtime;
      notes = r.notes;
      for (final note in r.notes) {
        edgeAiLog('ℹ️  Hugging Face ($repo): $note');
      }
    }

    if (modelSource == null) {
      throw StateError(
        'A model source is required. Use modelFromNetwork() (or '
        'modelFromAsset(), modelFromBundled(), modelFromFile()).',
      );
    }
    final modelFile = modelFilename == null
        ? EmbeddingModelFile.fromSource(modelSource)
        : EmbeddingModelFile(source: modelSource, filename: modelFilename);
    if (!isSelfContainedEmbeddingFilename(modelFile.filename) &&
        tokenizerSource == null) {
      throw StateError(
        'Both model and tokenizer required. Use modelFromNetwork() and tokenizerFromNetwork().',
      );
    }

    // Throws ArgumentError for a self-contained container given a tokenizer.
    final spec = EmbeddingModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: modelSource,
      tokenizerSource: tokenizerSource,
      modelFilename: modelFilename,
      tokenizerFilename: tokenizerFilename,
      replacePolicy: ModelReplacePolicy.keep,
    );
    _requireABackendThatCanRun(spec);

    // What each file must be, by its index in spec.files (model, tokenizer).
    final expectations = [modelExpected, tokenizerExpected];
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
      modelType: repo.ModelType.embedding,
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

    // AUTO-SET as active embedding model (even if already installed)
    _cancelToken?.throwIfCancelled();
    await verifyInstalledFiles(spec, expected, active: activeBefore);
    _cancelToken?.throwIfCancelled();
    await activateInstalledModel(manager, spec);
    await release.run(manager, spec);
    progress?.complete();

    edgeAiLog('✅ Embedding model installed and set as active: ${spec.name}');

    return EmbeddingInstallation(spec: spec, runtime: runtime, notes: notes);
  }

  /// The model file and the optional tokenizer file of the embedder [r]
  /// resolved for [repo], each with its download URL, the leaf name it is
  /// installed under and the size the resolver gave. Throws
  /// [UnsupportedError] for a model directory and [StateError] for a result
  /// an embedder cannot take.
  static ({ResolvedHfFile model, ResolvedHfFile? tokenizer}) _flatEmbedderFiles(
    String repo,
    ResolvedHfModel r, {
    required ModelFileType? fileType,
  }) {
    if (r.family case final family?) {
      throw StateError(
        'The Hugging Face resolver for "$repo" returned the family $family '
        '(${family.runtimeType}); embedders have no family type, so an '
        'embedding resolver resolves to null.',
      );
    }
    // `files` names its members by bare leaf; `file` may be a repo path.
    final modelLeaf = r.file.split('/').last;
    final files = r.files;
    if (r.directoryName != null ||
        (files != null &&
            files.any(
              (f) => f.name != modelLeaf && f.name != r.tokenizerFile,
            ))) {
      throw UnsupportedError(
        'The Hugging Face resolver resolved "$repo" to a model directory '
        '(${files?.length ?? 0} files under '
        '"${r.directoryName ?? r.file}"); embedder directories are not '
        'supported yet. Only a model file, with its tokenizer file when it '
        'needs one, installs as an embedder.',
      );
    }
    final ResolvedHfFile model;
    final ResolvedHfFile? tokenizer;
    if (files == null) {
      // A single file installs under the leaf of `r.file` (not the URL's
      // name), with the resolution's own size.
      model = ResolvedHfFile(
        name: modelLeaf,
        url: r.url,
        sizeBytes: r.sizeBytes,
      );
      tokenizer = null;
    } else {
      final member = files.where((f) => f.name == modelLeaf).firstOrNull;
      if (member == null) {
        throw StateError(
          'The Hugging Face resolver resolved "$repo" with file "${r.file}", '
          'which is not among its files '
          '(${files.map((f) => f.name).join(', ')}): the model file must be '
          'one of them, named by its leaf "$modelLeaf".',
        );
      }
      model = member;
      tokenizer = files.where((f) => f.name == r.tokenizerFile).firstOrNull;
    }
    if (tokenizer == null && !isSelfContainedEmbeddingFilename(model.name)) {
      final resolver = HuggingFaceResolverRegistry.instance.findFor(
        repo,
        type: ModelManagementType.embedding,
        fileType: fileType,
      );
      throw StateError(
        'The Hugging Face resolver "${resolver?.name ?? 'unknown'}" resolved '
        '"$repo" without a tokenizerFile, and ${model.name} needs a tokenizer '
        'file of its own (only a .litertlm or .gguf container carries one). '
        'The resolver must name its tokenizer in ResolvedHfModel.files and '
        'tokenizerFile.',
      );
    }
    return (model: model, tokenizer: tokenizer);
  }

  /// The install pre-check (R5 §5.3, D13): when embedding backends are
  /// registered, one of them must be able to run [spec] here, or nothing is
  /// downloaded. With none registered yet the install proceeds — the app may
  /// register one later — and says so once.
  static void _requireABackendThatCanRun(EmbeddingModelSpec spec) {
    final backends = EmbeddingRegistry.instance;
    final filename = spec.files.first.filename;
    if (!backends.hasAny) {
      if (!_noBackendNoticed) {
        _noBackendNoticed = true;
        edgeAiLog(
          'ℹ️  No embedding backend is registered yet, so whether one can run '
          '$filename is not checked before it is installed. Pass one in '
          'FlutterEdgeAi.initialize(embeddingBackends: ...).',
        );
      }
      return;
    }
    if (backends.findFor(spec) != null) return;
    final platform = kIsWeb ? 'web' : defaultTargetPlatform.name;
    throw UnsupportedError(
      'No registered embedding backend can run $filename on $platform. '
      'Registered: '
      '${backends.registered.map((b) => b.name).join(', ')}. Nothing was '
      'downloaded. Register a backend that runs this model (e.g. '
      'flutter_edge_ai_litertlm for .tflite and .litertlm, '
      'flutter_edge_ai_onnx for .onnx), or install a model one of these '
      'runs.',
    );
  }
}

/// Result of embedding model installation
class EmbeddingInstallation {
  final EmbeddingModelSpec spec;

  /// Overridable runtime defaults from the Hugging Face resolver when
  /// installed with `fromHuggingFace`; null for every other source. Pass
  /// them as `FlutterEdgeAi.getActiveEmbedder(defaults:)`. Not persisted.
  final ModelRuntimeDefaults? runtime;

  /// Advisory notes surfaced by the Hugging Face resolver (platform caveats,
  /// known issues) when installed with `fromHuggingFace`; empty for every
  /// other source. Also written to the debug log at install time; read them
  /// here in a release build. Unmodifiable — the constructor wraps whatever
  /// the resolver handed over, so this never aliases a list a resolver still
  /// holds.
  final List<String> notes;

  EmbeddingInstallation({
    required this.spec,
    this.runtime,
    List<String> notes = const [],
  }) : notes = List.unmodifiable(notes);

  /// Model ID (filename without extension)
  String get modelId => spec.name;
}

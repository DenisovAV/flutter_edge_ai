import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/model_management/model_specs.dart';
import 'package:flutter_gemma/core/utils/file_name_utils.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Fluent builder for inference model installation
///
/// Provides type-safe API for installing inference models with optional LoRA weights.
/// Automatically sets the installed model as the active inference model.
///
/// Usage:
/// ```dart
/// await FlutterGemma.installModel(
///   modelType: ModelType.gemmaIt,
/// )
///   .fromNetwork('https://example.com/model.task', token: 'hf_...')
///   .withProgress((progress) => print('$progress%'))
///   .install();
/// ```
class InferenceInstallationBuilder {
  final ModelType _modelType;
  final ModelFileType _fileType;

  ModelSource? _modelSource;
  ModelSource? _loraSource;
  void Function(int progress)? _onProgress;
  CancelToken? _cancelToken;

  // Deferred Hugging Face resolution — set by `fromHuggingFace(repo)` with no
  // `file`. The manifest is resolved in `install()`, not here, because
  // resolution is async and builder setters are synchronous. Mutually exclusive
  // with [_modelSource]: every other `fromX()` setter clears [_hfRepo], and the
  // deferred `fromHuggingFace` clears [_modelSource], so the last-called source
  // always wins.
  String? _hfRepo;
  String? _hfToken;
  bool? _hfForeground;

  /// Create builder with model identity
  InferenceInstallationBuilder({
    required ModelType modelType,
    ModelFileType fileType = ModelFileType.task,
  }) : _modelType = modelType,
       _fileType = fileType;

  /// Set model source from network URL (HTTP/HTTPS)
  ///
  /// Parameters:
  /// - [url]: The HTTP/HTTPS URL to download from
  /// - [token]: Optional authentication token (e.g., HuggingFace token)
  /// - [foreground]: Android foreground service mode (shows notification, no timeout)
  ///   - null (default): NO foreground service — this branch configures no
  ///     notification, and the platform needs one before it starts the service
  ///   - true: always use foreground
  ///   - false: never use foreground
  InferenceInstallationBuilder fromNetwork(
    String url, {
    String? token,
    bool? foreground,
  }) {
    _modelSource = ModelSource.network(
      url,
      authToken: token,
      foreground: foreground,
    );
    _hfRepo = null; // an explicit source cancels a pending deferred-HF resolve
    return this;
  }

  /// Set model source from Flutter asset
  ///
  /// Path should be relative to assets directory.
  /// Handles 'assets/' prefix automatically.
  InferenceInstallationBuilder fromAsset(String path) {
    _modelSource = ModelSource.asset(path);
    _hfRepo = null;
    return this;
  }

  /// Set model source from bundled native resource
  ///
  /// Platform-specific paths:
  /// - Android: assets/models/{resourceName}
  /// - iOS: Bundle.main.path(forResource:)
  /// - Web: /assets/{resourceName}
  InferenceInstallationBuilder fromBundled(String resourceName) {
    _modelSource = ModelSource.bundled(resourceName);
    _hfRepo = null;
    return this;
  }

  /// Set model source from external file path
  ///
  /// File must exist at the specified absolute path.
  /// Use case: User-provided models via file picker
  InferenceInstallationBuilder fromFile(String path) {
    _modelSource = ModelSource.file(path);
    _hfRepo = null;
    return this;
  }

  /// Set model source from a Hugging Face repo. Two modes:
  ///
  /// **Explicit file** (pass [file]): builds
  /// `https://huggingface.co/<repo>/resolve/<revision>/<file>` and installs it
  /// via the network path. [file] may contain `/` for a repo that nests
  /// variants in subfolders (e.g. `int4/model.litertlm`); each segment is
  /// URL-encoded independently so the path structure survives. Use this when
  /// you know the exact path (and optionally a pinned [revision]).
  ///
  /// **Manifest (one-call)** (OMIT [file]): resolves the repo's deployment
  /// manifest internally at [install] time — via the resolver registered for
  /// this builder's `fileType` (see [FlutterGemma.resolveHuggingFace]) — then
  /// installs the resolved, revision-pinned variant and returns the manifest's
  /// overridable runtime defaults on [InferenceInstallation.runtime]:
  /// ```dart
  /// final install = await FlutterGemma
  ///     .installModel(modelType: ModelType.general, fileType: ModelFileType.litertlm)
  ///     .fromHuggingFace('org/repo')            // no file — resolve the manifest
  ///     .install();
  /// final model = await FlutterGemma.getActiveModel(defaults: install.runtime);
  /// ```
  /// Notes on the manifest mode:
  /// - [revision] must be left `'main'`: the registered resolver owns the pin
  ///   (it builds a revision-pinned URL). Passing a non-`'main'` [revision]
  ///   without a [file] throws [ArgumentError].
  /// - The resolver's own behavior surfaces from [install]: `.onnx` resolves
  ///   and installs an ORT-GenAI model DIRECTORY (via the HF file tree), while
  ///   `.builtIn` throws `UnsupportedError` (the OS owns the weights — there is
  ///   no Hugging Face file) — naming the repo.
  /// - Unlike other sources, this requires NETWORK access at [install] even if
  ///   the model is already installed (the variant filename is only known after
  ///   the manifest fetch). For offline-safe idempotent installs, cache the
  ///   `ResolvedHfModel` yourself and install from `fromNetwork(r.url)`.
  /// - `modelType`: pass `ModelType.general` to let the manifest decide the
  ///   family; pass a SPECIFIC type to keep your choice (it wins over the
  ///   manifest, and any disagreement is surfaced in [InferenceInstallation.notes]).
  /// - A [CancelToken] set via `withCancelToken` cannot interrupt the manifest
  ///   fetch itself (the resolver takes no token); cancellation is honoured
  ///   immediately after the fetch returns, before the download starts.
  ///
  /// The plugin already applies the configured HuggingFace token to
  /// `huggingface.co` URLs for gated repos, so [token] is only needed to
  /// override it (it is also threaded into the manifest fetch).
  InferenceInstallationBuilder fromHuggingFace(
    String repo, {
    String? file,
    String revision = 'main',
    String? token,
    bool? foreground,
  }) {
    // Fail loud at the seam — an empty repo would otherwise build a URL that
    // only 404s (or, worse, saves a CDN error page as the model) far downstream.
    if (repo.trim().isEmpty) {
      throw ArgumentError.value(repo, 'repo', 'must be a non-empty "org/name"');
    }
    if (file == null) {
      // Manifest mode: defer resolution to install(). The resolver builds the
      // revision-pinned URL, so a caller-supplied non-'main' revision here has
      // nowhere to go — reject it loudly rather than silently dropping the pin.
      if (revision != 'main') {
        throw ArgumentError.value(
          revision,
          'revision',
          'cannot be set without an explicit `file`: the registered resolver '
              'owns the revision pin. Pass `file:` to install a specific path '
              'at a specific revision, or register the resolver with the '
              'revision you want.',
        );
      }
      _modelSource = null; // cancel any earlier explicit source
      _hfRepo = repo;
      _hfToken = token;
      _hfForeground = foreground;
      return this;
    }
    if (file.trim().isEmpty) {
      throw ArgumentError.value(
        file,
        'file',
        'must be a non-empty repo-relative path (or omit `file` to resolve the '
            'repo manifest)',
      );
    }
    final encodedPath = file.split('/').map(Uri.encodeComponent).join('/');
    final url = 'https://huggingface.co/$repo/resolve/$revision/$encodedPath';
    return fromNetwork(url, token: token, foreground: foreground);
  }

  /// Optional: Add LoRA weights from custom source
  InferenceInstallationBuilder withLora(ModelSource loraSource) {
    _loraSource = loraSource;
    return this;
  }

  /// Convenience: Add LoRA weights from network URL
  InferenceInstallationBuilder withLoraFromNetwork(
    String url, {
    String? token,
  }) {
    _loraSource = ModelSource.network(url, authToken: token);
    return this;
  }

  /// Convenience: Add LoRA weights from asset
  InferenceInstallationBuilder withLoraFromAsset(String path) {
    _loraSource = ModelSource.asset(path);
    return this;
  }

  /// Convenience: Add LoRA weights from bundled resource
  InferenceInstallationBuilder withLoraFromBundled(String resourceName) {
    _loraSource = ModelSource.bundled(resourceName);
    return this;
  }

  /// Convenience: Add LoRA weights from file
  InferenceInstallationBuilder withLoraFromFile(String path) {
    _loraSource = ModelSource.file(path);
    return this;
  }

  /// Add progress callback
  ///
  /// Called periodically during installation with progress percentage (0-100).
  InferenceInstallationBuilder withProgress(
    void Function(int progress) onProgress,
  ) {
    _onProgress = onProgress;
    return this;
  }

  /// Set cancellation token for this installation
  ///
  /// The same token will be used for both model and LoRA downloads.
  ///
  /// Example:
  /// ```dart
  /// final cancelToken = CancelToken();
  ///
  /// final future = FlutterGemma.installModel(modelType: ModelType.gemmaIt)
  ///   .fromNetwork(url)
  ///   .withCancelToken(cancelToken)
  ///   .install();
  ///
  /// // Cancel from elsewhere
  /// cancelToken.cancel('User cancelled');
  /// ```
  InferenceInstallationBuilder withCancelToken(CancelToken cancelToken) {
    _cancelToken = cancelToken;
    return this;
  }

  /// Execute the installation and automatically set as active inference model
  ///
  /// Returns [InferenceInstallation] with details about installed model.
  ///
  /// Throws:
  /// - [StateError] if no model source configured
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - [Exception] on installation failure
  ///
  /// Note: This method is idempotent - calling install() on an already-installed
  /// model will skip download and just set it as active.
  Future<InferenceInstallation> install() async {
    // Check cancellation before starting
    _cancelToken?.throwIfCancelled();

    // Runtime defaults / notes / model family resolved from a Hugging Face
    // manifest (deferred `fromHuggingFace(repo)`). Null/empty for every non-HF
    // source; they ride on the RESULT ([InferenceInstallation]), never on the
    // spec — preserving install-vs-runtime separation.
    ModelRuntimeDefaults? resolvedRuntime;
    List<String> resolvedNotes = const [];
    ModelType? resolvedModelType;

    // The effective model source. install() is a pure READER of builder state:
    // the deferred-HF resolve below assigns the resolved network source to this
    // LOCAL, never back to `_modelSource`, so reusing a builder instance never
    // sees install() mutate its source mid-flight.
    ModelSource? source = _modelSource;

    // Deferred Hugging Face resolution runs FIRST — before the builtIn /
    // onnx-web branches below, which assume a concrete source. A `.onnx` repo
    // resolves to a directory (or a fileless web model) here; a `.builtIn` repo
    // throws its own clear `UnsupportedError` (the OS owns the weights, no HF
    // file) — either way, before those branches trip over a null source.
    if (_hfRepo != null) {
      final r = await FlutterGemma.resolveHuggingFace(
        _hfRepo!,
        fileType: _fileType,
        token: _hfToken,
      );
      // The manifest fetch itself is not cancellable (the resolver contract
      // takes no CancelToken) — fail fast here, before the download starts.
      _cancelToken?.throwIfCancelled();

      // Model-family precedence: `ModelType.general` is the conventional "no
      // claim — resolve it for me" value, so the manifest's family wins over it;
      // any SPECIFIC modelType the caller passed wins over the manifest
      // (explicit > manifest, matching `mergeRuntimeDefault`). A real
      // disagreement is surfaced in a RELEASE-visible note — `gemmaLog` is
      // debug-only, so it can't be the only channel.
      final manifestType = r.modelType;
      if (_modelType == ModelType.general) {
        resolvedModelType = manifestType; // may be null → stays general
        resolvedNotes = r.notes;
      } else if (manifestType != null && manifestType != _modelType) {
        resolvedModelType = _modelType; // explicit wins
        final note =
            'Installed as ${_modelType.name} (your explicit choice); the '
            'Hugging Face manifest for "$_hfRepo" declares ${manifestType.name}.';
        resolvedNotes = [...r.notes, note];
        gemmaLog('ℹ️  $note');
      } else {
        resolvedModelType = _modelType; // agrees, or manifest silent
        resolvedNotes = r.notes;
      }
      for (final note in r.notes) {
        gemmaLog('ℹ️  Hugging Face ($_hfRepo): $note');
      }

      resolvedRuntime = r.runtime;

      // DIRECTORY model (ORT-GenAI): a set of files that must install together
      // into a per-model subdirectory with bare names (the layout
      // `OgaCreateModel` needs). Self-contained path — download the bundle and
      // return; the single-file flow below never runs.
      if (r.files != null) {
        return _installDirectory(
          r,
          modelType: resolvedModelType ?? _modelType,
          runtime: resolvedRuntime,
          notes: resolvedNotes,
        );
      }

      source = ModelSource.network(
        r.url,
        authToken: _hfToken,
        foreground: _hfForeground,
      );
    }

    if (source == null) {
      throw StateError(
        'Model source not configured. Use fromNetwork(), fromAsset(), '
        'fromBundled(), fromFile(), or fromHuggingFace().',
      );
    }

    // Built-in OS models: no file to install. Validate constraints, build the
    // spec, and persist the active identity without touching SourceHandlers
    // or ServiceRegistry (native side owns the model — nothing to download).
    if (_fileType == ModelFileType.builtIn) {
      if (_loraSource != null) {
        throw ArgumentError(
          'LoRA is not supported for built-in OS models (ModelFileType.builtIn).',
        );
      }
      final modelFile = InferenceModelFile.fromSource(source);
      final spec = InferenceModelSpec(
        name: FileNameUtils.getBaseName(modelFile.filename),
        modelSource: source,
        replacePolicy: ModelReplacePolicy.keep,
        modelType: resolvedModelType ?? _modelType,
        fileType: _fileType,
      );
      final manager = FlutterGemmaPlugin.instance.modelManager;
      manager.setActiveModel(spec);
      gemmaLog('✅ Built-in model set as active: ${spec.name}');
      return InferenceInstallation(
        spec: spec,
        runtime: resolvedRuntime,
        notes: resolvedNotes,
      );
    }

    // ONNX on WEB: Transformers.js (@huggingface/transformers) resolves +
    // caches the whole Hugging Face repo itself from a repo id — the model
    // identity is a repo id, not a single downloadable file, so there is
    // nothing for a SourceHandler to fetch. Persist the active identity only,
    // exactly like the built-in path above. This is WEB-ONLY: on native, an
    // ONNX model is a real on-disk directory (genai_config.json + .onnx +
    // tokenizer) that DOES install through the handler path below, so the
    // fileless shortcut must never fire off-web.
    if (kIsWeb && _fileType == ModelFileType.onnx) {
      if (_loraSource != null) {
        throw ArgumentError(
          'LoRA is not supported for ONNX web models (ModelFileType.onnx).',
        );
      }
      final modelFile = InferenceModelFile.fromSource(source);
      final spec = InferenceModelSpec(
        name: FileNameUtils.getBaseName(modelFile.filename),
        modelSource: source,
        replacePolicy: ModelReplacePolicy.keep,
        modelType: resolvedModelType ?? _modelType,
        fileType: _fileType,
      );
      final manager = FlutterGemmaPlugin.instance.modelManager;
      manager.setActiveModel(spec);
      gemmaLog(
        '✅ ONNX web model set as active (Transformers.js owns the weights): '
        '${spec.name}',
      );
      return InferenceInstallation(
        spec: spec,
        runtime: resolvedRuntime,
        notes: resolvedNotes,
      );
    }

    // Create spec
    final modelFile = InferenceModelFile.fromSource(source);
    final spec = InferenceModelSpec(
      name: FileNameUtils.getBaseName(modelFile.filename),
      modelSource: source,
      loraSource: _loraSource,
      replacePolicy: ModelReplacePolicy.keep,
      modelType: resolvedModelType ?? _modelType,
      fileType: _fileType,
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // spec.files is [modelFile, loraFile?] in that fixed order (see
    // InferenceModelSpec.files) — reuse the ALREADY-namespaced identity
    // instead of recomputing a basename, so the isInstalled check and the
    // download target always agree.
    final files = spec.files;
    final namespacedModelFilename = files[0].filename;

    // Check if model is already installed
    final isInstalled = await repository.isInstalled(namespacedModelFilename);

    if (isInstalled) {
      gemmaLog(
        'ℹ️  Model already installed: $namespacedModelFilename (skipping download)',
      );
    } else {
      // Install model file
      final handlerRegistry = registry.sourceHandlerRegistry;
      final handler = handlerRegistry.getHandler(source);
      if (_onProgress != null) {
        await for (final progress in handler!.installWithProgress(
          source,
          cancelToken: _cancelToken,
          targetFilename: namespacedModelFilename,
        )) {
          _onProgress!(progress);
        }
      } else {
        await handler!.install(
          source,
          cancelToken: _cancelToken,
          targetFilename: namespacedModelFilename,
        );
      }

      // Install LoRA if provided
      if (_loraSource != null) {
        final namespacedLoraFilename = files[1].filename;
        final loraHandler = handlerRegistry.getHandler(_loraSource!);
        await loraHandler!.install(
          _loraSource!,
          cancelToken: _cancelToken,
          targetFilename: namespacedLoraFilename,
        );
      }
    }

    // AUTO-SET as active inference model (even if already installed)
    final manager = FlutterGemmaPlugin.instance.modelManager;
    manager.setActiveModel(spec);

    gemmaLog('✅ Inference model installed and set as active: ${spec.name}');

    return InferenceInstallation(
      spec: spec,
      runtime: resolvedRuntime,
      notes: resolvedNotes,
    );
  }

  /// Installs a DIRECTORY (ORT-GenAI) model resolved from a Hugging Face repo:
  /// every file in [r].files is downloaded into a per-model subdirectory
  /// (`<modelId>/<bareLeaf>`) with its bare leaf name — the layout
  /// `OgaCreateModel` needs (`genai_config.json` references its siblings by bare
  /// name; the native loader is handed the directory). Mirrors the TTS bundle
  /// install loop, but subdir-namespaced rather than flat. The active spec's
  /// primary file is `genai_config.json`, so `getModelFilePaths.values.first`
  /// resolves inside the directory and the engine's `File(modelPath).parent` is
  /// exactly that directory.
  Future<InferenceInstallation> _installDirectory(
    ResolvedHfModel r, {
    required ModelType modelType,
    required ModelRuntimeDefaults? runtime,
    required List<String> notes,
  }) async {
    // LoRA rides on a single-file inference model; a directory (ORT-GenAI)
    // model has no place to attach it. Reject loudly instead of silently
    // dropping it (mirrors the builtIn / onnx-web paths).
    if (_loraSource != null) {
      throw ArgumentError(
        'LoRA is not supported for directory (ORT-GenAI) models installed via '
        'fromHuggingFace("$_hfRepo").',
      );
    }

    final hfFiles = r.files!;
    final primaryName = r.file; // bare leaf, e.g. genai_config.json

    // The subdirectory name is REQUIRED and must be variant-inclusive — a
    // repo-only fallback would let two execution-provider variants of the same
    // repo (cpu vs cuda) collide in one directory, and the second install's
    // "already installed" skips would activate a spec backed by the other
    // variant's files. The resolver supplies it via
    // FileNameUtils.sanitizeHfDirName(repo, variant: …).
    final modelId = r.directoryName;
    if (modelId == null || modelId.isEmpty) {
      throw ArgumentError(
        'A directory model resolved from "$_hfRepo" must supply '
        'ResolvedHfModel.directoryName (a variant-inclusive subdirectory name); '
        'got none.',
      );
    }
    // The subdir name is interpolated as a path segment (`<modelId>/<leaf>`) and
    // fed to deleteModel's recursive Directory.delete — a traversing modelId
    // (`..`, or one carrying a separator) would escape the storage dir and could
    // delete its parent. `sanitizeHfDirName` guards its own output, but a
    // third-party resolver can supply `directoryName` directly, so re-check here.
    if (modelId == '.' ||
        modelId == '..' ||
        modelId.contains('/') ||
        modelId.contains(r'\')) {
      throw ArgumentError.value(
        modelId,
        'ResolvedHfModel.directoryName',
        'must be a single safe path segment (no "/", "\\", "." or ".." ) — a '
            'traversing name would escape the model storage directory; refusing '
            '"$_hfRepo"',
      );
    }

    // A directory member must be a BARE leaf name. A resolver name with a path
    // separator or a "."/".." segment (e.g. "../victim.onnx") would escape the
    // model directory at both install and delete time — refuse it.
    for (final f in hfFiles) {
      if (!f.isBareLeafName) {
        throw ArgumentError.value(
          f.name,
          'ResolvedHfFile.name',
          'directory model file names must be bare leaf names (no path '
              'separators or "."/".." segments) — refusing "$_hfRepo" file',
        );
      }
    }

    if (!hfFiles.any((f) => f.name == primaryName)) {
      throw StateError(
        'Directory model "$_hfRepo" resolved without its primary file '
        '"$primaryName" in the file list — cannot locate the model directory\'s '
        'entry point.',
      );
    }

    // Belt-and-suspenders: a directory with a genai_config.json but no .onnx
    // GRAPH file installs "successfully" and only fails later inside
    // OgaCreateModel. This checks graph PRESENCE only — not that every weight
    // the graph references (external `.onnx_data`) is included, so a mis-export
    // can still fail at load. The onnx resolver already guards presence, but any
    // resolver could hand us an incomplete set — refuse the no-`.onnx` case here
    // too.
    if (!hfFiles.any((f) => f.name.endsWith('.onnx'))) {
      throw StateError(
        'Directory model "$_hfRepo" has no .onnx graph file among its '
        '${hfFiles.length} files — it cannot load. The resolver returned an '
        'incomplete file set.',
      );
    }

    // Primary first so getModelFilePaths.values.first is the file the engine
    // loads from (its parent dir is what OgaCreateModel is handed).
    final ordered = [
      ...hfFiles.where((f) => f.name == primaryName),
      ...hfFiles.where((f) => f.name != primaryName),
    ];
    final bundle = [
      for (final f in ordered)
        DirectoryBundleFile.member(
          modelId: modelId,
          bareName: f.name,
          primaryName: primaryName,
          source: ModelSource.network(
            f.url,
            authToken: _hfToken,
            foreground: _hfForeground,
          ),
        ),
    ];

    final spec = InferenceModelSpec(
      name: modelId,
      modelSource: bundle.first.source, // the primary (genai_config.json)
      replacePolicy: ModelReplacePolicy.keep,
      modelType: modelType,
      fileType: _fileType,
      directoryFiles: bundle,
    );

    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final handlerRegistry = registry.sourceHandlerRegistry;

    final files = spec.files;
    final total = files.length;
    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      _cancelToken?.throwIfCancelled();
      if (await repository.isInstalled(file.filename)) {
        gemmaLog('ℹ️  Already installed: ${file.filename} (skipping download)');
      } else {
        final handler = handlerRegistry.getHandler(file.source);
        if (handler == null) {
          throw StateError(
            'No source handler for ${file.source.runtimeType} (directory '
            'member "${file.filename}").',
          );
        }
        if (_onProgress != null) {
          // Each file owns the slice [i/total, (i+1)/total]; stream WITHIN it so
          // the bar keeps moving during the multi-GB model.onnx download instead
          // of freezing between file boundaries (weights dominate total size).
          await for (final pct in handler.installWithProgress(
            file.source,
            cancelToken: _cancelToken,
            targetFilename: file.filename,
          )) {
            _onProgress!((((i + pct / 100) / total) * 100).round());
          }
        } else {
          await handler.install(
            file.source,
            cancelToken: _cancelToken,
            targetFilename: file.filename,
          );
        }
      }
      _onProgress?.call((((i + 1) / total) * 100).round());
    }

    final manager = FlutterGemmaPlugin.instance.modelManager;
    manager.setActiveModel(spec);
    gemmaLog('✅ ONNX directory model installed and set as active: $modelId');

    return InferenceInstallation(spec: spec, runtime: runtime, notes: notes);
  }
}

/// Result of inference model installation
class InferenceInstallation {
  final InferenceModelSpec spec;

  /// Overridable runtime defaults resolved from a Hugging Face manifest when
  /// installed via `fromHuggingFace(repo)` (no `file`); `null` for every other
  /// source. Apply the model-level fields with
  /// `getActiveModel(defaults: installation.runtime)`, and forward the two
  /// session-level fields (`isThinking`, `minOutputTokens`) to `createSession`
  /// yourself.
  ///
  /// EPHEMERAL — not persisted. After an app restart the restored active model
  /// carries no manifest defaults, so re-resolve the manifest (or cache the
  /// `ResolvedHfModel` yourself) to recover these on a later launch.
  final ModelRuntimeDefaults? runtime;

  /// Advisory notes surfaced by the Hugging Face resolver (platform caveats,
  /// known issues); empty for non-HF sources. Also written to the log at
  /// install time. Unmodifiable — the constructor wraps whatever the resolver
  /// handed over, so this never aliases a list a resolver still holds.
  final List<String> notes;

  InferenceInstallation({
    required this.spec,
    this.runtime,
    List<String> notes = const [],
  }) : notes = List.unmodifiable(notes);

  /// Model ID (filename without extension)
  String get modelId => spec.name;

  /// Model type (gemmaIt, deepSeek, etc.)
  ModelType get modelType => spec.modelType;

  /// File type (task, binary)
  ModelFileType get fileType => spec.fileType;

  /// Whether LoRA weights were installed
  bool get hasLora => spec.loraSource != null;
}

part of '../../../mobile/flutter_gemma_mobile.dart';

/// Main unified model manager that orchestrates all model operations
class MobileModelManager extends ModelFileManager {
  /// Single-flight init guard. Cached so concurrent callers share one
  /// initialization. Init only restores the previously-active model identity
  /// (#227); a restore failure degrades to "no active model" rather than
  /// throwing, so a corrupt/unreadable prefs state never blocks app startup
  /// (#314 follow-up). The cached future therefore always completes normally.
  Future<void>? _initFuture;

  /// Initializes the unified model manager. Idempotent and concurrency-safe.
  Future<void> initialize() => _initFuture ??= _doInit();

  @override
  Future<void> ensureInitialized() => initialize();

  Future<void> _doInit() async {
    try {
      await _restoreActiveInferenceModel();
      await _restoreActiveEmbeddingModel();
      await _restoreActiveSttModel();
      await _restoreActiveTtsModel();
      gemmaLog('UnifiedModelManager initialized successfully');
    } catch (e, st) {
      // Restoring the previously-active model is best-effort. A failure here
      // (e.g. unreadable SharedPreferences) must not abort app startup — start
      // with no active model; the user can re-install/select. (#314 follow-up)
      // Include the stack trace so an unexpected restore bug stays diagnosable.
      gemmaLog(
        'UnifiedModelManager: active-model restore failed, starting with no active model: $e\n$st',
      );
    }
    // Reclaim multi-GB download temp files orphaned by failed / cancelled /
    // process-killed downloads (#383). Fire-and-forget: it must never block or
    // fail app startup, and it self-delays past WorkManager rescheduling before
    // reading the "no active downloads" gate.
    unawaited(_reclaimOrphanedDownloadTemps());
  }

  /// Deletes orphaned `background_downloader` partial temp files left in the
  /// Android persistent internal dir (`filesDir`) by downloads that failed,
  /// were cancelled, or died with the process (#383).
  ///
  /// background_downloader streams a large-file download into a randomly-named
  /// temp `filesDir/com.bbflight.background_downloader<rand>` and only moves it
  /// to the model path on success. On a resumable failure it deliberately KEEPS
  /// the partial; a fresh retry or a process-kill/WorkManager-restart then
  /// allocates a NEW temp and orphans the old one — filesDir is never reclaimed
  /// by the OS, so multi-GB partials accumulate forever.
  ///
  /// This runs only when it is SAFE: a live/queued download's temp path is not
  /// visible from Dart, so the sweep bails if any task is active, skips temps
  /// touched recently (a just-(re)started download), and preserves temps a
  /// valid pending resume would reuse.
  Future<void> _reclaimOrphanedDownloadTemps() async {
    // Temp-file lifecycle + `filesDir` location are Android-specific; on iOS the
    // resume data is opaque (not a temp path) and the leak doesn't apply.
    if (!Platform.isAndroid) return;
    try {
      // Let WorkManager finish re-registering any process-killed download so
      // the active-tasks gate below reflects reality (avoids racing — and then
      // deleting — a just-restarted download's temp on cold start).
      await Future<void>.delayed(const Duration(seconds: 5));
      final downloader = FileDownloader();
      await downloader.resumeFromBackground();

      // Narrow the blanket gate to GENUINELY-RUNNING native tasks. A legacy
      // record re-materialized by resumeFromBackground() shows up as a *paused*
      // task; gating on "any active task" would let one stale paused record wedge
      // reclaim forever — exactly the R2 upgrade-mid-download scenario (#383).
      // ignore: invalid_use_of_visible_for_testing_member
      final storage = downloader.database.storage;
      final pausedIds = (await storage.retrieveAllPausedTasks())
          .map((t) => t.taskId)
          .toSet();
      final allIds = (await downloader.allTasks(
        allGroups: true,
      )).map((t) => t.taskId).toSet();
      final nativeRunningIds = allIds.difference(pausedIds);

      // Reconcile every group-scoped resume record against the current scheme,
      // BEFORE the blanket sweep. Purge legacy records (temp + resume/paused/db
      // state); keep current-scheme and still-running temps.
      final resumeData = await storage.retrieveAllResumeData();
      final keep = <String>{};
      for (final r in resumeData) {
        if (r.task.group != SmartDownloader.downloadGroup) continue;
        try {
          final expectedId = computeTaskId(
            r.task.baseDirectory,
            r.task.directory,
            r.task.filename,
          );
          Duration tempAge;
          try {
            tempAge = DateTime.now().difference(
              await File(r.tempFilepath).lastModified(),
            );
          } catch (_) {
            tempAge =
                kDownloadTempMinReclaimAge; // treat unknown mtime as eligible-old
          }
          final decision = reconcileResumeRecord(
            taskId: r.task.taskId,
            expectedId: expectedId,
            isNativeRunning: nativeRunningIds.contains(r.task.taskId),
            tempAge: tempAge,
          );
          switch (decision) {
            case ReclaimDecision.keep:
              keep.add(r.tempFilepath);
            case ReclaimDecision.skip:
              break;
            case ReclaimDecision.purge:
              try {
                await File(r.tempFilepath).delete();
              } catch (_) {}
              await storage.removeResumeData(r.task.taskId);
              await storage.removePausedTask(r.task.taskId);
              await downloader.database.deleteRecordWithId(r.task.taskId);
              gemmaLog(
                'Reclaimed legacy download record ${r.task.taskId} (#383)',
              );
          }
        } catch (e) {
          gemmaLog('Reclaim: skipped record ${r.task.taskId} ($e) (#383)');
          continue;
        }
      }

      // Blanket filesystem sweep only when nothing is actively writing a temp.
      if (nativeRunningIds.isNotEmpty) {
        gemmaLog(
          'Download-temp sweep skipped: ${nativeRunningIds.length} running task(s) (#383)',
        );
        return;
      }
      final dir = await getApplicationSupportDirectory();
      final reclaimed = await sweepOrphanedDownloadTemps(dir, keepPaths: keep);
      gemmaLog(
        'Download-temp reclaim: kept ${keep.length}, reclaimed $reclaimed (#383)',
      );
    } catch (e, st) {
      gemmaLog('Orphaned download-temp reclaim failed (non-fatal): $e\n$st');
    }
  }

  /// Rehydrate `_activeInferenceModel` from the identity that
  /// `setActiveModel` persisted on the previous run (#227).
  ///
  /// Without this, `isModelInstalled()` returns true after restart
  /// (because the file exists) but `getActiveModel()` throws —
  /// callers had to re-invoke `installModel()` every launch.
  Future<void> _restoreActiveInferenceModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelTypeName = prefs.getString(
      PreferencesKeys.activeInferenceModelType,
    );
    final fileTypeName = prefs.getString(
      PreferencesKeys.activeInferenceFileType,
    );
    final filename = prefs.getString(PreferencesKeys.activeInferenceFilename);

    if (modelTypeName == null || fileTypeName == null || filename == null) {
      return;
    }

    final ModelType modelType;
    final ModelFileType fileType;
    try {
      modelType = ModelType.values.byName(modelTypeName);
      fileType = ModelFileType.values.byName(fileTypeName);
    } catch (e) {
      gemmaLog(
        '[ModelManager] active model restore: unknown enum value ($modelTypeName / $fileTypeName) — skipping',
      );
      return;
    }

    if (fileType == ModelFileType.builtIn) {
      // Built-in OS models have no file at getTargetPath. Reconstruct the
      // inert bundled-source carrier persisted at install time.
      _activeInferenceModel = InferenceModelSpec(
        name: filename,
        modelSource: BundledSource(filename),
        modelType: modelType,
        fileType: fileType,
      );
      gemmaLog('[ModelManager] restored active built-in model: $filename');
      return;
    }

    // DIRECTORY model (ORT-GenAI): the persisted primary filename is the
    // subpath `<modelId>/genai_config.json`. Rebuild the whole bundle from the
    // repository records under that subdir — the repository is the single
    // source of truth `_isModelInstalled` also checks, so restore and
    // install-check cannot desync. Reconstructing via `FileSource(path)` (the
    // single-file path below) would re-derive a BARE leaf filename, missing the
    // subpath repo key, and `isModelInstalled` would be false every launch.
    if (fileType == ModelFileType.onnx && filename.contains('/')) {
      await _restoreActiveInferenceDirectory(filename, modelType, fileType);
      return;
    }

    final filePath = await ServiceRegistry.instance.fileSystemService
        .getTargetPath(filename);
    if (!File(filePath).existsSync()) {
      gemmaLog(
        '[ModelManager] active model restore: file $filePath missing — skipping',
      );
      return;
    }

    _activeInferenceModel = InferenceModelSpec(
      name: filename,
      modelSource: FileSource(filePath),
      modelType: modelType,
      fileType: fileType,
    );
    gemmaLog('[ModelManager] restored active inference model: $filename');
  }

  /// Restores a DIRECTORY (ORT-GenAI) active model from the repository records
  /// under `<modelId>/`. [primaryFilename] is the persisted subpath
  /// `<modelId>/<primaryBareLeaf>` (the file the engine loads from). Every
  /// member is rebuilt with an EXPLICIT subpath filename (never derived from a
  /// source), primary first, so `getModelFilePaths.values.first` resolves inside
  /// the model directory.
  Future<void> _restoreActiveInferenceDirectory(
    String primaryFilename,
    ModelType modelType,
    ModelFileType fileType,
  ) async {
    final slash = primaryFilename.indexOf('/');
    final modelId = primaryFilename.substring(0, slash);
    final primaryBare = primaryFilename.substring(slash + 1);

    final repository = ServiceRegistry.instance.modelRepository;
    final members = (await repository.listInstalled())
        .where((m) => m.id.startsWith('$modelId/'))
        .toList();
    if (!members.any((m) => m.id == primaryFilename)) {
      gemmaLog(
        '[ModelManager] active directory model restore: no primary record '
        '"$primaryFilename" — skipping',
      );
      return;
    }

    // Every member must be physically present, or the model cannot load.
    for (final m in members) {
      final p = await ModelFileSystemManager.getModelFilePath(m.id);
      if (!File(p).existsSync()) {
        gemmaLog(
          '[ModelManager] active directory model restore: missing file $p '
          '— skipping',
        );
        return;
      }
    }

    DirectoryBundleFile toMember(repo.ModelInfo m) =>
        DirectoryBundleFile.member(
          modelId: modelId,
          bareName: m.id.substring(modelId.length + 1),
          primaryName: primaryBare,
          source: m.source,
        );
    final bundle = <DirectoryBundleFile>[
      ...members.where((m) => m.id == primaryFilename).map(toMember),
      ...members.where((m) => m.id != primaryFilename).map(toMember),
    ];

    _activeInferenceModel = InferenceModelSpec(
      name: modelId,
      modelSource: bundle.first.source,
      modelType: modelType,
      fileType: fileType,
      directoryFiles: bundle,
    );
    gemmaLog(
      '[ModelManager] restored active directory model: $modelId '
      '(${bundle.length} files)',
    );
  }

  /// One-time migration of a pre-refactor (plain-named) COMPANION file to its
  /// namespaced install identity, run from the active-model restore paths.
  ///
  /// The break this fixes: `EmbeddingModelSpec.files` / `SttModelSpec.files`
  /// now ALWAYS derive the namespaced tokenizer name (`<modelId>__<basename>`),
  /// but a model installed BEFORE the install-identity-namespacing refactor
  /// (2026-08-02) persisted + repository-keyed the PLAIN basename. So after
  /// upgrade `_isModelInstalled` (which checks the repo under the namespaced
  /// key) returns false for a model that is physically present, and
  /// `createEmbeddingModel()` / `createSttModel()` throw on first launch.
  ///
  /// This is the ONE place [FileSystemService.adoptLegacyFile] is safe to call
  /// for a colliding-basename companion (its docstring forbids blind calls):
  /// RESTORE operates on a single KNOWN active model, so [modelId]
  /// unambiguously identifies which model the plain file belongs to — the
  /// pre-refactor collision meant only the last-installed (= the active) model's
  /// tokenizer could exist on disk under the plain name.
  ///
  /// Renames the file to its namespaced identity, re-keys the repository, and
  /// rewrites the persisted active filename ([prefsKey]) so the next launch
  /// restores the namespaced identity directly. Returns the on-disk path the
  /// caller should use for the reconstructed spec (the namespaced path when a
  /// migration happened or the input was already namespaced; the plain read
  /// path when there was nothing to migrate — the caller's existence check
  /// then handles a truly-missing file).
  Future<String> _migrateLegacyCompanionForRestore({
    required String modelId,
    required String persistedFilename,
    required repo.ModelType repoType,
    required String prefsKey,
  }) async {
    final fs = ServiceRegistry.instance.fileSystemService;
    final namespaced = FileNameUtils.namespaced(modelId, persistedFilename);
    if (namespaced == persistedFilename) {
      // Already namespaced (post-refactor install) — nothing to migrate.
      return fs.getReadTargetPath(persistedFilename);
    }

    final adopted = await fs.adoptLegacyFile(persistedFilename, namespaced);
    final newPath = await fs.getWriteTargetPath(namespaced);
    if (!adopted && !File(newPath).existsSync()) {
      // No namespaced file and no plain file to adopt — leave the plain
      // identity untouched; the caller's existence check reports it missing.
      return fs.getReadTargetPath(persistedFilename);
    }

    final repository = ServiceRegistry.instance.modelRepository;
    await repository.saveModel(
      repo.ModelInfo(
        id: namespaced,
        source: FileSource(newPath),
        installedAt: DateTime.now(),
        sizeBytes: await fs.getFileSize(newPath),
        type: repoType,
        hasLoraWeights: false,
      ),
    );
    await repository.deleteModel(persistedFilename);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, namespaced);
    gemmaLog(
      '[ModelManager] migrated legacy companion "$persistedFilename" -> '
      '"$namespaced" (install-identity-namespacing)',
    );
    return newPath;
  }

  /// Mirror of [_restoreActiveInferenceModel] for the embedding pair
  /// (model + tokenizer).
  Future<void> _restoreActiveEmbeddingModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelFilename = prefs.getString(
      PreferencesKeys.activeEmbeddingFilename,
    );
    final tokenizerFilename = prefs.getString(
      PreferencesKeys.activeEmbeddingTokenizerFilename,
    );

    if (modelFilename == null || tokenizerFilename == null) {
      return;
    }

    final fs = ServiceRegistry.instance.fileSystemService;
    // The model weight keeps its plain basename (only companions are
    // namespaced), so only the tokenizer needs a legacy migration.
    final tokenizerPath = await _migrateLegacyCompanionForRestore(
      modelId: FileNameUtils.getBaseName(modelFilename),
      persistedFilename: tokenizerFilename,
      repoType: repo.ModelType.embedding,
      prefsKey: PreferencesKeys.activeEmbeddingTokenizerFilename,
    );
    final modelPath = await fs.getReadTargetPath(modelFilename);
    if (!File(modelPath).existsSync() || !File(tokenizerPath).existsSync()) {
      gemmaLog(
        '[ModelManager] active embedding restore: file missing — skipping',
      );
      return;
    }

    _activeEmbeddingModel = EmbeddingModelSpec(
      name: modelFilename,
      modelSource: FileSource(modelPath),
      tokenizerSource: FileSource(tokenizerPath),
    );
    gemmaLog('[ModelManager] restored active embedding model: $modelFilename');
  }

  /// Mirror of [_restoreActiveEmbeddingModel] for the STT pair
  /// (model + tokenizer). The model is SELECTABLE, so [SttModelType] is also
  /// persisted/restored (unlike embeddings, which have no type dimension).
  Future<void> _restoreActiveSttModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelFilename = prefs.getString(PreferencesKeys.activeSttFilename);
    final tokenizerFilename = prefs.getString(
      PreferencesKeys.activeSttTokenizerFilename,
    );
    final sttModelTypeName = prefs.getString(
      PreferencesKeys.activeSttModelType,
    );

    if (modelFilename == null ||
        tokenizerFilename == null ||
        sttModelTypeName == null) {
      return;
    }

    final SttModelType sttModelType;
    try {
      sttModelType = SttModelType.values.byName(sttModelTypeName);
    } catch (e) {
      gemmaLog(
        '[ModelManager] active STT restore: unknown SttModelType ($sttModelTypeName) — skipping',
      );
      return;
    }

    final fs = ServiceRegistry.instance.fileSystemService;
    // The model weight keeps its plain basename (only companions are
    // namespaced), so only the tokenizer needs a legacy migration.
    final tokenizerPath = await _migrateLegacyCompanionForRestore(
      modelId: FileNameUtils.getBaseName(modelFilename),
      persistedFilename: tokenizerFilename,
      repoType: repo.ModelType.stt,
      prefsKey: PreferencesKeys.activeSttTokenizerFilename,
    );
    final modelPath = await fs.getReadTargetPath(modelFilename);
    if (!File(modelPath).existsSync() || !File(tokenizerPath).existsSync()) {
      gemmaLog('[ModelManager] active STT restore: file missing — skipping');
      return;
    }

    _activeSttModel = SttModelSpec(
      name: modelFilename,
      modelSource: FileSource(modelPath),
      tokenizerSource: FileSource(tokenizerPath),
      sttModelType: sttModelType,
    );
    gemmaLog('[ModelManager] restored active STT model: $modelFilename');
  }

  /// Mirror of [_restoreActiveSttModel] for TTS. The bundle files are
  /// re-derived from [TtsModelType.manifest]; each is resolved to its local
  /// path (namespaced by [FileNameUtils.namespaced] — TTS restore does not
  /// persist per-file filenames the way Inference/Embedding/STT do, since
  /// _persistActiveTtsIdentity only stores `name` + `ttsModelType`, so the
  /// namespaced on-disk filename must be re-derived here, matching exactly
  /// what TtsBundleFile.fromSource computes at install time) and required
  /// to exist.
  Future<void> _restoreActiveTtsModel() async {
    final prefs = await SharedPreferences.getInstance();
    final name = prefs.getString(PreferencesKeys.activeTtsName);
    final typeName = prefs.getString(PreferencesKeys.activeTtsModelType);
    if (name == null || typeName == null) return;

    final TtsModelType ttsModelType;
    try {
      ttsModelType = TtsModelType.values.byName(typeName);
    } catch (e) {
      gemmaLog(
        '[ModelManager] active TTS restore: unknown TtsModelType ($typeName) — skipping',
      );
      return;
    }

    final fs = ServiceRegistry.instance.fileSystemService;
    final paths = <String, String>{};
    for (final fn in ttsModelType.manifest) {
      final namespacedFn = FileNameUtils.namespaced(ttsModelType.name, fn);
      final p = await fs.getTargetPath(namespacedFn);
      if (!File(p).existsSync()) {
        gemmaLog(
          '[ModelManager] active TTS restore: file missing ($namespacedFn) — skipping',
        );
        return;
      }
      paths[fn] = p;
    }

    _activeTtsModel = TtsModelSpec.fromManifest(
      name: name,
      ttsModelType: ttsModelType,
      sourceFor: (fn) => FileSource(paths[fn]!),
    );
    gemmaLog('[ModelManager] restored active TTS model: $name');
  }

  /// Internal method for ModelSpec-based operations
  Future<void> _ensureModelReadySpec(ModelSpec spec) async {
    await _ensureInitialized();

    gemmaLog('UnifiedModelManager: Ensuring model ready - ${spec.name}');

    try {
      await _ensureModelReady(spec);
      gemmaLog('UnifiedModelManager: Model ${spec.name} is ready');
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to ensure model ready - ${spec.name}: $e',
      );
      rethrow;
    }
  }

  /// Ensures a model is ready, applying replace policy
  /// Delegates to Modern API handlers via ServiceRegistry
  Future<void> _ensureModelReady(ModelSpec spec) async {
    gemmaLog('🔍 Ensuring model ready: ${spec.name}');
    gemmaLog('🔍 Model source type: ${spec.files.first.source.runtimeType}');

    // Check if already installed
    final installed = await _isModelInstalled(spec);
    gemmaLog('🔍 isModelInstalled returned: $installed');

    if (installed) {
      gemmaLog('✅ Model ${spec.name} already ready (skipping installation)');
      return;
    }

    gemmaLog('📥 Model not installed, proceeding with installation...');

    // Handle model switching with replace policy
    await _handleModelSwitching(spec);

    // Route to ServiceRegistry handlers
    await _routeModelBySource(spec);
  }

  /// Routes model handling to Modern API handlers via ServiceRegistry
  Future<void> _routeModelBySource(ModelSpec spec) async {
    // Install ALL files from spec (important for multi-file models like embedding)
    final registry = ServiceRegistry.instance;
    final handlerRegistry = registry.sourceHandlerRegistry;

    for (final file in spec.files) {
      gemmaLog(
        '🔀 Routing file: ${file.filename}, source type: ${file.source.runtimeType}',
      );

      try {
        final handler = handlerRegistry.getHandler(file.source);

        if (handler == null) {
          throw ModelStorageException(
            'No handler registered for source type: ${file.source.runtimeType}',
            null,
            '_routeModelBySource',
          );
        }

        await handler.install(file.source, modelType: _toRepoType(spec.type));
        gemmaLog(
          '✅ File installed: ${file.filename} via Modern handler: ${file.source.runtimeType}',
        );
      } catch (e) {
        throw ModelStorageException(
          'Failed to install file ${file.filename} via Modern handler',
          e,
          '_routeModelBySource',
        );
      }
    }
  }

  /// Handles model switching according to replace policy
  Future<void> _handleModelSwitching(ModelSpec spec) async {
    // If replace policy, clean up ALL models of this type before installing new one
    if (spec.replacePolicy == ModelReplacePolicy.replace) {
      gemmaLog(
        'Policy-based replacement: cleaning up ALL ${spec.type.name} models',
      );

      // Delete all installed models of this type from ModelRepository
      final installedFiles = await getInstalledModels(spec.type);
      final registry = ServiceRegistry.instance;
      final repository = registry.modelRepository;

      for (final filename in installedFiles) {
        try {
          await ModelFileSystemManager.deleteModelFile(filename);
          await repository.deleteModel(filename);
        } catch (e) {
          gemmaLog('Failed to delete model file $filename: $e');
        }
      }

      // Clean up tasks
      await _cleanupAllTasksOfType(spec.type);
    }
  }

  /// Clean up all tasks and files of a specific type
  Future<void> _cleanupAllTasksOfType(ModelManagementType type) async {
    try {
      gemmaLog('Cleaning up all tasks of type: ${type.name}');

      final downloader = FileDownloader();
      final records = await downloader.database.allRecords();
      int cleanedCount = 0;

      for (final record in records) {
        final filename = record.task.filename;
        final modelType = _detectModelType(filename);

        if (modelType == type) {
          cleanedCount++;
          try {
            await ModelFileSystemManager.deleteModelFile(filename);
          } catch (e) {
            gemmaLog('Could not delete partial file $filename: $e');
          }
        }
      }

      if (cleanedCount > 0) {
        gemmaLog('Cleaned up $cleanedCount tasks of type ${type.name}');
      }

      // Cancel only THIS type's tasks (deletes their paused temps) before the
      // group reset; cancelling the whole group here would abort an unrelated
      // model type's in-flight download (#383/#5).
      try {
        final groupTasks = await downloader.allTasks(
          group: SmartDownloader.downloadGroup,
          includeTasksWaitingToRetry: true,
        );
        final ofType = groupTasks
            .where((t) => _detectModelType(t.filename) == type)
            .map((t) => t.taskId)
            .toList();
        if (ofType.isNotEmpty) {
          await downloader.cancelTasksWithIds(ofType);
        }
      } catch (e) {
        gemmaLog('Failed to cancel ${type.name} tasks before reset: $e');
      }

      // Reset background_downloader tasks
      try {
        await downloader.reset(group: SmartDownloader.downloadGroup);
      } catch (e) {
        gemmaLog('Failed to reset background_downloader tasks: $e');
      }
    } catch (e) {
      gemmaLog('Failed to cleanup tasks of type ${type.name}: $e');
    }
  }

  /// Detect model type from filename
  ModelManagementType _detectModelType(String filename) {
    final extension = filename.split('.').last.toLowerCase();

    switch (extension) {
      case 'tflite':
      case 'json':
        return ModelManagementType.embedding;
      case 'bin':
      case 'task':
      case 'gguf':
        return ModelManagementType.inference;
      default:
        return ModelManagementType.inference;
    }
  }

  /// Modern API: Ensures a model spec is ready for use
  @override
  Future<void> ensureModelReadyFromSpec(ModelSpec spec) async {
    await _ensureModelReadySpec(spec);

    // Set as active model (automatically routes by type)
    setActiveModel(spec);
  }

  /// Legacy API: Ensures a model is ready for use
  @Deprecated('Use ensureModelReadyFromSpec with ModelSource instead')
  @override
  Future<void> ensureModelReady(String filename, String url) async {
    // Create spec from legacy parameters and delegate to internal method
    final spec = InferenceModelSpec.fromLegacyUrl(
      name: filename,
      modelUrl: url,
    );
    await _ensureModelReadySpec(spec);
    // Set as active inference model after ensuring it's ready
    setActiveModel(spec);
  }

  /// Downloads a model with progress tracking
  @override
  Stream<DownloadProgress> downloadModelWithProgress(
    ModelSpec spec, {
    String? token,
  }) async* {
    await _ensureInitialized();

    gemmaLog(
      'UnifiedModelManager: Starting download with progress - ${spec.name}',
    );

    try {
      yield* _downloadModelWithProgress(spec, token: token);
      gemmaLog('UnifiedModelManager: Download completed - ${spec.name}');

      // Set as active model after successful download (same as Modern API)
      setActiveModel(spec);
    } catch (e) {
      gemmaLog('UnifiedModelManager: Download failed - ${spec.name}: $e');
      rethrow;
    }
  }

  /// Internal implementation of download with progress
  Stream<DownloadProgress> _downloadModelWithProgress(
    ModelSpec spec, {
    String? token,
  }) async* {
    try {
      final totalFiles = spec.files.length;

      for (int i = 0; i < spec.files.length; i++) {
        final file = spec.files[i];
        final filePath = await ModelFileSystemManager.getModelFilePath(
          file.filename,
        );

        // Emit progress for current file start
        yield DownloadProgress(
          currentFileIndex: i,
          totalFiles: totalFiles,
          currentFileProgress: 0,
          currentFileName: file.filename,
        );

        // Download current file via ServiceRegistry handlers
        await for (final progress in _downloadSingleFileWithProgress(
          source: file.source,
          targetPath: filePath,
          token: token,
          modelType: _toRepoType(spec.type),
        )) {
          yield DownloadProgress(
            currentFileIndex: i,
            totalFiles: totalFiles,
            currentFileProgress: progress,
            currentFileName: file.filename,
          );
        }

        // Validate downloaded file
        final minSize = ModelFileSystemManager.getMinimumSize(file.extension);
        if (!await ModelFileSystemManager.isFileValid(
          filePath,
          minSizeBytes: minSize,
        )) {
          throw ModelValidationException(
            'Downloaded file failed validation: ${file.filename}',
            null,
            filePath,
          );
        }
      }

      // Note: Handlers already saved each file to ModelRepository

      // Emit final progress
      yield DownloadProgress(
        currentFileIndex: totalFiles,
        totalFiles: totalFiles,
        currentFileProgress: 100,
        currentFileName: 'Complete',
      );
    } catch (e) {
      // Cleanup any partial files
      await ModelFileSystemManager.cleanupFailedDownload(spec);

      if (e is ModelException || e is DownloadException) {
        rethrow;
      } else {
        throw ModelDownloadException(
          'Failed to download model: ${spec.name}',
          e,
        );
      }
    }
  }

  /// Downloads a single file with progress tracking via ServiceRegistry
  Stream<int> _downloadSingleFileWithProgress({
    required ModelSource source,
    required String targetPath,
    String? token,
    repo.ModelType modelType = repo.ModelType.inference,
  }) async* {
    // Delegate to ServiceRegistry handler
    if (source is! NetworkSource) {
      throw ModelStorageException(
        'Cannot download from ${source.runtimeType}, only NetworkSource supported',
        null,
        '_downloadSingleFileWithProgress',
      );
    }

    // Create new NetworkSource with token if provided
    final networkSource = token != null
        ? NetworkSource(source.url, authToken: token)
        : source;

    final registry = ServiceRegistry.instance;
    final handler = registry.networkHandler;

    // Use handler's progress stream
    await for (final progress in handler.installWithProgress(
      networkSource,
      modelType: modelType,
    )) {
      yield progress;
    }
  }

  /// Downloads a model without progress tracking
  @override
  Future<void> downloadModel(ModelSpec spec, {String? token}) async {
    await _ensureInitialized();

    gemmaLog('UnifiedModelManager: Starting download - ${spec.name}');

    try {
      await for (final _ in _downloadModelWithProgress(spec, token: token)) {
        // Just consume the stream without emitting progress
      }
      gemmaLog('UnifiedModelManager: Download completed - ${spec.name}');

      // Set as active model after successful download (same as Modern API)
      setActiveModel(spec);
    } catch (e) {
      gemmaLog('UnifiedModelManager: Download failed - ${spec.name}: $e');
      rethrow;
    }
  }

  /// Checks if a model is installed and valid
  @override
  Future<bool> isModelInstalled(ModelSpec spec) async {
    await _ensureInitialized();

    try {
      final result = await _isModelInstalled(spec);
      gemmaLog('UnifiedModelManager: Model ${spec.name} installed: $result');
      return result;
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to check if model installed - ${spec.name}: $e',
      );
      return false;
    }
  }

  /// Internal implementation of model installation check
  Future<bool> _isModelInstalled(ModelSpec spec) async {
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Check that ALL files from spec are installed in repository
    for (final file in spec.files) {
      if (!await repository.isInstalled(file.filename)) {
        return false;
      }
    }

    // Validate all files exist and are valid on filesystem
    return await ModelFileSystemManager.validateModelFiles(spec);
  }

  /// Deletes a model and all its files
  @override
  Future<void> deleteModel(ModelSpec spec) async {
    await _ensureInitialized();

    gemmaLog('UnifiedModelManager: Deleting model - ${spec.name}');

    try {
      final registry = ServiceRegistry.instance;
      final repository = registry.modelRepository;

      // Delete all files from filesystem and repository
      for (final file in spec.files) {
        await ModelFileSystemManager.deleteModelFile(file.filename);
        await repository.deleteModel(file.filename);
      }

      // Directory (ORT-GenAI) model: its members lived in a per-model
      // subdirectory. Remove the now-empty subdir so it doesn't accumulate
      // (deleteModelFile only removes the individual files inside it).
      if (spec is InferenceModelSpec && spec.directoryFiles != null) {
        final dirName = spec.directoryFiles!.first.filename.split('/').first;
        final dirPath = await ModelFileSystemManager.getModelFilePath(dirName);
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }

      gemmaLog('UnifiedModelManager: Model deleted - ${spec.name}');
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to delete model - ${spec.name}: $e',
      );
      throw ModelStorageException(
        'Failed to delete model: ${spec.name}',
        e,
        'deleteModel',
      );
    }
  }

  repo.ModelType _toRepoType(ModelManagementType type) => switch (type) {
    ModelManagementType.inference => repo.ModelType.inference,
    ModelManagementType.embedding => repo.ModelType.embedding,
    ModelManagementType.stt => repo.ModelType.stt,
    ModelManagementType.tts => repo.ModelType.tts,
  };

  /// Gets all installed models for a specific type
  @override
  Future<List<String>> getInstalledModels(ModelManagementType type) async {
    await _ensureInitialized();

    try {
      final registry = ServiceRegistry.instance;
      final repository = registry.modelRepository;

      final modelType = _toRepoType(type);

      // Get all installed models and filter by type
      final allModels = await repository.listInstalled();
      final files = allModels
          .where((info) => info.type == modelType)
          .map((info) => info.id)
          .toList();

      gemmaLog(
        'UnifiedModelManager: Found ${files.length} installed files for type $type',
      );
      return files;
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to get installed models for type $type: $e',
      );
      return [];
    }
  }

  /// Checks if ANY model of the given type is installed
  @override
  Future<bool> isAnyModelInstalled(ModelManagementType type) async {
    await _ensureInitialized();

    try {
      final files = await getInstalledModels(type);
      return files.isNotEmpty;
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to check if any model is installed for type $type: $e',
      );
      return false;
    }
  }

  /// Performs cleanup of orphaned files
  @override
  Future<void> performCleanup() async {
    await _ensureInitialized();

    gemmaLog('UnifiedModelManager: Performing cleanup');

    try {
      // 1. Get protected files from ModelRepository
      final protectedFiles = await _getAllProtectedFiles();

      final downloader = FileDownloader();
      // 2. Cancel every task in the group FIRST — cancellation deletes paused
      //    temp files (reset() only clears records), so this must precede both
      //    reset and the fragment sweep (#383/#5).
      final groupTasks = await downloader.allTasks(
        group: SmartDownloader.downloadGroup,
        includeTasksWaitingToRetry: true,
      );
      await downloader.cancelTasksWithIds(
        groupTasks.map((t) => t.taskId).toList(),
      );
      // 3. Reset residual records.
      await downloader.reset(group: SmartDownloader.downloadGroup);
      // 4. Filesystem cleanup last — now only truly-orphaned fragments remain.
      await ModelFileSystemManager.cleanupOrphanedFiles(
        protectedFiles: protectedFiles,
        enableResumeDetection: true,
      );

      gemmaLog('UnifiedModelManager: Cleanup completed');
    } catch (e) {
      gemmaLog('UnifiedModelManager: Cleanup failed: $e');
      rethrow;
    }
  }

  /// Get all protected files from ModelRepository
  Future<List<String>> _getAllProtectedFiles() async {
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    final allModels = await repository.listInstalled();
    return allModels.map((info) => info.id).toList();
  }

  /// Validates all files for a model specification
  @override
  Future<bool> validateModel(ModelSpec spec) async {
    await _ensureInitialized();

    try {
      final result = await ModelFileSystemManager.validateModelFiles(spec);
      gemmaLog('UnifiedModelManager: Model ${spec.name} validation: $result');
      return result;
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to validate model - ${spec.name}: $e',
      );
      return false;
    }
  }

  /// Gets the file paths for an installed model
  @override
  Future<Map<String, String>?> getModelFilePaths(ModelSpec spec) async {
    await _ensureInitialized();

    try {
      if (!await isModelInstalled(spec)) {
        return null;
      }

      final filePaths = <String, String>{};

      final registry = ServiceRegistry.instance;
      final fileSystem = registry.fileSystemService;

      for (final file in spec.files) {
        // Get path based on source type
        final String path;
        if (file is DirectoryBundleFile) {
          // Directory (ORT-GenAI) member: its identity is the explicit subpath
          // `<modelId>/<bareLeaf>` under the model storage dir — resolve by
          // filename regardless of the carrier source type (a restored bundle
          // may carry a network/file source, but the on-disk location is always
          // the subdir).
          path = await ModelFileSystemManager.getModelFilePath(file.filename);
        } else if (file.source is FileSource) {
          // External file - use path from source
          path = (file.source as FileSource).path;
        } else if (file.source is BundledSource) {
          // Bundled source - get platform-specific bundled path
          final bundledSource = file.source as BundledSource;
          path = await fileSystem.getBundledResourcePath(
            bundledSource.resourceName,
          );
        } else {
          // Downloaded/Asset file - use standard app directory
          path = await ModelFileSystemManager.getModelFilePath(file.filename);
        }
        filePaths[file.prefsKey] = path;
      }

      return filePaths;
    } catch (e) {
      gemmaLog(
        'UnifiedModelManager: Failed to get file paths for ${spec.name}: $e',
      );
      return null;
    }
  }

  /// Creates an inference model specification from parameters
  static InferenceModelSpec createInferenceSpec({
    required String name,
    required String modelUrl,
    String? loraUrl,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.replace,
  }) {
    return InferenceModelSpec.fromLegacyUrl(
      name: name,
      modelUrl: modelUrl,
      loraUrl: loraUrl,
      replacePolicy: replacePolicy,
    );
  }

  /// Creates an embedding model specification from parameters
  static EmbeddingModelSpec createEmbeddingSpec({
    required String name,
    required String modelUrl,
    required String tokenizerUrl,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) {
    return EmbeddingModelSpec.fromLegacyUrl(
      name: name,
      modelUrl: modelUrl,
      tokenizerUrl: tokenizerUrl,
      replacePolicy: replacePolicy,
    );
  }

  /// Creates a bundled inference model specification (for production builds)
  ///
  /// Use this for models packaged with your app in native platform assets:
  /// - Android: android/src/main/assets/models/
  /// - iOS: Xcode Bundle Resources
  /// - Web: web/assets/models/
  ///
  /// Example:
  /// ```dart
  /// final spec = MobileModelManager.createBundledInferenceSpec(
  ///   resourceName: 'gemma3-270m-it-q8.task',
  /// );
  /// await manager.ensureModelReadyFromSpec(spec);
  /// ```
  static InferenceModelSpec createBundledInferenceSpec({
    required String resourceName,
    String? loraResourceName,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.replace,
    ModelType modelType = ModelType.general,
    ModelFileType fileType = ModelFileType.task,
  }) {
    // Extract name from resource (without extension)
    final name = resourceName.split('.').first;

    return InferenceModelSpec(
      name: name,
      modelSource: BundledSource(resourceName),
      loraSource: loraResourceName != null
          ? BundledSource(loraResourceName)
          : null,
      replacePolicy: replacePolicy,
      modelType: modelType,
      fileType: fileType,
    );
  }

  /// Creates a bundled embedding model specification (for production builds)
  ///
  /// Use this for embedding models packaged with your app in native platform assets.
  ///
  /// Example:
  /// ```dart
  /// final spec = MobileModelManager.createBundledEmbeddingSpec(
  ///   modelResourceName: 'embeddinggemma-300M.tflite',
  ///   tokenizerResourceName: 'sentencepiece.model',
  /// );
  /// await manager.ensureModelReadyFromSpec(spec);
  /// ```
  static EmbeddingModelSpec createBundledEmbeddingSpec({
    required String modelResourceName,
    required String tokenizerResourceName,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
  }) {
    final name = modelResourceName.split('.').first;

    return EmbeddingModelSpec(
      name: name,
      modelSource: BundledSource(modelResourceName),
      tokenizerSource: BundledSource(tokenizerResourceName),
      replacePolicy: replacePolicy,
    );
  }

  /// Ensures the manager is initialized
  Future<void> _ensureInitialized() => initialize();

  // === Legacy Asset Loading Methods Implementation ===

  @override
  Future<void> installModelFromAsset(String path, {String? loraPath}) async {
    if (kReleaseMode) {
      throw UnsupportedError(
        "Asset model loading is not supported in release builds",
      );
    }

    await _ensureInitialized();

    final spec = InferenceModelSpec.fromLegacyUrl(
      name: ModelFileSystemManager.getBaseName(path.split('/').last),
      modelUrl: 'asset://$path',
      loraUrl: loraPath != null ? 'asset://$loraPath' : null,
    );

    await _ensureModelReadySpec(spec);
  }

  @override
  Stream<int> installModelFromAssetWithProgress(
    String path, {
    String? loraPath,
  }) async* {
    if (kReleaseMode) {
      throw UnsupportedError(
        "Asset model loading is not supported in release builds",
      );
    }

    await _ensureInitialized();

    final spec = InferenceModelSpec.fromLegacyUrl(
      name: ModelFileSystemManager.getBaseName(path.split('/').last),
      modelUrl: 'asset://$path',
      loraUrl: loraPath != null ? 'asset://$loraPath' : null,
    );

    // Since assets are copied instantly, we'll simulate progress
    for (int progress = 0; progress <= 100; progress += 10) {
      yield progress;
      if (progress < 100) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    await _ensureModelReadySpec(spec);
  }

  // === Legacy Direct Path Methods Implementation ===

  @override
  Future<void> setModelPath(String path, {String? loraPath}) async {
    await _ensureInitialized();

    final spec = InferenceModelSpec.fromLegacyUrl(
      name: ModelFileSystemManager.getBaseName(path.split('/').last),
      modelUrl: 'file://$path',
      loraUrl: loraPath != null ? 'file://$loraPath' : null,
    );

    await _ensureModelReadySpec(spec);
    setActiveModel(spec);
  }

  @override
  Future<void> clearModelCache() async {
    await _ensureInitialized();
    _activeInferenceModel = null;
    _activeEmbeddingModel = null;
    gemmaLog('Model cache cleared');
  }

  @override
  Future<void> clearActiveInferenceIdentity() async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PreferencesKeys.activeInferenceModelType);
      await prefs.remove(PreferencesKeys.activeInferenceFileType);
      await prefs.remove(PreferencesKeys.activeInferenceFilename);
      await prefs.remove(PreferencesKeys.activeInferenceSource);
      _activeInferenceModel = null;
    } catch (e) {
      gemmaLog('[ModelManager] clearActiveInferenceIdentity failed: $e');
      rethrow;
    }
    gemmaLog('Active inference identity cleared');
  }

  @override
  Future<void> clearActiveEmbeddingIdentity() async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PreferencesKeys.activeEmbeddingFilename);
      await prefs.remove(PreferencesKeys.activeEmbeddingTokenizerFilename);
      await prefs.remove(PreferencesKeys.activeEmbeddingSource);
      await prefs.remove(PreferencesKeys.activeEmbeddingTokenizerSource);
      _activeEmbeddingModel = null;
    } catch (e) {
      gemmaLog('[ModelManager] clearActiveEmbeddingIdentity failed: $e');
      rethrow;
    }
    gemmaLog('Active embedding identity cleared');
  }

  @override
  Future<void> clearActiveSttIdentity() async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PreferencesKeys.activeSttFilename);
      await prefs.remove(PreferencesKeys.activeSttTokenizerFilename);
      await prefs.remove(PreferencesKeys.activeSttModelType);
      await prefs.remove(PreferencesKeys.activeSttSource);
      await prefs.remove(PreferencesKeys.activeSttTokenizerSource);
      _activeSttModel = null;
    } catch (e) {
      gemmaLog('[ModelManager] clearActiveSttIdentity failed: $e');
      rethrow;
    }
    gemmaLog('Active STT identity cleared');
  }

  @override
  Future<void> clearActiveTtsIdentity() async {
    await _ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(PreferencesKeys.activeTtsName);
      await prefs.remove(PreferencesKeys.activeTtsModelType);
      _activeTtsModel = null;
    } catch (e) {
      gemmaLog('[ModelManager] clearActiveTtsIdentity failed: $e');
      rethrow;
    }
    gemmaLog('Active TTS identity cleared');
  }

  // === Active Model Management ===

  ModelSpec? _activeInferenceModel;
  ModelSpec? _activeEmbeddingModel;
  ModelSpec? _activeSttModel;
  ModelSpec? _activeTtsModel;

  /// Gets the currently active inference model specification
  @override
  ModelSpec? get activeInferenceModel => _activeInferenceModel;

  /// Gets the currently active embedding model specification
  @override
  ModelSpec? get activeEmbeddingModel => _activeEmbeddingModel;

  /// Gets the currently active STT model specification
  @override
  ModelSpec? get activeSttModel => _activeSttModel;

  /// Gets the currently active TTS model specification
  @override
  ModelSpec? get activeTtsModel => _activeTtsModel;

  /// Gets the currently active model specification (backward compatibility)
  @Deprecated('Use activeInferenceModel or activeEmbeddingModel instead')
  ModelSpec? get currentActiveModel =>
      _activeInferenceModel ?? _activeEmbeddingModel;

  /// Sets the active model for subsequent operations.
  ///
  /// Automatically routes to inference or embedding based on spec type.
  /// For inference specs, also persists `modelType` + `fileType` so the
  /// active reference survives an app restart (#227).
  @override
  void setActiveModel(ModelSpec spec) {
    if (spec is InferenceModelSpec) {
      _activeInferenceModel = spec;
      gemmaLog('✅ Set active inference model: ${spec.name}');
      // Fire-and-forget — SharedPreferences write is cheap and the
      // success of the operation is already reflected in memory.
      unawaited(_persistActiveInferenceIdentity(spec));
    } else if (spec is EmbeddingModelSpec) {
      _activeEmbeddingModel = spec;
      gemmaLog('✅ Set active embedding model: ${spec.name}');
      unawaited(_persistActiveEmbeddingIdentity(spec));
    } else if (spec is SttModelSpec) {
      _activeSttModel = spec;
      gemmaLog('✅ Set active STT model: ${spec.name}');
      unawaited(_persistActiveSttIdentity(spec));
    } else if (spec is TtsModelSpec) {
      _activeTtsModel = spec;
      gemmaLog('✅ Set active TTS model: ${spec.name}');
      unawaited(_persistActiveTtsIdentity(spec));
    } else {
      throw ArgumentError('Unknown ModelSpec type: ${spec.runtimeType}');
    }
  }

  Future<void> _persistActiveInferenceIdentity(InferenceModelSpec spec) async {
    try {
      final filename = spec.files
          .firstWhere(
            (f) => f.prefsKey == PreferencesKeys.installedModelFileName,
          )
          .filename;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeInferenceModelType,
        spec.modelType.name,
      );
      await prefs.setString(
        PreferencesKeys.activeInferenceFileType,
        spec.fileType.name,
      );
      await prefs.setString(PreferencesKeys.activeInferenceFilename, filename);
      await prefs.setString(
        PreferencesKeys.activeInferenceSource,
        spec.modelSource.encode(),
      );
    } catch (e) {
      gemmaLog('[ModelManager] persistActiveInferenceIdentity failed: $e');
    }
  }

  Future<void> _persistActiveEmbeddingIdentity(EmbeddingModelSpec spec) async {
    try {
      final modelFile = spec.files.firstWhere(
        (f) => f.prefsKey == PreferencesKeys.embeddingModelFile,
      );
      final tokenizerFile = spec.files.firstWhere(
        (f) => f.prefsKey == PreferencesKeys.embeddingTokenizerFile,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingFilename,
        modelFile.filename,
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerFilename,
        tokenizerFile.filename,
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingSource,
        spec.modelSource.encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerSource,
        spec.tokenizerSource.encode(),
      );
    } catch (e) {
      gemmaLog('[ModelManager] persistActiveEmbeddingIdentity failed: $e');
    }
  }

  Future<void> _persistActiveSttIdentity(SttModelSpec spec) async {
    try {
      final modelFile = spec.files.firstWhere(
        (f) => f.prefsKey == PreferencesKeys.sttModelFile,
      );
      final tokenizerFile = spec.files.firstWhere(
        (f) => f.prefsKey == PreferencesKeys.sttTokenizerFile,
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeSttFilename,
        modelFile.filename,
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerFilename,
        tokenizerFile.filename,
      );
      await prefs.setString(
        PreferencesKeys.activeSttModelType,
        spec.sttModelType.name,
      );
      await prefs.setString(
        PreferencesKeys.activeSttSource,
        spec.modelSource.encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeSttTokenizerSource,
        spec.tokenizerSource.encode(),
      );
    } catch (e) {
      gemmaLog('[ModelManager] persistActiveSttIdentity failed: $e');
    }
  }

  Future<void> _persistActiveTtsIdentity(TtsModelSpec spec) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PreferencesKeys.activeTtsName, spec.name);
      await prefs.setString(
        PreferencesKeys.activeTtsModelType,
        spec.ttsModelType.name,
      );
    } catch (e) {
      gemmaLog('[ModelManager] persistActiveTtsIdentity failed: $e');
    }
  }

  @override
  Future<void> setLoraWeightsPath(String path) async {
    await _ensureInitialized();

    if (_activeInferenceModel == null) {
      throw Exception(
        'No active inference model to apply LoRA weights to. Use setModelPath first.',
      );
    }

    // Create updated spec with new LoRA path
    final current = _activeInferenceModel as InferenceModelSpec;
    final updatedSpec = InferenceModelSpec.fromLegacyUrl(
      name: current.name,
      modelUrl: current.modelUrl,
      loraUrl: path.startsWith('/') ? 'file://$path' : path,
      replacePolicy: current.replacePolicy,
    );

    await _ensureModelReadySpec(updatedSpec);
    setActiveModel(updatedSpec);
  }

  @override
  Future<void> deleteLoraWeights() async {
    await _ensureInitialized();

    if (_activeInferenceModel == null) {
      throw Exception('No active inference model to remove LoRA weights from');
    }

    // Create updated spec without LoRA
    final current = _activeInferenceModel as InferenceModelSpec;
    final updatedSpec = InferenceModelSpec.fromLegacyUrl(
      name: current.name,
      modelUrl: current.modelUrl,
      loraUrl: null, // Remove LoRA
      replacePolicy: current.replacePolicy,
    );

    await _ensureModelReadySpec(updatedSpec);
    setActiveModel(updatedSpec);
  }

  // === Legacy Model Management Implementation ===

  @override
  Future<void> deleteCurrentModel() async {
    await _ensureInitialized();

    // Delete active inference model if exists
    if (_activeInferenceModel != null) {
      await deleteModel(_activeInferenceModel!);
      _activeInferenceModel = null;
    }

    // Delete active embedding model if exists
    if (_activeEmbeddingModel != null) {
      await deleteModel(_activeEmbeddingModel!);
      _activeEmbeddingModel = null;
    }
  }

  /// Gets storage statistics
  @override
  Future<Map<String, int>> getStorageStats() async {
    await _ensureInitialized();

    try {
      final stats = <String, int>{};

      // Get protected files from ModelRepository
      final protectedFiles = await _getAllProtectedFiles();
      stats['protectedFiles'] = protectedFiles.length;

      // Calculate total size of protected files
      int totalSize = 0;
      for (final filename in protectedFiles) {
        final path = await ModelFileSystemManager.getModelFilePath(filename);
        totalSize += await ModelFileSystemManager.getFileSize(path);
      }
      stats['totalSizeBytes'] = totalSize;
      stats['totalSizeMB'] = (totalSize / (1024 * 1024)).round();

      // Get counts by type from ModelRepository
      final inferenceFiles = await getInstalledModels(
        ModelManagementType.inference,
      );
      final embeddingFiles = await getInstalledModels(
        ModelManagementType.embedding,
      );

      stats['inferenceModels'] = inferenceFiles.length;
      stats['embeddingModels'] =
          embeddingFiles.length ~/ 2; // Each embedding model has 2 files

      return stats;
    } catch (e) {
      gemmaLog('UnifiedModelManager: Failed to get storage stats: $e');
      return {
        'protectedFiles': 0,
        'totalSizeBytes': 0,
        'totalSizeMB': 0,
        'inferenceModels': 0,
        'embeddingModels': 0,
      };
    }
  }

  /// Get information about orphaned files
  ///
  /// Returns list of files that don't have active downloads.
  /// These files can be safely deleted using cleanupStorage().
  @override
  Future<List<OrphanedFileInfo>> getOrphanedFiles() async {
    await _ensureInitialized();

    // Propagate real errors instead of returning an empty list: a failed scan
    // must not read as "no orphans" (which hides reclaimable multi-GB files).
    final protectedFiles = await _getProtectedFiles();
    return ModelFileSystemManager.getOrphanedFiles(
      protectedFiles: protectedFiles,
    );
  }

  /// Get storage statistics with orphaned file information
  @override
  Future<StorageStats> getStorageInfo() async {
    await _ensureInitialized();

    // Propagate real errors instead of laundering them into all-zero stats:
    // a scan failure must be distinguishable from "nothing installed" (0/0).
    final protectedFiles = await _getProtectedFiles();
    return ModelFileSystemManager.getStorageInfo(
      protectedFiles: protectedFiles,
    );
  }

  /// Clean up orphaned files
  ///
  /// ⚠️  This deletes files! Call getOrphanedFiles() first to see what will be deleted.
  ///
  /// Returns number of deleted files.
  @override
  Future<int> cleanupStorage() async {
    await _ensureInitialized();

    gemmaLog('UnifiedModelManager: Cleaning up storage (explicit user call)');

    // Propagate real errors instead of returning 0: this is a destructive op,
    // and a mid-sweep failure that already deleted some files must not report
    // as "0 removed" (indistinguishable from "nothing to clean").
    final protectedFiles = await _getProtectedFiles();
    final deletedCount = await ModelFileSystemManager.cleanupOrphanedFiles(
      protectedFiles: protectedFiles,
      enableResumeDetection: true,
    );

    gemmaLog('UnifiedModelManager: Cleaned up $deletedCount orphaned files');
    return deletedCount;
  }

  /// Get list of files that should NOT be deleted by cleanupStorage() /
  /// getOrphanedFiles() / getStorageInfo().
  ///
  /// Type-agnostic on purpose: it protects EVERY installed model (any
  /// [ModelManagementType]) via the repository, plus the active models' full
  /// file sets. It previously listed only inference + embedding, which silently
  /// relied on STT/TTS being mis-tagged `inference` — once #391 fixed that tag,
  /// stt/tts installs would have dropped out of the keep-set and been deleted by
  /// cleanupStorage(). Backing the installed set with the type-agnostic
  /// listInstalled() (via [_getAllProtectedFiles]) means a newly-added type can
  /// never silently fall out again.
  Future<List<String>> _getProtectedFiles() async {
    final protected = <String>[];

    try {
      // Active models' full file sets (model + tokenizer + companions) — all
      // modalities, not just inference/embedding.
      for (final active in [
        _activeInferenceModel,
        _activeEmbeddingModel,
        _activeSttModel,
        _activeTtsModel,
      ]) {
        if (active == null) continue;
        for (final file in active.files) {
          protected.add(file.filename);
        }
      }

      // All installed models, ANY type (ids from the repository).
      protected.addAll(await _getAllProtectedFiles());

      gemmaLog(
        'UnifiedModelManager: Protected files count: ${protected.length}',
      );
    } catch (e) {
      // This keep-set is the SOLE gate for the destructive cleanupStorage() (and
      // for the reporting getOrphanedFiles/getStorageInfo). Returning the partial
      // set accumulated so far would let cleanup delete installed models it must
      // protect — so a failed enumeration must ABORT the caller, not launder into
      // an under-protective list. Matches the "propagate real errors" contract
      // those three callers already document.
      gemmaLog('UnifiedModelManager: Failed to compute protected files: $e');
      rethrow;
    }

    return protected;
  }
}

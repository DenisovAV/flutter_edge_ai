import 'dart:async';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_download_service.dart';
import 'package:flutter_gemma/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_gemma/core/services/model_repository.dart' as repo;
import 'package:flutter_gemma/core/utils/file_name_utils.dart';

/// Web Model Manager - Modern API Facade Pattern
///
/// Phase 5 Complete: This class now delegates all model management to the
/// Modern API (ServiceRegistry + Handlers + Repository) instead of manually
/// managing state. All methods are thin facades over the Modern API.
///
/// Architecture:
/// - OLD: Manual state maps (_installedModels, _modelPaths, etc.)
/// - NEW: Delegates to ServiceRegistry.instance → handlers → repository
///
/// Benefits:
/// - Single source of truth (repository)
/// - No code duplication
/// - Platform-agnostic (same pattern as MobileModelManager)
/// - Easier to maintain and test
class WebModelManager extends ModelFileManager {
  /// Single-flight init guard. Cached so concurrent callers share one
  /// initialization; a restore failure degrades to "no active model" rather
  /// than throwing, so a corrupt/unreadable prefs state never blocks app
  /// startup (#314 follow-up). The cached future always completes normally.
  Future<void>? _initFuture;

  /// Initializes the web model manager. Idempotent and concurrency-safe.
  Future<void> initialize() => _initFuture ??= _doInit();

  @override
  Future<void> ensureInitialized() => initialize();

  Future<void> _doInit() async {
    try {
      await _restoreActiveInferenceModel();
      await _restoreActiveEmbeddingModel();
      await _restoreActiveSttModel();
      gemmaLog('WebModelManager initialized');
    } catch (e, st) {
      // Best-effort restore: a failure must not abort app startup — start with
      // no active model. (#314 follow-up; mirrors MobileModelManager.)
      // Include the stack trace so an unexpected restore bug stays diagnosable.
      gemmaLog(
        'WebModelManager: active-model restore failed, starting with no active model: $e\n$st',
      );
    }
  }

  /// Rehydrate `_activeInferenceModel` from the identity persisted by a
  /// prior `setActiveModel` call (#227). The Web `getModelFilePaths` flow
  /// resolves to a real blob/Cache-API URL based on `spec.modelSource`, so
  /// we have to recover the original ModelSource (not just a filename).
  Future<void> _restoreActiveInferenceModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelTypeName = prefs.getString(
      PreferencesKeys.activeInferenceModelType,
    );
    final fileTypeName = prefs.getString(
      PreferencesKeys.activeInferenceFileType,
    );
    final filename = prefs.getString(PreferencesKeys.activeInferenceFilename);
    final sourceEncoded = prefs.getString(
      PreferencesKeys.activeInferenceSource,
    );

    if (modelTypeName == null ||
        fileTypeName == null ||
        filename == null ||
        sourceEncoded == null) {
      return;
    }

    final ModelType modelType;
    final ModelFileType fileType;
    try {
      modelType = ModelType.values.byName(modelTypeName);
      fileType = ModelFileType.values.byName(fileTypeName);
    } catch (e) {
      gemmaLog(
        '[WebModelManager] active model restore: unknown enum value — skipping',
      );
      return;
    }

    final source = ModelSource.tryDecode(sourceEncoded);
    if (source == null) {
      gemmaLog(
        '[WebModelManager] active model restore: malformed source — skipping',
      );
      return;
    }

    if (fileType == ModelFileType.builtIn || fileType == ModelFileType.onnx) {
      // Both are FILELESS on web: built-in OS models (Gemini Nano via the
      // Chrome Prompt API) and ONNX web text generation (flutter_gemma_onnx's
      // Transformers.js arm) install no file — `InferenceInstallationBuilder`
      // bypasses SourceHandlers/the repository for these fileTypes, so nothing
      // was ever `repository.saveModel()`-ed and the `repo.isInstalled` gate
      // below would always be false, incorrectly skipping the restore on every
      // page reload. Reconstruct the identity carrier directly from the
      // persisted source (a bundled carrier for built-in; the HF repo id for
      // ONNX), mirroring `MobileModelManager._restoreActiveInferenceModel`.
      _activeInferenceModel = InferenceModelSpec(
        name: filename,
        modelSource: source,
        modelType: modelType,
        fileType: fileType,
      );
      gemmaLog(
        '[WebModelManager] restored active fileless '
        '(${fileType.name}) model: $filename',
      );
      return;
    }

    // Verify the underlying file is still installed in the Web repository
    // before we set it active — otherwise getModelFilePaths() will throw
    // later on the first getActiveModel() call.
    final repo = ServiceRegistry.instance.modelRepository;
    if (!await repo.isInstalled(filename)) {
      gemmaLog(
        '[WebModelManager] active model restore: $filename not in repository — skipping',
      );
      return;
    }

    _activeInferenceModel = InferenceModelSpec(
      name: filename,
      modelSource: source,
      modelType: modelType,
      fileType: fileType,
    );
    gemmaLog('[WebModelManager] restored active inference model: $filename');
  }

  /// Web mirror of `MobileModelManager._migrateLegacyCompanionForRestore`: on
  /// upgrade, re-key a pre-refactor (plain-named) COMPANION to its namespaced
  /// install identity so the namespaced `.files` lookup in `getModelFilePaths`
  /// / `isModelInstalled` resolves (both gate on `repository.isInstalled` per
  /// spec file). Web has no filesystem rename (`adoptLegacyFile` is a
  /// deliberate no-op), so this re-keys the repository metadata — re-registering
  /// the existing blob URL under the new key so the bytes are reused, not
  /// re-fetched — and rewrites the persisted active filename.
  ///
  /// Safe for the same reason as the mobile helper: RESTORE targets a single
  /// KNOWN active model, so [modelId] unambiguously identifies the owner (the
  /// pre-refactor collision meant only the last-installed = active model's file
  /// could exist under the plain name). Returns the filename to gate on going
  /// forward (namespaced if migrated or already namespaced; unchanged plain
  /// when there is nothing to migrate — the caller's `isInstalled` gate then
  /// reports it missing).
  Future<String> _migrateLegacyCompanionForRestore({
    required String modelId,
    required String persistedFilename,
    required ModelSource source,
    required repo.ModelType repoType,
    required String prefsKey,
  }) async {
    final namespaced = FileNameUtils.namespaced(modelId, persistedFilename);
    if (namespaced == persistedFilename) return persistedFilename;

    final repository = ServiceRegistry.instance.modelRepository;
    final plainInstalled = await repository.isInstalled(persistedFilename);
    final namespacedInstalled = await repository.isInstalled(namespaced);
    if (!plainInstalled && !namespacedInstalled) {
      return persistedFilename; // nothing on record to migrate
    }

    // Re-key the repository entry — skip the write if a prior run already
    // created it (no-clobber). Crucially we do NOT early-return on
    // namespacedInstalled: the cleanup below (drop the stale plain row + rewrite
    // prefs) must still run so an interruption between saveModel and those steps
    // self-heals on the next launch, matching the mobile helper. Otherwise a
    // web tab closed mid-migration would leave the plain row orphaned forever
    // (double-counting in getStorageStats) and prefs stuck on the plain name.
    if (!namespacedInstalled) {
      final fs = ServiceRegistry.instance.fileSystemService;
      if (fs is WebFileSystemService) {
        final url = fs.getUrl(persistedFilename);
        if (url != null) fs.registerUrl(namespaced, url);
      }
      await repository.saveModel(
        repo.ModelInfo(
          id: namespaced,
          source: source,
          installedAt: DateTime.now(),
          sizeBytes: await fs.getFileSize(persistedFilename),
          type: repoType,
          hasLoraWeights: false,
        ),
      );
      gemmaLog(
        '[WebModelManager] migrated legacy companion "$persistedFilename" -> '
        '"$namespaced" (install-identity-namespacing)',
      );
    }
    if (plainInstalled) await repository.deleteModel(persistedFilename);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, namespaced);
    return namespaced;
  }

  Future<void> _restoreActiveEmbeddingModel() async {
    final prefs = await SharedPreferences.getInstance();
    final modelFilename = prefs.getString(
      PreferencesKeys.activeEmbeddingFilename,
    );
    final tokenizerFilename = prefs.getString(
      PreferencesKeys.activeEmbeddingTokenizerFilename,
    );
    final modelSourceEncoded = prefs.getString(
      PreferencesKeys.activeEmbeddingSource,
    );
    final tokenizerSourceEncoded = prefs.getString(
      PreferencesKeys.activeEmbeddingTokenizerSource,
    );

    if (modelFilename == null ||
        tokenizerFilename == null ||
        modelSourceEncoded == null ||
        tokenizerSourceEncoded == null) {
      return;
    }

    final modelSource = ModelSource.tryDecode(modelSourceEncoded);
    final tokenizerSource = ModelSource.tryDecode(tokenizerSourceEncoded);
    if (modelSource == null || tokenizerSource == null) {
      gemmaLog(
        '[WebModelManager] active embedding restore: malformed source — skipping',
      );
      return;
    }

    // The model weight keeps its plain basename (only companions are
    // namespaced); migrate a pre-refactor plain tokenizer to its namespaced
    // repo identity so the reconstructed spec's namespaced .files lookup finds
    // it. No-op for post-refactor installs.
    final effectiveTokenizerFilename = await _migrateLegacyCompanionForRestore(
      modelId: FileNameUtils.getBaseName(modelFilename),
      persistedFilename: tokenizerFilename,
      source: tokenizerSource,
      repoType: repo.ModelType.embedding,
      prefsKey: PreferencesKeys.activeEmbeddingTokenizerFilename,
    );

    final repository = ServiceRegistry.instance.modelRepository;
    if (!await repository.isInstalled(modelFilename) ||
        !await repository.isInstalled(effectiveTokenizerFilename)) {
      gemmaLog(
        '[WebModelManager] active embedding restore: file missing — skipping',
      );
      return;
    }

    _activeEmbeddingModel = EmbeddingModelSpec(
      name: modelFilename,
      modelSource: modelSource,
      tokenizerSource: tokenizerSource,
    );
    gemmaLog(
      '[WebModelManager] restored active embedding model: $modelFilename',
    );
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
    final modelSourceEncoded = prefs.getString(PreferencesKeys.activeSttSource);
    final tokenizerSourceEncoded = prefs.getString(
      PreferencesKeys.activeSttTokenizerSource,
    );

    if (modelFilename == null ||
        tokenizerFilename == null ||
        sttModelTypeName == null ||
        modelSourceEncoded == null ||
        tokenizerSourceEncoded == null) {
      return;
    }

    final SttModelType sttModelType;
    try {
      sttModelType = SttModelType.values.byName(sttModelTypeName);
    } catch (e) {
      gemmaLog(
        '[WebModelManager] active STT restore: unknown SttModelType ($sttModelTypeName) — skipping',
      );
      return;
    }

    final modelSource = ModelSource.tryDecode(modelSourceEncoded);
    final tokenizerSource = ModelSource.tryDecode(tokenizerSourceEncoded);
    if (modelSource == null || tokenizerSource == null) {
      gemmaLog(
        '[WebModelManager] active STT restore: malformed source — skipping',
      );
      return;
    }

    // The model weight keeps its plain basename (only companions are
    // namespaced); migrate a pre-refactor plain tokenizer to its namespaced
    // repo identity so the reconstructed spec's namespaced .files lookup finds
    // it. No-op for post-refactor installs.
    final effectiveTokenizerFilename = await _migrateLegacyCompanionForRestore(
      modelId: FileNameUtils.getBaseName(modelFilename),
      persistedFilename: tokenizerFilename,
      source: tokenizerSource,
      repoType: repo.ModelType.stt,
      prefsKey: PreferencesKeys.activeSttTokenizerFilename,
    );

    final repository = ServiceRegistry.instance.modelRepository;
    if (!await repository.isInstalled(modelFilename) ||
        !await repository.isInstalled(effectiveTokenizerFilename)) {
      gemmaLog('[WebModelManager] active STT restore: file missing — skipping');
      return;
    }

    _activeSttModel = SttModelSpec(
      name: modelFilename,
      modelSource: modelSource,
      tokenizerSource: tokenizerSource,
      sttModelType: sttModelType,
    );
    gemmaLog('[WebModelManager] restored active STT model: $modelFilename');
  }

  /// Checks if a model is installed
  ///
  /// Phase 5.3: Delegates to Modern API (ModelRepository) instead of
  /// checking manual state (_modelPaths, _loadCompleters).
  @override
  Future<bool> isModelInstalled(ModelSpec spec) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Check if all files in the spec are installed
    for (final file in spec.files) {
      if (!await repository.isInstalled(file.filename)) {
        return false;
      }
    }

    return true;
  }

  @override
  Stream<DownloadProgress> downloadModelWithProgress(
    ModelSpec spec, {
    String? token,
  }) async* {
    await _ensureInitialized();

    gemmaLog('WebModelManager: Starting download for ${spec.name}');

    // Fileless identity installs — ONNX web (Transformers.js resolves + caches
    // the HF repo from the repo id in `spec.modelSource`, see
    // flutter_gemma_onnx's `TransformersWebResolver`) and builtIn (the
    // OS/browser owns the weights, e.g. Gemini Nano via the Chrome Prompt API).
    // Core must not byte-download either — otherwise a builtIn spec falls into
    // the per-file handler loop below and the bundled handler tries to fetch a
    // nonexistent `/<name>` resource. Skip the loop; just publish the identity
    // as active. Mirrors the fileless-restore branch above.
    if (spec is InferenceModelSpec &&
        (spec.fileType == ModelFileType.onnx ||
            spec.fileType == ModelFileType.builtIn)) {
      setActiveModel(spec);
      yield const DownloadProgress(
        currentFileIndex: 1,
        totalFiles: 1,
        currentFileProgress: 100,
        currentFileName: 'Complete',
      );
      gemmaLog(
        'WebModelManager: fileless (web) model set as active: ${spec.name}',
      );
      return;
    }

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final handlerRegistry = registry.sourceHandlerRegistry;
    final totalFiles = spec.files.length;

    for (int i = 0; i < totalFiles; i++) {
      final file = spec.files[i];

      // Emit file start progress
      yield DownloadProgress(
        currentFileIndex: i,
        totalFiles: totalFiles,
        currentFileProgress: 0,
        currentFileName: file.filename,
      );

      // Get handler for this file's source
      final handler = handlerRegistry.getHandler(file.source);
      if (handler == null) {
        throw ModelStorageException(
          'No handler for ${file.source.runtimeType}',
          null,
          'downloadModelWithProgress',
        );
      }

      // For NetworkSource with token, update the source
      ModelSource sourceToInstall = file.source;
      if (sourceToInstall is NetworkSource && token != null) {
        sourceToInstall = NetworkSource(sourceToInstall.url, authToken: token);
      }

      // Download via Modern API handler with progress
      // All handlers implement installWithProgress (handlers that don't support
      // true progress will emit 100% immediately)
      await for (final progress in handler.installWithProgress(
        sourceToInstall,
        modelType: _toRepoType(spec.type),
      )) {
        yield DownloadProgress(
          currentFileIndex: i,
          totalFiles: totalFiles,
          currentFileProgress: progress,
          currentFileName: file.filename,
        );
      }
    }

    // Set as active after successful download
    setActiveModel(spec);

    // Emit final progress
    yield DownloadProgress(
      currentFileIndex: totalFiles,
      totalFiles: totalFiles,
      currentFileProgress: 100,
      currentFileName: 'Complete',
    );

    gemmaLog('WebModelManager: Download completed for ${spec.name}');
  }

  @override
  Future<void> downloadModel(ModelSpec spec, {String? token}) async {
    await _ensureInitialized();
    // Use the stream version but don't yield progress
    await for (final _ in downloadModelWithProgress(spec, token: token)) {
      // Just consume the stream
    }
  }

  /// Deletes a model
  ///
  /// Phase 5.5: Delegates to Modern API (ModelRepository) instead of
  /// manually removing from state maps.
  @override
  Future<void> deleteModel(ModelSpec spec) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Delete all files in the spec from repository
    for (final file in spec.files) {
      await repository.deleteModel(file.filename);
    }

    gemmaLog('WebModelManager: Model ${spec.name} deleted');
  }

  repo.ModelType _toRepoType(ModelManagementType type) => switch (type) {
    ModelManagementType.inference => repo.ModelType.inference,
    ModelManagementType.embedding => repo.ModelType.embedding,
    ModelManagementType.stt => repo.ModelType.stt,
    ModelManagementType.tts => repo.ModelType.tts,
  };

  /// Gets list of installed model filenames
  ///
  /// Phase 5.5: Delegates to Modern API (ModelRepository) instead of
  /// querying _installedModels map.
  @override
  Future<List<String>> getInstalledModels(ModelManagementType type) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Get all installed models from repository
    final allInstalled = await repository.listInstalled();

    final filtered = allInstalled
        .where((m) => m.type == _toRepoType(type))
        .toList();

    // Return filenames
    return filtered.map((m) => m.id).toList();
  }

  /// Checks if any model is installed
  ///
  /// Phase 5.5: Delegates to Modern API (ModelRepository) instead of
  /// checking _installedModels map.
  @override
  Future<bool> isAnyModelInstalled(ModelManagementType type) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Get all installed models from repository
    final allInstalled = await repository.listInstalled();

    return allInstalled.any((m) => m.type == _toRepoType(type));
  }

  @override
  Future<void> performCleanup() async {
    await _ensureInitialized();
    gemmaLog('WebModelManager: Cleanup not needed on web');
  }

  /// Validates if a model is properly installed
  ///
  /// Phase 5.3: Delegates to Modern API (isModelInstalled) instead of
  /// checking manual _installedModels map.
  @override
  Future<bool> validateModel(ModelSpec spec) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    // validateModel is essentially the same as isModelInstalled on web
    return await isModelInstalled(spec);
  }

  @override
  Future<Map<String, String>?> getModelFilePaths(ModelSpec spec) async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;
    final fileSystem = registry.fileSystemService as WebFileSystemService;

    // Check installation via repository
    bool allFilesInstalled = true;
    for (final file in spec.files) {
      if (!await repository.isInstalled(file.filename)) {
        allFilesInstalled = false;
        break;
      }
    }

    if (!allFilesInstalled) {
      return null;
    }

    final filePaths = <String, String>{};

    for (final file in spec.files) {
      // Get URL from WebFileSystemService based on source type
      final String path;

      if (file.source is NetworkSource) {
        // Web: Get registered URL (blob URL for auth downloads)
        // If URL lost (page reload), restore from Cache API
        var url = fileSystem.getUrl(file.filename);
        if (url == null) {
          gemmaLog(
            '[WebModelManager] Blob URL lost for ${file.filename}, restoring from cache...',
          );

          // Try to restore from Cache API
          final networkSource = file.source as NetworkSource;
          final downloadService =
              registry.downloadService as WebDownloadService;
          final cacheService = downloadService.cacheService;

          // Get cached blob URL (cache service handles URL normalization internally)
          final cachedBlobUrl = await cacheService.getCachedBlobUrl(
            networkSource.url,
          );
          if (cachedBlobUrl != null) {
            gemmaLog(
              '[WebModelManager] ✅ Restored blob URL from cache: $cachedBlobUrl',
            );
            // Re-register the blob URL
            fileSystem.registerUrl(file.filename, cachedBlobUrl);
            url = cachedBlobUrl;
          } else {
            gemmaLog(
              '[WebModelManager] ⚠️  Not found in cache, will use original URL (may require auth)',
            );
          }
        }
        path = url ?? (file.source as NetworkSource).url;
      } else if (file.source is BundledSource) {
        // Web: Bundled resources
        path = await fileSystem.getBundledResourcePath(
          (file.source as BundledSource).resourceName,
        );
      } else if (file.source is AssetSource) {
        // Web: Get registered Blob URL (created by WebAssetSourceHandler)
        // If URL lost (page reload), recreate it
        var url = fileSystem.getUrl(file.filename);
        if (url == null) {
          gemmaLog(
            '[WebModelManager] Blob URL lost for ${file.filename}, recreating from asset...',
          );
          // Recreate Blob URL by reinstalling
          final handler = registry.sourceHandlerRegistry.getHandler(
            file.source,
          );
          if (handler != null) {
            await handler.install(
              file.source,
              modelType: _toRepoType(spec.type),
            );
            url = fileSystem.getUrl(file.filename);
          }
        }
        path = url ?? (file.source as AssetSource).normalizedPath;
      } else if (file.source is FileSource) {
        // Web: External URL or registered path
        final fileSource = file.source as FileSource;
        path = fileSystem.getUrl(file.filename) ?? fileSource.path;
      } else {
        // Fallback: use getTargetPath
        path = await fileSystem.getTargetPath(file.filename);
      }

      filePaths[file.prefsKey] = path;
    }

    return filePaths.isNotEmpty ? filePaths : null;
  }

  /// Gets storage statistics for installed models
  ///
  /// Phase 5.3: Delegates to Modern API (ModelRepository) instead of
  /// checking manual _installedModels map.
  @override
  Future<Map<String, int>> getStorageStats() async {
    await _ensureInitialized();

    // Phase 5: Delegate to Modern API
    final registry = ServiceRegistry.instance;
    final repository = registry.modelRepository;

    // Get all installed models from repository
    final allInstalled = await repository.listInstalled();
    final installedCount = allInstalled.length;

    // Count by type
    final inferenceCount = allInstalled
        .where((m) => m.type == repo.ModelType.inference)
        .length;
    final embeddingCount = allInstalled
        .where((m) => m.type == repo.ModelType.embedding)
        .length;

    return {
      'protectedFiles': installedCount,
      'totalSizeBytes': 0, // Unknown for web URLs (no local file system)
      'totalSizeMB': 0,
      'inferenceModels': inferenceCount,
      'embeddingModels': embeddingCount,
    };
  }

  /// Modern API: Ensures a model spec is ready for use
  ///
  /// Phase 5.1: This method now delegates to ServiceRegistry (Modern API)
  /// instead of manually managing state. All installation is handled by
  /// source handlers through the ServiceRegistry pattern.
  @override
  Future<void> ensureModelReadyFromSpec(ModelSpec spec) async {
    await _ensureInitialized();

    // Phase 5: Delegate to ServiceRegistry (Modern API)
    final registry = ServiceRegistry.instance;
    final handlerRegistry = registry.sourceHandlerRegistry;
    final repository = registry.modelRepository;

    // Check if already installed via repository
    bool allFilesInstalled = true;
    for (final file in spec.files) {
      if (!await repository.isInstalled(file.filename)) {
        allFilesInstalled = false;
        break;
      }
    }

    if (!allFilesInstalled) {
      // Install via Modern API handlers
      for (final file in spec.files) {
        final handler = handlerRegistry.getHandler(file.source);
        if (handler == null) {
          throw ModelStorageException(
            'No handler for ${file.source.runtimeType}',
            null,
            'ensureModelReadyFromSpec',
          );
        }
        await handler.install(file.source, modelType: _toRepoType(spec.type));
      }
    }

    setActiveModel(spec);
  }

  /// Legacy API: Ensures a model is ready for use, handling all necessary operations
  ///
  /// Phase 5.5: Thin facade over ensureModelReadyFromSpec (Modern API)
  @Deprecated('Use ensureModelReadyFromSpec with ModelSource instead')
  @override
  Future<void> ensureModelReady(String filename, String url) async {
    await _ensureInitialized();

    // Create a spec and delegate to Modern API
    final spec = InferenceModelSpec.fromLegacyUrl(
      name: filename,
      modelUrl: url,
    );

    // Delegate to Modern API (no manual state management needed)
    await ensureModelReadyFromSpec(spec);
  }

  Future<void> _ensureInitialized() => initialize();

  /// Creates an inference model specification from parameters
  static InferenceModelSpec createInferenceSpec({
    required String name,
    required String modelUrl,
    String? loraUrl,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
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
  /// Use this for models packaged in web/assets/models/
  ///
  /// Example:
  /// ```dart
  /// final spec = WebModelManager.createBundledInferenceSpec(
  ///   resourceName: 'gemma3-270m-it-q8.task',
  /// );
  /// await manager.ensureModelReadyFromSpec(spec);
  /// ```
  static InferenceModelSpec createBundledInferenceSpec({
    required String resourceName,
    String? loraResourceName,
    ModelReplacePolicy replacePolicy = ModelReplacePolicy.keep,
    ModelType modelType = ModelType.general,
    ModelFileType fileType = ModelFileType.task,
  }) {
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
  /// Use this for embedding models packaged in web/assets/models/
  ///
  /// Example:
  /// ```dart
  /// final spec = WebModelManager.createBundledEmbeddingSpec(
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

  // Active models (modern API)
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

  // === Legacy Asset Loading Methods Implementation ===

  /// Installs model from Flutter asset (debug mode only)
  ///
  /// ⚠️ DEPRECATED: Use FlutterGemma.installModel().fromAsset() instead
  ///
  /// This method provides backward compatibility but delegates to Modern API.
  ///
  /// Migration:
  /// ```dart
  /// // OLD:
  /// await manager.installModelFromAsset('assets/models/gemma.task');
  ///
  /// // NEW:
  /// await FlutterGemma.installModel()
  ///   .fromAsset('assets/models/gemma.task')
  ///   .install();
  /// ```
  @Deprecated('Use FlutterGemma.installModel().fromAsset() instead')
  @override
  Future<void> installModelFromAsset(String path, {String? loraPath}) async {
    if (kReleaseMode) {
      throw UnsupportedError(
        "Asset model loading is not supported in release builds. "
        "Use fromNetwork() or fromBundled() instead.",
      );
    }

    await _ensureInitialized();

    // Convert legacy parameters to Modern API ModelSpec
    final spec = InferenceModelSpec(
      name: FileNameUtils.getBaseName(path.split('/').last),
      modelSource: ModelSource.asset(path),
      loraSource: loraPath != null ? ModelSource.asset(loraPath) : null,
      modelType: ModelType.general, // Default for legacy API
      fileType: ModelFileType.task, // Default for legacy API
    );

    // Delegate to Modern API
    // This uses AssetSourceHandler which handles all the work
    await ensureModelReadyFromSpec(spec);
  }

  /// Installs model from Flutter asset with progress (debug mode only)
  ///
  /// ⚠️ DEPRECATED: Use FlutterGemma.installModel().fromAsset().installWithProgress() instead
  ///
  /// Migration:
  /// ```dart
  /// // OLD:
  /// await for (final progress in manager.installModelFromAssetWithProgress('assets/models/gemma.task')) {
  ///   gemmaLog('Progress: $progress%');
  /// }
  ///
  /// // NEW:
  /// await for (final progress in FlutterGemma.installModel()
  ///     .fromAsset('assets/models/gemma.task')
  ///     .installWithProgress()) {
  ///   gemmaLog('Progress: ${progress.currentFileProgress}%');
  /// }
  /// ```
  @Deprecated(
    'Use FlutterGemma.installModel().fromAsset().installWithProgress() instead',
  )
  @override
  Stream<int> installModelFromAssetWithProgress(
    String path, {
    String? loraPath,
  }) async* {
    if (kReleaseMode) {
      throw UnsupportedError(
        "Asset model loading is not supported in release builds. "
        "Use fromNetwork() or fromBundled() instead.",
      );
    }

    await _ensureInitialized();

    // Convert legacy parameters to Modern API ModelSpec
    final spec = InferenceModelSpec(
      name: FileNameUtils.getBaseName(path.split('/').last),
      modelSource: ModelSource.asset(path),
      loraSource: loraPath != null ? ModelSource.asset(loraPath) : null,
      modelType: ModelType.general, // Default for legacy API
      fileType: ModelFileType.task, // Default for legacy API
    );

    // Delegate to Modern API downloadModelWithProgress
    // This provides real progress tracking from handlers
    await for (final downloadProgress in downloadModelWithProgress(spec)) {
      yield downloadProgress.currentFileProgress;
    }
  }

  // === Legacy Direct Path Methods Implementation ===

  /// Sets model path for inference (web: URLs only)
  ///
  /// ⚠️ DEPRECATED: Use FlutterGemma.installModel().fromNetwork() instead
  ///
  /// This method provides backward compatibility but delegates to Modern API.
  ///
  /// Migration:
  /// ```dart
  /// // OLD:
  /// await manager.setModelPath('https://example.com/model.task');
  ///
  /// // NEW:
  /// await FlutterGemma.installModel()
  ///   .fromNetwork('https://example.com/model.task')
  ///   .install();
  /// ```
  @Deprecated('Use FlutterGemma.installModel().fromNetwork() instead')
  @override
  Future<void> setModelPath(String path, {String? loraPath}) async {
    await _ensureInitialized();

    // Create ModelSource based on path type
    final modelSource = path.startsWith('http')
        ? ModelSource.network(path)
        : ModelSource.file(path);

    final loraSource = loraPath != null
        ? (loraPath.startsWith('http')
              ? ModelSource.network(loraPath)
              : ModelSource.file(loraPath))
        : null;

    // Convert legacy parameters to Modern API ModelSpec
    final spec = InferenceModelSpec(
      name: FileNameUtils.getBaseName(path.split('/').last),
      modelSource: modelSource,
      loraSource: loraSource,
      modelType: ModelType.general, // Default for legacy API
      fileType: ModelFileType.task, // Default for legacy API
    );

    // Delegate to Modern API
    await ensureModelReadyFromSpec(spec);
  }

  /// Clears model cache (legacy method)
  ///
  /// ⚠️ Note: In Modern API, model persistence is managed by ModelRepository.
  /// This method only clears active model references, not installed models.
  /// Use deleteModel() to remove installed models.
  @override
  Future<void> clearModelCache() async {
    await _ensureInitialized();

    // Clear active models
    _activeInferenceModel = null;
    _activeEmbeddingModel = null;

    gemmaLog('WebModelManager: Model cache cleared (active models reset)');
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
      gemmaLog('[WebModelManager] clearActiveInferenceIdentity failed: $e');
      rethrow;
    }
    gemmaLog('WebModelManager: active inference identity cleared');
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
      gemmaLog('[WebModelManager] clearActiveEmbeddingIdentity failed: $e');
      rethrow;
    }
    gemmaLog('WebModelManager: active embedding identity cleared');
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
      gemmaLog('[WebModelManager] clearActiveSttIdentity failed: $e');
      rethrow;
    }
    gemmaLog('WebModelManager: active STT identity cleared');
  }

  @override
  Future<void> clearActiveTtsIdentity() async {
    // TTS is native-only; web keeps only the in-memory reference (no prefs).
    _activeTtsModel = null;
    gemmaLog('WebModelManager: active TTS identity cleared (in-memory only)');
  }

  // === Legacy LoRA Management Methods Implementation ===

  @override
  Future<void> setLoraWeightsPath(String path) async {
    await _ensureInitialized();

    if (_activeInferenceModel == null) {
      throw Exception(
        'No active inference model to apply LoRA weights to. Use setModelPath first.',
      );
    }

    final current = _activeInferenceModel as InferenceModelSpec;

    // Create LoRA source from path
    final loraSource = path.startsWith('http')
        ? ModelSource.network(path)
        : ModelSource.file(path);

    final updatedSpec = InferenceModelSpec(
      name: current.name,
      modelSource: current.modelSource,
      loraSource: loraSource,
      replacePolicy: current.replacePolicy,
      modelType: current.modelType,
      fileType: current.fileType,
    );

    // Update active model (no manual _loraPaths management needed)
    setActiveModel(updatedSpec);
  }

  @override
  Future<void> deleteLoraWeights() async {
    await _ensureInitialized();

    if (_activeInferenceModel == null) {
      throw Exception('No active inference model to remove LoRA weights from');
    }

    final current = _activeInferenceModel as InferenceModelSpec;

    final updatedSpec = InferenceModelSpec(
      name: current.name,
      modelSource: current.modelSource,
      loraSource: null, // Remove LoRA
      replacePolicy: current.replacePolicy,
      modelType: current.modelType,
      fileType: current.fileType,
    );

    // Update active model (no manual _loraPaths management needed)
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

  @override
  void setActiveModel(ModelSpec spec) {
    if (spec is InferenceModelSpec) {
      _activeInferenceModel = spec;
      gemmaLog('✅ Set active inference model: ${spec.name}');
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
      // TTS is native-only; on web we keep the in-memory reference so the API
      // doesn't throw, but do not persist/restore (its backend is a stub).
      _activeTtsModel = spec;
      gemmaLog('✅ Set active TTS model (web, in-memory only): ${spec.name}');
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
      // Issued together, with no `await` between them, and that is the whole
      // fix for #468. `SharedPreferences._setValue` is not async: it writes
      // `_preferenceCache[key]` synchronously and only then starts the platform
      // write, and `getInstance()` memoises one instance per isolate — so every
      // reader, on any manager instance, shares that map. Awaiting each call in
      // turn yielded between them, and a reader that interleaved saw a partial
      // identity (measured: one key of four) or, on a re-install, a mixed one:
      // the new modelType with the old filename, which is well-formed, passes
      // `isInstalled`, and loads the wrong weights silently. Written in one
      // uninterrupted burst, neither state can be observed at all.
      await Future.wait([
        prefs.setString(
          PreferencesKeys.activeInferenceModelType,
          spec.modelType.name,
        ),
        prefs.setString(
          PreferencesKeys.activeInferenceFileType,
          spec.fileType.name,
        ),
        prefs.setString(PreferencesKeys.activeInferenceFilename, filename),
        prefs.setString(
          PreferencesKeys.activeInferenceSource,
          spec.modelSource.encode(),
        ),
      ]);
    } catch (e) {
      gemmaLog('[WebModelManager] persistActiveInferenceIdentity failed: $e');
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
      // One burst — see _persistActiveInferenceIdentity for why (#468).
      await Future.wait([
        prefs.setString(
          PreferencesKeys.activeEmbeddingFilename,
          modelFile.filename,
        ),
        prefs.setString(
          PreferencesKeys.activeEmbeddingTokenizerFilename,
          tokenizerFile.filename,
        ),
        prefs.setString(
          PreferencesKeys.activeEmbeddingSource,
          spec.modelSource.encode(),
        ),
        prefs.setString(
          PreferencesKeys.activeEmbeddingTokenizerSource,
          spec.tokenizerSource.encode(),
        ),
      ]);
    } catch (e) {
      gemmaLog('[WebModelManager] persistActiveEmbeddingIdentity failed: $e');
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
      // One burst — see _persistActiveInferenceIdentity for why (#468).
      await Future.wait([
        prefs.setString(PreferencesKeys.activeSttFilename, modelFile.filename),
        prefs.setString(
          PreferencesKeys.activeSttTokenizerFilename,
          tokenizerFile.filename,
        ),
        prefs.setString(
          PreferencesKeys.activeSttModelType,
          spec.sttModelType.name,
        ),
        prefs.setString(
          PreferencesKeys.activeSttSource,
          spec.modelSource.encode(),
        ),
        prefs.setString(
          PreferencesKeys.activeSttTokenizerSource,
          spec.tokenizerSource.encode(),
        ),
      ]);
    } catch (e) {
      gemmaLog('[WebModelManager] persistActiveSttIdentity failed: $e');
    }
  }

  // === Storage Management Implementation ===

  @override
  Future<StorageStats> getStorageInfo() async {
    await _ensureInitialized();
    // Web platform doesn't have file system access, return empty stats
    return const StorageStats(
      totalFiles: 0,
      totalSizeBytes: 0,
      orphanedFiles: [],
    );
  }

  @override
  Future<List<OrphanedFileInfo>> getOrphanedFiles() async {
    await _ensureInitialized();
    // Web platform doesn't have file system access, no orphaned files
    return [];
  }

  @override
  Future<int> cleanupStorage() async {
    await _ensureInitialized();
    // Web platform doesn't have file system access, nothing to cleanup
    gemmaLog('WebModelManager: cleanupStorage() is a no-op on web');
    return 0;
  }

  // === Web Cache Management (NEW) ===

  /// Clear browser cache for models
  ///
  /// Deletes all cached model data from browser Cache API.
  /// This is separate from deleteModel() which only removes
  /// installation records.
  Future<void> clearCache() async {
    await _ensureInitialized();

    try {
      final registry = ServiceRegistry.instance;
      final downloadService = registry.downloadService as WebDownloadService;
      await downloadService.cacheService.clearCache();
      gemmaLog('WebModelManager: Browser cache cleared');
    } catch (e) {
      gemmaLog('WebModelManager: clearCache failed: $e');
      rethrow;
    }
  }

  /// Get cache statistics
  ///
  /// Returns information about browser cache usage.
  Future<Map<String, dynamic>> getCacheStats() async {
    await _ensureInitialized();

    try {
      final registry = ServiceRegistry.instance;
      final downloadService = registry.downloadService as WebDownloadService;
      final cacheService = downloadService.cacheService;

      final quota = await cacheService.getStorageQuota();
      final urls = await cacheService.getCachedUrls();

      return {
        'cachedUrls': urls.length,
        'storageUsage': quota.usage,
        'storageQuota': quota.quota,
        'usagePercent': quota.usagePercent,
        'availableBytes': quota.available,
      };
    } catch (e) {
      gemmaLog('[WebModelManager] ❌ getCacheStats failed: $e');
      return {
        'cachedUrls': 0,
        'storageUsage': 0,
        'storageQuota': 0,
        'usagePercent': 0.0,
        'availableBytes': 0,
      };
    }
  }
}

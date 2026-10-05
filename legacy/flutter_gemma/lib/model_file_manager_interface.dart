import 'package:flutter_gemma/core/model_management/model_specs.dart';
// ModelReplacePolicy moved into model_specs.dart (breaks the specs↔interface
// import cycle); re-export it here so existing importers of this interface
// keep seeing it.
export 'package:flutter_gemma/core/model_management/model_specs.dart'
    show ModelReplacePolicy;

abstract class ModelFileManager {
  /// Check if a model is installed and valid
  Future<bool> isModelInstalled(ModelSpec spec);

  /// Downloads a model with progress tracking
  Stream<DownloadProgress> downloadModelWithProgress(
    ModelSpec spec, {
    String? token,
  });

  /// Downloads a model without progress tracking
  Future<void> downloadModel(ModelSpec spec, {String? token});

  /// Deletes a model and all its files
  Future<void> deleteModel(ModelSpec spec);

  /// Gets all installed models for a specific type
  Future<List<String>> getInstalledModels(ModelManagementType type);

  /// Checks if ANY model of the given type is installed
  Future<bool> isAnyModelInstalled(ModelManagementType type);

  /// Performs cleanup of orphaned files
  Future<void> performCleanup();

  /// Validates all files for a model specification
  Future<bool> validateModel(ModelSpec spec);

  /// Gets the file paths for an installed model
  Future<Map<String, String>?> getModelFilePaths(ModelSpec spec);

  /// Gets storage statistics (legacy format)
  Future<Map<String, int>> getStorageStats();

  /// Gets detailed storage information including orphaned files
  Future<StorageStats> getStorageInfo();

  /// Gets list of orphaned files (files without active downloads)
  Future<List<OrphanedFileInfo>> getOrphanedFiles();

  /// Explicitly cleanup orphaned files (user must call this - NOT automatic)
  /// Returns number of deleted files
  Future<int> cleanupStorage();

  /// Modern API: Ensures a model spec is ready for use
  Future<void> ensureModelReadyFromSpec(ModelSpec spec);

  /// Legacy API: Ensures a model is ready for use, handling all necessary operations
  @Deprecated('Use ensureModelReadyFromSpec with ModelSource instead')
  Future<void> ensureModelReady(String filename, String url);

  /// Legacy API: Installs model from Flutter assets (debug only)
  @Deprecated('Use FlutterGemma.installModel().fromAsset() instead')
  Future<void> installModelFromAsset(String path, {String? loraPath});

  /// Legacy API: Installs model from Flutter assets with progress tracking (debug only)
  @Deprecated(
    'Use FlutterGemma.installModel().fromAsset().withProgress() instead',
  )
  Stream<int> installModelFromAssetWithProgress(
    String path, {
    String? loraPath,
  });

  /// Legacy API: Sets direct path to existing model files
  @Deprecated('Use FlutterGemma.installModel().fromFile() instead')
  Future<void> setModelPath(String path, {String? loraPath});

  /// Clears current model cache/state
  Future<void> clearModelCache();

  /// Clears the active inference identity (in-memory spec + persisted prefs).
  ///
  /// Has a default body (rather than being abstract) so adding it does not
  /// break third-party [ModelFileManager] implementers at compile time — but
  /// the default THROWS rather than silently succeeding: a "clear" that
  /// quietly does nothing would leave a stale active identity persisted (a
  /// silent failure). Implementers that persist active state must override it.
  Future<void> clearActiveInferenceIdentity() async {
    throw UnimplementedError(
      'clearActiveInferenceIdentity is not implemented by this ModelFileManager',
    );
  }

  /// Clears the active embedding identity (in-memory spec + persisted prefs).
  ///
  /// See [clearActiveInferenceIdentity]: default throws rather than silently
  /// no-op'ing, so a non-overriding implementer fails loudly instead of
  /// leaving a stale persisted identity.
  Future<void> clearActiveEmbeddingIdentity() async {
    throw UnimplementedError(
      'clearActiveEmbeddingIdentity is not implemented by this ModelFileManager',
    );
  }

  /// Clears the active STT identity (in-memory spec + persisted prefs).
  ///
  /// See [clearActiveInferenceIdentity]: default throws rather than silently
  /// no-op'ing, so a non-overriding implementer fails loudly instead of
  /// leaving a stale persisted identity.
  Future<void> clearActiveSttIdentity() async {
    throw UnimplementedError(
      'clearActiveSttIdentity is not implemented by this ModelFileManager',
    );
  }

  /// Clears the active TTS identity (in-memory spec + persisted prefs).
  ///
  /// See [clearActiveInferenceIdentity]: default throws rather than silently
  /// no-op'ing, so a non-overriding implementer fails loudly instead of
  /// leaving a stale persisted identity.
  Future<void> clearActiveTtsIdentity() async {
    throw UnimplementedError(
      'clearActiveTtsIdentity is not implemented by this ModelFileManager',
    );
  }

  /// Legacy API: Sets path to LoRA weights for current model
  @Deprecated('Use FlutterGemma.installModel().withLoraFromFile() instead')
  Future<void> setLoraWeightsPath(String path);

  /// Legacy API: Removes LoRA weights from current model
  @Deprecated('Reinstall model without LoRA using FlutterGemma.installModel()')
  Future<void> deleteLoraWeights();

  /// Legacy API: Deletes current active model (legacy method without parameters)
  @Deprecated('Use deleteModel(spec) with ModelSpec instead')
  Future<void> deleteCurrentModel();

  /// Sets the active model for subsequent inference operations
  void setActiveModel(ModelSpec spec);

  /// Ensures the manager is fully initialized — active model/embedder state
  /// restored from storage (#227). Idempotent and safe to call concurrently;
  /// all callers share a single initialization. Await this before reading
  /// [activeInferenceModel] / [activeEmbeddingModel] (#314).
  Future<void> ensureInitialized();

  /// Gets the currently active inference model specification
  ModelSpec? get activeInferenceModel;

  /// Gets the currently active embedding model specification
  ModelSpec? get activeEmbeddingModel;

  /// Gets the currently active STT model specification
  ModelSpec? get activeSttModel;

  /// Gets the currently active TTS model specification.
  ModelSpec? get activeTtsModel;
}

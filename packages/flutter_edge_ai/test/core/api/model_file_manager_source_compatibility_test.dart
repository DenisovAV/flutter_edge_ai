import 'package:flutter_edge_ai/core/model_management/model_specs.dart';
import 'package:flutter_edge_ai/model_file_manager_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('legacy ModelFileManager implementer remains source-compatible', () {
    expect(_LegacyModelFileManager(), isA<ModelFileManager>());
  });
}

/// Compile fixture representing an existing third-party implementation.
///
/// Deliberately implements every [ModelFileManager] member. Adding a new member
/// to ModelFileManager makes this fixture fail at compile time.
final class _LegacyModelFileManager implements ModelFileManager {
  @override
  ModelSpec? get activeEmbeddingModel => null;

  @override
  ModelSpec? get activeInferenceModel => null;

  @override
  ModelSpec? get activeSttModel => null;

  @override
  ModelSpec? get activeTtsModel => null;

  @override
  Future<int> cleanupStorage() => throw UnimplementedError();

  @override
  Future<void> clearActiveEmbeddingIdentity() => throw UnimplementedError();

  @override
  Future<void> clearActiveInferenceIdentity() => throw UnimplementedError();

  @override
  Future<void> clearActiveSttIdentity() => throw UnimplementedError();

  @override
  Future<void> clearActiveTtsIdentity() => throw UnimplementedError();

  @override
  Future<void> clearModelCache() => throw UnimplementedError();

  @override
  Future<void> deleteCurrentModel() => throw UnimplementedError();

  @override
  Future<void> deleteLoraWeights() => throw UnimplementedError();

  @override
  Future<void> deleteModel(ModelSpec spec) => throw UnimplementedError();

  @override
  Future<void> downloadModel(ModelSpec spec, {String? token}) =>
      throw UnimplementedError();

  @override
  Stream<DownloadProgress> downloadModelWithProgress(
    ModelSpec spec, {
    String? token,
  }) => throw UnimplementedError();

  @override
  Future<void> ensureInitialized() => throw UnimplementedError();

  @override
  Future<void> ensureModelReady(String filename, String url) =>
      throw UnimplementedError();

  @override
  Future<void> ensureModelReadyFromSpec(ModelSpec spec) =>
      throw UnimplementedError();

  @override
  Future<Map<String, String>?> getModelFilePaths(ModelSpec spec) =>
      throw UnimplementedError();

  @override
  Future<List<OrphanedFileInfo>> getOrphanedFiles() =>
      throw UnimplementedError();

  @override
  Future<List<String>> getInstalledModels(ModelManagementType type) =>
      throw UnimplementedError();

  @override
  Future<StorageStats> getStorageInfo() => throw UnimplementedError();

  @override
  Future<Map<String, int>> getStorageStats() => throw UnimplementedError();

  @override
  Future<void> installModelFromAsset(String path, {String? loraPath}) =>
      throw UnimplementedError();

  @override
  Stream<int> installModelFromAssetWithProgress(
    String path, {
    String? loraPath,
  }) => throw UnimplementedError();

  @override
  Future<bool> isAnyModelInstalled(ModelManagementType type) =>
      throw UnimplementedError();

  @override
  Future<bool> isModelInstalled(ModelSpec spec) => throw UnimplementedError();

  @override
  Future<void> performCleanup() => throw UnimplementedError();

  @override
  Future<void> setLoraWeightsPath(String path) => throw UnimplementedError();

  @override
  Future<void> setModelPath(String path, {String? loraPath}) =>
      throw UnimplementedError();

  @override
  Future<bool> validateModel(ModelSpec spec) => throw UnimplementedError();
}

import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// In-memory implementation of ModelRepository
///
/// This repository stores model metadata in memory only.
/// Data is lost when:
/// - Dart VM restarts (hot restart in dev mode)
/// - Page reloads (production)
/// - Application terminates
///
/// Use cases:
/// - Web platform with enableCache=false (ephemeral models)
/// - Testing (fast, no I/O)
/// - Temporary model installations
///
/// Lifecycle:
/// - enableCache=false: metadata lives only during current session
/// - After reload: all metadata is lost, models must be re-downloaded
/// - Matches blob URL lifecycle (memory-only)
///
/// Platform: All platforms (but primarily for web with cache disabled)
class InMemoryModelRepository implements ModelRepository {
  final Map<String, ModelInfo> _models = {};

  @override
  Future<void> saveModel(ModelInfo info) async {
    if (info.id.isEmpty) {
      throw ArgumentError('Model ID cannot be empty');
    }
    gemmaLog('[InMemoryModelRepository] 💾 Saving model: ${info.id}');
    _models[info.id] = info;
  }

  @override
  Future<ModelInfo?> loadModel(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('Model ID cannot be empty');
    }
    final model = _models[id];
    gemmaLog(
      '[InMemoryModelRepository] ${model != null ? "✅ Loaded" : "❌ Not found"}: $id',
    );
    return model;
  }

  @override
  Future<void> deleteModel(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('Model ID cannot be empty');
    }
    final existed = _models.remove(id) != null;
    gemmaLog(
      '[InMemoryModelRepository] ${existed ? "🗑️  Deleted" : "⚠️  Not found"}: $id',
    );
  }

  @override
  Future<List<ModelInfo>> listInstalled() async {
    final models = _models.values.toList();
    gemmaLog(
      '[InMemoryModelRepository] 📋 Listing ${models.length} installed models',
    );
    return models;
  }

  @override
  Future<bool> isInstalled(String id) async {
    if (id.isEmpty) {
      throw ArgumentError('Model ID cannot be empty');
    }
    final installed = _models.containsKey(id);
    gemmaLog(
      '[InMemoryModelRepository] ${installed ? "✅" : "❌"} isInstalled($id): $installed',
    );
    return installed;
  }

  /// Clears all stored metadata
  ///
  /// Useful for testing or manual cleanup.
  /// Not part of ModelRepository interface.
  void clear() {
    final count = _models.length;
    _models.clear();
    gemmaLog('[InMemoryModelRepository] 🧹 Cleared $count models from memory');
  }

  /// Gets the current number of installed models
  ///
  /// Useful for debugging or telemetry.
  /// Not part of ModelRepository interface.
  int get count => _models.length;
}

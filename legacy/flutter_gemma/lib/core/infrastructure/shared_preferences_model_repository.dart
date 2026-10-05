import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// Model repository using SharedPreferences for persistence
///
/// Features:
/// - Stores model metadata as JSON
/// - Key format: 'model_{modelId}'
/// - Index key: 'model_index' (list of all model IDs)
/// - Atomic operations with transaction-like updates
class SharedPreferencesModelRepository implements ModelRepository {
  static const String _keyPrefix = 'model_';
  static const String _indexKey = 'model_index';

  final Future<SharedPreferences> Function() _prefsProvider;

  SharedPreferencesModelRepository({
    Future<SharedPreferences> Function()? prefsProvider,
  }) : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  @override
  Future<void> saveModel(ModelInfo info) async {
    final prefs = await _prefsProvider();

    // Save model metadata
    final key = _makeKey(info.id);
    final json = jsonEncode(info.toJson());
    await prefs.setString(key, json);

    // Update index
    await _addToIndex(prefs, info.id);
  }

  @override
  Future<ModelInfo?> loadModel(String id) async {
    final prefs = await _prefsProvider();
    final key = _makeKey(id);
    final json = prefs.getString(key);

    if (json == null) return null;

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return ModelInfo.fromJson(map);
    } catch (e) {
      // Invalid JSON, remove corrupted entry
      await prefs.remove(key);
      await _removeFromIndex(prefs, id);
      return null;
    }
  }

  @override
  Future<void> deleteModel(String id) async {
    final prefs = await _prefsProvider();
    final key = _makeKey(id);

    await prefs.remove(key);
    await _removeFromIndex(prefs, id);
  }

  @override
  Future<List<ModelInfo>> listInstalled() async {
    final prefs = await _prefsProvider();
    final index = await _getIndex(prefs);

    final models = <ModelInfo>[];
    for (final id in index) {
      final model = await loadModel(id);
      if (model != null) {
        models.add(model);
      }
    }

    return models;
  }

  @override
  Future<bool> isInstalled(String id) async {
    final prefs = await _prefsProvider();
    final key = _makeKey(id);
    return prefs.containsKey(key);
  }

  /// Creates storage key for model ID
  String _makeKey(String id) => '$_keyPrefix$id';

  /// Gets list of all model IDs from index
  Future<List<String>> _getIndex(SharedPreferences prefs) async {
    final json = prefs.getString(_indexKey);
    if (json == null) return [];

    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<String>();
    } catch (e) {
      // Corrupted index, reset
      await prefs.remove(_indexKey);
      return [];
    }
  }

  /// Adds model ID to index
  Future<void> _addToIndex(SharedPreferences prefs, String id) async {
    final index = await _getIndex(prefs);

    if (!index.contains(id)) {
      index.add(id);
      final json = jsonEncode(index);
      await prefs.setString(_indexKey, json);
    }
  }

  /// Removes model ID from index
  Future<void> _removeFromIndex(SharedPreferences prefs, String id) async {
    final index = await _getIndex(prefs);

    if (index.remove(id)) {
      final json = jsonEncode(index);
      await prefs.setString(_indexKey, json);
    }
  }
}

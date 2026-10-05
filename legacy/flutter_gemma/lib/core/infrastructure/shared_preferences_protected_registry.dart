import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma/core/services/protected_files_registry.dart';

/// Protected files registry using SharedPreferences
///
/// Features:
/// - Tracks files protected from cleanup
/// - Stores external file path mappings
/// - Key format: 'protected_files' (set of filenames)
/// - External paths: 'external_paths' (map of filename -> path)
class SharedPreferencesProtectedRegistry implements ProtectedFilesRegistry {
  static const String _protectedKey = 'protected_files';
  static const String _externalPathsKey = 'external_paths';

  final Future<SharedPreferences> Function() _prefsProvider;

  SharedPreferencesProtectedRegistry({
    Future<SharedPreferences> Function()? prefsProvider,
  }) : _prefsProvider = prefsProvider ?? SharedPreferences.getInstance;

  @override
  Future<void> protect(String filename) async {
    final prefs = await _prefsProvider();
    final files = await _getProtectedFiles(prefs);

    if (!files.contains(filename)) {
      files.add(filename);
      await _saveProtectedFiles(prefs, files);
    }
  }

  @override
  Future<void> unprotect(String filename) async {
    final prefs = await _prefsProvider();
    final files = await _getProtectedFiles(prefs);

    if (files.remove(filename)) {
      await _saveProtectedFiles(prefs, files);
    }
  }

  @override
  Future<bool> isProtected(String filename) async {
    final prefs = await _prefsProvider();
    final files = await _getProtectedFiles(prefs);
    return files.contains(filename);
  }

  @override
  Future<List<String>> getProtectedFiles() async {
    final prefs = await _prefsProvider();
    final files = await _getProtectedFiles(prefs);
    return files.toList();
  }

  @override
  Future<void> clearAll() async {
    final prefs = await _prefsProvider();
    await prefs.remove(_protectedKey);
    await prefs.remove(_externalPathsKey);
  }

  @override
  Future<void> registerExternalPath(
    String filename,
    String externalPath,
  ) async {
    final prefs = await _prefsProvider();
    final paths = await _getExternalPaths(prefs);

    paths[filename] = externalPath;
    await _saveExternalPaths(prefs, paths);
  }

  @override
  Future<String?> getExternalPath(String filename) async {
    final prefs = await _prefsProvider();
    final paths = await _getExternalPaths(prefs);
    return paths[filename];
  }

  /// Gets set of protected filenames
  Future<Set<String>> _getProtectedFiles(SharedPreferences prefs) async {
    final json = prefs.getString(_protectedKey);
    if (json == null) return {};

    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list.cast<String>().toSet();
    } catch (e) {
      // Corrupted data, reset
      await prefs.remove(_protectedKey);
      return {};
    }
  }

  /// Saves set of protected filenames
  Future<void> _saveProtectedFiles(
    SharedPreferences prefs,
    Set<String> files,
  ) async {
    final json = jsonEncode(files.toList());
    await prefs.setString(_protectedKey, json);
  }

  /// Gets map of external paths
  Future<Map<String, String>> _getExternalPaths(SharedPreferences prefs) async {
    final json = prefs.getString(_externalPathsKey);
    if (json == null) return {};

    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.cast<String, String>();
    } catch (e) {
      // Corrupted data, reset
      await prefs.remove(_externalPathsKey);
      return {};
    }
  }

  /// Saves map of external paths
  Future<void> _saveExternalPaths(
    SharedPreferences prefs,
    Map<String, String> paths,
  ) async {
    final json = jsonEncode(paths);
    await prefs.setString(_externalPathsKey, json);
  }
}

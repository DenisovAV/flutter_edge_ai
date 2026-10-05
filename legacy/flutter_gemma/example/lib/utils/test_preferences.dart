import 'package:shared_preferences/shared_preferences.dart';

/// Isolated test data storage with explicit prefix to avoid conflicts with plugin data
/// ONLY used for "interrupt and restart" test that requires persistence across app kills
class TestPreferences {
  static const _prefix = '__test_data__';

  // Test stage tracking
  static Future<void> setTestStage(String stage) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}stage', stage);
  }

  static Future<String?> getTestStage() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefix}stage');
  }

  // Test URL
  static Future<void> setTestUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}url', url);
  }

  static Future<String?> getTestUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefix}url');
  }

  // Test filename
  static Future<void> setTestFilename(String filename) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}filename', filename);
  }

  static Future<String?> getTestFilename() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefix}filename');
  }

  // Test filepath
  static Future<void> setTestFilepath(String filepath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}filepath', filepath);
  }

  static Future<String?> getTestFilepath() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('${_prefix}filepath');
  }

  // Progress before kill
  static Future<void> setProgressBefore(int progress) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}progress_before', progress);
  }

  static Future<int?> getProgressBefore() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('${_prefix}progress_before');
  }

  // Partial file size
  static Future<void> setPartialSize(int size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('${_prefix}partial_size', size);
  }

  static Future<int?> getPartialSize() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt('${_prefix}partial_size');
  }

  // Interrupted download tracking
  static Future<void> setInterruptedDownload(String url, String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_prefix}interrupted_url', url);
    await prefs.setString('${_prefix}interrupted_path', path);
  }

  static Future<(String?, String?)> getInterruptedDownload() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('${_prefix}interrupted_url');
    final path = prefs.getString('${_prefix}interrupted_path');
    return (url, path);
  }

  static Future<void> clearInterruptedDownload() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('${_prefix}interrupted_url');
    await prefs.remove('${_prefix}interrupted_path');
  }

  /// Clear all test data
  static Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final key in keys) {
      await prefs.remove(key);
    }
  }
}

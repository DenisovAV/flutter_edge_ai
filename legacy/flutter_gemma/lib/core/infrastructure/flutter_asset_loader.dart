import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/core/services/asset_loader.dart';
import 'package:large_file_handler/large_file_handler.dart';

/// Flutter asset loader using LargeFileHandler plugin
///
/// Features:
/// - Loads assets using native platform code (iOS/Android)
/// - Handles LARGE files efficiently (290MB+) without loading into memory
/// - Copies files in chunks, avoiding memory issues
/// - Works on all platforms (Android, iOS, Web)
class FlutterAssetLoader implements AssetLoader {
  final _handler = LargeFileHandler();

  @override
  Future<Uint8List> loadAsset(String path) async {
    // Used as the desktop fallback in AssetSourceHandler when
    // large_file_handler has no plugin implementation (#250 Mode 2).
    // rootBundle.load() works on all platforms including macOS / Windows /
    // Linux desktop. Loads the whole asset into memory — fine for the small
    // models that are typically bundled (large models go through
    // copyAssetToFile which streams via large_file_handler).
    final byteData = await rootBundle.load(path);
    return byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
  }

  /// Copies asset file directly to target path using LargeFileHandler
  /// This is the CORRECT way to handle large files
  Future<void> copyAssetToFile(String assetPath, String targetPath) {
    // Do NOT wrap exceptions: callers (e.g. AssetSourceHandler) match by type
    // — wrapping MissingPluginException in a generic Exception would defeat
    // the desktop fallback path (#250).
    return _handler.copyAssetToLocalStorage(
      assetName: assetPath,
      targetPath: targetPath,
    );
  }

  /// Copies asset with progress tracking
  Stream<int> copyAssetToFileWithProgress(String assetPath, String targetPath) {
    return _handler.copyAssetToLocalStorageWithProgress(
      assetName: assetPath,
      targetPath: targetPath,
    );
  }
}

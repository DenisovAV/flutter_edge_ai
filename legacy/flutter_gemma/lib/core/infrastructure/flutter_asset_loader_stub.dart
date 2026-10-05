/// Stub implementation for platforms where dart:io is not available (web)
/// This file is used when large_file_handler cannot be imported
library;

import 'dart:typed_data';
import 'package:flutter_gemma/core/services/asset_loader.dart';

/// Stub class - should never be instantiated on web platform
class FlutterAssetLoader implements AssetLoader {
  @override
  Future<Uint8List> loadAsset(String path) => throw UnsupportedError(
    'FlutterAssetLoader is not available on this platform',
  );

  Future<void> copyAssetToFile(String assetPath, String targetPath) =>
      throw UnsupportedError(
        'FlutterAssetLoader is not available on this platform',
      );

  Stream<int> copyAssetToFileWithProgress(
    String assetPath,
    String targetPath,
  ) => throw UnsupportedError(
    'FlutterAssetLoader is not available on this platform',
  );
}

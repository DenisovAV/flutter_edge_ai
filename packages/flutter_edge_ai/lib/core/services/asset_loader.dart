import 'dart:typed_data';

/// Abstraction for loading Flutter assets
/// Platform-specific implementations handle asset loading differently
///
/// Platform implementations:
/// - FlutterAssetLoader: uses rootBundle for Flutter apps
/// - WebAssetLoader: uses fetch API for web
/// - TestAssetLoader: loads from test fixtures for testing
abstract interface class AssetLoader {
  /// Loads an asset as bytes from the given path
  ///
  /// The path should be relative to the assets directory
  /// Example: 'models/demo.bin' or 'assets/models/demo.bin'
  ///
  /// Throws:
  /// - [AssetNotFoundException] if asset doesn't exist
  /// - [Exception] for other loading errors
  Future<Uint8List> loadAsset(String path);
}

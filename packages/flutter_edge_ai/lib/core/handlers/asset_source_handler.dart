import 'package:flutter/services.dart';
import 'package:flutter_edge_ai/core/domain/model_source.dart';
import 'package:flutter_edge_ai/core/handlers/source_handler.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/core/services/asset_loader.dart';
import 'package:flutter_edge_ai/core/services/file_system_service.dart';
import 'package:flutter_edge_ai/core/services/model_repository.dart';
import 'package:flutter_edge_ai/core/infrastructure/flutter_asset_loader_stub.dart'
    if (dart.library.io) 'package:flutter_edge_ai/core/infrastructure/flutter_asset_loader.dart';
import 'package:path/path.dart' as path;

/// Handles installation of models from Flutter assets
///
/// Features:
/// - Loads assets using AssetLoader (supports web and mobile)
/// - Copies asset data to app documents directory
/// - Normalizes asset paths (handles assets/ prefix automatically)
/// - Single-step progress (no chunked loading for assets)
class AssetSourceHandler implements SourceHandler {
  final AssetLoader assetLoader;
  final FileSystemService fileSystem;
  final ModelRepository repository;

  AssetSourceHandler({
    required this.assetLoader,
    required this.fileSystem,
    required this.repository,
  });

  @override
  bool supports(ModelSource source) => source is AssetSource;

  /// Whether the streamed large_file_handler copy lands where models are read.
  bool get _streamsIntoModelDirectory => switch (assetLoader) {
    final FlutterAssetLoader loader => loader.copiesIntoModelDirectory,
    _ => false,
  };

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    if (source is! AssetSource) {
      throw ArgumentError('AssetSourceHandler only supports AssetSource');
    }

    final filename = targetFilename ?? path.basename(source.path);
    // ignore: deprecated_member_use_from_same_package
    final targetPath = await fileSystem.getWriteTargetPath(filename);

    // LargeFileHandler's `targetName` parameter is *just* a filename — the
    // plugin prepends app docs dir itself. We keep the bare filename here.
    // Only Android and iOS store models in that same Documents directory; a
    // desktop build keeps them in app support (see getWriteTargetPath), so
    // the streamed copy would land where nothing reads it (see
    // FlutterAssetLoader.copiesIntoModelDirectory). Desktop, and any platform
    // without the plugin (MissingPluginException), load the asset into memory
    // and write it to targetPath instead.
    //
    // Lookup keys differ between paths:
    // - `pathForLookupKey` (no `assets/` prefix) for the native channel call
    // - `normalizedPath` (with `assets/` prefix) for the Flutter rootBundle
    //   fallback (#250 Mode 2)
    if (_streamsIntoModelDirectory) {
      try {
        await (assetLoader as FlutterAssetLoader).copyAssetToFile(
          source.pathForLookupKey,
          filename,
        );
      } on MissingPluginException {
        final assetData = await assetLoader.loadAsset(source.normalizedPath);
        await fileSystem.writeFile(targetPath, assetData);
      }
    } else {
      final assetData = await assetLoader.loadAsset(source.normalizedPath);
      await fileSystem.writeFile(targetPath, assetData);
    }

    final sizeBytes = await fileSystem.getFileSize(targetPath);
    assertInstalledFilePresent(sizeBytes, targetPath);

    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async* {
    if (source is! AssetSource) {
      throw ArgumentError('AssetSourceHandler only supports AssetSource');
    }

    final filename = targetFilename ?? path.basename(source.path);
    // ignore: deprecated_member_use_from_same_package
    final targetPath = await fileSystem.getWriteTargetPath(filename);

    if (_streamsIntoModelDirectory) {
      try {
        await for (final progress
            in (assetLoader as FlutterAssetLoader).copyAssetToFileWithProgress(
              source.pathForLookupKey,
              filename,
            )) {
          yield progress;
        }
      } on MissingPluginException {
        final assetData = await assetLoader.loadAsset(source.normalizedPath);
        await fileSystem.writeFile(targetPath, assetData);
        yield 100;
      }
    } else {
      final assetData = await assetLoader.loadAsset(source.normalizedPath);
      await fileSystem.writeFile(targetPath, assetData);
      yield 100;
    }

    final sizeBytes = await fileSystem.getFileSize(targetPath);
    assertInstalledFilePresent(sizeBytes, targetPath);

    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  bool supportsResume(ModelSource source) {
    return false;
  }
}

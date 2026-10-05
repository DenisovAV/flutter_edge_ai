import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Handles installation of models from Flutter assets on web platform
///
/// On web, Flutter assets are served by the web server at paths like:
/// - assets/models/gemma.task
/// - assets/lora/weights.bin
///
/// This handler:
/// 1. Registers the asset URL with WebFileSystemService
/// 2. Saves metadata to ModelRepository
/// 3. MediaPipe loads directly from the URL (no file copy)
///
/// Features:
/// - No file copying (web has no local file system)
/// - Direct URL registration for MediaPipe
/// - Simulated progress for UX consistency
/// - Instant "installation" (assets already bundled)
///
/// Platform: Web only
class WebAssetSourceHandler implements SourceHandler {
  final WebFileSystemService fileSystem;
  final ModelRepository repository;
  final WebCacheService cacheService;

  WebAssetSourceHandler({
    required this.fileSystem,
    required this.repository,
    required this.cacheService,
  });

  @override
  bool supports(ModelSource source) => source is AssetSource;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    // Delegate to installWithProgress, ignore progress events
    await for (final _ in installWithProgress(
      source,
      cancelToken: cancelToken,
      targetFilename: targetFilename,
      modelType: modelType,
    )) {
      // Ignore progress updates
    }
  }

  @override
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async* {
    if (source is! AssetSource) {
      throw ArgumentError('WebAssetSourceHandler only supports AssetSource');
    }

    final filename = targetFilename ?? path.basename(source.path);
    final cacheKey = source.normalizedPath; // Already has 'assets/' prefix

    try {
      // Use unified caching helper (cache key is already normalized, no '?' added)
      yield* cacheService.getOrCacheAndRegisterWithProgress(
        cacheKey: cacheKey,
        loader: (onProgress) async {
          gemmaLog(
            '[WebAssetSourceHandler] Loading asset: ${source.normalizedPath}',
          );

          onProgress(0.0);
          final byteData = await rootBundle.load(source.normalizedPath);
          final bytes = byteData.buffer.asUint8List();

          // Validate asset is not empty
          if (bytes.isEmpty) {
            throw StateError(
              'Asset file is empty: ${source.normalizedPath}. '
              'Check that the file exists and is not corrupted.',
            );
          }

          gemmaLog(
            '[WebAssetSourceHandler] Asset loaded: ${bytes.length} bytes',
          );
          onProgress(1.0);

          return bytes;
        },
        targetPath: filename,
      );

      // Save metadata to repository
      // Repository type is selected by ServiceRegistry based on enableCache:
      // - enableCache=true: SharedPreferencesModelRepository (persistent)
      // - enableCache=false: InMemoryModelRepository (ephemeral)
      final modelInfo = ModelInfo(
        id: filename,
        source: source,
        installedAt: DateTime.now(),
        sizeBytes: -1,
        type: modelType,
        hasLoraWeights: false,
      );

      await repository.saveModel(modelInfo);
    } catch (e) {
      gemmaLog('[WebAssetSourceHandler] ❌ Failed to install asset: $e');
      rethrow;
    }
  }

  @override
  bool supportsResume(ModelSource source) {
    // Assets are bundled with the app, no download/resume needed
    return false;
  }
}

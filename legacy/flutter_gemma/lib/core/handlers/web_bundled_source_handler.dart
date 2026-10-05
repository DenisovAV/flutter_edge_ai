import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_js_interop.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Handles installation of models from native bundled resources (WEB PLATFORM)
///
/// On web, bundled resources are served by the web server at paths like:
/// - assets/models/gemma.task
/// - assets/models/lora-weights.bin
///
/// This handler:
/// 1. Constructs the bundled resource URL path
/// 2. Registers the URL with WebFileSystemService
/// 3. Saves metadata to ModelRepository
/// 4. MediaPipe loads directly from the URL (no file copy)
///
/// Features:
/// - No file copying (web has no local file system)
/// - Direct URL registration for MediaPipe
/// - Simulated progress for UX consistency
/// - Instant "installation" (resources already bundled)
///
/// Platform: Web only
class WebBundledSourceHandler implements SourceHandler {
  final WebFileSystemService fileSystem;
  final ModelRepository repository;
  final WebCacheService cacheService;
  final WebJsInterop jsInterop;

  WebBundledSourceHandler({
    required this.fileSystem,
    required this.repository,
    required this.cacheService,
    required this.jsInterop,
  });

  @override
  bool supports(ModelSource source) => source is BundledSource;

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
    if (source is! BundledSource) {
      throw ArgumentError(
        'WebBundledSourceHandler only supports BundledSource',
      );
    }

    final resourceName = source.resourceName;
    final cacheKey = resourceName;
    final targetPath = targetFilename ?? resourceName;

    try {
      // Use unified caching helper
      yield* cacheService.getOrCacheAndRegisterWithProgress(
        cacheKey: cacheKey,
        loader: (onProgress) async {
          gemmaLog(
            '[WebBundledSourceHandler] Fetching bundled resource: $resourceName',
          );

          onProgress(0.0);
          final response = await jsInterop.fetchFile('/$resourceName');

          // Validate resource is not empty
          if (response.data.isEmpty) {
            throw StateError(
              'Bundled resource is empty: $resourceName. '
              'Check that the resource exists in the web bundle.',
            );
          }

          gemmaLog(
            '[WebBundledSourceHandler] Resource fetched: ${response.data.length} bytes',
          );
          onProgress(1.0);

          return response.data;
        },
        targetPath: targetPath,
      );

      // Save metadata to repository
      // Repository type is selected by ServiceRegistry based on enableCache:
      // - enableCache=true: SharedPreferencesModelRepository (persistent)
      // - enableCache=false: InMemoryModelRepository (ephemeral)
      final modelInfo = ModelInfo(
        id: targetPath,
        source: source,
        installedAt: DateTime.now(),
        sizeBytes: -1,
        type: modelType,
        hasLoraWeights: false,
      );

      await repository.saveModel(modelInfo);
    } catch (e) {
      gemmaLog(
        '[WebBundledSourceHandler] ❌ Failed to install bundled resource: $e',
      );
      rethrow;
    }
  }

  @override
  bool supportsResume(ModelSource source) {
    // Bundled resources are always available, no resume needed
    return false;
  }
}

import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/domain/download_exception.dart';
import 'package:flutter_gemma/core/domain/download_error.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_service.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Handles installation of models from network URLs on web platform
///
/// On web, network models are downloaded and optionally cached:
/// - With cache: saved to Cache API, blob URL created, metadata saved
/// - Without cache: blob URL created in memory only, NO metadata saved
///
/// This handler:
/// 1. Downloads model using WebDownloadService (with unified caching)
/// 2. Conditionally saves metadata based on enableCache
/// 3. MediaPipe loads directly from blob URL
///
/// Features:
/// - Cache API persistent storage (optional)
/// - In-memory blob URLs when cache disabled
/// - Simulated progress for UX consistency
/// - Authentication token support (HuggingFace)
///
/// Platform: Web only
class WebNetworkSourceHandler implements SourceHandler {
  final DownloadService downloadService;
  final ModelRepository repository;
  final WebCacheService cacheService;
  final String? huggingFaceToken;

  WebNetworkSourceHandler({
    required this.downloadService,
    required this.repository,
    required this.cacheService,
    this.huggingFaceToken,
  });

  @override
  bool supports(ModelSource source) => source is NetworkSource;

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
    if (source is! NetworkSource) {
      throw ArgumentError(
        'WebNetworkSourceHandler only supports NetworkSource',
      );
    }

    // Extract filename and validate
    final uri = Uri.parse(source.url);
    final filename = targetFilename ?? path.basename(uri.path);
    if (filename.isEmpty) {
      throw ArgumentError('URL must contain a filename: ${source.url}');
    }

    // Get token: prefer from source, fallback to constructor
    final token =
        source.authToken ??
        (_isHuggingFaceUrl(source.url) ? huggingFaceToken : null);

    try {
      // Download with progress tracking (uses unified caching helper internally)
      await for (final progress in downloadService.downloadWithProgress(
        source.url,
        filename, // targetPath is just filename on web
        token: token,
        maxRetries: 10, // Explicit (matches ServiceRegistry default)
        cancelToken: cancelToken,
      )) {
        yield progress;
      }

      // Save metadata to repository
      // Repository type is selected by ServiceRegistry based on enableCache:
      // - enableCache=true: SharedPreferencesModelRepository (persistent)
      // - enableCache=false: InMemoryModelRepository (ephemeral)
      final modelInfo = ModelInfo(
        id: filename,
        source: source,
        installedAt: DateTime.now(),
        sizeBytes: -1, // Web doesn't track size (blob URL)
        type: modelType,
        hasLoraWeights: false,
      );

      await repository.saveModel(modelInfo);
    } on DownloadCancelledException {
      gemmaLog('[WebNetworkSourceHandler] ⏸️  Installation cancelled');
      rethrow;
    } on DownloadException catch (e) {
      final errorMsg = switch (e.error) {
        UnauthorizedError() => 'Unauthorized (401) - authentication required',
        ForbiddenError() => 'Forbidden (403) - invalid token or gated model',
        NotFoundError() => 'Not Found (404) - resource not found',
        RateLimitedError() => 'Rate Limited (429) - too many requests',
        ServerError(:final statusCode) => 'Server Error ($statusCode)',
        NetworkError(:final message) => 'Network Error: $message',
        CanceledError() => 'Canceled',
        UnknownError(:final message) => 'Unknown Error: $message',
      };
      gemmaLog('[WebNetworkSourceHandler] ❌ Download failed: $errorMsg');
      rethrow;
    } catch (e) {
      gemmaLog(
        '[WebNetworkSourceHandler] ❌ Failed to install network model: $e',
      );
      rethrow;
    }
  }

  @override
  bool supportsResume(ModelSource source) {
    if (source is! NetworkSource) return false;
    // Web doesn't support resume (downloads are fast with caching)
    return false;
  }

  /// Checks if URL is a HuggingFace URL that may require authentication
  bool _isHuggingFaceUrl(String url) {
    final uri = Uri.parse(url);
    return uri.host.contains('huggingface.co');
  }
}

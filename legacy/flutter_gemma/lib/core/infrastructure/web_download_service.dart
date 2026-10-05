import 'dart:async';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/domain/download_exception.dart';
import 'package:flutter_gemma/core/domain/download_error.dart';
import 'package:flutter_gemma/core/domain/web_storage_mode.dart';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_js_interop.dart';
import 'package:flutter_gemma/core/infrastructure/blob_url_manager.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_service.dart';
import 'package:flutter_gemma/core/infrastructure/web_opfs_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/web_opfs_service.dart';
import 'package:flutter_gemma/core/infrastructure/url_utils.dart';

/// JavaScript AbortController for cancelling fetch requests
@JS('AbortController')
extension type JSAbortController._(JSObject _) implements JSObject {
  external factory JSAbortController();
  external JSObject get signal;
  external void abort();
}

/// Web implementation of DownloadService
///
/// Supports multiple storage modes:
/// - cacheApi: Cache API with Blob URLs (for models <2GB)
/// - streaming: OPFS with streaming (for models >2GB)
/// - none: No caching (ephemeral)
///
/// Features:
/// - URL registration (cacheApi/none modes)
/// - OPFS streaming download (streaming mode)
/// - Progress tracking for all modes
/// - Authentication token support
///
/// Design rationale:
/// - Cache API mode: Fast for small models, browser handles caching
/// - Streaming mode: Bypasses ArrayBuffer limits for large models
/// - OPFS provides persistent storage with streaming support
///
/// Platform: Web only
class WebDownloadService implements DownloadService {
  final WebFileSystemService _fileSystem;
  final WebJsInterop _jsInterop;
  final BlobUrlManager _blobUrlManager;
  final WebCacheService cacheService;
  final WebOPFSService? opfsService;
  final WebStorageMode webStorageMode;

  WebDownloadService(
    this._fileSystem,
    this._jsInterop,
    this._blobUrlManager,
    this.cacheService, {
    this.opfsService,
    this.webStorageMode = WebStorageMode.cacheApi,
  });

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    // Delegate to downloadWithProgress, ignore progress events
    await for (final _ in downloadWithProgress(
      url,
      targetPath,
      token: token,
      cancelToken: cancelToken,
    )) {
      // Ignore progress updates
    }
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground, // Ignored on web - no foreground service concept
  }) async* {
    // Check cancellation before starting
    cancelToken?.throwIfCancelled();

    // STREAMING MODE: Use OPFS for large models
    if (webStorageMode == WebStorageMode.streaming) {
      if (opfsService == null) {
        gemmaLog('[WARNING] OPFS not available, falling back to cacheApi mode');
        gemmaLog(
          '[WARNING] Large models (>2GB) may fail with ArrayBuffer limit',
        );
        gemmaLog(
          '[WARNING] Use a browser that supports OPFS (Chrome 86+, Edge 86+, Safari 15.2+)',
        );
        // Fall back to cache API mode
        yield* _downloadToCache(
          url,
          targetPath,
          token: token,
          cancelToken: cancelToken,
        );
        return;
      }
      yield* _downloadToOPFS(
        url,
        targetPath,
        token: token,
        cancelToken: cancelToken,
      );
      return;
    }

    // CACHE API / NONE MODES: Use blob URLs
    yield* _downloadToCache(
      url,
      targetPath,
      token: token,
      cancelToken: cancelToken,
    );
  }

  /// Download to cache (Cache API or None mode)
  Stream<int> _downloadToCache(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async* {
    // Normalize URL for cache lookup
    final normalizedUrl = UrlUtils.normalizeUrl(url);

    // Check cache first (works for both public and private models)
    final cachedBlobUrl = await cacheService.getCachedBlobUrl(normalizedUrl);
    if (cachedBlobUrl != null) {
      gemmaLog('✅ Model found in cache (skipping download): $url');

      // Register cached blob URL
      _fileSystem.registerUrl(targetPath, cachedBlobUrl);
      _blobUrlManager.track(targetPath, cachedBlobUrl);

      // Simulate instant progress
      yield 100;
      return;
    }

    // Not in cache - proceed with download
    gemmaLog('📥 Model not in cache, downloading: $url');

    if (token == null) {
      // PUBLIC PATH: Download and cache
      yield* _downloadPublic(url, normalizedUrl, targetPath, cancelToken);
    } else {
      // PRIVATE PATH: Fetch with auth
      gemmaLog(
        'WebDownloadService: Starting authenticated download for $targetPath',
      );

      yield* _downloadWithAuth(
        url,
        normalizedUrl,
        targetPath,
        token,
        cancelToken,
      );
    }
  }

  /// Download to OPFS (streaming mode for large models >2GB)
  ///
  /// Uses AbortController for proper cancellation of fetch requests.
  Stream<int> _downloadToOPFS(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async* {
    StreamController<int>? streamController;
    JSAbortController? abortController;

    try {
      cancelToken?.throwIfCancelled();

      gemmaLog('[WebDownloadService] 🚀 OPFS streaming download: $targetPath');

      // Check if already in OPFS
      final isAlreadyCached = await opfsService!.isModelCached(targetPath);
      // ignore: dead_code
      if (isAlreadyCached) {
        gemmaLog('[WebDownloadService] ✅ Model already in OPFS: $targetPath');

        // Register as OPFS file (special marker for getStreamReader)
        _fileSystem.registerUrl(targetPath, 'opfs://$targetPath');

        yield 100;
        return;
      }

      // Create AbortController for cancellation support
      abortController = JSAbortController();

      // Download to OPFS with progress tracking
      streamController = StreamController<int>();

      // Start download in background with abort signal
      // ignore: receiver_of_type_never
      opfsService!
          .downloadToOPFS(
            url,
            targetPath,
            authToken: token,
            onProgress: (percentage) {
              if (streamController != null && !streamController.isClosed) {
                streamController.add(percentage);
              }
            },
            abortSignal: abortController.signal,
          )
          .then((_) {
            gemmaLog(
              '[WebDownloadService] ✅ OPFS download complete: $targetPath',
            );

            // Register as OPFS file
            _fileSystem.registerUrl(targetPath, 'opfs://$targetPath');

            if (streamController != null && !streamController.isClosed) {
              streamController.close();
            }
          })
          .catchError((error) {
            gemmaLog('[WebDownloadService] ❌ OPFS download failed: $error');
            if (streamController != null && !streamController.isClosed) {
              streamController.addError(error);
              streamController.close();
            }
          });

      // Yield progress events
      await for (final progress in streamController.stream) {
        cancelToken?.throwIfCancelled();
        yield progress;
      }
    } on DownloadCancelledException {
      // Abort the JS fetch request
      abortController?.abort();
      gemmaLog('[WebDownloadService] 🛑 OPFS download cancelled: $targetPath');
      rethrow;
    } catch (e) {
      gemmaLog('[WebDownloadService] ❌ OPFS download error: $e');
      throw DownloadException(
        DownloadError.unknown('Failed to download to OPFS: $e'),
      );
    } finally {
      // Cleanup StreamController
      if (streamController != null && !streamController.isClosed) {
        streamController.close();
      }
    }
  }

  /// Download public model (no auth) and cache
  Stream<int> _downloadPublic(
    String url,
    String normalizedUrl,
    String targetPath,
    CancelToken? cancelToken,
  ) async* {
    try {
      cancelToken?.throwIfCancelled();

      // Use unified caching helper with progress
      yield* cacheService.getOrCacheAndRegisterWithProgress(
        cacheKey: normalizedUrl,
        loader: (onProgress) async {
          cancelToken?.throwIfCancelled();

          gemmaLog('[WebDownloadService] 📥 Downloading public model: $url');

          // Note: fetchFile doesn't support progress callbacks yet
          final response = await _jsInterop.fetchFile(url);

          gemmaLog(
            '[WebDownloadService] ✅ Downloaded: ${response.data.length} bytes',
          );
          onProgress(1.0);

          return response.data;
        },
        targetPath: targetPath,
      );

      // Track blob URL for cleanup (works with or without cache)
      final blobUrl = _fileSystem.getUrl(targetPath);
      if (blobUrl != null) {
        _blobUrlManager.track(targetPath, blobUrl);
      }

      gemmaLog('[WebDownloadService] ✅ Public model downloaded and cached');
    } on DownloadCancelledException {
      rethrow;
    } catch (e) {
      gemmaLog('[WebDownloadService] ❌ Public download failed: $e');
      throw DownloadException(
        DownloadError.unknown('Failed to download public model: $e'),
      );
    }
  }

  Stream<int> _downloadWithAuth(
    String url,
    String normalizedUrl,
    String targetPath,
    String authToken,
    CancelToken? cancelToken,
  ) async* {
    try {
      cancelToken?.throwIfCancelled();

      gemmaLog(
        'WebDownloadService: Starting authenticated download for $targetPath',
      );

      // Use unified caching helper with auth download
      yield* cacheService.getOrCacheAndRegisterWithProgress(
        cacheKey: normalizedUrl,
        loader: (onProgress) async {
          cancelToken?.throwIfCancelled();

          gemmaLog(
            '[WebDownloadService] 📥 Downloading authenticated model: $url',
          );

          // Create completer for async result
          final completer = Completer<Uint8List>();

          // Start download with streaming progress
          _jsInterop
              .fetchWithAuth(
                url,
                authToken,
                onProgress: onProgress, // Pass progress callback directly
              )
              .then((response) {
                gemmaLog(
                  '[WebDownloadService] ✅ Downloaded: ${response.data.length} bytes',
                );
                completer.complete(response.data);
              })
              .catchError((error) {
                completer.completeError(error);
              });

          return await completer.future;
        },
        targetPath: targetPath,
      );

      // Track blob URL for cleanup (works with or without cache)
      final blobUrl = _fileSystem.getUrl(targetPath);
      if (blobUrl != null) {
        _blobUrlManager.track(targetPath, blobUrl);
      }

      gemmaLog(
        '[WebDownloadService] ✅ Authenticated model downloaded and cached',
      );
    } on DownloadCancelledException {
      gemmaLog('WebDownloadService: Download cancelled for $targetPath');
      rethrow;
    } catch (e) {
      gemmaLog('[WebDownloadService] ❌ Authenticated download failed: $e');
      throw DownloadException(
        DownloadError.unknown('Failed to download authenticated model: $e'),
      );
    }
  }
}

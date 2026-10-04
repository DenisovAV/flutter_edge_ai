/// Web-platform service factory.
/// This file is only compiled on web platform.
/// Uses dart:js_interop for browser-based downloads.
library;

import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/web_storage_mode.dart';
import '../../infrastructure/web_download_service.dart';
import '../../infrastructure/web_file_system_service.dart';
import '../../infrastructure/web_js_interop.dart';
import '../../infrastructure/blob_url_manager.dart';
import '../../infrastructure/web_cache_service.dart';
import '../../infrastructure/web_cache_interop_stub.dart'
    if (dart.library.js_interop) '../../infrastructure/web_cache_interop.dart';
import '../../infrastructure/web_opfs_interop_stub.dart'
    if (dart.library.js_interop) '../../infrastructure/web_opfs_service.dart';
import '../../services/download_service.dart';
import '../../services/file_system_service.dart';

/// Creates the default DownloadService for web platform
///
/// Web platform uses WebDownloadService with authenticated fetch
/// support via WebJsInterop, blob URL management, and Cache API
/// or OPFS for persistent model storage.
///
/// The [fileSystem] parameter is required on web platform (must be WebFileSystemService).
/// The [webStorageMode] parameter controls storage strategy:
/// - cacheApi: Cache API with Blob URLs (for models <2GB)
/// - streaming: OPFS with streaming (for models >2GB)
/// - none: No caching (ephemeral)
/// The [prefs] parameter must be pre-initialized SharedPreferences instance.
DownloadService createDownloadService(
  FileSystemService fileSystem,
  WebStorageMode webStorageMode,
  SharedPreferences prefs,
) {
  // Cast to WebFileSystemService (guaranteed by ServiceRegistry validation)
  final webFs = fileSystem as WebFileSystemService;

  final jsInteropInstance = WebJsInterop();
  final blobManager = BlobUrlManager(jsInteropInstance, webFs);

  // Link cleanup callback
  webFs.setOnBlobUrlRemoved(blobManager.cleanupByUrl);

  // Create WebCacheService with pre-initialized SharedPreferences
  // enableCache is true for both cacheApi and streaming modes
  final enableCache = webStorageMode != WebStorageMode.none;
  final cacheService = WebCacheService(
    WebCacheInterop(),
    prefs,
    webFs,
    enableCache: enableCache,
  );

  // Create OPFS service for streaming mode
  final opfsService = webStorageMode == WebStorageMode.streaming
      ? WebOPFSService.fromWindow()
      : null;

  return WebDownloadService(
    webFs,
    jsInteropInstance,
    blobManager,
    cacheService,
    opfsService: opfsService,
    webStorageMode: webStorageMode,
  );
}

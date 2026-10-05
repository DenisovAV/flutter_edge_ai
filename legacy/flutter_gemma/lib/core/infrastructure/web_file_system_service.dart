import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/services/file_system_service.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Web implementation of FileSystemService using URL-based storage
///
/// This implementation doesn't actually store files locally (web has no
/// local file system). Instead, it maintains a registry of URLs that
/// MediaPipe can fetch directly.
///
/// Features:
/// - URL registry for model paths (in-memory)
/// - No actual file downloads (MediaPipe fetches URLs directly)
/// - Asset path resolution for web
/// - Memory-efficient (stores URLs, not file data)
///
/// Platform: Web only
class WebFileSystemService implements FileSystemService {
  // Maps filename -> URL (either network URL or blob URL)
  final Map<String, String> _urlMappings = {};
  // Tracks which URLs are blob URLs (need revocation on cleanup)
  final Map<String, bool> _isBlobUrl = {};

  @override
  Future<void> writeFile(String path, Uint8List data) async {
    // On web, we can't write files to local file system
    // Instead, we create a blob URL via WebJsInterop (handled by WebDownloadService)
    // For now, this is primarily used for registration
    gemmaLog(
      'WebFileSystemService: writeFile called for $path (${data.length} bytes)',
    );

    // Store a marker that this file exists
    // Note: Actual blob URL creation is handled by WebDownloadService + WebJsInterop
    // This method is primarily for registering already-created blob URLs
    _urlMappings[path] = 'blob:$path';
    _isBlobUrl[path] = true; // Mark as blob URL for future cleanup
  }

  @override
  Future<Uint8List> readFile(String path) async {
    // Web can't read files from local file system
    // This would typically be used to read downloaded files,
    // but on web MediaPipe loads directly from URLs
    throw UnsupportedError(
      'Reading files is not supported on web platform. '
      'MediaPipe loads models directly from URLs.',
    );
  }

  @override
  Future<void> deleteFile(String path) async {
    // Remove from registry
    final url = _urlMappings.remove(path);
    final wasBlob = _isBlobUrl.remove(path);

    // Blob URL revocation is handled by BlobUrlManager (integrated via WebDownloadService)
    // The cleanup callback (_onBlobUrlRemoved) will be invoked if this is a blob URL
    if (url != null && wasBlob == true) {
      gemmaLog('WebFileSystemService: Triggering blob URL cleanup for $path');
      _onBlobUrlRemoved?.call(url);
    }

    if (url != null) {
      gemmaLog('WebFileSystemService: Removed URL mapping for $path');
    }
  }

  @override
  Future<bool> fileExists(String path) async {
    // Check if URL is registered for this path
    return _urlMappings.containsKey(path);
  }

  @override
  Future<int> getFileSize(String path) async {
    // On web, we can't determine file size without fetching
    // Return 0 to indicate unknown size
    // The actual file will be fetched by MediaPipe when needed
    if (!_urlMappings.containsKey(path)) {
      return 0;
    }

    // File exists in registry but size is unknown without HTTP HEAD request
    // Return -1 to indicate "unknown but exists"
    return -1;
  }

  @override
  Future<String> getWriteTargetPath(String filename) async {
    // On web there is no legacy-Documents concept; write and read targets
    // are the same identifier used to look up the URL in _urlMappings.
    return filename;
  }

  @override
  Future<String> getReadTargetPath(String filename) async {
    return filename;
  }

  @Deprecated(
    'Use getReadTargetPath for reads or getWriteTargetPath for writes',
  )
  @override
  Future<String> getTargetPath(String filename) async {
    return filename;
  }

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    // On web, bundled resources are served from web root
    // MediaPipe expects a URL path, not a file system path
    // Use absolute path starting with / to ensure proper resolution
    final assetPath = '/$resourceName';

    gemmaLog(
      'WebFileSystemService: Bundled resource path for $resourceName: $assetPath',
    );

    return assetPath;
  }

  @override
  Future<void> registerExternalFile(
    String filename,
    String externalPath,
  ) async {
    // Register the external path as a URL
    // On web, external paths are URLs
    _urlMappings[filename] = externalPath;

    gemmaLog(
      'WebFileSystemService: Registered external file $filename -> $externalPath',
    );
  }

  @override
  Future<String> getModelStorageDirectory() async {
    throw UnsupportedError(
      'getModelStorageDirectory() is not supported on the web platform. '
      'Web models are stored as URLs, not local files.',
    );
  }

  @override
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename) async {
    // Web has no local filesystem to rename on; the identity change is
    // absorbed by a normal fresh fetch under the new key instead.
    return false;
  }

  /// Registers a URL for a model (web-specific extension)
  ///
  /// This is the primary way to "install" models on web.
  /// The URL is stored and MediaPipe will fetch it when needed.
  ///
  /// Parameters:
  /// - [filename]: Identifier for this model file
  /// - [url]: Network URL where the model can be fetched
  void registerUrl(String filename, String url) {
    _urlMappings[filename] = url;
    _isBlobUrl[filename] = url.startsWith('blob:'); // Auto-detect blob URLs
  }

  /// Gets the URL for a registered model (web-specific extension)
  ///
  /// Returns null if no URL is registered for this filename.
  String? getUrl(String filename) {
    return _urlMappings[filename];
  }

  /// Gets all registered URLs (web-specific extension)
  ///
  /// Useful for debugging and inspection.
  Map<String, String> getAllUrls() {
    return Map.unmodifiable(_urlMappings);
  }

  /// Clears all URL mappings (web-specific extension)
  ///
  /// Useful for testing and cleanup.
  void clearAllUrls() {
    // Blob URL revocation is handled by BlobUrlManager
    // Trigger cleanup callback for all blob URLs
    for (final entry in _urlMappings.entries) {
      if (_isBlobUrl[entry.key] == true) {
        gemmaLog(
          'WebFileSystemService: Triggering blob URL cleanup for ${entry.key}',
        );
        _onBlobUrlRemoved?.call(entry.value);
      }
    }

    _urlMappings.clear();
    _isBlobUrl.clear();
    gemmaLog('WebFileSystemService: Cleared all URL mappings');
  }

  /// Callback for blob URL removal (set by BlobUrlManager)
  void Function(String blobUrl)? _onBlobUrlRemoved;

  void setOnBlobUrlRemoved(void Function(String blobUrl) callback) {
    _onBlobUrlRemoved = callback;
  }

  /// Checks if a URL is a blob URL
  bool isBlobUrl(String url) {
    return url.startsWith('blob:');
  }

  /// Removes a URL registration and notifies cleanup managers.
  ///
  /// For blob URLs, this triggers BlobUrlManager cleanup.
  void unregisterUrl(String filename) {
    final url = _urlMappings.remove(filename);

    if (url != null && isBlobUrl(url)) {
      _onBlobUrlRemoved?.call(url);
    }
  }
}

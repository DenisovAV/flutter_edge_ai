import 'package:flutter_gemma/core/infrastructure/web_js_interop.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';

/// Manages blob URL lifecycle to prevent memory leaks.
///
/// Tracks active blob URLs and ensures they are revoked when no longer needed.
/// Blob URLs hold memory in the browser until explicitly revoked.
class BlobUrlManager {
  final WebJsInterop _jsInterop;

  /// Maps filename to blob URL for tracking
  final Map<String, String> _activeBlobUrls = {};

  BlobUrlManager(this._jsInterop, WebFileSystemService fileSystemService);

  /// Tracks a new blob URL for a model file.
  ///
  /// If a blob URL already exists for this filename, revokes the old one first.
  void track(String filename, String blobUrl) {
    // Clean up old blob URL if exists
    final oldUrl = _activeBlobUrls[filename];
    if (oldUrl != null) {
      _jsInterop.revokeBlobUrl(oldUrl);
    }

    _activeBlobUrls[filename] = blobUrl;
  }

  /// Cleans up a blob URL by filename.
  ///
  /// Called when a model is closed or replaced.
  void cleanup(String filename) {
    final blobUrl = _activeBlobUrls.remove(filename);
    if (blobUrl != null) {
      _jsInterop.revokeBlobUrl(blobUrl);
    }
  }

  /// Cleans up a blob URL directly (callback from WebFileSystemService).
  void cleanupByUrl(String blobUrl) {
    _jsInterop.revokeBlobUrl(blobUrl);

    // Remove from tracking
    _activeBlobUrls.removeWhere((_, url) => url == blobUrl);
  }

  /// Cleans up all blob URLs.
  ///
  /// Should be called on plugin disposal or app termination.
  void cleanupAll() {
    for (final blobUrl in _activeBlobUrls.values) {
      _jsInterop.revokeBlobUrl(blobUrl);
    }
    _activeBlobUrls.clear();
  }

  /// Returns the number of active blob URLs.
  ///
  /// Useful for debugging and testing.
  int get activeBlobCount => _activeBlobUrls.length;

  /// Returns whether a blob URL is being tracked.
  bool isTracking(String blobUrl) => _activeBlobUrls.containsValue(blobUrl);
}

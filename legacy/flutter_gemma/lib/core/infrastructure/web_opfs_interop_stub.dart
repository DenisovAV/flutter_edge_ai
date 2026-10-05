/// Stub for OPFS interop on non-web platforms
///
/// This file is used when compiling for mobile/desktop platforms.
/// The actual implementation is in web_opfs_interop.dart (web only).
library;

/// Stub class for non-web platforms
class WebOPFSService {
  WebOPFSService.fromWindow() {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never isModelCached(String filename) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never getCachedModelSize(String filename) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never downloadToOPFS(
    String url,
    String filename, {
    String? authToken,
    required void Function(int percentage) onProgress,
    dynamic abortSignal,
  }) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never getStreamReader(String filename) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never getStream(String filename) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never deleteModel(String filename) {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never getStorageStats() {
    throw UnsupportedError('OPFS is only supported on web platform');
  }

  Never clearAll() {
    throw UnsupportedError('OPFS is only supported on web platform');
  }
}

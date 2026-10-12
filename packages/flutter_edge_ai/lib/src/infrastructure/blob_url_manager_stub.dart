/// Stub implementation for non-web platforms
class BlobUrlManager {
  BlobUrlManager(dynamic jsInterop, dynamic fileSystemService) {
    throw UnsupportedError('BlobUrlManager is only available on web platform');
  }

  void track(String filename, String blobUrl) {
    throw UnsupportedError('BlobUrlManager is only available on web platform');
  }

  void cleanup(String filename) {
    throw UnsupportedError('BlobUrlManager is only available on web platform');
  }

  void cleanupByUrl(String blobUrl) {
    throw UnsupportedError('BlobUrlManager is only available on web platform');
  }

  void cleanupAll() {
    throw UnsupportedError('BlobUrlManager is only available on web platform');
  }

  int get activeBlobCount => throw UnsupportedError(
    'BlobUrlManager is only available on web platform',
  );

  bool isTracking(String blobUrl) => throw UnsupportedError(
    'BlobUrlManager is only available on web platform',
  );
}

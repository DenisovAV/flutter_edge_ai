/// Stub implementation for non-web platforms
library;

/// Storage quota Dart wrapper
class StorageQuota {
  final int usage;
  final int quota;

  StorageQuota(this.usage, this.quota);

  double get usagePercent => (usage / quota) * 100;
  int get available => quota - usage;

  @override
  String toString() =>
      'StorageQuota(usage: $usage, quota: $quota, percent: ${usagePercent.toStringAsFixed(1)}%)';
}

/// Stub implementation of WebCacheInterop for non-web platforms
class WebCacheInterop {
  WebCacheInterop() {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<bool> has(String cacheName, String url) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<String?> getBlobUrl(String cacheName, String url) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<void> put(String cacheName, String url, dynamic data) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<bool> delete(String cacheName, String url) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<bool> deleteCache(String cacheName) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<List<String>> getAllKeys(String cacheName) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<bool> requestPersistentStorage() {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  Future<StorageQuota> getStorageQuota() {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  void revokeBlobUrl(String blobUrl) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }

  String createBlobUrl(dynamic data) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }
}

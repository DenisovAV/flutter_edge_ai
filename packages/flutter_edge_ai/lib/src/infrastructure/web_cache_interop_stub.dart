/// Stub implementation for non-web platforms
library;

import 'dart:typed_data';

/// Stub of the web model body for non-web platforms.
class WebModelBody {
  WebModelBody(
    this.body, {
    required this.bytesRead,
    this.replayable = false,
    void Function()? abort,
  }) : abort = abort ?? _noAbort;

  static void _noAbort() {}

  factory WebModelBody.ofBytes(Uint8List bytes) {
    throw UnsupportedError('WebModelBody is only available on web platform');
  }

  final Object body;
  final int Function() bytesRead;
  final bool replayable;
  final void Function() abort;

  int get size => bytesRead();
}

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

  Future<void> put(String cacheName, String url, WebModelBody body) {
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

  Future<String> createBlobUrl(WebModelBody body) {
    throw UnsupportedError('WebCacheInterop is only available on web platform');
  }
}

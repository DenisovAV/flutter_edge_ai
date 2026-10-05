import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_gemma/core/infrastructure/web_cache_interop_stub.dart';

/// Stub implementation for non-web platforms
class WebCacheService {
  WebCacheService(
    dynamic cacheInterop,
    dynamic prefs,
    dynamic fileSystem, {
    bool enableCache = true,
  }) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<bool> isCached(String url) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<String?> getCachedBlobUrl(String url) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<void> cacheModel(String url, Uint8List data) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<void> clearCache() {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<bool> requestPersistentStorage() {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<StorageQuota> getStorageQuota() {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<List<String>> getCachedUrls() {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Stream<int> getOrCacheAndRegisterWithProgress({
    required String cacheKey,
    required Future<Uint8List> Function(void Function(double) onProgress)
    loader,
    required String targetPath,
  }) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  Future<String> getOrCacheAndRegister({
    required String cacheKey,
    required Future<Uint8List> Function() loader,
    required String targetPath,
  }) {
    throw UnsupportedError('WebCacheService is only available on web platform');
  }

  bool get enableCache => throw UnsupportedError(
    'WebCacheService is only available on web platform',
  );
}

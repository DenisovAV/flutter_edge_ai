/// JavaScript interop for Cache API
///
/// Provides type-safe wrappers for Cache API operations using dart:js_interop.
/// All operations go through cache_api.js to ensure proper error handling.
library;

import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import '../utils/gemma_log.dart';

/// External JS functions for Cache API
@JS('cacheHas')
external JSPromise<JSBoolean> _cacheHasJS(JSString cacheName, JSString url);

@JS('cacheGetBlobUrl')
external JSPromise<JSString?> _cacheGetBlobUrlJS(
  JSString cacheName,
  JSString url,
);

@JS('cachePut')
external JSPromise<JSAny?> _cachePutJS(
  JSString cacheName,
  JSString url,
  JSUint8Array data,
);

@JS('cacheDelete')
external JSPromise<JSBoolean> _cacheDeleteJS(JSString cacheName, JSString url);

@JS('cacheDeleteCache')
external JSPromise<JSBoolean> _cacheDeleteCacheJS(JSString cacheName);

@JS('cacheGetAllKeys')
external JSPromise<JSArray<JSString>> _cacheGetAllKeysJS(JSString cacheName);

@JS('storageRequestPersistent')
external JSPromise<JSBoolean> _storageRequestPersistentJS();

@JS('storageGetQuota')
external JSPromise<JSStorageQuota> _storageGetQuotaJS();

@JS('blobUrlRevoke')
external void _blobUrlRevokeJS(JSString blobUrl);

/// Storage quota information from JavaScript
extension type JSStorageQuota._(JSObject _) implements JSObject {
  external JSNumber get usage;
  external JSNumber get quota;
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

/// Dart wrapper for Cache API JavaScript functions
class WebCacheInterop {
  /// Check if URL is cached
  Future<bool> has(String cacheName, String url) async {
    try {
      final result = await _cacheHasJS(cacheName.toJS, url.toJS).toDart;
      return result.toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ has failed for $url: $e');
      return false;
    }
  }

  /// Get blob URL from cache
  Future<String?> getBlobUrl(String cacheName, String url) async {
    try {
      final result = await _cacheGetBlobUrlJS(cacheName.toJS, url.toJS).toDart;
      return result?.toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ getBlobUrl failed for $url: $e');
      return null;
    }
  }

  /// Save data to cache
  Future<void> put(String cacheName, String url, Uint8List data) async {
    try {
      await _cachePutJS(cacheName.toJS, url.toJS, data.toJS).toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ put failed for $url: $e');
      rethrow;
    }
  }

  /// Delete cached entry
  Future<bool> delete(String cacheName, String url) async {
    try {
      final result = await _cacheDeleteJS(cacheName.toJS, url.toJS).toDart;
      return result.toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ delete failed for $url: $e');
      return false;
    }
  }

  /// Delete entire cache
  Future<bool> deleteCache(String cacheName) async {
    try {
      final result = await _cacheDeleteCacheJS(cacheName.toJS).toDart;
      return result.toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ deleteCache failed: $e');
      return false;
    }
  }

  /// Get all cached URLs
  Future<List<String>> getAllKeys(String cacheName) async {
    try {
      final result = await _cacheGetAllKeysJS(cacheName.toJS).toDart;
      return result.toDart.map((js) => js.toDart).toList();
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ getAllKeys failed: $e');
      return [];
    }
  }

  /// Request persistent storage
  Future<bool> requestPersistentStorage() async {
    try {
      final result = await _storageRequestPersistentJS().toDart;
      return result.toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ requestPersistentStorage failed: $e');
      return false;
    }
  }

  /// Get storage quota
  Future<StorageQuota> getStorageQuota() async {
    try {
      final result = await _storageGetQuotaJS().toDart;
      return StorageQuota(result.usage.toDartInt, result.quota.toDartInt);
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ getStorageQuota failed: $e');
      return StorageQuota(0, 0);
    }
  }

  /// Revoke blob URL
  void revokeBlobUrl(String blobUrl) {
    try {
      _blobUrlRevokeJS(blobUrl.toJS);
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ revokeBlobUrl failed: $e');
    }
  }

  /// Create blob URL from data
  String createBlobUrl(Uint8List data) {
    try {
      final blob = _createBlobJs(data.toJS);
      return _createObjectUrlJs(blob).toDart;
    } catch (e) {
      gemmaLog('[WebCacheInterop] ❌ createBlobUrl failed: $e');
      rethrow;
    }
  }
}

@JS('URL.createObjectURL')
external JSString _createObjectUrlJs(JSAny blob);

@JS('createBlob')
external JSAny _createBlobJs(JSUint8Array data);

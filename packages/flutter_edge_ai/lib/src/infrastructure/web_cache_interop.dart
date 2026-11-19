/// JavaScript interop for Cache API
///
/// Provides type-safe wrappers for Cache API operations using dart:js_interop.
/// Operations go through cache_api.js to ensure proper error handling, except
/// [WebCacheInterop.put], which streams a body into the Cache API itself.
library;

import 'dart:js_interop';

import 'package:flutter/foundation.dart';

import '../utils/edge_ai_log.dart';

/// A model's bytes on their way into browser storage, held by the browser and
/// never copied into a Dart typed array.
///
/// Under dart2wasm a Dart `Uint8List` is a WasmGC array inside V8's heap,
/// which V8 caps at 2^30 - 20 bytes (Chrome 157, every build mode); a larger
/// one traps with `RuntimeError: requested new array is too large`, which no
/// Dart `catch` sees, so the call never completes. A download goes from
/// `fetch` into the Cache API as a stream instead.
///
/// [body] is what `new Response(body)` takes: a `ReadableStream` that reads a
/// download as it arrives (read once), or a `Blob`.
class WebModelBody {
  WebModelBody(
    this.body, {
    required this.bytesRead,
    this.replayable = false,
    void Function()? abort,
  }) : abort = abort ?? _noAbort;

  static void _noAbort() {}

  /// A body over [bytes], for data that is already in Dart memory.
  factory WebModelBody.ofBytes(Uint8List bytes) {
    final blob = _Blob(
      [bytes.toJS].toJS,
      {'type': 'application/octet-stream'}.jsify(),
    );
    return WebModelBody(blob, bytesRead: () => bytes.length, replayable: true);
  }

  final JSObject body;

  /// The bytes the body has given so far.
  final int Function() bytesRead;

  /// Whether [body] can be read more than once (a `Blob`); a download can
  /// not.
  final bool replayable;

  /// Stops a download: the fetch is aborted and whoever reads [body] gets
  /// an `AbortError`. A no-op for a body that is not a download.
  final void Function() abort;

  /// The bytes the body has given so far: its size once it has been read to
  /// its end.
  int get size => bytesRead();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts, JSAny? options);
}

@JS('caches')
external _CacheStorage get _caches;

extension type _CacheStorage._(JSObject _) implements JSObject {
  external JSPromise<_Cache> open(JSString cacheName);
}

extension type _Cache._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> put(JSString url, _Response response);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSAny body, JSAny? init);
  external JSPromise<_Blob> blob();
}

/// External JS functions for Cache API
@JS('cacheHas')
external JSPromise<JSBoolean> _cacheHasJS(JSString cacheName, JSString url);

@JS('cacheGetBlobUrl')
external JSPromise<JSString?> _cacheGetBlobUrlJS(
  JSString cacheName,
  JSString url,
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
      edgeAiLog('[WebCacheInterop] ❌ has failed for $url: $e');
      return false;
    }
  }

  /// Get blob URL from cache
  Future<String?> getBlobUrl(String cacheName, String url) async {
    try {
      final result = await _cacheGetBlobUrlJS(cacheName.toJS, url.toJS).toDart;
      return result?.toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ getBlobUrl failed for $url: $e');
      return null;
    }
  }

  /// Stores [body] in the cache under [url], reading it to its end: a
  /// download streams from the network into the cache.
  ///
  /// Calls the Cache API directly rather than `cache_api.js`'s `cachePut`,
  /// whose copy in an app takes a `Uint8Array` (it reads `data.length`).
  Future<void> put(String cacheName, String url, WebModelBody body) async {
    try {
      final cache = await _caches.open(cacheName.toJS).toDart;
      final response = _Response(
        body.body,
        {
          'headers': {'Content-Type': 'application/octet-stream'},
        }.jsify(),
      );
      await cache.put(url.toJS, response).toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ put failed for $url: $e');
      rethrow;
    }
  }

  /// Delete cached entry
  Future<bool> delete(String cacheName, String url) async {
    try {
      final result = await _cacheDeleteJS(cacheName.toJS, url.toJS).toDart;
      return result.toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ delete failed for $url: $e');
      return false;
    }
  }

  /// Delete entire cache
  Future<bool> deleteCache(String cacheName) async {
    try {
      final result = await _cacheDeleteCacheJS(cacheName.toJS).toDart;
      return result.toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ deleteCache failed: $e');
      return false;
    }
  }

  /// Get all cached URLs
  Future<List<String>> getAllKeys(String cacheName) async {
    try {
      final result = await _cacheGetAllKeysJS(cacheName.toJS).toDart;
      return result.toDart.map((js) => js.toDart).toList();
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ getAllKeys failed: $e');
      return [];
    }
  }

  /// Request persistent storage
  Future<bool> requestPersistentStorage() async {
    try {
      final result = await _storageRequestPersistentJS().toDart;
      return result.toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ requestPersistentStorage failed: $e');
      return false;
    }
  }

  /// Get storage quota
  Future<StorageQuota> getStorageQuota() async {
    try {
      final result = await _storageGetQuotaJS().toDart;
      return StorageQuota(result.usage.toDartInt, result.quota.toDartInt);
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ getStorageQuota failed: $e');
      return StorageQuota(0, 0);
    }
  }

  /// Revoke blob URL
  void revokeBlobUrl(String blobUrl) {
    try {
      _blobUrlRevokeJS(blobUrl.toJS);
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ revokeBlobUrl failed: $e');
    }
  }

  /// Reads [body] to its end into a `Blob` and returns a blob URL for it.
  Future<String> createBlobUrl(WebModelBody body) async {
    try {
      final blob = await _Response(body.body, null).blob().toDart;
      return _createObjectUrlJs(blob).toDart;
    } catch (e) {
      edgeAiLog('[WebCacheInterop] ❌ createBlobUrl failed: $e');
      rethrow;
    }
  }
}

@JS('URL.createObjectURL')
external JSString _createObjectUrlJs(JSAny blob);

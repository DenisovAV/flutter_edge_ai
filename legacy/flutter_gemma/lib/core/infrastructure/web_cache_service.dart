/// Web cache service for persistent model storage
///
/// Provides persistent caching using browser Cache API.
/// Models cached here survive browser restarts.
///
/// Features:
/// - Cache API for binary data storage (no serialization needed)
/// - SharedPreferences for metadata (URLs, sizes, timestamps)
/// - Blob URL creation on-demand
/// - URL normalization (same URL = same cache entry)
/// - Storage quota management
/// - Persistent storage support
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_gemma/core/domain/cache_metadata.dart';
import 'package:flutter_gemma/core/infrastructure/web_cache_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/web_cache_interop.dart';
import 'package:flutter_gemma/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_gemma/core/infrastructure/url_utils.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

/// Web cache service
///
/// Coordinates caching using:
/// - Cache API: Binary model data storage
/// - SharedPreferences: Metadata storage
/// - Blob URLs: Created on-demand from cached data
class WebCacheService {
  /// Cache name for models
  static const String cacheName = 'flutter_gemma_models';

  /// Maximum cache age before cleanup (30 days)
  static const Duration maxCacheAge = Duration(days: 30);

  final WebCacheInterop _cacheInterop;
  final SharedPreferences _prefs;
  final WebFileSystemService _fileSystem;
  final bool enableCache;

  WebCacheService(
    this._cacheInterop,
    this._prefs,
    this._fileSystem, {
    this.enableCache = true,
  });

  /// Check if a URL is cached
  ///
  /// Uses URL normalization to ensure same URL = same cache entry.
  /// Returns true if model exists in Cache API.
  Future<bool> isCached(String url) async {
    try {
      final normalizedUrl = UrlUtils.normalizeUrl(url);
      final cached = await _cacheInterop.has(cacheName, normalizedUrl);

      if (kDebugMode) {
        gemmaLog(
          '[WebCacheService] 🔍 isCached($url) -> $cached (normalized: $normalizedUrl)',
        );
      }

      return cached;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ isCached failed for $url: $e');
      return false;
    }
  }

  /// Get cached blob URL
  ///
  /// Returns blob URL created from cached data.
  /// Returns null if not cached or error.
  Future<String?> getCachedBlobUrl(String url) async {
    try {
      final normalizedUrl = UrlUtils.normalizeUrl(url);

      if (kDebugMode) {
        gemmaLog(
          'WebCacheService: getCachedBlobUrl($url) normalized: $normalizedUrl',
        );
      }

      // Check cache first
      final cached = await _cacheInterop.has(cacheName, normalizedUrl);
      if (!cached) {
        if (kDebugMode) {
          gemmaLog('[WebCacheService] ⚠️  Not cached: $normalizedUrl');
        }
        return null;
      }

      // Get blob URL from cache
      final blobUrl = await _cacheInterop.getBlobUrl(cacheName, normalizedUrl);

      if (blobUrl == null) {
        gemmaLog(
          '[WebCacheService] ❌ Failed to create blob URL for $normalizedUrl',
        );
        // Cache corrupted? Delete metadata
        await _deleteMetadata(url);
        return null;
      }

      if (kDebugMode) {
        gemmaLog('[WebCacheService] ✅ Created blob URL: $blobUrl');
      }

      return blobUrl;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ getCachedBlobUrl failed for $url: $e');
      return null;
    }
  }

  /// Cache a model
  ///
  /// Stores binary data in Cache API and metadata in SharedPreferences.
  /// Uses URL normalization.
  ///
  /// Throws if storage quota exceeded or other error.
  Future<void> cacheModel(String url, Uint8List data) async {
    try {
      final normalizedUrl = UrlUtils.normalizeUrl(url);

      if (kDebugMode) {
        gemmaLog(
          'WebCacheService: cacheModel($url) size: ${data.length} bytes, normalized: $normalizedUrl',
        );
      }

      // Store in Cache API
      await _cacheInterop.put(cacheName, normalizedUrl, data);

      // Store metadata
      await _saveMetadata(
        CacheMetadata(
          url: url,
          sizeInBytes: data.length,
          timestamp: DateTime.now(),
          cacheKey: normalizedUrl,
        ),
      );

      if (kDebugMode) {
        gemmaLog('[WebCacheService] ✅ Successfully cached $url');
      }
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ cacheModel failed for $url: $e');

      // Handle QuotaExceededError
      if (e.toString().contains('quota')) {
        gemmaLog(
          '[WebCacheService] ⚠️  Storage quota exceeded, attempting cleanup',
        );
        await _cleanupOldEntries();
        // Retry once after cleanup
        try {
          final normalizedUrl = UrlUtils.normalizeUrl(url);
          await _cacheInterop.put(cacheName, normalizedUrl, data);
          await _saveMetadata(
            CacheMetadata(
              url: url,
              sizeInBytes: data.length,
              timestamp: DateTime.now(),
              cacheKey: normalizedUrl,
            ),
          );
          gemmaLog('[WebCacheService] ✅ Cached after cleanup: $url');
          return;
        } catch (retryError) {
          gemmaLog('[WebCacheService] ❌ Retry failed: $retryError');
        }
      }

      rethrow;
    }
  }

  /// Clear all cache
  ///
  /// Deletes entire cache and all metadata.
  Future<void> clearCache() async {
    try {
      if (kDebugMode) {
        gemmaLog('[WebCacheService] 🗑️ Clearing cache');
      }

      // Delete Cache API
      await _cacheInterop.deleteCache(cacheName);

      // Delete all metadata
      final prefs = _prefs;
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith(PreferencesKeys.webCacheMetadataPrefix)) {
          await prefs.remove(key);
        }
      }

      if (kDebugMode) {
        gemmaLog('[WebCacheService] ✅ Cache cleared');
      }
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ clearCache failed: $e');
      rethrow;
    }
  }

  /// Request persistent storage
  ///
  /// Requests browser to persist cache across sessions.
  /// Returns true if granted.
  Future<bool> requestPersistentStorage() async {
    try {
      final granted = await _cacheInterop.requestPersistentStorage();

      if (kDebugMode) {
        gemmaLog(
          '[WebCacheService] ${granted ? "✅" : "⚠️ "} Persistent storage ${granted ? "granted" : "denied"}',
        );
      }

      // Save grant status
      final prefs = _prefs;
      await prefs.setBool(PreferencesKeys.webCachePersistentGranted, granted);

      return granted;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ requestPersistentStorage failed: $e');
      return false;
    }
  }

  /// Get storage quota information
  ///
  /// Returns current usage and quota in bytes.
  Future<StorageQuota> getStorageQuota() async {
    try {
      final quota = await _cacheInterop.getStorageQuota();

      if (kDebugMode) {
        gemmaLog('[WebCacheService] 📊 Storage quota: $quota');
      }

      return quota;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ getStorageQuota failed: $e');
      return StorageQuota(0, 0);
    }
  }

  /// Get all cached URLs
  Future<List<String>> getCachedUrls() async {
    try {
      final urls = await _cacheInterop.getAllKeys(cacheName);

      if (kDebugMode) {
        gemmaLog('[WebCacheService] 🔍 Found ${urls.length} cached URLs');
      }

      return urls;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ getCachedUrls failed: $e');
      return [];
    }
  }

  // === Private Helpers ===

  /// Get metadata key for URL
  String _getMetadataKey(String url) {
    final hash = url.hashCode.abs();
    return '${PreferencesKeys.webCacheMetadataPrefix}$hash';
  }

  /// Save metadata to SharedPreferences
  Future<void> _saveMetadata(CacheMetadata metadata) async {
    try {
      final prefs = _prefs;
      final key = _getMetadataKey(metadata.url);
      final json = jsonEncode(metadata.toJson());
      await prefs.setString(key, json);

      if (kDebugMode) {
        gemmaLog('[WebCacheService] 💾 Saved metadata for ${metadata.url}');
      }
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ _saveMetadata failed: $e');
    }
  }

  /// Delete metadata for URL
  Future<void> _deleteMetadata(String url) async {
    try {
      final prefs = _prefs;
      final key = _getMetadataKey(url);
      await prefs.remove(key);

      if (kDebugMode) {
        gemmaLog('[WebCacheService] 🗑️ Deleted metadata for $url');
      }
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ _deleteMetadata failed: $e');
    }
  }

  /// Get all metadata entries
  Future<List<CacheMetadata>> _getAllMetadata() async {
    try {
      final prefs = _prefs;
      final keys = prefs.getKeys();
      final metadataList = <CacheMetadata>[];

      for (final key in keys) {
        if (key.startsWith(PreferencesKeys.webCacheMetadataPrefix)) {
          final jsonString = prefs.getString(key);
          if (jsonString != null) {
            try {
              final json = jsonDecode(jsonString) as Map<String, dynamic>;
              final metadata = CacheMetadata.fromJson(json);
              metadataList.add(metadata);
            } catch (e) {
              gemmaLog('[WebCacheService] ❌ Failed to parse metadata: $e');
              // Invalid metadata - delete it
              await prefs.remove(key);
            }
          }
        }
      }

      return metadataList;
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ _getAllMetadata failed: $e');
      return [];
    }
  }

  /// Cleanup old cache entries
  ///
  /// Deletes entries older than maxCacheAge.
  Future<void> _cleanupOldEntries() async {
    try {
      if (kDebugMode) {
        gemmaLog('[WebCacheService] 🗑️ Running cleanup');
      }

      final now = DateTime.now();
      final metadata = await _getAllMetadata();

      // Sort by timestamp (oldest first)
      metadata.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      int deletedCount = 0;

      for (final meta in metadata) {
        final age = now.difference(meta.timestamp);

        if (age > maxCacheAge) {
          // Delete from Cache API
          await _cacheInterop.delete(cacheName, meta.cacheKey);

          // Delete metadata
          await _deleteMetadata(meta.url);

          deletedCount++;

          if (kDebugMode) {
            gemmaLog(
              '[WebCacheService] 🗑️ Deleted old entry: ${meta.url} (age: ${age.inDays} days)',
            );
          }
        }
      }

      if (kDebugMode) {
        gemmaLog(
          '[WebCacheService] ✅ Cleanup complete, deleted $deletedCount entries',
        );
      }

      // Update last cleanup timestamp
      final prefs = _prefs;
      await prefs.setInt(
        PreferencesKeys.webCacheLastCleanup,
        now.millisecondsSinceEpoch,
      );
    } catch (e) {
      gemmaLog('[WebCacheService] ❌ _cleanupOldEntries failed: $e');
    }
  }

  /// Universal caching wrapper with progress tracking (stream version)
  ///
  /// Checks cache first (if enabled), loads if needed, caches (if enabled),
  /// creates blob URL, registers in file system.
  /// Yields progress as int percentage (0-100).
  ///
  /// [cacheKey] - Key for Cache API storage
  /// [loader] - Async function that loads data and reports progress via callback
  /// [targetPath] - Path to register in WebFileSystemService
  ///
  /// Returns: Stream of progress percentages (0-100)
  Stream<int> getOrCacheAndRegisterWithProgress({
    required String cacheKey,
    required Future<Uint8List> Function(void Function(double) onProgress)
    loader,
    required String targetPath,
  }) async* {
    try {
      // 1. Check cache first (only if caching enabled)
      if (enableCache) {
        final cachedBlobUrl = await getCachedBlobUrl(cacheKey);
        if (cachedBlobUrl != null) {
          gemmaLog('[WebCacheService] ✅ Found in cache: $cacheKey');
          _fileSystem.registerUrl(targetPath, cachedBlobUrl);
          yield 100; // Instant completion
          return;
        }
      }

      // 2. Load data with progress tracking
      gemmaLog(
        '[WebCacheService] 📥 Loading: $cacheKey (cache: ${enableCache ? "enabled" : "disabled"})',
      );

      final controller = StreamController<int>();
      Uint8List? loadedData;

      // Start loading in background with progress callback
      loader((progress) {
            final percent = (progress * 100).clamp(0, 99).toInt();
            if (!controller.isClosed) {
              controller.add(percent);
            }
          })
          .then((data) {
            loadedData = data;
            if (!controller.isClosed) {
              controller.close();
            }
          })
          .catchError((error) {
            if (!controller.isClosed) {
              controller.addError(error);
              controller.close();
            }
          });

      // Yield progress updates
      await for (final progress in controller.stream) {
        yield progress;
      }

      if (loadedData == null) {
        throw Exception('Failed to load data for: $cacheKey');
      }

      // 3. Cache the data (only if caching enabled)
      if (enableCache) {
        await cacheModel(cacheKey, loadedData!);

        // 4. Create blob URL from cache
        final blobUrl = await getCachedBlobUrl(cacheKey);
        if (blobUrl == null) {
          throw Exception('Failed to create blob URL for: $cacheKey');
        }

        // 5. Register in file system
        _fileSystem.registerUrl(targetPath, blobUrl);

        gemmaLog('[WebCacheService] ✅ Cached and registered: $cacheKey');
      } else {
        // Create temporary blob URL without caching
        final blobUrl = _cacheInterop.createBlobUrl(loadedData!);
        _fileSystem.registerUrl(targetPath, blobUrl);

        gemmaLog('[WebCacheService] ✅ Registered (no cache): $cacheKey');
      }

      yield 100; // Final completion
    } catch (e) {
      gemmaLog(
        '[WebCacheService] ❌ getOrCacheAndRegisterWithProgress failed: $e',
      );
      rethrow;
    }
  }

  /// Simple version without progress tracking
  ///
  /// Use this for instant loads (assets, bundled) where progress isn't needed.
  /// Delegates to getOrCacheAndRegisterWithProgress and ignores progress events.
  Future<String> getOrCacheAndRegister({
    required String cacheKey,
    required Future<Uint8List> Function() loader,
    required String targetPath,
  }) async {
    // Delegate to progress version, ignore progress events
    await for (final _ in getOrCacheAndRegisterWithProgress(
      cacheKey: cacheKey,
      loader: (_) => loader(), // Ignore progress callback
      targetPath: targetPath,
    )) {
      // Ignore progress updates
    }

    return targetPath;
  }
}

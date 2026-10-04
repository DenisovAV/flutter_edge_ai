/// Metadata for cached models
///
/// Stores information about cached models in SharedPreferences
/// for tracking cache entries and managing cleanup.
class CacheMetadata {
  /// Original URL of the model
  final String url;

  /// Size in bytes
  final int sizeInBytes;

  /// Timestamp when cached
  final DateTime timestamp;

  /// Cache key (normalized URL)
  final String cacheKey;

  const CacheMetadata({
    required this.url,
    required this.sizeInBytes,
    required this.timestamp,
    required this.cacheKey,
  });

  /// Create from JSON
  factory CacheMetadata.fromJson(Map<String, dynamic> json) {
    return CacheMetadata(
      url: json['url'] as String,
      sizeInBytes: json['sizeInBytes'] as int,
      timestamp: DateTime.parse(json['timestamp'] as String),
      cacheKey: json['cacheKey'] as String,
    );
  }

  /// Convert to JSON
  Map<String, dynamic> toJson() {
    return {
      'url': url,
      'sizeInBytes': sizeInBytes,
      'timestamp': timestamp.toIso8601String(),
      'cacheKey': cacheKey,
    };
  }

  @override
  String toString() {
    return 'CacheMetadata{url: $url, size: $sizeInBytes, timestamp: $timestamp, cacheKey: $cacheKey}';
  }
}

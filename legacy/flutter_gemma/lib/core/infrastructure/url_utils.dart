import '../utils/gemma_log.dart';

/// Utilities for URL manipulation
class UrlUtils {
  /// Normalize URL for cache lookup
  ///
  /// Removes query parameters and trailing slashes to ensure
  /// the same model uses the same cache entry regardless of
  /// authentication tokens in URL.
  static String normalizeUrl(String url) {
    try {
      final uri = Uri.parse(url);

      // Only remove query if it exists (avoid adding '?' to URLs without query)
      String normalized;
      if (uri.hasQuery) {
        normalized = uri.replace(query: '').toString();
      } else {
        normalized = uri.toString();
      }

      // Remove trailing slash
      if (normalized.endsWith('/')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }

      // Remove trailing '?' if present (bug in Uri.replace)
      if (normalized.endsWith('?')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }

      return normalized;
    } catch (e) {
      gemmaLog('[UrlUtils] ⚠️  URL normalization failed: $e');
      return url;
    }
  }
}

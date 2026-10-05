import 'package:flutter_gemma/core/model_management/cancel_token.dart';

/// Abstraction for downloading files from network
/// Different implementations for different strategies
///
/// Platform implementations:
/// - BackgroundDownloaderService: uses background_downloader package
/// - SimpleDownloadService: uses http package
/// - MockDownloadService: for testing
abstract interface class DownloadService {
  /// Downloads a file from URL to target path
  ///
  /// Parameters:
  /// - [url]: Source URL (must be HTTP/HTTPS)
  /// - [targetPath]: Full path where file should be saved
  /// - [token]: Optional authentication token
  /// - [cancelToken]: Optional token for cancellation
  ///
  /// Throws:
  /// - [DownloadException] with [DownloadError.network] for network errors
  /// - [DownloadException] with [DownloadError.unknown] for file write errors
  /// - [DownloadCancelledException] if cancelled via cancelToken
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  });

  /// Downloads a file with progress tracking
  ///
  /// Returns a stream of progress percentages (0-100)
  ///
  /// Parameters:
  /// - [url]: Source URL
  /// - [targetPath]: Destination path
  /// - [token]: Optional auth token
  /// - [maxRetries]: Max retry attempts for transient errors (default: 10)
  ///   Note: Auth errors (401/403/404) fail after 1 attempt regardless of this value
  /// - [cancelToken]: Optional token for cancellation
  /// - [foreground]: Android foreground service mode (shows notification, no timeout)
  ///   - null (default): NO foreground service (no notification is configured)
  ///   - true: always use foreground
  ///   - false: never use foreground
  ///
  /// Throws:
  /// - [DownloadCancelledException] if cancelled via cancelToken
  ///
  /// Example:
  /// ```dart
  /// final cancelToken = CancelToken();
  /// await for (final progress in downloader.downloadWithProgress(..., cancelToken: cancelToken)) {
  ///   print('Progress: $progress%');
  /// }
  /// // Cancel from elsewhere: cancelToken.cancel('User cancelled');
  /// ```
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  });
}

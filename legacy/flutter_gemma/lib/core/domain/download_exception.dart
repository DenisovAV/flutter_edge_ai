import 'download_error.dart';

/// Custom exception for download failures
class DownloadException implements Exception {
  const DownloadException(this.error);

  final DownloadError error;

  @override
  String toString() => 'DownloadException: ${error.toUserMessage()}';
}

/// Extension to convert DownloadError to user-friendly messages
extension DownloadErrorMessage on DownloadError {
  /// Returns a user-friendly error message
  String toUserMessage() {
    return switch (this) {
      UnauthorizedError() =>
        'Authentication required (HTTP 401).\n'
            'Please provide a valid HuggingFace token using:\n'
            'FlutterGemma.initialize(huggingFaceToken: "hf_...")',
      ForbiddenError() =>
        'Access forbidden (HTTP 403).\n'
            'Your HuggingFace token is either invalid or does not have access to this model.\n'
            'For gated models, visit the model page on HuggingFace and request access.',
      NotFoundError() =>
        'Model not found (HTTP 404).\n'
            'Please check the URL and ensure the model exists.\n'
            'Use /resolve/main/ format, not /blob/main/',
      RateLimitedError() =>
        'Rate limit exceeded (HTTP 429).\n'
            'Please wait a few minutes before trying again.\n'
            'Authenticated requests have higher rate limits.',
      ServerError(:final statusCode) =>
        'Server error (HTTP $statusCode).\n'
            'The download service is experiencing issues.\n'
            'Please try again later.',
      NetworkError(:final message) =>
        'Network error: $message\n'
            'Please check your internet connection.',
      CanceledError() => 'Download was canceled.',
      UnknownError(:final message) => 'Download failed: $message',
    };
  }

  /// Returns a short error title for UI dialogs
  String toTitle() {
    return switch (this) {
      UnauthorizedError() => 'Authentication Required',
      ForbiddenError() => 'Access Forbidden',
      NotFoundError() => 'Model Not Found',
      RateLimitedError() => 'Rate Limited',
      ServerError() => 'Server Error',
      NetworkError() => 'Network Error',
      CanceledError() => 'Download Canceled',
      UnknownError() => 'Download Failed',
    };
  }

  /// Returns true if error is recoverable by retrying
  bool get isRetryable {
    return switch (this) {
      NetworkError() => true,
      ServerError() => true,
      RateLimitedError() => true,
      _ => false,
    };
  }

  /// Returns true if error requires user action
  bool get requiresUserAction {
    return switch (this) {
      UnauthorizedError() => true,
      ForbiddenError() => true,
      NotFoundError() => true,
      _ => false,
    };
  }
}

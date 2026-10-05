/// Download error types using sealed classes for exhaustive pattern matching
sealed class DownloadError {
  const DownloadError();

  /// HTTP 401 - Authentication required
  const factory DownloadError.unauthorized() = UnauthorizedError;

  /// HTTP 403 - Access forbidden (invalid token or gated model)
  const factory DownloadError.forbidden() = ForbiddenError;

  /// HTTP 404 - Resource not found
  const factory DownloadError.notFound() = NotFoundError;

  /// HTTP 429 - Rate limit exceeded
  const factory DownloadError.rateLimited() = RateLimitedError;

  /// HTTP 5xx - Server error
  const factory DownloadError.serverError(int statusCode) = ServerError;

  /// Network error (connection issues, timeouts, etc.)
  const factory DownloadError.network(String message) = NetworkError;

  /// Download was canceled by user
  const factory DownloadError.canceled() = CanceledError;

  /// Unknown error
  const factory DownloadError.unknown(String message) = UnknownError;
}

/// HTTP 401 - Authentication required
final class UnauthorizedError extends DownloadError {
  const UnauthorizedError();
}

/// HTTP 403 - Access forbidden
final class ForbiddenError extends DownloadError {
  const ForbiddenError();
}

/// HTTP 404 - Resource not found
final class NotFoundError extends DownloadError {
  const NotFoundError();
}

/// HTTP 429 - Rate limit exceeded
final class RateLimitedError extends DownloadError {
  const RateLimitedError();
}

/// HTTP 5xx - Server error
final class ServerError extends DownloadError {
  const ServerError(this.statusCode);
  final int statusCode;
}

/// Network connectivity error
final class NetworkError extends DownloadError {
  const NetworkError(this.message);
  final String message;
}

/// Download canceled
final class CanceledError extends DownloadError {
  const CanceledError();
}

/// Unknown error
final class UnknownError extends DownloadError {
  const UnknownError(this.message);
  final String message;
}

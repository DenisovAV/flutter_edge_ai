import 'package:flutter_edge_ai/core/domain/download_error.dart';
import 'package:flutter_edge_ai/core/domain/download_exception.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Error retry logic validation', () {
    test('401 UnauthorizedError is NOT retryable', () {
      const error = DownloadError.unauthorized();

      expect(error.isRetryable, isFalse, reason: '401 should NOT be retryable');
      expect(
        error.requiresUserAction,
        isTrue,
        reason: '401 requires user to add token',
      );
    });

    test('403 ForbiddenError is NOT retryable', () {
      const error = DownloadError.forbidden();

      expect(error.isRetryable, isFalse, reason: '403 should NOT be retryable');
      expect(
        error.requiresUserAction,
        isTrue,
        reason: '403 requires user action',
      );
    });

    test('404 NotFoundError is NOT retryable', () {
      const error = DownloadError.notFound();

      expect(error.isRetryable, isFalse, reason: '404 should NOT be retryable');
      expect(error.requiresUserAction, isTrue);
    });

    test('NetworkError IS retryable', () {
      const error = DownloadError.network('Connection timeout');

      expect(error.isRetryable, isTrue, reason: 'Network errors ARE retryable');
      expect(error.requiresUserAction, isFalse);
    });

    test('ServerError (5xx) IS retryable', () {
      const error = DownloadError.serverError(503);

      expect(error.isRetryable, isTrue, reason: '5xx errors ARE retryable');
      expect(error.requiresUserAction, isFalse);
    });

    test('RateLimitedError IS retryable', () {
      const error = DownloadError.rateLimited();

      expect(error.isRetryable, isTrue, reason: '429 errors ARE retryable');
      expect(error.requiresUserAction, isFalse);
    });

    test('Retry logic should stop on 401', () {
      const errors = [
        DownloadError.unauthorized(),
        DownloadError.forbidden(),
        DownloadError.notFound(),
      ];

      for (final error in errors) {
        expect(
          error.isRetryable,
          isFalse,
          reason: '${error.runtimeType} should stop retry immediately',
        );
      }
    });

    test('Example retry function behavior', () {
      // Simulate retry logic
      bool shouldRetry(DownloadError error) {
        return error.isRetryable;
      }

      // Auth errors should NOT retry
      expect(shouldRetry(const DownloadError.unauthorized()), isFalse);
      expect(shouldRetry(const DownloadError.forbidden()), isFalse);
      expect(shouldRetry(const DownloadError.notFound()), isFalse);

      // Transient errors SHOULD retry
      expect(shouldRetry(const DownloadError.network('test')), isTrue);
      expect(shouldRetry(const DownloadError.serverError(503)), isTrue);
      expect(shouldRetry(const DownloadError.rateLimited()), isTrue);
    });
  });

  group('Retry loop simulation', () {
    test('Should stop immediately on 401', () async {
      int attempts = 0;

      Future<void> download() async {
        attempts++;
        throw const DownloadException(DownloadError.unauthorized());
      }

      try {
        await download();
      } on DownloadException catch (e) {
        // Should NOT retry
        if (e.error.isRetryable) {
          fail('401 should not be retryable!');
        }
      }

      expect(attempts, equals(1), reason: 'Should only attempt once for 401');
    });

    test('Should retry on network error', () async {
      int attempts = 0;
      const maxRetries = 3;

      Future<void> downloadWithRetry() async {
        while (attempts < maxRetries) {
          try {
            attempts++;
            throw const DownloadException(
              DownloadError.network('Connection failed'),
            );
          } on DownloadException catch (e) {
            if (!e.error.isRetryable || attempts >= maxRetries) {
              rethrow;
            }
            // Continue retry loop
          }
        }
      }

      try {
        await downloadWithRetry();
        fail('Should have thrown after max retries');
      } on DownloadException catch (e) {
        expect(e.error, isA<NetworkError>());
      }

      expect(
        attempts,
        equals(maxRetries),
        reason: 'Should retry max times for network errors',
      );
    });
  });
}

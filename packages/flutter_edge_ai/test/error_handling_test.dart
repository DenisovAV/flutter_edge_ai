import 'package:flutter_edge_ai/core/domain/download_error.dart';
import 'package:flutter_edge_ai/core/domain/download_exception.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DownloadError sealed class', () {
    test('UnauthorizedError has correct user message', () {
      const error = DownloadError.unauthorized();
      final message = error.toUserMessage();

      expect(message, contains('401'));
      expect(message, contains('token'));
      expect(message, contains('FlutterEdgeAi.initialize'));
    });

    test('ForbiddenError has correct user message', () {
      const error = DownloadError.forbidden();
      final message = error.toUserMessage();

      expect(message, contains('403'));
      expect(message, contains('forbidden'));
      expect(message, contains('invalid'));
      expect(message, contains('gated models'));
      expect(message, contains('request access'));
    });

    test('NotFoundError has correct user message', () {
      const error = DownloadError.notFound();
      final message = error.toUserMessage();

      expect(message, contains('404'));
      expect(message, contains('not found'));
      expect(message, contains('URL'));
      expect(message, contains('/resolve/main/'));
    });

    test('RateLimitedError has correct user message', () {
      const error = DownloadError.rateLimited();
      final message = error.toUserMessage();

      expect(message, contains('429'));
      expect(message, contains('Rate limit'));
      expect(message, contains('wait'));
    });

    test('ServerError includes status code', () {
      const error = DownloadError.serverError(503);
      final message = error.toUserMessage();

      expect(message, contains('503'));
      expect(message, contains('Server error'));
    });

    test('NetworkError includes custom message', () {
      const error = DownloadError.network('Connection timeout');
      final message = error.toUserMessage();

      expect(message, contains('Network error'));
      expect(message, contains('Connection timeout'));
    });
  });

  group('DownloadError utility methods', () {
    test('isRetryable returns true for network errors', () {
      expect(const DownloadError.network('test').isRetryable, isTrue);
      expect(const DownloadError.serverError(500).isRetryable, isTrue);
      expect(const DownloadError.rateLimited().isRetryable, isTrue);
    });

    test('isRetryable returns false for auth errors', () {
      expect(const DownloadError.unauthorized().isRetryable, isFalse);
      expect(const DownloadError.forbidden().isRetryable, isFalse);
      expect(const DownloadError.notFound().isRetryable, isFalse);
    });

    test('requiresUserAction returns true for auth errors', () {
      expect(const DownloadError.unauthorized().requiresUserAction, isTrue);
      expect(const DownloadError.forbidden().requiresUserAction, isTrue);
      expect(const DownloadError.notFound().requiresUserAction, isTrue);
    });

    test('requiresUserAction returns false for transient errors', () {
      expect(const DownloadError.network('test').requiresUserAction, isFalse);
      expect(const DownloadError.serverError(500).requiresUserAction, isFalse);
      expect(const DownloadError.canceled().requiresUserAction, isFalse);
    });

    test('toTitle returns short error titles', () {
      expect(
        const DownloadError.unauthorized().toTitle(),
        'Authentication Required',
      );
      expect(const DownloadError.forbidden().toTitle(), 'Access Forbidden');
      expect(const DownloadError.notFound().toTitle(), 'Model Not Found');
      expect(const DownloadError.rateLimited().toTitle(), 'Rate Limited');
      expect(const DownloadError.serverError(500).toTitle(), 'Server Error');
      expect(const DownloadError.network('test').toTitle(), 'Network Error');
      expect(const DownloadError.canceled().toTitle(), 'Download Canceled');
      expect(const DownloadError.unknown('test').toTitle(), 'Download Failed');
    });
  });

  group('DownloadException', () {
    test('toString includes user message', () {
      const error = DownloadError.forbidden();
      const exception = DownloadException(error);

      expect(exception.toString(), contains('DownloadException'));
      expect(exception.toString(), contains('403'));
      expect(exception.toString(), contains('forbidden'));
    });

    test('Pattern matching works with sealed classes', () {
      const error = DownloadError.unauthorized();

      final result = switch (error) {
        UnauthorizedError() => 'auth',
        ForbiddenError() => 'forbidden',
        NotFoundError() => 'not_found',
        RateLimitedError() => 'rate_limit',
        ServerError() => 'server',
        NetworkError() => 'network',
        CanceledError() => 'canceled',
        UnknownError() => 'unknown',
      };

      expect(result, 'auth');
    });
  });
}

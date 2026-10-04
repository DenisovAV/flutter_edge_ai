import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';

void main() {
  group('CancelToken', () {
    test('initial state is not cancelled', () {
      final token = CancelToken();

      expect(token.isCancelled, isFalse);
      expect(token.cancelReason, isNull);
    });

    test('cancel() marks token as cancelled', () {
      final token = CancelToken();

      token.cancel('Test reason');

      expect(token.isCancelled, isTrue);
      expect(token.cancelReason, 'Test reason');
    });

    test('cancel() with default reason', () {
      final token = CancelToken();

      token.cancel();

      expect(token.isCancelled, isTrue);
      expect(token.cancelReason, 'Operation cancelled');
    });

    test('cancel() is idempotent', () {
      final token = CancelToken();

      token.cancel('First reason');
      token.cancel('Second reason');

      // Should keep first reason
      expect(token.isCancelled, isTrue);
      expect(token.cancelReason, 'First reason');
    });

    test('throwIfCancelled() throws when cancelled', () {
      final token = CancelToken();
      token.cancel('Test cancellation');

      expect(
        () => token.throwIfCancelled(),
        throwsA(isA<DownloadCancelledException>()),
      );
    });

    test('throwIfCancelled() does not throw when not cancelled', () {
      final token = CancelToken();

      expect(() => token.throwIfCancelled(), returnsNormally);
    });

    test('whenCancelled completes when cancelled', () async {
      final token = CancelToken();
      var completed = false;

      token.whenCancelled.then((_) {
        completed = true;
      });

      expect(completed, isFalse);

      token.cancel('Test');

      await Future.delayed(Duration.zero);
      expect(completed, isTrue);
    });

    test('whenCancelled completes immediately if already cancelled', () async {
      final token = CancelToken();
      token.cancel('Test');

      final future = token.whenCancelled;
      await expectLater(future, completes);
    });

    test('isCancel() static method detects DownloadCancelledException', () {
      final exception = DownloadCancelledException('Test', null);

      expect(CancelToken.isCancel(exception), isTrue);
      expect(CancelToken.isCancel(Exception('Other')), isFalse);
      expect(CancelToken.isCancel('String error'), isFalse);
    });

    test('multiple listeners on whenCancelled', () async {
      final token = CancelToken();
      var listener1Called = false;
      var listener2Called = false;

      token.whenCancelled.then((_) {
        listener1Called = true;
      });

      token.whenCancelled.then((_) {
        listener2Called = true;
      });

      token.cancel('Test');

      await Future.delayed(Duration.zero);
      expect(listener1Called, isTrue);
      expect(listener2Called, isTrue);
    });
  });

  group('DownloadCancelledException', () {
    test('has message and stackTrace', () {
      final stackTrace = StackTrace.current;
      final exception = DownloadCancelledException('Test message', stackTrace);

      expect(exception.message, 'Test message');
      expect(exception.stackTrace, stackTrace);
    });

    test('toString() returns formatted message', () {
      final exception = DownloadCancelledException('Test reason', null);

      expect(exception.toString(), 'DownloadCancelledException: Test reason');
    });

    test('can be thrown and caught', () {
      expect(
        () => throw DownloadCancelledException('Test', null),
        throwsA(isA<DownloadCancelledException>()),
      );
    });

    test('implements Exception', () {
      final exception = DownloadCancelledException('Test', null);

      expect(exception, isA<Exception>());
    });
  });

  group('CancelToken Integration', () {
    test('usage pattern: cancel before operation', () {
      final token = CancelToken();
      token.cancel('User cancelled');

      expect(
        () => token.throwIfCancelled(),
        throwsA(
          isA<DownloadCancelledException>().having(
            (e) => e.message,
            'message',
            'User cancelled',
          ),
        ),
      );
    });

    test('usage pattern: check cancellation in error handler', () {
      final token = CancelToken();
      token.cancel('Test');

      try {
        token.throwIfCancelled();
        fail('Should have thrown');
      } catch (e) {
        expect(CancelToken.isCancel(e), isTrue);
      }
    });

    test('usage pattern: cancel during async operation', () async {
      final token = CancelToken();
      var operationCancelled = false;

      // Simulate async operation
      Future<void> operation() async {
        for (var i = 0; i < 10; i++) {
          token.throwIfCancelled();
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      // Start operation
      final future = operation().catchError((e) {
        if (CancelToken.isCancel(e)) {
          operationCancelled = true;
        }
      });

      // Cancel after a short delay
      await Future.delayed(const Duration(milliseconds: 25));
      token.cancel('User cancelled');

      await future;
      expect(operationCancelled, isTrue);
    });
  });
}

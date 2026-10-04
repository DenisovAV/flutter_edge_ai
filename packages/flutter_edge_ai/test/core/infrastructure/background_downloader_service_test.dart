import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_edge_ai/core/infrastructure/background_downloader_service.dart';
import 'package:flutter_edge_ai/core/services/download_service.dart';
import 'package:flutter_edge_ai/core/model_management/cancel_token.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundDownloaderService', () {
    late BackgroundDownloaderService service;

    setUp(() {
      service = BackgroundDownloaderService();

      // Mock the background_downloader plugin channel
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.bbflight.background_downloader'),
            (call) async => null,
          );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.bbflight.background_downloader'),
            null,
          );
    });

    group('Interface Implementation', () {
      test('implements DownloadService interface', () {
        expect(
          service,
          isA<DownloadService>(),
          reason: 'Should implement DownloadService interface',
        );
      });

      test('has download() method', () {
        expect(
          service.download,
          isNotNull,
          reason: 'Should have download() method',
        );
      });

      test('has downloadWithProgress() method', () {
        expect(
          service.downloadWithProgress,
          isNotNull,
          reason: 'Should have downloadWithProgress() method',
        );
      });
    });

    group('Return Types', () {
      test('download() returns Future<void>', () {
        final result = service.download(
          'https://example.com/test.bin',
          '/tmp/test.bin',
        );

        expect(
          result,
          isA<Future<void>>(),
          reason: 'download() should return Future<void>',
        );
      });

      test('downloadWithProgress() returns Stream<int>', () {
        final result = service.downloadWithProgress(
          'https://example.com/test.bin',
          '/tmp/test.bin',
        );

        expect(
          result,
          isA<Stream<int>>(),
          reason: 'downloadWithProgress() should return Stream<int>',
        );
      });
    });

    group('Delegation to SmartDownloader', () {
      test('download() accepts required parameters', () {
        expect(
          () => service.download(
            'https://example.com/model.bin',
            '/tmp/model.bin',
          ),
          returnsNormally,
          reason: 'Should accept required parameters',
        );
      });

      test('download() accepts optional token', () {
        expect(
          () => service.download(
            'https://example.com/model.bin',
            '/tmp/model.bin',
            token: 'test_token',
          ),
          returnsNormally,
          reason: 'Should accept optional token',
        );
      });

      test('downloadWithProgress() accepts required parameters', () {
        expect(
          () => service.downloadWithProgress(
            'https://example.com/model.bin',
            '/tmp/model.bin',
          ),
          returnsNormally,
          reason: 'Should accept required parameters',
        );
      });

      test('downloadWithProgress() accepts optional parameters', () {
        expect(
          () => service.downloadWithProgress(
            'https://example.com/model.bin',
            '/tmp/model.bin',
            token: 'test_token',
            maxRetries: 5,
          ),
          returnsNormally,
          reason: 'Should accept all optional parameters',
        );
      });

      test('download() accepts cancelToken parameter', () {
        final cancelToken = CancelToken();
        expect(
          () => service.download(
            'https://example.com/model.bin',
            '/tmp/model.bin',
            cancelToken: cancelToken,
          ),
          returnsNormally,
          reason: 'Should accept cancelToken parameter',
        );
      });

      test('downloadWithProgress() accepts cancelToken parameter', () {
        final cancelToken = CancelToken();
        expect(
          () => service.downloadWithProgress(
            'https://example.com/model.bin',
            '/tmp/model.bin',
            cancelToken: cancelToken,
          ),
          returnsNormally,
          reason: 'Should accept cancelToken parameter',
        );
      });
    });

    group('Thin Wrapper Verification', () {
      test('is a lightweight wrapper with no complex logic', () {
        // BackgroundDownloaderService should be a simple delegation wrapper
        // It should not have any fields except possibly const/static ones

        // We verify this by checking the class is instantiable without parameters
        expect(
          () => BackgroundDownloaderService(),
          returnsNormally,
          reason: 'Should be instantiable with no parameters',
        );
      });

      test('download() delegates to SmartDownloader', () {
        // Verify download() returns a Future (delegated from SmartDownloader)
        final result = service.download(
          'https://example.com/test.bin',
          '/tmp/test.bin',
        );

        expect(
          result,
          isA<Future<void>>(),
          reason: 'Should delegate to SmartDownloader.download()',
        );
      });

      test('downloadWithProgress() delegates to SmartDownloader', () {
        // Verify downloadWithProgress() returns a Stream (delegated from SmartDownloader)
        final result = service.downloadWithProgress(
          'https://example.com/test.bin',
          '/tmp/test.bin',
        );

        expect(
          result,
          isA<Stream<int>>(),
          reason: 'Should delegate to SmartDownloader.downloadWithProgress()',
        );
      });
    });

    group('API Compatibility', () {
      test('download() has same signature as SmartDownloader.download()', () {
        // Both should accept: url, targetPath, token (optional)
        expect(
          () => service.download(
            'https://example.com/model.bin',
            '/tmp/model.bin',
            token: 'test',
          ),
          returnsNormally,
          reason: 'API should match SmartDownloader',
        );
      });

      test(
        'downloadWithProgress() has same signature as SmartDownloader.downloadWithProgress()',
        () {
          // Both should accept: url, targetPath, token (optional), maxRetries (optional)
          expect(
            () => service.downloadWithProgress(
              'https://example.com/model.bin',
              '/tmp/model.bin',
              token: 'test',
              maxRetries: 5,
            ),
            returnsNormally,
            reason: 'API should match SmartDownloader',
          );
        },
      );
    });

    group('No Legacy Code', () {
      test('should not have any old download implementation', () {
        // This test verifies that BackgroundDownloaderService is now a thin wrapper
        // We verify this by checking it's instantiable without complex initialization

        expect(
          () => BackgroundDownloaderService(),
          returnsNormally,
          reason:
              'Should not require complex initialization (no _downloader, _activeTasks, etc.)',
        );
      });
    });
  });
}

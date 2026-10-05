import 'dart:async';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';

/// Stub implementation for non-web platforms
class WebDownloadService implements DownloadService {
  WebDownloadService(
    dynamic fileSystem,
    dynamic jsInterop,
    dynamic blobUrlManager,
    dynamic cacheService,
  ) {
    throw UnsupportedError(
      'WebDownloadService is only available on web platform',
    );
  }

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) {
    throw UnsupportedError(
      'WebDownloadService is only available on web platform',
    );
  }

  @override
  Stream<int> downloadWithProgress(
    String url,
    String targetPath, {
    String? token,
    int maxRetries = 10,
    CancelToken? cancelToken,
    bool? foreground,
  }) {
    throw UnsupportedError(
      'WebDownloadService is only available on web platform',
    );
  }

  dynamic get cacheService => throw UnsupportedError(
    'WebDownloadService is only available on web platform',
  );

  dynamic get opfsService => null;
}

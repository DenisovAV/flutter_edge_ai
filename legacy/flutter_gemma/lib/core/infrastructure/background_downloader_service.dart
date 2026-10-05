import 'dart:async';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/mobile/smart_downloader.dart';

/// Download service implementation using SmartDownloader
///
/// This is a thin wrapper around SmartDownloader to implement the DownloadService interface.
/// All downloads benefit from SmartDownloader's HTTP-aware retry logic.
///
/// Features (provided by SmartDownloader):
/// - HTTP-aware retry (401/403/404 fail after 1 attempt, others retry up to maxRetries)
/// - Background downloads with resume capability
/// - Progress tracking via streams
/// - Network interruption recovery
/// - Authentication token support
/// - Cancellation support via CancelToken
/// - Works with ANY URL (HuggingFace, Google Drive, custom servers, etc.)
class BackgroundDownloaderService implements DownloadService {
  BackgroundDownloaderService();

  @override
  Future<void> download(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    // Delegate to SmartDownloader for consistent behavior
    // SmartDownloader provides HTTP-aware retry logic for ALL downloads
    return SmartDownloader.download(
      url: url,
      targetPath: targetPath,
      token: token,
      cancelToken: cancelToken,
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
    // Delegate to SmartDownloader for all URLs
    // SmartDownloader provides HTTP-aware retry logic for ANY URL
    return SmartDownloader.downloadWithProgress(
      url: url,
      targetPath: targetPath,
      token: token,
      maxRetries: maxRetries,
      cancelToken: cancelToken,
      foreground: foreground,
    );
  }
}

import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/download_service.dart';
import 'package:flutter_gemma/core/services/file_system_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:path/path.dart' as path;

/// Handles installation of models from network URLs (HTTP/HTTPS)
///
/// Features:
/// - Background downloads with progress tracking
/// - Resume capability for interrupted downloads
/// - HuggingFace authentication support
/// - HTTP-aware retry logic (auth errors fail after 1 attempt, others retry up to maxRetries)
class NetworkSourceHandler implements SourceHandler {
  final DownloadService downloadService;
  final FileSystemService fileSystem;
  final ModelRepository repository;
  final String? huggingFaceToken;
  final int maxDownloadRetries;

  NetworkSourceHandler({
    required this.downloadService,
    required this.fileSystem,
    required this.repository,
    this.huggingFaceToken,
    this.maxDownloadRetries = 10,
  });

  @override
  bool supports(ModelSource source) => source is NetworkSource;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    if (source is! NetworkSource) {
      throw ArgumentError('NetworkSourceHandler only supports NetworkSource');
    }

    final effectiveToken =
        source.authToken ??
        (_isHuggingFaceUrl(source.url) ? huggingFaceToken : null);
    final filename =
        targetFilename ?? path.basename(Uri.parse(source.url).path);
    final targetPath = await fileSystem.getWriteTargetPath(filename);

    // Download file with cancellation support
    await downloadService.download(
      source.url,
      targetPath,
      token: effectiveToken,
      cancelToken: cancelToken,
    );

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(targetPath);

    // A download that reports success but leaves no file at targetPath means the
    // downloader wrote elsewhere (see the background_downloader BaseDirectory
    // note in smart_downloader.dart). Fail loudly instead of saving a broken
    // "installed" record.
    assertInstalledFilePresent(sizeBytes, targetPath);

    // Save metadata to repository
    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async* {
    if (source is! NetworkSource) {
      throw ArgumentError('NetworkSourceHandler only supports NetworkSource');
    }

    final effectiveToken =
        source.authToken ??
        (_isHuggingFaceUrl(source.url) ? huggingFaceToken : null);
    final filename =
        targetFilename ?? path.basename(Uri.parse(source.url).path);
    final targetPath = await fileSystem.getWriteTargetPath(filename);

    // Download with progress tracking, configurable retries, and cancellation support
    await for (final progress in downloadService.downloadWithProgress(
      source.url,
      targetPath,
      token: effectiveToken,
      maxRetries: maxDownloadRetries,
      cancelToken: cancelToken,
      foreground: source.foreground,
    )) {
      yield progress;
    }

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(targetPath);

    // A download that reports success but leaves no file at targetPath means the
    // downloader wrote elsewhere (see the background_downloader BaseDirectory
    // note in smart_downloader.dart). Fail loudly instead of saving a broken
    // "installed" record.
    assertInstalledFilePresent(sizeBytes, targetPath);

    // Save metadata to repository
    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: sizeBytes,
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  bool supportsResume(ModelSource source) {
    if (source is! NetworkSource) return false;
    return source.supportsResume;
  }

  /// Checks if URL is a HuggingFace URL that may require authentication
  bool _isHuggingFaceUrl(String url) {
    final uri = Uri.parse(url);
    return uri.host.contains('huggingface.co');
  }
}

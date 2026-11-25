import 'package:flutter_edge_ai/src/domain/model_source.dart';
import 'package:flutter_edge_ai/src/handlers/source_handler.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_edge_ai/src/services/completed_downloads.dart';
import 'package:flutter_edge_ai/src/services/download_service.dart';
import 'package:flutter_edge_ai/src/services/file_system_service.dart';
import 'package:flutter_edge_ai/src/services/model_repository.dart';
import 'package:flutter_edge_ai/src/services/remote_size_probe.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
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

  /// Downloads that finished while the app was closed, whose files are
  /// recorded instead of downloaded again (#873). Null: none are reused.
  final CompletedDownloads? completedDownloads;

  /// The size of a file whose finished download did not state it (#873).
  final RemoteSizeProbe? sizeProbe;

  NetworkSourceHandler({
    required this.downloadService,
    required this.fileSystem,
    required this.repository,
    this.huggingFaceToken,
    this.maxDownloadRetries = 10,
    this.completedDownloads,
    this.sizeProbe,
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

    // Download file with cancellation support, unless it already finished
    // while the app was closed (#873).
    if (!await _finishedWhileClosed(
      source.url,
      targetPath,
      token: effectiveToken,
      cancelToken: cancelToken,
    )) {
      await downloadService.download(
        source.url,
        targetPath,
        token: effectiveToken,
        cancelToken: cancelToken,
      );
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

    if (await _finishedWhileClosed(
      source.url,
      targetPath,
      token: effectiveToken,
      cancelToken: cancelToken,
    )) {
      // Finished while the app was closed (#873): nothing to download, but the
      // caller still sees the stream end on 100.
      yield 100;
    } else {
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

  /// Whether the file at [targetPath] is a download of [url] that finished
  /// while the app was closed, to be recorded instead of downloaded again
  /// (#873).
  ///
  /// Only on evidence: [completedDownloads] has a completion of this source
  /// for it, with no live or paused task, and the file is exactly the size
  /// the download's final response stated — or, when it stated none, the size
  /// [sizeProbe] reports. Anything less, and the file is downloaded as before,
  /// over whatever is there; nothing is deleted first.
  Future<bool> _finishedWhileClosed(
    String url,
    String targetPath, {
    String? token,
    CancelToken? cancelToken,
  }) async {
    final completed = completedDownloads;
    if (completed == null) return false;
    final completion = await completed.completedWhileAway(url, targetPath);
    if (completion == null) return false;
    final total =
        completion.totalBytes ??
        await sizeProbe?.sizeOf(url, token: token, cancelToken: cancelToken);
    if (total == null || total <= 0) return false;
    final size = await fileSystem.getFileSize(targetPath);
    if (size != total) {
      edgeAiLog(
        'NetworkSourceHandler: $targetPath finished while the app was closed '
        'but is $size bytes, not $total: downloading it again',
      );
      return false;
    }
    edgeAiLog(
      'NetworkSourceHandler: $targetPath finished while the app was closed '
      '($size bytes): recording it instead of downloading again',
    );
    return true;
  }

  /// Checks if URL is a HuggingFace URL that may require authentication
  bool _isHuggingFaceUrl(String url) {
    final uri = Uri.parse(url);
    return uri.host.contains('huggingface.co');
  }
}

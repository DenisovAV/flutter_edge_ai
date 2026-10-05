import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/infrastructure/web_file_system_service.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:path/path.dart' as path;

/// Handles installation of models from external file paths (WEB PLATFORM)
///
/// On web, FileSource can ONLY work with:
/// 1. HTTP/HTTPS URLs (e.g., https://example.com/model.task)
/// 2. Asset paths (e.g., assets/models/model.task)
///
/// Local file paths (e.g., /path/to/model.task) are NOT supported because
/// web browsers cannot access the local file system.
///
/// This handler:
/// 1. Validates that the path is a URL or asset path
/// 2. Registers the URL with WebFileSystemService
/// 3. Saves metadata to ModelRepository
/// 4. MediaPipe loads directly from the URL
///
/// Features:
/// - URL validation (must be http://, https://, or assets/)
/// - Direct URL registration (no copying)
/// - Single-step progress (URL already exists)
/// - Clear error messages for unsupported paths
///
/// Platform: Web only
class WebFileSourceHandler implements SourceHandler {
  final WebFileSystemService fileSystem;
  final ModelRepository repository;

  WebFileSourceHandler({required this.fileSystem, required this.repository});

  @override
  bool supports(ModelSource source) => source is FileSource;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    // Web file registration is instant, no cancellation needed
    if (source is! FileSource) {
      throw ArgumentError('WebFileSourceHandler only supports FileSource');
    }

    // Validate and normalize the path
    final validatedUrl = _validateAndNormalizePath(source.path);

    // Generate filename from path
    final filename = targetFilename ?? path.basename(source.path);

    // Register URL with WebFileSystemService
    // This allows MediaPipe to look up the URL via getUrl()
    fileSystem.registerUrl(filename, validatedUrl);

    // Save metadata to repository
    // Note: Can't determine file size without HTTP HEAD request
    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: -1, // Unknown for web external files
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
    // Same as above - web file registration is instant
    if (source is! FileSource) {
      throw ArgumentError('WebFileSourceHandler only supports FileSource');
    }

    // Simulate progress for UX consistency
    yield 0;
    await Future.delayed(const Duration(milliseconds: 50));
    yield 50;
    await Future.delayed(const Duration(milliseconds: 50));

    // Validate and normalize the path
    final validatedUrl = _validateAndNormalizePath(source.path);

    // Generate filename from path
    final filename = targetFilename ?? path.basename(source.path);

    // Register URL with WebFileSystemService
    fileSystem.registerUrl(filename, validatedUrl);

    yield 100;

    // Save metadata to repository
    final modelInfo = ModelInfo(
      id: filename,
      source: source,
      installedAt: DateTime.now(),
      sizeBytes: -1, // Unknown for web external files
      type: modelType,
      hasLoraWeights: false,
    );

    await repository.saveModel(modelInfo);
  }

  @override
  bool supportsResume(ModelSource source) {
    // External URLs are instantly registered, no resume needed
    return false;
  }

  /// Validates and normalizes a file path for web platform
  ///
  /// Valid paths:
  /// - HTTP/HTTPS URLs: http://example.com/model.task
  /// - Asset paths: assets/models/model.task
  /// - Asset paths (with prefix): /assets/model.task
  ///
  /// Invalid paths:
  /// - Local file system paths: /path/to/model.task
  /// - Relative paths without 'assets': ../model.task
  ///
  /// Returns the normalized URL that can be used by MediaPipe.
  /// Throws [UnsupportedError] for invalid paths.
  String _validateAndNormalizePath(String path) {
    // HTTP/HTTPS URLs - valid as-is
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }

    // Asset paths - normalize to 'assets/...' format
    if (path.startsWith('assets/') || path.contains('/assets/')) {
      // If already starts with 'assets/', use as-is
      if (path.startsWith('assets/')) {
        return path;
      }
      // Extract assets path: '/some/path/assets/foo.task' -> 'assets/foo.task'
      final assetsIndex = path.indexOf('/assets/');
      return path.substring(assetsIndex + 1); // Remove leading '/'
    }

    // Local file path or unsupported format - throw error
    throw UnsupportedError(
      'FileSource with local file paths is not supported on web platform.\n'
      'Provided path: $path\n'
      'Web platform only supports:\n'
      '  • HTTP/HTTPS URLs: https://example.com/model.task\n'
      '  • Asset paths: assets/models/model.task\n'
      '\n'
      'For URLs, use NetworkSource instead.\n'
      'For assets, use AssetSource instead.',
    );
  }
}

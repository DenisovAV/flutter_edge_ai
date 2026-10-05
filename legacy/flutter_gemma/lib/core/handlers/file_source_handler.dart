import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/handlers/source_handler.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/file_system_service.dart';
import 'package:flutter_gemma/core/services/protected_files_registry.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';
import 'package:path/path.dart' as path;

/// Handles installation of models from external file paths
///
/// Features:
/// - Registers external files (user-provided paths)
/// - Protects files from cleanup operations
/// - No copying (uses external path directly)
/// - Validates file existence before registration
/// - Single-step progress (file already exists)
class FileSourceHandler implements SourceHandler {
  final FileSystemService fileSystem;
  final ProtectedFilesRegistry protectedFiles;
  final ModelRepository repository;

  FileSourceHandler({
    required this.fileSystem,
    required this.protectedFiles,
    required this.repository,
  });

  @override
  bool supports(ModelSource source) => source is FileSource;

  @override
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  }) async {
    // File sources are instant (just registration), no cancellation needed
    if (source is! FileSource) {
      throw ArgumentError('FileSourceHandler only supports FileSource');
    }

    // Verify external file exists
    final exists = await fileSystem.fileExists(source.path);
    if (!exists) {
      throw Exception('External file does not exist: ${source.path}');
    }

    // Generate unique filename for tracking
    final filename = targetFilename ?? path.basename(source.path);

    // Register external file in file system
    await fileSystem.registerExternalFile(filename, source.path);

    // Protect file from cleanup operations
    await protectedFiles.protect(filename);

    // Register external path mapping
    await protectedFiles.registerExternalPath(filename, source.path);

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(source.path);
    assertInstalledFilePresent(sizeBytes, source.path);

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
    // Same as above - file registration is instant
    if (source is! FileSource) {
      throw ArgumentError('FileSourceHandler only supports FileSource');
    }

    // Verify external file exists
    final exists = await fileSystem.fileExists(source.path);
    if (!exists) {
      throw Exception('External file does not exist: ${source.path}');
    }

    // Generate unique filename for tracking
    final filename = targetFilename ?? path.basename(source.path);

    // Register external file in file system
    await fileSystem.registerExternalFile(filename, source.path);

    // Protect file from cleanup operations
    await protectedFiles.protect(filename);

    // Register external path mapping
    await protectedFiles.registerExternalPath(filename, source.path);

    // External files are immediately available, report 100% after registration
    yield 100;

    // Get file size for metadata
    final sizeBytes = await fileSystem.getFileSize(source.path);
    assertInstalledFilePresent(sizeBytes, source.path);

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
    // External files are already complete, no resume needed
    return false;
  }
}

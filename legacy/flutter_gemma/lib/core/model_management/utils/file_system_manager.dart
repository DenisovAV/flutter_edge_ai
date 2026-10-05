part of '../../../mobile/flutter_gemma_mobile.dart';

/// Unified file system operations for model management (Mobile only)
///
/// This class delegates filename utilities to FileNameUtils for platform-agnostic
/// string operations, and provides mobile-specific file system operations.
class ModelFileSystemManager {
  /// Supported model file extensions (delegates to FileNameUtils)
  static const List<String> supportedExtensions =
      FileNameUtils.supportedExtensions;

  /// Small file extensions (configs, tokenizers) - use smaller minimum size
  static const List<String> smallFileExtensions = ['.json', '.model'];

  static const int _defaultMinSizeBytes = 1024 * 1024; // 1MB

  /// Removes all supported extensions from filename (delegates to FileNameUtils)
  ///
  /// Example: 'gemma-2b.task' -> 'gemma-2b'
  ///
  /// Platform Support: All (delegates to platform-agnostic FileNameUtils)
  static String getBaseName(String filename) =>
      FileNameUtils.getBaseName(filename);

  /// Creates regex pattern for matching extensions (delegates to FileNameUtils)
  ///
  /// Example: r'\.(task|bin|tflite|json|model|litertlm)$'
  ///
  /// Platform Support: All (delegates to platform-agnostic FileNameUtils)
  static String get extensionRegexPattern =>
      FileNameUtils.extensionRegexPattern;

  /// Checks if file extension requires smaller minimum size (delegates to FileNameUtils)
  ///
  /// Platform Support: All (delegates to platform-agnostic FileNameUtils)
  static bool isSmallFile(String extension) =>
      FileNameUtils.isSmallFile(extension);

  /// Gets minimum file size based on extension (delegates to FileNameUtils)
  ///
  /// Platform Support: All (delegates to platform-agnostic FileNameUtils)
  static int getMinimumSize(String extension) =>
      FileNameUtils.getMinimumSize(extension);

  /// Corrects Android path from /data/user/0/ to /data/data/ for proper file access
  /// Uses path.join() for cross-platform path separator handling
  static String getCorrectedPath(String originalPath, String filename) {
    // Check if this is the problematic Android path format
    if (originalPath.contains('/data/user/0/')) {
      // Replace with the correct Android app data path
      final correctedPath = originalPath.replaceFirst(
        '/data/user/0/',
        '/data/data/',
      );
      return path.join(correctedPath, filename);
    }
    // For other platforms, use path.join for correct separators (\ on Windows, / on Unix)
    return path.join(originalPath, filename);
  }

  /// Validates if a file exists and meets minimum size requirements
  static Future<bool> isFileValid(
    String filePath, {
    int minSizeBytes = _defaultMinSizeBytes,
  }) async {
    try {
      final file = File(filePath);

      if (!await file.exists()) {
        return false;
      }

      // Basic size check - model files should be at least the minimum size
      final sizeInBytes = await file.length();
      if (sizeInBytes < minSizeBytes) {
        gemmaLog(
          'File $filePath too small: $sizeInBytes bytes (minimum: $minSizeBytes)',
        );
        return false;
      }

      return true;
    } catch (e) {
      gemmaLog('Error validating file $filePath: $e');
      return false;
    }
  }

  /// Gets the full file path for a model file.
  ///
  /// Delegates to [FileSystemService.getTargetPath] so that the correct
  /// storage directory is used on every platform (Android/iOS: Documents;
  /// desktop: Application Support/flutter_gemma/; legacy Desktop: Documents
  /// fallback with a debug-print nudge to re-install).
  static Future<String> getModelFilePath(String filename) async {
    return ServiceRegistry.instance.fileSystemService.getTargetPath(filename);
  }

  /// Get information about orphaned files without deleting them
  ///
  /// ⚠️  This method only returns information, it does NOT delete files.
  /// Call cleanupOrphanedFiles() explicitly to delete them.
  static Future<List<OrphanedFileInfo>> getOrphanedFiles({
    List<String>? protectedFiles,
    List<String>? supportedExtensions,
  }) async {
    final storageDirPath = await ServiceRegistry.instance.fileSystemService
        .getModelStorageDirectory();
    final directory = Directory(storageDirPath);
    final extensions =
        supportedExtensions ?? ModelFileSystemManager.supportedExtensions;
    final protected = protectedFiles ?? [];

    final orphaned = <OrphanedFileInfo>[];

    // v1 limitation: non-recursive + extension-filtered. Directory (ORT-GenAI)
    // models live under `<storage>/<modelId>/…` with `.onnx`/`.onnx_data`/config
    // files that are NOT in [supportedExtensions], so this scan — and
    // getStorageInfo / cleanupStorage, which share it — does NOT see them: it
    // under-reports their (often multi-GB) size and cannot reclaim an orphaned
    // ORT subdirectory. getStorageStats (repo-id based) IS directory-aware, so
    // the two reporting APIs can disagree. A recursive scan is a follow-up; the
    // direction is safe — a directory model is never wrongly deleted, only unseen.
    final files = directory
        .listSync()
        .whereType<File>()
        .where((file) => extensions.any((ext) => file.path.endsWith(ext)))
        .toList();

    for (final file in files) {
      final fileName = path.basename(file.path);

      if (protected.contains(fileName)) {
        continue;
      }

      // Check if has active task
      final hasTask = await _hasActiveDownloadTask(fileName);
      if (hasTask) {
        continue;
      }

      // This file is orphaned
      final stat = await file.stat();
      orphaned.add(
        OrphanedFileInfo(
          filename: fileName,
          path: file.path,
          sizeBytes: stat.size,
          lastModified: stat.modified,
        ),
      );
    }

    // Downloader partial temps are extensionless and live in applicationSupport
    // (Android filesDir), outside the model dir — invisible to the loop above
    // (#383/#3, #6). Scan for them so getOrphanedFiles/cleanupStorage can report
    // and delete them. Android-only: iOS uses opaque URLSession resume data with
    // no filesDir temp. A live/resumable temp is spared via the resume keep-set;
    // explicit cleanup additionally cancels all group tasks first (#383/#5).
    if (Platform.isAndroid) {
      try {
        final downloader = FileDownloader();
        // ignore: invalid_use_of_visible_for_testing_member
        final keep = (await downloader.database.storage.retrieveAllResumeData())
            .map((r) => r.tempFilepath)
            .toSet();
        final supportDir = await getApplicationSupportDirectory();
        for (final entity in supportDir.listSync(followLinks: false)) {
          if (entity is! File) continue;
          final name = path.basename(entity.path);
          if (!isDownloadFragmentName(name)) continue;
          if (keep.contains(entity.path)) continue;
          try {
            final stat = await entity.stat();
            orphaned.add(
              OrphanedFileInfo(
                filename: name,
                path: entity.path,
                sizeBytes: stat.size,
                lastModified: stat.modified,
                isDownloadFragment: true,
              ),
            );
          } catch (_) {
            continue; // vanished mid-scan (e.g. a concurrent reclaim)
          }
        }
      } catch (e) {
        gemmaLog('Fragment scan failed (non-fatal): $e');
      }
    }

    return orphaned;
  }

  /// Get storage statistics
  static Future<StorageStats> getStorageInfo({
    List<String>? protectedFiles,
  }) async {
    final storageDirPath = await ServiceRegistry.instance.fileSystemService
        .getModelStorageDirectory();
    final directory = Directory(storageDirPath);

    final files = directory
        .listSync()
        .whereType<File>()
        .where(
          (file) => supportedExtensions.any((ext) => file.path.endsWith(ext)),
        )
        .toList();

    int totalSize = 0;
    for (final file in files) {
      final stat = await file.stat();
      totalSize += stat.size;
    }

    final orphaned = await getOrphanedFiles(protectedFiles: protectedFiles);

    return StorageStats(
      totalFiles: files.length,
      totalSizeBytes: totalSize,
      orphanedFiles: orphaned,
    );
  }

  /// Check if file has active download task
  static Future<bool> _hasActiveDownloadTask(String filename) async {
    try {
      final downloader = FileDownloader();

      // Check active tasks
      final allTasks = await downloader.allTasks(
        group: SmartDownloader.downloadGroup,
        includeTasksWaitingToRetry: true,
      );

      if (allTasks.any((task) => task.filename == filename)) {
        return true;
      }

      // Check database records
      final records = await downloader.database.allRecords();
      if (records.any(
        (record) =>
            record.task.filename == filename &&
            record.status != TaskStatus.complete,
      )) {
        return true;
      }

      return false;
    } catch (e) {
      gemmaLog('Failed to check active task for $filename: $e');
      return true; // Assume has task to be safe
    }
  }

  /// Cleans up orphaned files
  ///
  /// ⚠️  USER MUST CALL THIS EXPLICITLY - it is NOT called automatically!
  ///
  /// This method deletes files that don't have active download tasks.
  /// Use getOrphanedFiles() first to see what will be deleted.
  ///
  /// Returns the number of files deleted.
  static Future<int> cleanupOrphanedFiles({
    required List<String> protectedFiles,
    List<String>? supportedExtensions,
    bool enableResumeDetection = true,
  }) async {
    gemmaLog('⚠️  cleanupOrphanedFiles() called explicitly by user');

    final orphaned = await getOrphanedFiles(
      protectedFiles: protectedFiles,
      supportedExtensions: supportedExtensions,
    );

    int deletedCount = 0;
    for (final info in orphaned) {
      try {
        await File(info.path).delete();
        deletedCount++;
        gemmaLog('Deleted orphaned file: ${info.filename}');
      } catch (e) {
        gemmaLog('Failed to delete ${info.filename}: $e');
      }
    }

    gemmaLog('Cleaned up $deletedCount orphaned files');
    return deletedCount;
  }

  /// Safely deletes a model file
  static Future<void> deleteModelFile(String filename) async {
    try {
      // A FileSource install is referenced in place under its (possibly
      // namespaced) filename -> its original path; delete THAT, not the
      // managed-dir path the filename would otherwise map to (which is empty
      // for an externally-referenced companion, so uninstall would leave the
      // real file behind).
      final external = await ServiceRegistry.instance.protectedFilesRegistry
          .getExternalPath(filename);
      final filePath = external ?? await getModelFilePath(filename);
      final file = File(filePath);

      if (await file.exists()) {
        await file.delete();
        gemmaLog('Deleted model file: $filename');
      }
    } catch (e) {
      gemmaLog('Failed to delete model file $filename: $e');
      throw ModelStorageException(
        'Failed to delete model file: $filename',
        e,
        'delete',
      );
    }
  }

  /// Ensures a directory exists, creating it if necessary
  static Future<void> ensureDirectoryExists(String dirPath) async {
    try {
      final directory = Directory(dirPath);
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
    } catch (e) {
      gemmaLog('Failed to create directory $dirPath: $e');
      throw ModelStorageException(
        'Failed to create directory: $dirPath',
        e,
        'create_directory',
      );
    }
  }

  /// Gets file size in bytes, returns 0 if file doesn't exist
  static Future<int> getFileSize(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        return await file.length();
      }
      return 0;
    } catch (e) {
      gemmaLog('Failed to get file size for $filePath: $e');
      return 0;
    }
  }

  /// Validates all files in a model specification
  static Future<bool> validateModelFiles(ModelSpec spec) async {
    for (final file in spec.files) {
      // Get file path based on source type
      final String filePath;

      if (file.source is FileSource) {
        // External file - use path from source
        filePath = (file.source as FileSource).path;
      } else if (file.source is BundledSource) {
        // Bundled source - get platform-specific bundled path
        final bundledSource = file.source as BundledSource;
        filePath = await _getBundledResourcePath(bundledSource.resourceName);
      } else {
        // Downloaded/Asset file - use standard app directory
        filePath = await getModelFilePath(file.filename);
      }

      // Platform-specific validation for bundled files
      if (file.source is BundledSource) {
        if (!await _validateBundledResource(filePath)) {
          gemmaLog('Bundled resource validation failed: ${file.filename}');
          return false;
        }
      } else {
        // Standard file validation
        final minSize = file.minimumSizeBytes ?? getMinimumSize(file.extension);

        if (!await isFileValid(filePath, minSizeBytes: minSize)) {
          gemmaLog('Model file validation failed: ${file.filename}');
          return false;
        }
      }
    }
    return true;
  }

  /// Validate bundled resource (platform-specific)
  static Future<bool> _validateBundledResource(String bundledPath) async {
    if (Platform.isAndroid) {
      // Android: MediaPipe uses path without 'assets/' prefix
      return bundledPath.startsWith('models/');
    } else if (Platform.isIOS) {
      // iOS: check if file exists at Bundle path
      final file = File(bundledPath);
      return await file.exists();
    } else if (kIsWeb) {
      // Web: assume valid (checked at runtime by MediaPipe)
      return true;
    }
    return false;
  }

  static const MethodChannel _bundledChannel = MethodChannel(
    'flutter_gemma_bundled',
  );

  /// Get platform-specific bundled resource path
  static Future<String> _getBundledResourcePath(String resourceName) async {
    if (Platform.isAndroid) {
      // Android: MediaPipe expects path WITHOUT 'assets/' prefix
      // MediaPipe internally adds 'assets/' when loading from assets
      return 'models/$resourceName';
    } else if (Platform.isIOS) {
      // iOS: Get real file path from Bundle via platform channel
      try {
        final result = await _bundledChannel.invokeMethod<String>(
          'getBundledResourcePath',
          {'resourceName': resourceName},
        );

        if (result == null) {
          throw FileSystemException(
            'Bundled resource not found in iOS Bundle: $resourceName',
          );
        }

        return result;
      } catch (e) {
        throw FileSystemException(
          'Failed to get iOS bundled path for $resourceName: $e',
        );
      }
    } else if (kIsWeb) {
      return 'assets/models/$resourceName';
    } else {
      throw UnsupportedError(
        'Bundled resources not supported on ${Platform.operatingSystem}',
      );
    }
  }

  /// Cleans up failed download files for a model specification
  static Future<void> cleanupFailedDownload(ModelSpec spec) async {
    gemmaLog('Cleaning up failed download for model: ${spec.name}');

    for (final file in spec.files) {
      try {
        final filePath = await getModelFilePath(file.filename);
        final fileObj = File(filePath);
        if (await fileObj.exists()) {
          await fileObj.delete();
          gemmaLog('Cleaned up partial file: ${file.filename}');
        }
      } catch (e) {
        gemmaLog('Failed to cleanup file ${file.filename}: $e');
      }
    }
  }
}

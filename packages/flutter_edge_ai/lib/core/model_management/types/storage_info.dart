part of '../model_specs.dart';

/// Information about a potentially orphaned file
class OrphanedFileInfo {
  final String filename;
  final String path;
  final int sizeBytes;
  final DateTime? lastModified;
  final bool isDownloadFragment;

  const OrphanedFileInfo({
    required this.filename,
    required this.path,
    required this.sizeBytes,
    this.lastModified,
    this.isDownloadFragment = false,
  });

  double get sizeMB => sizeBytes / (1024 * 1024);

  @override
  String toString() =>
      '$filename${isDownloadFragment ? ' [download fragment]' : ''} '
      '(${sizeMB.toStringAsFixed(2)} MB)';
}

/// Storage statistics
class StorageStats {
  final int totalFiles;
  final int totalSizeBytes;
  final List<OrphanedFileInfo> orphanedFiles;

  const StorageStats({
    required this.totalFiles,
    required this.totalSizeBytes,
    required this.orphanedFiles,
  });

  int get orphanedFilesSize =>
      orphanedFiles.fold(0, (sum, f) => sum + f.sizeBytes);

  double get totalSizeMB => totalSizeBytes / (1024 * 1024);

  /// Download fragments (`background_downloader` partial temps, #383) live
  /// out-of-tree in `applicationSupport`/`filesDir`, outside the model dir
  /// that [totalSizeMB] scans — so this can exceed [totalSizeMB].
  double get orphanedSizeMB => orphanedFilesSize / (1024 * 1024);

  @override
  String toString() {
    return 'StorageStats:\n'
        '  Total files: $totalFiles (${totalSizeMB.toStringAsFixed(2)} MB)\n'
        '  Orphaned files: ${orphanedFiles.length} (${orphanedSizeMB.toStringAsFixed(2)} MB)';
  }
}

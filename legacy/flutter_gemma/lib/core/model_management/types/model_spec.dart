part of '../model_specs.dart';

/// Base enumeration for different model management types
enum ModelManagementType { inference, embedding, stt, tts }

// ModelReplacePolicy is defined in model_specs.dart (this part's library).

/// Represents a single file that belongs to a model
abstract class ModelFile {
  /// Source from which this file can be obtained (NEW: type-safe ModelSource)
  ModelSource get source;

  /// Local filename for this file
  String get filename;

  /// SharedPreferences key for storing this file's installation status
  String get prefsKey;

  /// Whether this file is required for the model to function
  bool get isRequired;

  /// File extension for validation purposes (with leading dot, e.g., '.model')
  String get extension {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot == -1) return '';
    return filename.substring(lastDot); // Returns '.model', '.tflite', etc.
  }

  /// Optional per-file minimum size (bytes) for the download-corruption check.
  /// Null → the validator falls back to the extension heuristic
  /// (`FileNameUtils.getMinimumSize`). Override for files whose real size is
  /// legitimately below the 1 MB default (e.g. a small embedding blob).
  int? get minimumSizeBytes => null;
}

/// Base specification for any model (inference or embedding)
abstract class ModelSpec {
  /// Type of this model
  ModelManagementType get type;

  /// Human-readable name for this model
  String get name;

  /// All files that belong to this model
  List<ModelFile> get files;

  /// Policy for replacing old models
  ModelReplacePolicy get replacePolicy;

  /// Whether this model specification is valid
  bool get isValid => files.isNotEmpty && files.any((f) => f.isRequired);
}

/// Progress information for model downloads
class DownloadProgress {
  final int currentFileIndex;
  final int totalFiles;
  final int currentFileProgress; // 0-100
  final String currentFileName;

  const DownloadProgress({
    required this.currentFileIndex,
    required this.totalFiles,
    required this.currentFileProgress,
    required this.currentFileName,
  });

  /// Overall progress across all files (0-100)
  int get overallProgress {
    if (totalFiles == 0) return 0;

    final completedFiles = currentFileIndex;
    final currentFileWeight = currentFileProgress / 100.0;
    final totalProgress = (completedFiles + currentFileWeight) / totalFiles;

    return (totalProgress * 100).round().clamp(0, 100);
  }

  @override
  String toString() =>
      'DownloadProgress(file $currentFileIndex/$totalFiles, $currentFileProgress%, $currentFileName)';
}

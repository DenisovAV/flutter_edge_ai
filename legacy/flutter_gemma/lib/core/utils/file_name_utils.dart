/// Platform-agnostic filename utilities
///
/// These utilities work on all platforms (mobile + web) and have no
/// dart:io dependencies.
///
/// Features:
/// - Extract base name from filename (remove extensions)
/// - Validate file extensions
/// - Determine minimum file sizes
/// - Generate regex patterns for file matching
///
/// Platform Support: All (web + mobile)
class FileNameUtils {
  /// Supported model file extensions (SINGLE SOURCE OF TRUTH)
  ///
  /// This list defines all file extensions that Flutter Gemma recognizes
  /// as valid model files. Any file with these extensions can be managed
  /// by the model system.
  static const List<String> supportedExtensions = [
    '.task', // MediaPipe task bundles (inference models)
    '.bin', // Binary model files (various formats)
    '.tflite', // TensorFlow Lite models (embedding models)
    '.json', // Config/tokenizer files (metadata)
    '.model', // SentencePiece tokenizers (embedding models)
    '.litertlm', // LiteRT model files (newer format)
  ];

  /// Removes all supported extensions from filename to get base name
  ///
  /// This method strips ALL occurrences of supported extensions from
  /// the filename, not just the last one. This handles cases like
  /// 'model.bin.task' -> 'model'.
  ///
  /// Examples:
  /// - 'gemma-2b.task' -> 'gemma-2b'
  /// - 'model.bin.task' -> 'model'
  /// - 'tokenizer.model' -> 'tokenizer'
  /// - 'config.json' -> 'config'
  /// - 'mymodel' -> 'mymodel' (no extension)
  ///
  /// Platform Support: All (no dart:io dependency)
  ///
  /// Parameters:
  /// - [filename]: The filename to process (can include path)
  ///
  /// Returns: The base name with all extensions removed
  static String getBaseName(String filename) {
    String result = filename;
    for (final ext in supportedExtensions) {
      result = result.replaceAll(ext, '');
    }
    return result;
  }

  /// Creates regex pattern for matching any supported extension
  ///
  /// Generates a regex pattern that matches filenames ending with
  /// any of the supported extensions. Useful for file filtering
  /// and validation.
  ///
  /// Example output: r'\.(task|bin|tflite|json|model|litertlm)$'
  ///
  /// Usage:
  /// ```dart
  /// final pattern = RegExp(FileNameUtils.extensionRegexPattern);
  /// final hasValidExtension = pattern.hasMatch('model.task'); // true
  /// ```
  ///
  /// Platform Support: All
  ///
  /// Returns: A regex pattern string for matching supported extensions
  static String get extensionRegexPattern {
    final extensions = supportedExtensions
        .map((e) => e.substring(1)) // Remove leading dot
        .join('|');
    return r'\.(' + extensions + r')$';
  }

  /// Checks if file extension requires smaller minimum size
  ///
  /// Some files (configs, tokenizers) are naturally small and don't
  /// need the 1MB minimum size check that model files require.
  ///
  /// Small file extensions:
  /// - .json (config files, typically <100KB)
  /// - .model (SentencePiece tokenizers, typically <500KB)
  ///
  /// Platform Support: All
  ///
  /// Parameters:
  /// - [extension]: File extension to check (with leading dot, e.g., '.json')
  ///
  /// Returns: true if extension is for small files, false otherwise
  static bool isSmallFile(String extension) {
    const smallFileExtensions = ['.json', '.model'];
    return smallFileExtensions.contains(extension);
  }

  /// Gets minimum file size based on extension
  ///
  /// Returns appropriate minimum size threshold for file validation:
  /// - Small files (.json, .model): 1KB (1024 bytes)
  /// - Model files (all others): 1MB (1048576 bytes)
  ///
  /// This helps detect corrupted or incomplete downloads.
  ///
  /// Platform Support: All
  ///
  /// Parameters:
  /// - [extension]: File extension (with leading dot, e.g., '.bin')
  ///
  /// Returns: Minimum valid file size in bytes
  static int getMinimumSize(String extension) {
    const defaultMinSizeBytes = 1024 * 1024; // 1MB for model files
    const smallFileMinSizeBytes = 1024; // 1KB for config/tokenizer files
    return isSmallFile(extension) ? smallFileMinSizeBytes : defaultMinSizeBytes;
  }

  /// Extracts file extension from filename
  ///
  /// Examples:
  /// - 'model.task' -> '.task'
  /// - 'file.bin.task' -> '.task' (last extension)
  /// - 'noextension' -> '' (empty string)
  ///
  /// Platform Support: All
  ///
  /// Parameters:
  /// - [filename]: The filename to extract extension from
  ///
  /// Returns: The file extension (with leading dot) or empty string if none
  static String getExtension(String filename) {
    final lastDot = filename.lastIndexOf('.');
    if (lastDot == -1 || lastDot == filename.length - 1) {
      return '';
    }
    return filename.substring(lastDot);
  }

  /// Validates if filename has a supported extension
  ///
  /// Platform Support: All
  ///
  /// Parameters:
  /// - [filename]: The filename to validate
  ///
  /// Returns: true if filename has a supported extension, false otherwise
  static bool hasValidExtension(String filename) {
    final extension = getExtension(filename);
    return supportedExtensions.contains(extension);
  }

  /// Validates if file meets minimum size requirements
  ///
  /// Platform Support: All
  ///
  /// Parameters:
  /// - [filename]: The filename to check extension from
  /// - [fileSize]: The actual file size in bytes
  ///
  /// Returns: true if file meets minimum size for its type, false otherwise
  static bool isFileValid(String filename, int fileSize) {
    final extension = getExtension(filename);
    final minSize = getMinimumSize(extension);
    return fileSize >= minSize;
  }

  /// Prefixes [basename] with the owning model's [modelId] so a companion
  /// file (a tokenizer, an aux bundle member) never collides on disk or in
  /// the install-identity cache key with the SAME basename belonging to a
  /// DIFFERENT model (e.g. moonshine's and whisper's tokenizers are both
  /// literally named `tokenizer.json`; embeddinggemma's and Gecko's
  /// tokenizers are both literally named `sentencepiece.model`).
  ///
  /// [modelId] is the owning model's own stable identity — in practice the
  /// model's own (already-unique) weight-file basename without extension,
  /// e.g. `FileNameUtils.getBaseName(modelFile.filename)`.
  ///
  /// Uses a double-underscore separator (`__`) to avoid ambiguity with
  /// underscores that already appear inside real model ids (e.g.
  /// `moonshine_tiny_5s_f32`).
  ///
  /// Idempotent: if [basename] is already namespaced under this EXACT
  /// [modelId], it is returned unchanged instead of being double-prefixed
  /// (`modelId__modelId__basename`). This matters because the active-model
  /// restore path on mobile reconstructs `ModelFile`s from a `FileSource`
  /// that already points at a namespaced on-disk path (see
  /// `MobileModelManager._restoreActiveEmbeddingModel` /
  /// `_restoreActiveSttModel` / `_restoreActiveTtsModel`); when that
  /// reconstructed file's `.files` getter re-derives its basename and calls
  /// this method again, it must be a no-op.
  static String namespaced(String modelId, String basename) {
    final prefix = '${modelId}__';
    if (basename.startsWith(prefix)) return basename;
    return '$prefix$basename';
  }

  /// A filesystem-safe directory name for a DIRECTORY model (ORT-GenAI)
  /// installed from a Hugging Face repo. Unlike [namespaced] (which produces a
  /// FLAT `modelId__basename` prefix), a directory model's files must keep their
  /// BARE leaf names inside a real subdirectory — `genai_config.json` references
  /// its siblings by bare name and the native loader is handed the directory.
  ///
  /// [repo] is the HF `org/name`; [variant] is the resolved execution-provider
  /// subfolder when the resolver picked one (e.g. `cpu_and_mobile/cpu-int4-…`)
  /// — it MUST be part of the id, or two EP variants of the same repo would
  /// share one directory and `OgaCreateModel` could load a `genai_config.json`
  /// from one against a `model.onnx` from the other.
  ///
  /// The `/` separators (repo owner, nested variant) and any other character
  /// outside `[A-Za-z0-9._-]` collapse to the `__` separator, so the result is a
  /// single path segment safe on POSIX and Windows and free of the `/` that the
  /// restore path uses to split `modelId` from the bare leaf. Idempotent for an
  /// already-sanitized id.
  ///
  /// **v1 limitation — not injective.** A literal `_` passes through while `/`
  /// and other disallowed runs collapse to `__`, so two distinct
  /// `(repo, variant)` inputs can map to the same id (e.g.
  /// `sanitizeHfDirName('a/b__c')` and `sanitizeHfDirName('a/b', variant: 'c')`
  /// both → `a__b__c`). Collision odds for real ORT-GenAI repo/variant names are
  /// very low; if two colliding installs did occur, the second would silently
  /// skip download (its members read as "already installed"). Reserving a
  /// distinct join token is a follow-up if it ever bites.
  ///
  /// Throws [ArgumentError] if [repo]/[variant] sanitize to an empty or
  /// dot-only name (`.`/`..`): `.` survives the charset filter, so a literal
  /// `".."` repo would otherwise pass through verbatim and — interpolated as a
  /// path segment — escape the model storage directory (a `deleteModel` on such
  /// a spec would recursively delete its PARENT).
  static String sanitizeHfDirName(String repo, {String? variant}) {
    final raw = variant == null || variant.isEmpty ? repo : '$repo/$variant';
    final sanitized = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '__');
    // Trim any leading/trailing separators so the id is never empty-segmented.
    final result = sanitized.replaceAll(RegExp(r'^_+|_+$'), '');
    if (result.isEmpty || result == '.' || result == '..') {
      throw ArgumentError.value(
        raw,
        'repo/variant',
        'sanitizes to "$result" — an empty or dot-only directory name that '
            'would escape the model storage directory',
      );
    }
    return result;
  }
}

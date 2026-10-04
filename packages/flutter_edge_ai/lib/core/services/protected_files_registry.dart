/// Abstraction for managing protected files
/// Protected files are NOT deleted during cleanup operations
///
/// Use cases:
/// - External files (FileSource) should never be deleted
/// - Currently downloading files should be protected
/// - Active model files should be protected
///
/// Platform implementations:
/// - SharedPreferencesProtectedRegistry: uses SharedPreferences
/// - InMemoryProtectedRegistry: for testing
abstract interface class ProtectedFilesRegistry {
  /// Marks a file as protected from cleanup
  ///
  /// Protected files will not be deleted by cleanup operations
  Future<void> protect(String filename);

  /// Removes protection from a file
  ///
  /// File can now be deleted by cleanup operations
  Future<void> unprotect(String filename);

  /// Checks if a file is protected
  Future<bool> isProtected(String filename);

  /// Gets all protected files
  ///
  /// Returns list of filenames (not full paths)
  Future<List<String>> getProtectedFiles();

  /// Clears all protections
  ///
  /// Use with caution! This removes protection from ALL files
  Future<void> clearAll();

  /// Registers an external file path mapping
  ///
  /// This is specifically for FileSource - maps internal filename
  /// to external file path so we can find it later
  ///
  /// Example:
  /// ```dart
  /// registry.registerExternalPath('model.bin', '/tmp/user_model.bin');
  /// ```
  Future<void> registerExternalPath(String filename, String externalPath);

  /// Gets the external path for a filename
  ///
  /// Returns null if no external path registered
  Future<String?> getExternalPath(String filename);
}

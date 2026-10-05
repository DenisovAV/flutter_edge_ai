import 'dart:typed_data';

/// Abstraction for file system operations
/// Allows different implementations for different platforms (mobile/web)
/// and easy mocking in tests
///
/// Platform implementations:
/// - PlatformFileSystemService: uses dart:io for mobile
/// - WebFileSystemService: uses IndexedDB/LocalStorage for web
abstract interface class FileSystemService {
  /// Writes data to a file at the given path
  ///
  /// Creates parent directories if they don't exist
  ///
  /// Throws:
  /// - [FileSystemException] if write fails
  Future<void> writeFile(String path, Uint8List data);

  /// Reads data from a file at the given path
  ///
  /// Throws:
  /// - [FileSystemException] if file doesn't exist or read fails
  Future<Uint8List> readFile(String path);

  /// Deletes a file at the given path
  ///
  /// Does nothing if file doesn't exist
  ///
  /// Throws:
  /// - [FileSystemException] if delete fails
  Future<void> deleteFile(String path);

  /// Checks if a file exists at the given path
  Future<bool> fileExists(String path);

  /// Gets the size of a file in bytes
  ///
  /// Returns 0 if file doesn't exist
  Future<int> getFileSize(String path);

  /// Gets the target path for storing a model file with given filename.
  ///
  /// Returns the canonical write destination (no legacy probe). Writers
  /// must use this method so that files always land in the correct location
  /// and never accidentally migrate to the legacy Documents path.
  ///
  /// Example: '/data/data/com.app/files/model.bin'
  Future<String> getWriteTargetPath(String filename);

  /// Gets the path for reading a model file with given filename.
  ///
  /// On desktop (macOS/Windows/Linux) performs a legacy-Documents fallback
  /// probe so that models installed before 0.15.1 (which stored everything
  /// in `~/Documents/`) continue to load on upgrade without a forced
  /// re-install. A single debug log is emitted per unique legacy path to
  /// nudge the user to re-install.
  ///
  /// Writers must use [getWriteTargetPath] instead.
  Future<String> getReadTargetPath(String filename);

  /// Deprecated. Use [getReadTargetPath] for reads or [getWriteTargetPath]
  /// for writes to route paths correctly.
  @Deprecated(
    'Use getReadTargetPath for reads or getWriteTargetPath for writes',
  )
  Future<String> getTargetPath(String filename);

  /// Gets the path to a bundled native resource
  ///
  /// This is platform-specific:
  /// - Android: assets/models/{resourceName}
  /// - iOS: Bundle.main.path(forResource:)
  /// - Web: /assets/{resourceName}
  ///
  /// Throws:
  /// - [UnsupportedError] if bundled resources not supported
  /// - [FileSystemException] if resource not found
  Future<String> getBundledResourcePath(String resourceName);

  /// Registers an external file path (for FileSource)
  ///
  /// This marks the file as external so it won't be cleaned up
  /// The actual path mapping is stored in ProtectedFilesRegistry
  Future<void> registerExternalFile(String filename, String externalPath);

  /// Returns the canonical directory where model files are stored.
  ///
  /// On mobile this is the app's Documents directory; on desktop it is the
  /// platform-appropriate Application Support subdirectory that avoids
  /// cloud-synced paths (see [PlatformFileSystemService._getDocumentsDirectory]).
  ///
  /// Returns the directory path as a [String] so that this interface remains
  /// usable without importing [dart:io] (which is unavailable on Web).
  ///
  /// Throws [UnsupportedError] on Web (no local file system).
  Future<String> getModelStorageDirectory();

  /// Migration-only (install-identity-namespacing, 2026-08-02): if a file
  /// already exists on disk under [oldFilename] (the pre-refactor flat
  /// name) and nothing exists yet under [newFilename] (the namespaced
  /// identity), renames it in place and returns true — the caller should
  /// treat this as "already installed" and persist repository metadata
  /// under [newFilename] instead of re-downloading. Returns false when
  /// there is nothing to adopt: no old file, [newFilename] already exists,
  /// or `oldFilename == newFilename` (nothing changed identity, so there is
  /// nothing to migrate).
  ///
  /// SAFE ONLY when the caller KNOWS the file under [oldFilename] belongs to
  /// the model it is adopting it into — the old flat name carries no type
  /// marker, so a blind adoption could hand this model another model's file
  /// and resurrect the exact collision this refactor fixes. Two call patterns
  /// satisfy that precondition:
  ///   1. The old basename is UNIQUE across the whole model catalog (e.g. a
  ///      TTS bundle's `.tflite` graphs, or a TTS basename gated on
  ///      [TtsModelType]-catalog uniqueness in `TtsInstallationBuilder`) — a
  ///      unique name can only have been written by the one model that owns it.
  ///   2. The caller is migrating a SINGLE KNOWN active model (the active-model
  ///      restore paths in `MobileModelManager`/`WebModelManager`): the model's
  ///      own id disambiguates the owner even for a colliding-basename companion
  ///      (`tokenizer.json`, `sentencepiece.model`), because the pre-refactor
  ///      collision meant only the last-installed = active model's file could
  ///      exist under the plain name.
  /// NEVER call this for a colliding-basename companion at plain INSTALL time
  /// (where the on-disk plain file could belong to any previously-installed
  /// model). See
  /// `docs/superpowers/specs/2026-08-02-install-identity-namespacing-design.md`.
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename);
}

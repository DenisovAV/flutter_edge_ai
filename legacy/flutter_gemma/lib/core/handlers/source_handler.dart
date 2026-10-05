import 'package:flutter_gemma/core/domain/model_source.dart';
import 'package:flutter_gemma/core/model_management/cancel_token.dart';
import 'package:flutter_gemma/core/services/model_repository.dart';

/// Base interface for handling different model source types
/// Each source type (Network, Asset, Bundled, File) has its own handler implementation
///
/// This follows the Strategy pattern and allows for:
/// - Type-safe handling of each source type
/// - Dependency injection of platform-specific services
/// - Easy testing with mocks
/// - Extension with new source types without modifying existing code (OCP)
abstract interface class SourceHandler {
  /// Checks if this handler supports the given source type
  ///
  /// Example:
  /// ```dart
  /// final handler = NetworkSourceHandler(...);
  /// handler.supports(ModelSource.network('https://...')); // true
  /// handler.supports(ModelSource.asset('assets/...')); // false
  /// ```
  bool supports(ModelSource source);

  /// Installs the model from the given source
  ///
  /// This method performs the actual installation:
  /// - NetworkSource: downloads from URL
  /// - AssetSource: copies from Flutter assets
  /// - BundledSource: accesses native resources
  /// - FileSource: registers external file path
  ///
  /// Parameters:
  /// - [source]: The model source to install from
  /// - [cancelToken]: Optional token for cancelling the installation
  /// - [targetFilename]: Optional override for the installed file's
  ///   identity (write-target basename, `ModelInfo.id`, and — on web — the
  ///   registration/cache key). Defaults to null, which reproduces today's
  ///   behavior: the basename is derived from [source] (URL path segment /
  ///   asset path / bundled resource name / file path). Passed by the four
  ///   `*InstallationBuilder`s so a companion file's on-disk identity can be
  ///   namespaced by its owning model (see
  ///   `docs/superpowers/specs/2026-08-02-install-identity-namespacing-design.md`).
  ///
  /// Throws:
  /// - [UnsupportedError] if this handler doesn't support the source type
  /// - [ArgumentError] if the source is invalid
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// - Platform-specific exceptions for download/file errors
  /// [modelType]: the repository model-type tag written to ModelInfo
  /// (defaults to inference; STT/TTS/embedding builders override).
  Future<void> install(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  });

  /// Installs the model with progress tracking
  ///
  /// Returns a stream of progress percentages (0-100)
  ///
  /// Parameters:
  /// - [source]: The model source to install from
  /// - [cancelToken]: Optional token for cancelling the installation
  /// - [targetFilename]: See [install].
  ///
  /// Note: Some sources may not support true progress:
  /// - AssetSource: simulates progress (copy is instant)
  /// - BundledSource: returns 100 immediately (no download)
  /// - FileSource: returns 100 immediately (just registration)
  ///
  /// Example:
  /// ```dart
  /// final cancelToken = CancelToken();
  ///
  /// try {
  ///   await for (final progress in handler.installWithProgress(
  ///     source,
  ///     cancelToken: cancelToken,
  ///   )) {
  ///     print('Progress: $progress%');
  ///   }
  /// } catch (e) {
  ///   if (CancelToken.isCancel(e)) {
  ///     print('Installation cancelled');
  ///   }
  /// }
  /// ```
  ///
  /// Throws:
  /// - [DownloadCancelledException] if cancelled via cancelToken
  /// [modelType]: the repository model-type tag written to ModelInfo
  /// (defaults to inference; STT/TTS/embedding builders override).
  Stream<int> installWithProgress(
    ModelSource source, {
    CancelToken? cancelToken,
    String? targetFilename,
    ModelType modelType = ModelType.inference,
  });

  /// Checks if this source supports resume after interruption
  ///
  /// Only NetworkSource typically supports resume
  bool supportsResume(ModelSource source);
}

/// Fail loudly when an install "succeeded" but no usable file landed at
/// [targetPath].
///
/// [FileSystemService.getFileSize] returns 0 for a missing file (and for a
/// genuine 0-byte file), so a non-positive [sizeBytes] means there is no
/// installable model. Throwing here prevents persisting a broken "installed"
/// record that `isModelInstalled()` / `validateModelFiles` then rejects — the
/// silent failure the Windows download-path fix closed on the network path.
///
/// NOTE: intentionally NOT used by `BundledSourceHandler` — a bundled native
/// resource (Android APK asset, iOS bundle) is not a stat-able filesystem file,
/// so `getFileSize` can legitimately return 0 there without the resource being
/// absent.
void assertInstalledFilePresent(int sizeBytes, String targetPath) {
  if (sizeBytes <= 0) {
    throw StateError(
      'Install reported success but no usable file (0 bytes) was found at '
      '"$targetPath". The model was not installed.',
    );
  }
}

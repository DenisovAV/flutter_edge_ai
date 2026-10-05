import 'dart:io';
import 'package:flutter_gemma/core/utils/gemma_log.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:flutter_gemma/core/services/file_system_service.dart';

/// Platform-specific file system implementation using dart:io
///
/// Features:
/// - Uses path_provider for platform directories
/// - Supports Android and iOS
/// - Automatic parent directory creation
/// - External file registration tracking
class PlatformFileSystemService implements FileSystemService {
  // Cache for app documents directory
  Directory? _documentsDirectory;

  @override
  Future<void> writeFile(String filePath, Uint8List data) async {
    final file = File(filePath);

    // Create parent directories if they don't exist
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    await file.writeAsBytes(data);
  }

  @override
  Future<Uint8List> readFile(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      throw FileSystemException('File not found', filePath);
    }

    return await file.readAsBytes();
  }

  @override
  Future<void> deleteFile(String filePath) async {
    final file = File(filePath);

    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<bool> fileExists(String filePath) async {
    final file = File(filePath);
    return await file.exists();
  }

  @override
  Future<int> getFileSize(String filePath) async {
    final file = File(filePath);

    if (!await file.exists()) {
      return 0;
    }

    final stat = await file.stat();
    return stat.size;
  }

  /// Per-process set of legacy paths already logged; prevents log spam on
  /// repeated reads (e.g. every `isModelInstalled` check).
  static final Set<String> _legacyFallbackLogged = {};

  @override
  Future<String> getWriteTargetPath(String filename) async {
    final dir = await _getDocumentsDirectory();
    return path.join(dir.path, filename);
  }

  @override
  Future<String> getReadTargetPath(String filename) async {
    final dir = await _getDocumentsDirectory();
    final newPath = path.join(dir.path, filename);

    // Backward-compat: if model file isn't in the new location but exists
    // in pre-0.15.1 Documents (where desktop stored everything before the
    // OneDrive/iCloud-sync fix), keep using that path so existing installs
    // don't break on upgrade. Writes always go to the new location.
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
        !await File(newPath).exists()) {
      final legacy = await getApplicationDocumentsDirectory();
      final legacyPath = path.join(legacy.path, filename);
      if (await File(legacyPath).exists()) {
        if (_legacyFallbackLogged.add(legacyPath)) {
          gemmaLog(
            '[flutter_gemma] Reading model from legacy Documents path; '
            'consider re-installing to migrate: $legacyPath',
          );
        }
        return legacyPath;
      }
    }
    return newPath;
  }

  @Deprecated(
    'Use getReadTargetPath for reads or getWriteTargetPath for writes',
  )
  @override
  Future<String> getTargetPath(String filename) => getReadTargetPath(filename);

  @override
  Future<String> getModelStorageDirectory() async {
    final dir = await _getDocumentsDirectory();
    return dir.path;
  }

  @override
  Future<String> getBundledResourcePath(String resourceName) async {
    // Web doesn't support bundled resources via this service
    if (kIsWeb) {
      throw UnsupportedError('Bundled resources not supported on web platform');
    }

    // Platform-specific bundled resource handling
    if (Platform.isAndroid) {
      // Android: Copy from native assets to filesDir (MediaPipe can't read from APK directly)
      final dir = await _getDocumentsDirectory();
      final destPath = path.join(dir.path, resourceName);
      final destFile = File(destPath);

      // Check if already copied
      if (await destFile.exists()) {
        return destPath;
      }

      // Copy from native assets via platform channel
      const platform = MethodChannel('flutter_gemma_bundled');
      final result = await platform.invokeMethod<String>('copyAssetToFile', {
        'assetPath': 'models/$resourceName',
        'destPath': destPath,
      });

      if (result == null || result != 'success') {
        throw Exception('Failed to copy asset from Android assets');
      }

      return destPath;
    } else if (Platform.isIOS) {
      // On iOS, MediaPipe CAN read directly from Bundle (after iOS native fix)
      // Simply get the bundle path and return it - no copying needed!
      const platform = MethodChannel('flutter_gemma_bundled');
      final bundlePath = await platform.invokeMethod<String>(
        'getBundledResourcePath',
        {'resourceName': resourceName},
      );

      if (bundlePath == null) {
        throw Exception('Bundled resource not found: $resourceName');
      }

      return bundlePath;
    } else {
      throw UnsupportedError(
        'Bundled resources not supported on ${Platform.operatingSystem}',
      );
    }
  }

  @override
  Future<void> registerExternalFile(
    String filename,
    String externalPath,
  ) async {
    // External file registration is handled by ProtectedFilesRegistry
    // This method is a no-op here since file system doesn't track registrations
    // The actual tracking is done in ProtectedFilesRegistry.registerExternalPath()
  }

  @override
  Future<bool> adoptLegacyFile(String oldFilename, String newFilename) async {
    if (oldFilename == newFilename) return false;
    final newPath = await getWriteTargetPath(newFilename);
    if (await File(newPath).exists()) return false;
    // Locate the old file via the READ path (which includes the desktop
    // legacy-Documents fallback), not getWriteTargetPath — otherwise a
    // companion installed before the 0.15.1 path routing sits in Documents and
    // adoption silently never finds it. Rename it to the canonical write path.
    final oldPath = await getReadTargetPath(oldFilename);
    final oldFile = File(oldPath);
    if (!await oldFile.exists()) return false;
    await oldFile.rename(newPath);
    gemmaLog(
      '[flutter_gemma] Migrated legacy install "$oldFilename" -> '
      '"$newFilename" (install-identity-namespacing)',
    );
    return true;
  }

  /// Gets the model storage directory with caching.
  ///
  /// Mobile (Android, iOS): app's Documents — sandboxed, never cloud-synced.
  /// Desktop:
  ///   - Windows: `%LOCALAPPDATA%\flutter_gemma\` — truly local, never
  ///     OneDrive-synced (unlike Documents or Roaming AppData). NOTE:
  ///     path_provider's `getApplicationSupportDirectory()` returns
  ///     `%APPDATA%` (Roaming) which is Domain-synced in corporate envs,
  ///     so we use LOCALAPPDATA directly via env var.
  ///   - macOS/Linux: `getApplicationSupportDirectory()` — not cloud-synced
  ///     by default.
  Future<Directory> _getDocumentsDirectory() async {
    // Web doesn't support local file system
    if (kIsWeb) {
      throw UnsupportedError('Local file system not supported on web platform');
    }

    final cached = _documentsDirectory;
    if (cached != null) {
      return cached;
    }

    final Directory dir;
    if (Platform.isAndroid || Platform.isIOS) {
      dir = await getApplicationDocumentsDirectory();
    } else if (Platform.isWindows) {
      // Windows: prefer LOCALAPPDATA (never OneDrive-synced, unlike
      // Documents or Roaming AppData). But the env var is unreliable:
      // some shells / dev containers / sandboxes return it relative
      // ("Users\me\AppData\Local") or empty, in which case the
      // resulting Directory resolves against $PWD at access time —
      // a moving target that breaks install/validate roundtrips.
      // See https://github.com/DenisovAV/flutter_gemma/issues/<...>
      // for the original bug report.
      //
      // Defence in depth:
      //   1. Read LOCALAPPDATA; accept only if non-empty AND absolute.
      //   2. Otherwise compose from USERPROFILE + \AppData\Local if
      //      USERPROFILE itself is absolute.
      //   3. Last resort: path_provider's getApplicationSupportDirectory()
      //      (Roaming AppData via the Windows SHGetKnownFolderPath API).
      final local = Platform.environment['LOCALAPPDATA'];
      Directory? base;
      if (local != null && local.isNotEmpty && path.isAbsolute(local)) {
        base = Directory(local);
      } else {
        if (local != null && local.isNotEmpty) {
          gemmaLog(
            '[flutter_gemma] LOCALAPPDATA is not absolute '
            '("$local") — falling back to USERPROFILE / Application '
            'Support. Models would otherwise land in a \$PWD-relative '
            'directory.',
          );
        }
        final userProfile = Platform.environment['USERPROFILE'];
        if (userProfile != null &&
            userProfile.isNotEmpty &&
            path.isAbsolute(userProfile)) {
          base = Directory(path.join(userProfile, 'AppData', 'Local'));
        } else {
          base = await getApplicationSupportDirectory();
        }
      }
      dir = Directory(path.join(base.path, 'flutter_gemma'));
    } else {
      // macOS, Linux — namespace under flutter_gemma/ inside Application
      // Support so models don't pollute the package root.
      final base = await getApplicationSupportDirectory();
      dir = Directory(path.join(base.path, 'flutter_gemma'));
    }

    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _documentsDirectory = dir;
    return dir;
  }
}

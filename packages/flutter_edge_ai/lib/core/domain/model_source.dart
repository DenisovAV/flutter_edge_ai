import 'package:flutter/foundation.dart' show kIsWeb;

// Constants for URL schemes and validation
const _httpScheme = 'http';
const _httpsScheme = 'https';
const _assetsPrefix = 'assets/';
const _pathSeparator = '/';
const _parentDirReference = '..';

/// Sealed class representing all possible model sources
/// Provides type-safe alternative to string URLs
sealed class ModelSource {
  const ModelSource();

  /// Creates a network-based source (HTTPS/HTTP)
  ///
  /// [foreground] controls Android foreground service:
  /// - null (default): NO foreground service — this branch configures no
  ///   notification, and the platform needs one before it starts the service
  /// - true: always use foreground (shows notification)
  /// - false: never use foreground
  factory ModelSource.network(
    String url, {
    String? authToken,
    bool? foreground,
  }) = NetworkSource;

  /// Creates an asset-based source (Flutter assets)
  factory ModelSource.asset(String path) = AssetSource;

  /// Creates a bundled resource source (native resources)
  factory ModelSource.bundled(String resourceName) = BundledSource;

  /// Creates a file-based source (external files, mobile only)
  factory ModelSource.file(String path) = FileSource;

  /// Whether this source requires downloading
  bool get requiresDownload;

  /// Whether this source supports progress tracking
  bool get supportsProgress;

  /// Whether this source supports resume after interruption
  bool get supportsResume;

  /// Validates if LoRA source is compatible with this model source
  bool validateLoraSource(ModelSource loraSource);

  /// Compact string representation for SharedPreferences-based active-model
  /// persistence (#227). Format: `<kind>|<value>` where kind ∈ {`network`,
  /// `asset`,`bundled`,`file`}. Auth tokens are NOT encoded — restored
  /// network sources will re-request without auth and let the file system
  /// service serve the previously-cached blob instead of re-downloading.
  String encode() => switch (this) {
    NetworkSource(:final url) => 'network|$url',
    AssetSource(:final path) => 'asset|$path',
    BundledSource(:final resourceName) => 'bundled|$resourceName',
    FileSource(:final path) => 'file|$path',
  };

  /// Decode the string produced by [encode]. Returns null if the input
  /// is malformed or names an unknown kind (forward-compat).
  static ModelSource? tryDecode(String? encoded) {
    if (encoded == null) return null;
    final pipe = encoded.indexOf('|');
    if (pipe <= 0) return null;
    final kind = encoded.substring(0, pipe);
    final value = encoded.substring(pipe + 1);
    try {
      return switch (kind) {
        'network' => NetworkSource(value),
        'asset' => AssetSource(value),
        'bundled' => BundledSource(value),
        'file' => FileSource(value),
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}

/// Network source - downloads from HTTPS/HTTP URLs
final class NetworkSource extends ModelSource {
  final String url;
  final String? authToken;

  /// Whether to use foreground service on Android (shows notification)
  /// - null: NO foreground service (no notification is configured)
  /// - true: always use foreground
  /// - false: never use foreground
  final bool? foreground;

  NetworkSource(this.url, {this.authToken, this.foreground}) {
    if (url.isEmpty) {
      throw ArgumentError('URL cannot be empty');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || ![_httpScheme, _httpsScheme].contains(uri.scheme)) {
      throw ArgumentError('Invalid URL: $url. Must be HTTP or HTTPS.');
    }
  }

  /// Whether the connection uses HTTPS
  bool get isSecure => url.startsWith('$_httpsScheme://');

  @override
  bool get requiresDownload => true;

  @override
  bool get supportsProgress => true;

  @override
  bool get supportsResume => true;

  @override
  bool validateLoraSource(ModelSource loraSource) =>
      loraSource is NetworkSource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NetworkSource &&
          other.url == url &&
          other.authToken == authToken &&
          other.foreground == foreground;

  @override
  int get hashCode => Object.hash(url, authToken, foreground);

  @override
  String toString() =>
      'NetworkSource(url: $url, secure: $isSecure, hasToken: ${authToken != null}, foreground: $foreground)';
}

/// Asset source - copies from Flutter assets
final class AssetSource extends ModelSource {
  final String path;

  AssetSource(this.path) {
    if (path.isEmpty) {
      throw ArgumentError('Asset path cannot be empty');
    }
    if (path.contains(_parentDirReference)) {
      throw ArgumentError('Asset path cannot contain "$_parentDirReference"');
    }
    if (path.startsWith(_httpScheme)) {
      throw ArgumentError('Asset path cannot be a URL');
    }
  }

  /// Normalized path with 'assets/' prefix (for Flutter asset system)
  String get normalizedPath {
    String normalized = path;
    if (normalized.startsWith(_pathSeparator)) {
      normalized = normalized.substring(1);
    }
    if (!normalized.startsWith(_assetsPrefix)) {
      normalized = '$_assetsPrefix$normalized';
    }
    return normalized;
  }

  /// Path WITHOUT 'assets/' prefix (for native platform lookupKey)
  /// Example: 'assets/models/file.task' → 'models/file.task'
  String get pathForLookupKey {
    String result = normalizedPath;
    if (result.startsWith(_assetsPrefix)) {
      result = result.substring(_assetsPrefix.length);
    }
    return result;
  }

  @override
  bool get requiresDownload => false;

  @override
  bool get supportsProgress => true; // Simulated

  @override
  bool get supportsResume => false;

  @override
  bool validateLoraSource(ModelSource loraSource) => loraSource is AssetSource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AssetSource && other.normalizedPath == normalizedPath;

  @override
  int get hashCode => normalizedPath.hashCode;

  @override
  String toString() => 'AssetSource(path: $normalizedPath)';
}

/// Bundled source - native platform resources
final class BundledSource extends ModelSource {
  final String resourceName;

  BundledSource(this.resourceName) {
    if (resourceName.isEmpty) {
      throw ArgumentError('Resource name cannot be empty');
    }
    if (resourceName.contains(_pathSeparator)) {
      throw ArgumentError('Resource name cannot contain "$_pathSeparator"');
    }
    if (resourceName.contains(' ')) {
      throw ArgumentError('Resource name cannot contain spaces');
    }
    // Note: lowercase validation removed - Android/iOS support case-sensitive names
  }

  @override
  bool get requiresDownload => false;

  @override
  bool get supportsProgress => false; // Instant access

  @override
  bool get supportsResume => false;

  @override
  bool validateLoraSource(ModelSource loraSource) =>
      loraSource is BundledSource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BundledSource && other.resourceName == resourceName;

  @override
  int get hashCode => resourceName.hashCode;

  @override
  String toString() => 'BundledSource(resourceName: $resourceName)';
}

/// File source - external files (mobile only)
final class FileSource extends ModelSource {
  final String path;

  FileSource(this.path) {
    if (kIsWeb) {
      throw UnsupportedError('File sources are not supported on web platform');
    }
    if (path.isEmpty) {
      throw ArgumentError('File path cannot be empty');
    }
    if (!path.startsWith('/') && !RegExp(r'^[A-Za-z]:[/\\]').hasMatch(path)) {
      throw ArgumentError('File path must be absolute');
    }
  }

  @override
  bool get requiresDownload => false;

  @override
  bool get supportsProgress => false;

  @override
  bool get supportsResume => false;

  @override
  bool validateLoraSource(ModelSource loraSource) => loraSource is FileSource;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FileSource && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'FileSource(path: $path)';
}

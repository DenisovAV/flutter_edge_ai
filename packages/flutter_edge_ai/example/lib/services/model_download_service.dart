import 'package:flutter/foundation.dart';
import 'catalog_install.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/services/auth_token_service.dart';
import 'package:flutter_edge_ai_example/utils/platform_io_helper.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class ModelDownloadService {
  ModelDownloadService({
    required this.modelUrl,
    required this.modelFilename,
    required this.licenseUrl,
    required this.modelType,
    this.fileType = ModelFileType.task,
    this.foreground,
    this.catalogVariant,
  });

  /// The model registry build to install, when the model is one: then it is
  /// installed with `FlutterEdgeAi.installModelFromCatalog`, which takes the type,
  /// file type and pinned URL from it and checks the file's size.
  final CatalogVariant? catalogVariant;

  final String modelUrl;
  final String modelFilename;
  final String licenseUrl;
  final ModelType modelType;
  final ModelFileType fileType;

  /// Whether to use foreground service on Android for large downloads.
  /// - null: auto-detect based on file size (>500MB = foreground)
  /// - true: always use foreground (shows notification, bypasses 9-min timeout)
  /// - false: never use foreground
  final bool? foreground;

  /// Load the token from SharedPreferences.
  Future<String?> loadToken() => AuthTokenService.loadToken();

  /// Save the token to SharedPreferences.
  Future<void> saveToken(String token) => AuthTokenService.saveToken(token);

  /// Helper method to get the file path.
  Future<String> getFilePath() async {
    // Use the same path correction logic as the unified system
    final directory = await getApplicationDocumentsDirectory();
    // Apply Android path correction for consistency with unified download system
    final correctedPath = directory.path.contains('/data/user/0/')
        ? directory.path.replaceFirst('/data/user/0/', '/data/data/')
        : directory.path;
    return '$correctedPath/$modelFilename';
  }

  /// Checks if the model file exists and matches the remote file size.
  /// The name core installs the model under: the catalog's install name for
  /// a registry build, otherwise the URL's file name.
  String get installedName {
    if (catalogVariant case InferenceVariant(file: final file?)) {
      return file.installFilename;
    }
    final uri = Uri.parse(modelUrl);
    return uri.pathSegments.isNotEmpty ? uri.pathSegments.last : modelFilename;
  }

  Future<bool> checkModelExistence(String token) async {
    try {
      // The name core installs the model under.
      final actualFilename = installedName;

      // Modern API: Check if model is installed using actual filename
      final isInstalled = await FlutterEdgeAi.isModelInstalled(actualFilename);

      if (isInstalled) {
        return true;
      }

      // Fallback: check physical file existence with size validation
      // (not available on web — File/path_provider don't work in WASM)
      if (kIsWeb) {
        return false;
      }

      final filePath = await getFilePath();
      final file = createFile(filePath);

      if (!file.existsSync()) {
        return false;
      }

      // Validate size if possible
      final Map<String, String> headers = token.isNotEmpty
          ? {'Authorization': 'Bearer $token'}
          : {};

      try {
        final headResponse = await http.head(
          Uri.parse(modelUrl),
          headers: headers,
        );
        if (headResponse.statusCode == 200) {
          final contentLengthHeader = headResponse.headers['content-length'];
          if (contentLengthHeader != null) {
            final remoteFileSize = int.parse(contentLengthHeader);
            return await file.length() == remoteFileSize;
          }
        }
      } catch (e) {
        // HEAD request failed (e.g., CORS on web), trust file existence
        if (kDebugMode) {
          debugPrint('HEAD request failed, trusting file existence: $e');
        }
        return true;
      }

      return true; // File exists, size validation failed/skipped
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking model existence: $e');
      }
    }
    return false;
  }

  /// Downloads the model file and tracks progress using Modern API.
  ///
  /// [confirmReplace] is asked before an active model in the way of a
  /// catalog install is uninstalled (see `installFromCatalogReplacingActive`).
  Future<void> downloadModel({
    required String token,
    required Function(double) onProgress,
    required Future<bool> Function(ActiveModelInTheWay model, int bytes)
    confirmReplace,
  }) async {
    try {
      // Convert empty string to null for cleaner API
      final authToken = token.isEmpty ? null : token;

      if (catalogVariant case final InferenceVariant variant) {
        await installFromCatalogReplacingActive(
          () =>
              FlutterEdgeAi.installModelFromCatalog(
                    variant,
                    token: authToken,
                    foreground: foreground,
                  )
                  .withProgress((progress) => onProgress(progress.toDouble()))
                  .install(),
          variant: variant,
          confirm: confirmReplace,
        );
        return;
      }
      // Modern API: Install inference model from network with progress tracking
      await FlutterEdgeAi.installModel(modelType: modelType, fileType: fileType)
          .fromNetwork(modelUrl, token: authToken, foreground: foreground)
          .withProgress((progress) {
            onProgress(progress.toDouble());
          })
          .install();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error downloading model: $e');
      }
      rethrow;
    }
  }

  /// Deletes the downloaded file and metadata.
  Future<void> deleteModel() async {
    try {
      // The name core installed the model under.
      final actualFilename = installedName;

      // Use Modern API to properly uninstall (deletes metadata + file)
      await FlutterEdgeAi.uninstallModel(actualFilename);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error deleting model: $e');
      }
    }
  }
}

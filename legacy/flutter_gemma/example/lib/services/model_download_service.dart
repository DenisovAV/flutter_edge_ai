import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/api/flutter_gemma.dart';
import 'package:flutter_gemma/core/model.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/utils/platform_io_helper.dart';
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
  });

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
  Future<bool> checkModelExistence(String token) async {
    try {
      // Extract SAME filename that Modern API will use during download
      final uri = Uri.parse(modelUrl);
      final actualFilename = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : modelFilename;

      // Modern API: Check if model is installed using actual filename
      final isInstalled = await FlutterGemma.isModelInstalled(actualFilename);

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
  Future<void> downloadModel({
    required String token,
    required Function(double) onProgress,
  }) async {
    try {
      // Convert empty string to null for cleaner API
      final authToken = token.isEmpty ? null : token;

      // Modern API: Install inference model from network with progress tracking
      await FlutterGemma.installModel(modelType: modelType, fileType: fileType)
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
      // Extract actual filename used by Modern API
      final uri = Uri.parse(modelUrl);
      final actualFilename = uri.pathSegments.isNotEmpty
          ? uri.pathSegments.last
          : modelFilename;

      // Use Modern API to properly uninstall (deletes metadata + file)
      await FlutterGemma.uninstallModel(actualFilename);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error deleting model: $e');
      }
    }
  }
}

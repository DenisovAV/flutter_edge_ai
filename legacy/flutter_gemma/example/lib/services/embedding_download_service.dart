import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart'; // For EmbeddingModelSpec
import 'package:flutter_gemma_example/models/base_model.dart'; // For ModelSourceType
import 'package:flutter_gemma_example/models/embedding_model.dart'
    as example_embedding_model;
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:path_provider/path_provider.dart';

class EmbeddingModelDownloadService {
  final example_embedding_model.EmbeddingModel model;

  EmbeddingModelDownloadService({required this.model});

  /// Load the token from SharedPreferences.
  Future<String?> loadToken() => AuthTokenService.loadToken();

  /// Save the token to SharedPreferences.
  Future<void> saveToken(String token) => AuthTokenService.saveToken(token);

  /// Helper method to get the model file path.
  Future<String> getModelFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/${model.filename}';
  }

  /// Helper method to get the tokenizer file path.
  Future<String> getTokenizerFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/${model.tokenizerFilename}';
  }

  /// Checks if both model and tokenizer files exist and match remote file sizes.
  Future<bool> checkModelExistence(String token) async {
    try {
      // Extract SAME filenames that Modern API will use during download
      String extractFilename(String url, ModelSourceType sourceType) {
        if (sourceType == ModelSourceType.network) {
          final uri = Uri.parse(url);
          return uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : model.filename;
        }
        // For asset/bundled, use the path as-is
        return url.split('/').last;
      }

      final modelFilename = extractFilename(model.url, model.sourceType);
      final tokenizerFilename = extractFilename(
        model.tokenizerUrl,
        model.sourceType,
      );

      // Check if both files are installed using actual filenames
      final modelInstalled = await FlutterGemma.isModelInstalled(modelFilename);
      final tokenizerInstalled = await FlutterGemma.isModelInstalled(
        tokenizerFilename,
      );

      final installed = modelInstalled && tokenizerInstalled;

      if (installed) {
        debugPrint('[EmbeddingDownloadService] Model files are installed');
        return true;
      }

      debugPrint('[EmbeddingDownloadService] Model files are NOT installed');
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking model existence: $e');
      }
      return false;
    }
  }

  /// Downloads both model and tokenizer with progress tracking using Modern API.
  ///
  /// [onProgress] callback receives (modelProgress, tokenizerProgress) as doubles 0-100
  Future<void> downloadModel(
    String token,
    void Function(double modelProgress, double tokenizerProgress) onProgress,
  ) async {
    try {
      double modelProgress = 0;
      double tokenizerProgress = 0;

      // Start building the installer
      var builder = FlutterGemma.installEmbedder();

      // Add model source based on sourceType
      switch (model.sourceType) {
        case ModelSourceType.network:
          final authToken = token.isEmpty ? null : token;
          builder = builder.modelFromNetwork(model.url, token: authToken);
        case ModelSourceType.asset:
          builder = builder.modelFromAsset(model.url);
        case ModelSourceType.bundled:
          builder = builder.modelFromBundled(model.url);
      }

      // Add tokenizer source based on sourceType
      switch (model.sourceType) {
        case ModelSourceType.network:
          final authToken = token.isEmpty ? null : token;
          builder = builder.tokenizerFromNetwork(
            model.tokenizerUrl,
            token: authToken,
          );
        case ModelSourceType.asset:
          builder = builder.tokenizerFromAsset(model.tokenizerUrl);
        case ModelSourceType.bundled:
          builder = builder.tokenizerFromBundled(model.tokenizerUrl);
      }

      // Add progress callbacks and install
      await builder
          .withModelProgress((progress) {
            modelProgress = progress.toDouble();
            onProgress(modelProgress, tokenizerProgress);
          })
          .withTokenizerProgress((progress) {
            tokenizerProgress = progress.toDouble();
            onProgress(modelProgress, tokenizerProgress);
          })
          .install();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error downloading embedding model: $e');
      }
      rethrow;
    }
  }

  /// Deletes both downloaded files and metadata.
  Future<void> deleteModel() async {
    try {
      // Extract actual filenames used by Modern API
      String extractFilename(String url, ModelSourceType sourceType) {
        if (sourceType == ModelSourceType.network) {
          final uri = Uri.parse(url);
          return uri.pathSegments.isNotEmpty
              ? uri.pathSegments.last
              : model.filename;
        }
        return url.split('/').last;
      }

      final modelFilename = extractFilename(model.url, model.sourceType);
      final tokenizerFilename = extractFilename(
        model.tokenizerUrl,
        model.sourceType,
      );

      // Use Modern API to properly uninstall (deletes metadata + files)
      await FlutterGemma.uninstallModel(modelFilename);
      await FlutterGemma.uninstallModel(tokenizerFilename);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error deleting embedding model: $e');
      }
    }
  }

  /// Check if the embedding model is installed
  Future<bool> isEmbeddingModelInstalled() async {
    try {
      // Modern API: Check if both files are installed
      final modelInstalled = await FlutterGemma.isModelInstalled(
        model.filename,
      );
      final tokenizerInstalled = await FlutterGemma.isModelInstalled(
        model.tokenizerFilename,
      );
      return modelInstalled && tokenizerInstalled;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking embedding model installation: $e');
      }
      // Fallback to file existence check
      return await checkModelExistence('');
    }
  }
}

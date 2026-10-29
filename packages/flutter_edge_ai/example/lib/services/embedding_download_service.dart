import 'package:flutter/foundation.dart';
import 'catalog_install.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'; // For EmbeddingModelSpec
import 'package:flutter_edge_ai_example/models/embedding_model.dart'
    as example_embedding_model;
import 'package:flutter_edge_ai_example/services/auth_token_service.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
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

  /// Helper method to get the tokenizer file path; null for a `.litertlm`
  /// bundle, which carries its own tokenizer.
  Future<String?> getTokenizerFilePath() async {
    final tokenizer = model.tokenizerFilename;
    if (tokenizer == null) return null;
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/$tokenizer';
  }

  /// Whether the model's tokenizer is installed — trivially true for a
  /// `.litertlm` bundle, which has none.
  Future<bool> _tokenizerInstalled() async {
    final tokenizer = model.tokenizerFilename;
    return tokenizer == null || await FlutterEdgeAi.isModelInstalled(tokenizer);
  }

  /// Checks if both model and tokenizer files exist and match remote file sizes.
  Future<bool> checkModelExistence(String token) async {
    try {
      // Catalog identities are intentionally versioned. Never treat the old
      // URL basename cache as this immutable revision.
      final modelInstalled = await FlutterEdgeAi.isModelInstalled(
        model.filename,
      );
      final tokenizerInstalled = await _tokenizerInstalled();

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

      final authToken = token.isEmpty ? null : token;
      if (model.catalogVariant case final variant?) {
        // A model registry build: fromCatalog installs the model and its
        // tokenizer under their fixed names and checks their sizes.
        final hasTokenizer = variant.tokenizer != null;
        await installFromCatalogReplacingActive(
          () => FlutterEdgeAi.installEmbedder()
              .fromCatalog(variant, token: authToken)
              .withModelProgress((progress) {
                modelProgress = progress.toDouble();
                onProgress(
                  modelProgress,
                  hasTokenizer ? tokenizerProgress : modelProgress,
                );
              })
              .withTokenizerProgress((progress) {
                tokenizerProgress = progress.toDouble();
                onProgress(modelProgress, tokenizerProgress);
              })
              .install(),
          uninstall: FlutterEdgeAi.uninstallEmbedder,
        );
        await persistVerifiedEmbeddingCatalogSelection(model);
        return;
      }
      final builder = withCatalogEmbedderSources(
        FlutterEdgeAi.installEmbedder(),
        model,
        token: authToken,
      );

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
      await persistVerifiedEmbeddingCatalogSelection(model);
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
      final wasActive =
          FlutterEdgeAi.activeEmbedderSpec?.files.any(
            (file) => file.filename == model.filename,
          ) ??
          false;
      // Use Modern API to properly uninstall (deletes metadata + files)
      await FlutterEdgeAi.uninstallModel(model.filename);
      final tokenizer = model.tokenizerFilename;
      if (tokenizer != null) await FlutterEdgeAi.uninstallModel(tokenizer);
      if (wasActive) {
        await FlutterEdgeAi.clearActiveEmbeddingIdentity();
        await clearEmbeddingCatalogProvenance();
      }
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
      final modelInstalled = await FlutterEdgeAi.isModelInstalled(
        model.filename,
      );
      return modelInstalled && await _tokenizerInstalled();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error checking embedding model installation: $e');
      }
      // Fallback to file existence check
      return await checkModelExistence('');
    }
  }
}

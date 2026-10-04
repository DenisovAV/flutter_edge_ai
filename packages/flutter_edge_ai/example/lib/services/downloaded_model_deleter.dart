import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/services/downloaded_model_loader.dart';
import 'package:flutter_edge_ai_example/utils/installed_model_lookup.dart';

class DownloadedModelDeleter {
  const DownloadedModelDeleter._();

  /// Whether deleting [installedId] will also remove its shared tokenizer file.
  static Future<bool> willUninstallTokenizer(String installedId) async {
    final match = resolveCatalog(installedId);
    if (match is! EmbeddingMatch || match.isTokenizer) return false;

    final tokenizerId = match.model.tokenizerFilename;
    if (tokenizerId == installedId) return false;
    if (!await FlutterEdgeAi.isModelInstalled(tokenizerId)) return false;

    return !await isEmbeddingTokenizerStillNeeded(
      tokenizerFilename: tokenizerId,
      removedModelFilename: installedId,
    );
  }

  static Future<void> delete(String installedId) async {
    if (loadedModelIds().contains(installedId)) {
      await DownloadedModelLoader.unloadAllInMemory();
    }

    final match = resolveCatalog(installedId);
    if (match is EmbeddingMatch && !match.isTokenizer) {
      await FlutterEdgeAi.uninstallModel(installedId);
      final tokenizerId = match.model.tokenizerFilename;
      if (tokenizerId != installedId &&
          await FlutterEdgeAi.isModelInstalled(tokenizerId) &&
          !await isEmbeddingTokenizerStillNeeded(
            tokenizerFilename: tokenizerId,
            removedModelFilename: installedId,
          )) {
        await FlutterEdgeAi.uninstallModel(tokenizerId);
      }
      await _clearActiveIdentityIfUninstalled(installedId);
      return;
    }

    await FlutterEdgeAi.uninstallModel(installedId);
    await _clearActiveIdentityIfUninstalled(installedId);
  }

  static Future<void> _clearActiveIdentityIfUninstalled(
    String installedId,
  ) async {
    if (activeInferenceModelId() == installedId) {
      await FlutterEdgeAi.clearActiveInferenceIdentity();
    }
    if (isActiveEmbeddingArtifact(installedId)) {
      await FlutterEdgeAi.clearActiveEmbeddingIdentity();
    }
  }
}

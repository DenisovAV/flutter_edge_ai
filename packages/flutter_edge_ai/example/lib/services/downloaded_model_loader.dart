import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/services/auth_token_service.dart';
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_edge_ai_example/utils/installed_model_lookup.dart';

class DownloadedModelLoader {
  const DownloadedModelLoader._();

  static Future<void> unloadAllInMemory() async {
    final plugin = FlutterEdgeAiPlugin.instance;
    await plugin.initializedModel?.close();
    await plugin.initializedEmbeddingModel?.close();
  }

  static Future<void> load(String installedId) async {
    final match = resolveCatalog(installedId);
    if (match == null) {
      throw StateError('Cannot load unknown model: $installedId');
    }

    final loaded = loadedModelIds();
    if (loaded.length == 1 && loaded.contains(installedId)) {
      if (match is EmbeddingMatch && !match.isTokenizer) {
        await resolveActiveEmbeddingCatalogProfile();
      }
      return;
    }

    if (match is EmbeddingMatch && match.isTokenizer) {
      throw StateError('Tokenizer files cannot be loaded directly');
    }

    await unloadAllInMemory();

    if (match is InferenceMatch) {
      await _loadInference(match);
      return;
    }
    if (match is TranslationMatch) {
      await _loadTranslation(match);
      return;
    }
    if (match is EmbeddingMatch) {
      await _loadEmbedding(match);
      return;
    }
  }

  static Future<void> _loadInference(InferenceMatch match) async {
    final model = match.model;
    final installer = FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: model.fileType,
    );

    if (model.localModel) {
      await installer.fromAsset(model.url).install();
    } else {
      String? token;
      if (model.needsAuth) {
        token = await AuthTokenService.loadToken();
      }
      await installer.fromNetwork(model.url, token: token).install();
    }

    await FlutterEdgeAi.getActiveModel(
      maxTokens: model.maxTokens,
      preferredBackend: model.preferredBackend,
      supportImage: model.supportImage,
      supportAudio: model.supportAudio,
      maxNumImages: model.maxNumImages,
    );
  }

  static Future<void> _loadTranslation(TranslationMatch match) async {
    final model = match.model;
    String? token;
    if (model.needsAuth) {
      token = await AuthTokenService.loadToken();
    }

    await FlutterEdgeAi.installModel(
      modelType: model.modelType,
      fileType: model.fileType,
    ).fromNetwork(model.url, token: token).install();

    await FlutterEdgeAi.getActiveModel(
      maxTokens: model.maxTokens,
      preferredBackend: model.preferredBackend,
    );
  }

  static Future<void> _loadEmbedding(EmbeddingMatch match) async {
    final model = match.model;
    String? token;
    if (model.needsAuth) {
      token = await AuthTokenService.loadToken();
    }

    var builder = FlutterEdgeAi.installEmbedder();

    switch (model.sourceType) {
      case ModelSourceType.network:
        builder = builder.modelFromNetwork(
          model.url,
          token: token,
          filename: model.filename,
        );
      case ModelSourceType.asset:
        builder = builder.modelFromAsset(model.url, filename: model.filename);
      case ModelSourceType.bundled:
        builder = builder.modelFromBundled(model.url, filename: model.filename);
    }

    switch (model.sourceType) {
      case ModelSourceType.network:
        builder = builder.tokenizerFromNetwork(
          model.tokenizerUrl,
          token: token,
          filename: model.tokenizerFilename,
        );
      case ModelSourceType.asset:
        builder = builder.tokenizerFromAsset(
          model.tokenizerUrl,
          filename: model.tokenizerFilename,
        );
      case ModelSourceType.bundled:
        builder = builder.tokenizerFromBundled(
          model.tokenizerUrl,
          filename: model.tokenizerFilename,
        );
    }

    await builder.install();
    await persistVerifiedEmbeddingCatalogSelection(model);
    await FlutterEdgeAi.getActiveEmbedder(
      preferredBackend: PreferredBackend.gpu,
    );

    if (kDebugMode) {
      debugPrint(
        '[DownloadedModelLoader] Loaded embedding model: ${model.filename}',
      );
    }
  }
}

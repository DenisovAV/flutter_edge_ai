import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_example/models/base_model.dart';
import 'package:flutter_gemma_example/services/auth_token_service.dart';
import 'package:flutter_gemma_example/utils/installed_model_lookup.dart';

class DownloadedModelLoader {
  const DownloadedModelLoader._();

  static Future<void> unloadAllInMemory() async {
    final plugin = FlutterGemmaPlugin.instance;
    await plugin.initializedModel?.close();
    await plugin.initializedEmbeddingModel?.close();
  }

  static Future<void> load(String installedId) async {
    final loaded = loadedModelIds();
    if (loaded.length == 1 && loaded.contains(installedId)) {
      return;
    }

    final match = resolveCatalog(installedId);
    if (match == null) {
      throw StateError('Cannot load unknown model: $installedId');
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
    final installer = FlutterGemma.installModel(
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

    await FlutterGemma.getActiveModel(
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

    await FlutterGemma.installModel(
      modelType: model.modelType,
      fileType: model.fileType,
    ).fromNetwork(model.url, token: token).install();

    await FlutterGemma.getActiveModel(
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

    var builder = FlutterGemma.installEmbedder();

    switch (model.sourceType) {
      case ModelSourceType.network:
        builder = builder.modelFromNetwork(model.url, token: token);
      case ModelSourceType.asset:
        builder = builder.modelFromAsset(model.url);
      case ModelSourceType.bundled:
        builder = builder.modelFromBundled(model.url);
    }

    switch (model.sourceType) {
      case ModelSourceType.network:
        builder = builder.tokenizerFromNetwork(
          model.tokenizerUrl,
          token: token,
        );
      case ModelSourceType.asset:
        builder = builder.tokenizerFromAsset(model.tokenizerUrl);
      case ModelSourceType.bundled:
        builder = builder.tokenizerFromBundled(model.tokenizerUrl);
    }

    await builder.install();
    await FlutterGemma.getActiveEmbedder(
      preferredBackend: PreferredBackend.gpu,
    );

    if (kDebugMode) {
      debugPrint(
        '[DownloadedModelLoader] Loaded embedding model: ${model.filename}',
      );
    }
  }
}

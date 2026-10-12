import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;

/// Points [builder] at [model]'s files, from where the catalog says they live:
/// the model, and its tokenizer when it has one. A self-contained `.litertlm`
/// bundle (EmbeddingGemma 2) carries its own tokenizer, so it installs one
/// file — passing a tokenizer for it is refused by the installer.
EmbeddingInstallationBuilder withCatalogEmbedderSources(
  EmbeddingInstallationBuilder builder,
  catalog.EmbeddingModel model, {
  String? token,
}) {
  final b = switch (model.sourceType) {
    ModelSourceType.network => builder.modelFromNetwork(
      model.url,
      token: token,
      filename: model.filename,
    ),
    ModelSourceType.asset => builder.modelFromAsset(
      model.url,
      filename: model.filename,
    ),
    ModelSourceType.bundled => builder.modelFromBundled(
      model.url,
      filename: model.filename,
    ),
  };
  final tokenizerUrl = model.tokenizerUrl;
  if (tokenizerUrl == null) return b;
  return switch (model.sourceType) {
    ModelSourceType.network => b.tokenizerFromNetwork(
      tokenizerUrl,
      token: token,
      filename: model.tokenizerFilename,
    ),
    ModelSourceType.asset => b.tokenizerFromAsset(
      tokenizerUrl,
      filename: model.tokenizerFilename,
    ),
    ModelSourceType.bundled => b.tokenizerFromBundled(
      tokenizerUrl,
      filename: model.tokenizerFilename,
    ),
  };
}

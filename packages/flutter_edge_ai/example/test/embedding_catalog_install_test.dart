import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a .litertlm bundle installs one file; every other entry its model and '
      'its tokenizer, from where the catalog says', () {
    for (final model in catalog.EmbeddingModel.values) {
      final builder = _RecordingBuilder();
      final returned = withCatalogEmbedderSources(
        builder,
        model,
        token: 'hf_x',
      );
      expect(identical(returned, builder), isTrue, reason: model.name);

      final kind = switch (model.sourceType) {
        ModelSourceType.network => 'Network',
        ModelSourceType.asset => 'Asset',
        ModelSourceType.bundled => 'Bundled',
      };
      final token = model.sourceType == ModelSourceType.network ? 'hf_x' : null;
      expect(builder.calls, [
        'modelFrom$kind(${model.url}, ${model.filename}, $token)',
        if (model.tokenizerUrl != null)
          'tokenizerFrom$kind(${model.tokenizerUrl}, '
              '${model.tokenizerFilename}, $token)',
      ], reason: model.name);
    }
  });

  test('EmbeddingGemma 2 gets no tokenizer at all', () {
    final builder = _RecordingBuilder();
    withCatalogEmbedderSources(
      builder,
      catalog.EmbeddingModel.embeddingGemma2Text270m,
    );
    expect(builder.calls.where((c) => c.startsWith('tokenizer')), isEmpty);
  });
}

/// Records which sources the helper set, in order.
final class _RecordingBuilder implements EmbeddingInstallationBuilder {
  final calls = <String>[];

  @override
  EmbeddingInstallationBuilder modelFromNetwork(
    String url, {
    String? token,
    String? filename,
    int? expectedSize,
    String? expectedSha256,
  }) {
    calls.add('modelFromNetwork($url, $filename, $token)');
    return this;
  }

  @override
  EmbeddingInstallationBuilder modelFromAsset(String path, {String? filename}) {
    calls.add('modelFromAsset($path, $filename, null)');
    return this;
  }

  @override
  EmbeddingInstallationBuilder modelFromBundled(
    String resourceName, {
    String? filename,
  }) {
    calls.add('modelFromBundled($resourceName, $filename, null)');
    return this;
  }

  @override
  EmbeddingInstallationBuilder tokenizerFromNetwork(
    String url, {
    String? token,
    String? filename,
    int? expectedSize,
    String? expectedSha256,
  }) {
    calls.add('tokenizerFromNetwork($url, $filename, $token)');
    return this;
  }

  @override
  EmbeddingInstallationBuilder tokenizerFromAsset(
    String path, {
    String? filename,
  }) {
    calls.add('tokenizerFromAsset($path, $filename, null)');
    return this;
  }

  @override
  EmbeddingInstallationBuilder tokenizerFromBundled(
    String resourceName, {
    String? filename,
  }) {
    calls.add('tokenizerFromBundled($resourceName, $filename, null)');
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

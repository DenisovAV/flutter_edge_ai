// Small catalogs for the catalog tests: hand-written subclasses of the core
// base classes, the way an engine's generated catalog extends them.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show TtsModelTypeManifest;

const rev = '0123456789abcdef0123456789abcdef01234567';

ModelArtifact artifact(
  String path, {
  int size = 1024 * 1024 + 16,
  String? installFilename,
  String sha = 'aa',
}) => ModelArtifact(
  repo: 'litert-community/tiny',
  revision: rev,
  path: path,
  sha256: sha,
  sizeBytes: size,
  installFilename: installFilename ?? path.split('/').last,
);

final class TestNpu extends NpuTarget {
  const TestNpu(this.npuVendor, this.socModel);

  @override
  final NpuVendor? npuVendor;

  @override
  final String socModel;
}

final class TestLlm extends InferenceVariant {
  TestLlm(
    this.slug, {
    this.modelId = 'tiny-llm',
    ModelArtifact? file,
    this.npuTarget,
    this.backendsHere = const {PreferredBackend.cpu, PreferredBackend.gpu},
    this.modelType = ModelType.gemma4,
    this.fileType = ModelFileType.litertlm,
    this.noFile = false,
  }) : _file = file ?? artifact('$slug.litertlm');

  final String slug;
  final ModelArtifact _file;
  final bool noFile;

  @override
  ModelArtifact? get file => noFile ? null : _file;

  @override
  final String modelId;

  @override
  String get id => '$modelId/$slug';

  @override
  String get catalogName => 'test_catalog';

  @override
  final NpuTarget? npuTarget;

  @override
  final Set<PreferredBackend> backendsHere;

  @override
  final ModelType modelType;

  @override
  final ModelFileType fileType;

  @override
  ModelRuntimeDefaults get runtimeDefaults =>
      const ModelRuntimeDefaults(maxTokens: 4096);
}

final class TestEmbedder extends EmbedderVariant {
  TestEmbedder({
    required this.model,
    this.tokenizer,
    this.ragProfileId = 'tiny-embedder-v1',
  });

  @override
  final ModelArtifact model;

  @override
  final ModelArtifact? tokenizer;

  @override
  final String ragProfileId;

  @override
  String get id => 'tiny-embedder/seq256';

  @override
  String get modelId => 'tiny-embedder';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.cpu};

  @override
  int get dimension => 768;

  @override
  int get maxInputTokens => 256;

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};
}

/// A Matcha bundle: one artifact per manifest file, all of [size] bytes.
final class TestTts extends TtsVariant {
  TestTts({
    int size = 1024 * 1024 + 16,
    this.type = TtsModelType.matcha,
    bool dropLast = false,
  }) : files = [for (final name in type.manifest) artifact(name, size: size)]
         ..length -= dropLast ? 1 : 0;

  @override
  final List<ModelArtifact> files;

  @override
  final TtsModelType type;

  @override
  String get baseUrl =>
      'https://huggingface.co/litert-community/tiny/resolve/$rev/';

  @override
  String get id => 'tiny-tts/bundle';

  @override
  String get modelId => 'tiny-tts';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.cpu};
}

final class TestStt extends SttVariant {
  TestStt({int modelSize = 1024 * 1024 + 16, String? modelInstallFilename})
    : model = artifact(
        'tiny_stt.tflite',
        size: modelSize,
        installFilename: modelInstallFilename,
      ),
      tokenizer = artifact('tiny_stt_tokenizer.json');

  @override
  final ModelArtifact model;

  @override
  final ModelArtifact tokenizer;

  @override
  SttModelType get type => SttModelType.moonshine;

  @override
  String get id => 'tiny-stt/f32';

  @override
  String get modelId => 'tiny-stt';

  @override
  String get catalogName => 'test_catalog';

  @override
  Set<PreferredBackend> get backendsHere => const {PreferredBackend.cpu};
}

final class TestModel extends CatalogModel {
  TestModel(this.id, this.variants, {this.displayName = 'Tiny'});

  @override
  final String id;

  @override
  final List<CatalogVariant> variants;

  @override
  final String displayName;

  @override
  String get family => 'tiny';

  @override
  String get archClass => 'dense';

  @override
  String get license => 'apache-2.0';

  @override
  String get licenseUrl => 'https://www.apache.org/licenses/LICENSE-2.0';
}

final class TestCatalog extends ModelCatalog {
  TestCatalog(this.name, this.models);

  @override
  final String name;

  @override
  final List<CatalogModel> models;
}

/// A provider that ships [modelCatalog], like an engine package.
final class TestSource implements ModelCatalogSource {
  TestSource(this.modelCatalog);

  @override
  final ModelCatalog modelCatalog;
}

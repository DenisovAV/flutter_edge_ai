// Small catalogs for the catalog tests: hand-written subclasses of the core
// base classes, the way an engine's generated catalog extends them.

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show TtsAbsoluteUrl, TtsModelTypeManifest, TtsRelativeSuffix;

const rev = '0123456789abcdef0123456789abcdef01234567';

/// A well-formed sha256 (64 hex digits): core checks its form, never the
/// bytes.
const sha64 =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// The artifact [type]'s installer downloads for [name] under [base]: its own
/// repo, or the absolute URL the type fetches it from (Inflect's G2P files).
ModelArtifact ttsArtifact(
  TtsModelType type,
  String name, {
  required int size,
  String revision = rev,
}) {
  switch (type.fetchLocationFor(name)) {
    case TtsAbsoluteUrl(:final url):
      final parts = Uri.parse(url).pathSegments; // owner/repo/resolve/rev/…
      return artifact(
        parts.skip(4).join('/'),
        size: size,
        repo: '${parts[0]}/${parts[1]}',
        revision: parts[3],
        installFilename: name,
      );
    case TtsRelativeSuffix(:final suffix):
      return artifact(
        suffix,
        size: size,
        installFilename: name,
        revision: revision,
      );
  }
}

ModelArtifact artifact(
  String path, {
  int size = 1024 * 1024 + 16,
  String? installFilename,
  String sha = sha64,
  String repo = 'litert-community/tiny',
  String revision = rev,
}) => ModelArtifact(
  repo: repo,
  revision: revision,
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
    this.backendsHere = const {PreferredBackend.cpu},
  });

  @override
  final Set<PreferredBackend> backendsHere;

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
    this.revision = rev,
    String? baseUrl,
    List<String> extra = const [],
    bool repeatFirst = false,
  }) : baseUrl =
           baseUrl ??
           'https://huggingface.co/litert-community/tiny/resolve/$revision/',
       files = [
         for (final name in type.manifest)
           ttsArtifact(type, name, size: size, revision: revision),
         if (repeatFirst)
           ttsArtifact(
             type,
             type.manifest.first,
             size: size,
             revision: revision,
           ),
         for (final name in extra)
           ttsArtifact(type, name, size: size, revision: revision),
       ]..length -= dropLast ? 1 : 0;

  @override
  final List<ModelArtifact> files;

  @override
  final TtsModelType type;

  /// The commit the bundle's own files are pinned to.
  final String revision;

  @override
  final String baseUrl;

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
  TestStt({
    int modelSize = 1024 * 1024 + 16,
    int tokenizerSize = 1024 * 1024 + 16,
    String? modelInstallFilename,
    this.backendsHere = const {PreferredBackend.cpu},
  }) : model = artifact(
         'tiny_stt.tflite',
         size: modelSize,
         installFilename: modelInstallFilename,
       ),
       tokenizer = artifact('tiny_stt_tokenizer.json', size: tokenizerSize);

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
  final Set<PreferredBackend> backendsHere;
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

/// The model manager is one per isolate, so a test would otherwise start
/// with the active models an earlier test left (whose files went with its
/// temporary directory).
Future<void> clearActiveModels() async {
  final manager = FlutterEdgeAiPlugin.instance.modelManager;
  await manager.clearActiveInferenceIdentity();
  await manager.clearActiveEmbeddingIdentity();
  await manager.clearActiveSttIdentity();
  await manager.clearActiveTtsIdentity();
}

import 'dart:convert';
import 'dart:async';

import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/gemma_bootstrap.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_provenance.dart';
import 'package:flutter_edge_ai_example/utils/installed_model_lookup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every catalog embedder has a unique path-safe stable profile', () {
    final ids = catalog.EmbeddingModel.values
        .map((model) => model.ragProfileId)
        .toList();

    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[a-z0-9][a-z0-9._-]*$')));
      expect(id, isNot(contains('/')));
      expect(id, isNot(contains('resolve')));
    }
  });

  test('profile lookup matches both model and tokenizer sources', () {
    for (final model in catalog.EmbeddingModel.values) {
      final spec = EmbeddingModelSpec(
        name: model.name,
        modelSource: _source(model.sourceType, model.url),
        tokenizerSource: _source(model.sourceType, model.tokenizerUrl),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );

      expect(embeddingProfileIdForSpec(spec), model.ragProfileId);
    }
  });

  test('profile lookup refuses custom and mixed-source models', () {
    final custom = EmbeddingModelSpec(
      name: 'custom',
      modelSource: ModelSource.file('/tmp/model.tflite'),
      tokenizerSource: ModelSource.file('/tmp/tokenizer.model'),
    );
    expect(embeddingProfileIdForSpec(custom), isNull);

    const catalogModel = catalog.EmbeddingModel.embeddingGemma256;
    final mixed = EmbeddingModelSpec(
      name: catalogModel.name,
      modelSource: ModelSource.network(catalogModel.url),
      tokenizerSource: ModelSource.asset('assets/models/sentencepiece.model'),
      modelFilename: catalogModel.filename,
      tokenizerFilename: catalogModel.tokenizerFilename,
    );
    expect(embeddingProfileIdForSpec(mixed), isNull);
  });

  test('remote artifacts use revision-qualified cache identities', () {
    final remoteModels = catalog.EmbeddingModel.values.where(
      (model) => model.sourceType == ModelSourceType.network,
    );
    expect(
      remoteModels.map((model) => model.filename).toSet(),
      hasLength(remoteModels.length),
    );
    expect(
      remoteModels.map((model) => model.tokenizerFilename).toSet(),
      hasLength(remoteModels.length),
    );
    for (final model in remoteModels) {
      expect(model.filename, contains('__rev-'));
      expect(model.tokenizerFilename, contains('__rev-'));
      expect(model.filename, isNot(Uri.parse(model.url).pathSegments.last));
      expect(
        model.tokenizerFilename,
        isNot(Uri.parse(model.tokenizerUrl).pathSegments.last),
      );
    }
  });

  test('local asset has its own versioned install identities', () {
    const local = catalog.EmbeddingModel.localEmbeddingGemma256;
    const remote = catalog.EmbeddingModel.embeddingGemma256;
    final legacyModel = Uri.parse(remote.url).pathSegments.last;

    expect(local.filename, contains('__example-asset-v1'));
    expect(local.tokenizerFilename, contains('__example-asset-v1'));
    expect(local.filename, isNot(legacyModel));
    expect(local.filename, isNot(remote.filename));
    expect(local.tokenizerFilename, isNot(remote.tokenizerFilename));
  });

  test(
    'verified network install restores profile from native FileSources',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      final networkSpec = _catalogSpec(model);
      await persistVerifiedEmbeddingCatalogSelection(model, spec: networkSpec);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingIdentityRecord,
        ActiveEmbeddingIdentityRecord.fromSpec(networkSpec).encode(),
      );

      final restored = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.file('/managed/${model.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${model.tokenizerFilename}',
        ),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );

      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restored),
        model.ragProfileId,
      );
    },
  );

  test(
    'legacy basename cache is never relabeled with catalog provenance',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      await persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingIdentityRecord,
        ActiveEmbeddingIdentityRecord.fromSpec(_catalogSpec(model)).encode(),
      );

      final oldModelFilename = Uri.parse(model.url).pathSegments.last;
      final oldTokenizerFilename =
          '${oldModelFilename.substring(0, oldModelFilename.lastIndexOf('.'))}__sentencepiece.model';
      final legacyRestored = EmbeddingModelSpec(
        name: oldModelFilename,
        modelSource: ModelSource.file('/legacy/$oldModelFilename'),
        tokenizerSource: ModelSource.file('/legacy/$oldTokenizerFilename'),
        modelFilename: oldModelFilename,
        tokenizerFilename: oldTokenizerFilename,
      );

      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: legacyRestored),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    },
  );

  test('unknown provenance schema is cleared instead of adopted', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
      jsonEncode({'schemaVersion': 999}),
    );

    final unknown = EmbeddingModelSpec(
      name: 'custom',
      modelSource: ModelSource.file('/tmp/custom.tflite'),
      tokenizerSource: ModelSource.file('/tmp/custom.model'),
    );
    expect(await resolveActiveEmbeddingCatalogProfile(spec: unknown), isNull);
    expect(
      prefs.getString(EmbeddingCatalogPreferencesKeys.activeProfileProvenance),
      isNull,
    );
  });

  test(
    'present malformed core identity blocks legacy provenance fallback',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      await persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        PreferencesKeys.activeEmbeddingIdentityRecord,
        '{"schemaVersion":999,"active":false}',
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingSource,
        ModelSource.network(model.url).encode(),
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingTokenizerSource,
        ModelSource.network(model.tokenizerUrl).encode(),
      );
      final restored = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.file('/managed/${model.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${model.tokenizerFilename}',
        ),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );

      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restored),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    },
  );

  test(
    'restored FileSource rejects mismatched persisted source pair',
    () async {
      const model = catalog.EmbeddingModel.embeddingGemma256;
      const other = catalog.EmbeddingModel.gecko256;
      await persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
      );
      final prefs = await SharedPreferences.getInstance();
      final mismatchedSpec = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.network(model.url),
        tokenizerSource: ModelSource.network(other.tokenizerUrl),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );
      await prefs.setString(
        PreferencesKeys.activeEmbeddingIdentityRecord,
        ActiveEmbeddingIdentityRecord.fromSpec(mismatchedSpec).encode(),
      );

      final restored = EmbeddingModelSpec(
        name: model.name,
        modelSource: ModelSource.file('/managed/${model.filename}'),
        tokenizerSource: ModelSource.file(
          '/managed/${model.tokenizerFilename}',
        ),
        modelFilename: model.filename,
        tokenizerFilename: model.tokenizerFilename,
      );
      expect(
        await resolveActiveEmbeddingCatalogProfile(spec: restored),
        isNull,
      );
      expect(
        prefs.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ),
        isNull,
      );
    },
  );

  test('backend locations are isolated by backend and embedding profile', () {
    const first = 'embedding-profile-v1';
    const second = 'embedding-profile-v2';

    expect(
      RagBackend.sqlite.storageName(first),
      isNot(RagBackend.sqlite.storageName(second)),
    );
    expect(
      RagBackend.sqlite.storageName(first),
      isNot(RagBackend.qdrant.storageName(first)),
    );
  });

  test('failed provenance writes are reported', () async {
    const model = catalog.EmbeddingModel.embeddingGemma256;
    final storage = _FakeProvenanceStorage()..setResult = false;

    await expectLater(
      persistVerifiedEmbeddingCatalogSelection(
        model,
        spec: _catalogSpec(model),
        storage: storage,
      ),
      throwsStateError,
    );
  });

  test('active embedder switches invalidate an in-flight resolution', () async {
    const model = catalog.EmbeddingModel.embeddingGemma256;
    final first = _catalogSpec(model);
    final second = _catalogSpec(catalog.EmbeddingModel.gecko256);
    final storage = _FakeProvenanceStorage(blockSet: true);
    EmbeddingModelSpec? active = first;

    final resolving = resolveActiveEmbeddingCatalogProfile(
      storage: storage,
      activeSpecReader: () => active,
    );
    await storage.setStarted.future;
    active = second;
    storage.releaseSet();

    await expectLater(resolving, throwsStateError);
    expect(
      storage.getString(
        EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
      ),
      isNull,
    );
  });
}

EmbeddingModelSpec _catalogSpec(catalog.EmbeddingModel model) =>
    EmbeddingModelSpec(
      name: model.name,
      modelSource: _source(model.sourceType, model.url),
      tokenizerSource: _source(model.sourceType, model.tokenizerUrl),
      modelFilename: model.filename,
      tokenizerFilename: model.tokenizerFilename,
    );

ModelSource _source(ModelSourceType type, String location) => switch (type) {
  ModelSourceType.network => ModelSource.network(location),
  ModelSourceType.asset => ModelSource.asset(location),
  ModelSourceType.bundled => ModelSource.bundled(location),
};

class _FakeProvenanceStorage implements EmbeddingCatalogProvenanceStorage {
  _FakeProvenanceStorage({this.blockSet = false});

  final bool blockSet;
  bool setResult = true;
  bool removeResult = true;
  final values = <String, String>{};
  final setStarted = Completer<void>();
  Completer<void>? _setGate;

  @override
  String? getString(String key) => values[key];

  @override
  Future<bool> setString(String key, String value) async {
    if (!setStarted.isCompleted) setStarted.complete();
    if (blockSet) {
      _setGate ??= Completer<void>();
      await _setGate!.future;
    }
    if (setResult) values[key] = value;
    return setResult;
  }

  void releaseSet() => _setGate?.complete();

  @override
  Future<bool> remove(String key) async {
    if (removeResult) values.remove(key);
    return removeResult;
  }
}

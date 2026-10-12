import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:shared_preferences/shared_preferences.dart';

const _provenanceSchemaVersion = 1;

/// The part of a catalog embedder that provenance reads.
///
/// A self-contained entry (one `.litertlm` bundle that carries its own
/// tokenizer) has no tokenizer: [tokenizerUrl] and [tokenizerFilename] are
/// both null.
typedef EmbeddingCatalogEntry = ({
  String profileId,
  ModelSourceType sourceType,
  String url,
  String filename,
  String? tokenizerUrl,
  String? tokenizerFilename,
});

EmbeddingCatalogEntry _entryOf(catalog.EmbeddingModel model) => (
  profileId: model.ragProfileId,
  sourceType: model.sourceType,
  url: model.url,
  filename: model.filename,
  tokenizerUrl: model.tokenizerUrl,
  tokenizerFilename: model.tokenizerFilename,
);

/// Every embedder in this app's catalog.
List<EmbeddingCatalogEntry> get shippedEmbeddingCatalog => [
  for (final model in catalog.EmbeddingModel.values) _entryOf(model),
];

/// The profile of the catalog entry [spec] was installed from, by its
/// immutable sources and versioned install identities; null for anything
/// else.
String? embeddingCatalogProfileForSpec(
  EmbeddingModelSpec spec, {
  @visibleForTesting List<EmbeddingCatalogEntry>? catalogEntries,
}) {
  for (final entry in catalogEntries ?? shippedEmbeddingCatalog) {
    if (_matchesCatalogSpec(spec, entry)) return entry.profileId;
  }
  return null;
}

abstract final class EmbeddingCatalogPreferencesKeys {
  static const activeProfileProvenance =
      'flutter_edge_ai_example.active_embedding_profile_provenance';
}

/// Minimal preferences seam used to verify persistence failures and races.
@visibleForTesting
abstract interface class EmbeddingCatalogProvenanceStorage {
  String? getString(String key);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);
}

class _SharedPreferencesProvenanceStorage
    implements EmbeddingCatalogProvenanceStorage {
  const _SharedPreferencesProvenanceStorage(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);

  @override
  Future<bool> remove(String key) => _preferences.remove(key);
}

/// Persists a verified catalog identity separately from the runtime paths.
///
/// This must only be called while [model]'s exact immutable sources (model,
/// and tokenizer when it has one) and versioned install identities are
/// active. Unknown FileSource pairs are never
/// promoted into catalog provenance.
Future<void> persistVerifiedEmbeddingCatalogSelection(
  catalog.EmbeddingModel model, {
  EmbeddingModelSpec? spec,
  @visibleForTesting EmbeddingCatalogProvenanceStorage? storage,
  @visibleForTesting EmbeddingModelSpec? Function()? activeSpecReader,
}) => _persistVerified(
  _entryOf(model),
  spec: spec,
  storage: storage,
  activeSpecReader: activeSpecReader,
);

Future<void> _persistVerified(
  EmbeddingCatalogEntry model, {
  EmbeddingModelSpec? spec,
  EmbeddingCatalogProvenanceStorage? storage,
  EmbeddingModelSpec? Function()? activeSpecReader,
}) async {
  final readActiveSpec =
      activeSpecReader ?? () => FlutterEdgeAi.activeEmbedderSpec;
  final tracksActiveSpec = spec == null;
  final activeSpec = spec ?? readActiveSpec();
  if (activeSpec == null || !_matchesCatalogSpec(activeSpec, model)) {
    throw StateError(
      'Cannot persist ${model.profileId}: the active embedder does not '
      'match its immutable catalog sources and install identities.',
    );
  }

  final record = _EmbeddingCatalogProvenance.fromCatalog(model);
  final target = storage ?? await _loadStorage();
  if (tracksActiveSpec) _ensureStillActive(activeSpec, readActiveSpec);
  final encoded = jsonEncode(record.toJson());
  final persisted = await target.setString(
    EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
    encoded,
  );
  if (!persisted) {
    throw StateError('Failed to persist embedding catalog provenance.');
  }
  if (tracksActiveSpec && !identical(readActiveSpec(), activeSpec)) {
    if (target.getString(
          EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
        ) ==
        encoded) {
      final removed = await target.remove(
        EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
      );
      if (!removed) {
        throw StateError(
          'The active embedder changed while provenance was being persisted, '
          'and the stale record could not be removed.',
        );
      }
    }
    throw StateError(
      'The active embedder changed while catalog provenance was being '
      'persisted. Retry with the current embedder.',
    );
  }
}

/// Resolves the active profile across restart without trusting FileSource
/// paths on their own.
///
/// Reads only the public `FlutterEdgeAi.activeEmbedderSpec`. After a native
/// restart that spec points at the installed files (`FileSource`s), so the
/// catalog source is no longer in it: the profile is then taken from this
/// app's own provenance record, and only when that record names a catalog
/// model whose revision-qualified file names are exactly the active files.
Future<String?> resolveActiveEmbeddingCatalogProfile({
  EmbeddingModelSpec? spec,
  @visibleForTesting EmbeddingCatalogProvenanceStorage? storage,
  @visibleForTesting EmbeddingModelSpec? Function()? activeSpecReader,
  @visibleForTesting List<EmbeddingCatalogEntry>? catalogEntries,
}) async {
  final entries = catalogEntries ?? shippedEmbeddingCatalog;
  final readActiveSpec =
      activeSpecReader ?? () => FlutterEdgeAi.activeEmbedderSpec;
  final tracksActiveSpec = spec == null;
  final activeSpec = spec ?? readActiveSpec();
  if (activeSpec == null) {
    await clearEmbeddingCatalogProvenance(storage: storage);
    return null;
  }

  for (final model in entries) {
    if (_matchesCatalogSpec(activeSpec, model)) {
      await _persistVerified(
        model,
        spec: tracksActiveSpec ? null : activeSpec,
        storage: storage,
        activeSpecReader: readActiveSpec,
      );
      return model.profileId;
    }
  }

  final tokenizerSource = activeSpec.tokenizerSource;
  if (activeSpec.modelSource is! FileSource ||
      (tokenizerSource != null && tokenizerSource is! FileSource)) {
    await clearEmbeddingCatalogProvenance(storage: storage);
    return null;
  }

  final target = storage ?? await _loadStorage();
  if (tracksActiveSpec) _ensureStillActive(activeSpec, readActiveSpec);
  final encoded = target.getString(
    EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
  );
  final record = _EmbeddingCatalogProvenance.tryDecode(encoded);
  if (record == null) {
    if (encoded != null) {
      await clearEmbeddingCatalogProvenance(storage: target);
    }
    return null;
  }

  final model = _catalogModelForRecord(record, entries);
  final valid =
      model != null &&
      _filesAre(activeSpec, record.modelFilename, record.tokenizerFilename);
  if (!valid) {
    await clearEmbeddingCatalogProvenance(storage: target);
    return null;
  }
  if (tracksActiveSpec) _ensureStillActive(activeSpec, readActiveSpec);
  return record.profileId;
}

Future<void> clearEmbeddingCatalogProvenance({
  @visibleForTesting EmbeddingCatalogProvenanceStorage? storage,
}) async {
  final target = storage ?? await _loadStorage();
  final removed = await target.remove(
    EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
  );
  if (!removed) {
    throw StateError('Failed to clear embedding catalog provenance.');
  }
}

Future<EmbeddingCatalogProvenanceStorage> _loadStorage() async =>
    _SharedPreferencesProvenanceStorage(await SharedPreferences.getInstance());

void _ensureStillActive(
  EmbeddingModelSpec expected,
  EmbeddingModelSpec? Function() readActiveSpec,
) {
  if (!identical(readActiveSpec(), expected)) {
    throw StateError(
      'The active embedder changed while catalog provenance was being '
      'resolved. Retry with the current embedder.',
    );
  }
}

bool _matchesCatalogSpec(EmbeddingModelSpec spec, EmbeddingCatalogEntry model) {
  final tokenizerUrl = model.tokenizerUrl;
  return _filesAre(spec, model.filename, model.tokenizerFilename) &&
      spec.modelSource.encode() ==
          _catalogSource(model.url, model.sourceType) &&
      spec.tokenizerSource?.encode() ==
          (tokenizerUrl == null
              ? null
              : _catalogSource(tokenizerUrl, model.sourceType));
}

/// Whether [spec]'s files are exactly [modelFilename], then
/// [tokenizerFilename] when the model has one (a self-contained `.litertlm`
/// bundle has none).
bool _filesAre(
  EmbeddingModelSpec spec,
  String modelFilename,
  String? tokenizerFilename,
) {
  final files = spec.files;
  return files.length == (tokenizerFilename == null ? 1 : 2) &&
      files[0].filename == modelFilename &&
      (tokenizerFilename == null || files[1].filename == tokenizerFilename);
}

String _catalogSource(String location, ModelSourceType sourceType) =>
    switch (sourceType) {
      ModelSourceType.network => ModelSource.network(location).encode(),
      ModelSourceType.asset => ModelSource.asset(location).encode(),
      ModelSourceType.bundled => ModelSource.bundled(location).encode(),
    };

/// The catalog entry [record] was written for, matched on every field: two
/// entries may share a profile id (the EmbeddingGemma 2 bundles share one text
/// space), so the id alone does not say which was installed.
EmbeddingCatalogEntry? _catalogModelForRecord(
  _EmbeddingCatalogProvenance record,
  List<EmbeddingCatalogEntry> entries,
) {
  for (final model in entries) {
    if (_EmbeddingCatalogProvenance.fromCatalog(model) == record) return model;
  }
  return null;
}

class _EmbeddingCatalogProvenance {
  const _EmbeddingCatalogProvenance({
    required this.schemaVersion,
    required this.profileId,
    required this.modelFilename,
    required this.tokenizerFilename,
    required this.modelSource,
    required this.tokenizerSource,
  }) : assert(
         (tokenizerFilename == null) == (tokenizerSource == null),
         'a tokenizer has both a file name and a source, or neither',
       );

  factory _EmbeddingCatalogProvenance.fromCatalog(
    EmbeddingCatalogEntry model,
  ) => _EmbeddingCatalogProvenance(
    schemaVersion: _provenanceSchemaVersion,
    profileId: model.profileId,
    modelFilename: model.filename,
    tokenizerFilename: model.tokenizerFilename,
    modelSource: _catalogSource(model.url, model.sourceType),
    tokenizerSource: switch (model.tokenizerUrl) {
      final url? => _catalogSource(url, model.sourceType),
      null => null,
    },
  );

  static _EmbeddingCatalogProvenance? tryDecode(String? encoded) {
    if (encoded == null) return null;
    try {
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) return null;
      final schemaVersion = json['schemaVersion'];
      final profileId = json['profileId'];
      final modelFilename = json['modelFilename'];
      final tokenizerFilename = json['tokenizerFilename'];
      final modelSource = json['modelSource'];
      final tokenizerSource = json['tokenizerSource'];
      // A self-contained model has no tokenizer: both tokenizer fields are
      // absent. One without the other is a broken record.
      final hasTokenizer =
          tokenizerFilename is String && tokenizerSource is String;
      final noTokenizer = tokenizerFilename == null && tokenizerSource == null;
      if (schemaVersion is! int ||
          schemaVersion != _provenanceSchemaVersion ||
          profileId is! String ||
          modelFilename is! String ||
          modelSource is! String ||
          !(hasTokenizer || noTokenizer)) {
        return null;
      }
      return _EmbeddingCatalogProvenance(
        schemaVersion: schemaVersion,
        profileId: profileId,
        modelFilename: modelFilename,
        tokenizerFilename: tokenizerFilename as String?,
        modelSource: modelSource,
        tokenizerSource: tokenizerSource as String?,
      );
    } catch (_) {
      return null;
    }
  }

  final int schemaVersion;
  final String profileId;
  final String modelFilename;

  /// Null, with [tokenizerSource], for a self-contained model.
  final String? tokenizerFilename;
  final String modelSource;
  final String? tokenizerSource;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'profileId': profileId,
    'modelFilename': modelFilename,
    'tokenizerFilename': ?tokenizerFilename,
    'modelSource': modelSource,
    'tokenizerSource': ?tokenizerSource,
  };

  @override
  bool operator ==(Object other) =>
      other is _EmbeddingCatalogProvenance &&
      schemaVersion == other.schemaVersion &&
      profileId == other.profileId &&
      modelFilename == other.modelFilename &&
      tokenizerFilename == other.tokenizerFilename &&
      modelSource == other.modelSource &&
      tokenizerSource == other.tokenizerSource;

  @override
  int get hashCode => Object.hash(
    schemaVersion,
    profileId,
    modelFilename,
    tokenizerFilename,
    modelSource,
    tokenizerSource,
  );
}

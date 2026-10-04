import 'dart:convert';

import 'package:flutter_edge_ai/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_edge_ai/core/model_management/active_embedding_identity.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/base_model.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:shared_preferences/shared_preferences.dart';

const _provenanceSchemaVersion = 1;

abstract final class EmbeddingCatalogPreferencesKeys {
  static const activeProfileProvenance =
      'flutter_edge_ai_example.active_embedding_profile_provenance';
}

/// Persists a verified catalog identity separately from the runtime paths.
///
/// This must only be called while [model]'s exact immutable source pair and
/// versioned install identities are active. Unknown FileSource pairs are never
/// promoted into catalog provenance.
Future<void> persistVerifiedEmbeddingCatalogSelection(
  catalog.EmbeddingModel model, {
  EmbeddingModelSpec? spec,
}) async {
  final activeSpec = spec ?? FlutterEdgeAi.activeEmbedderSpec;
  if (activeSpec == null || !_matchesCatalogSpec(activeSpec, model)) {
    throw StateError(
      'Cannot persist ${model.ragProfileId}: the active embedding pair does '
      'not match its immutable catalog sources and install identities.',
    );
  }

  final record = _EmbeddingCatalogProvenance.fromCatalog(model);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
    jsonEncode(record.toJson()),
  );
}

/// Resolves the active profile across restart without trusting FileSource
/// names or paths on their own.
Future<String?> resolveActiveEmbeddingCatalogProfile({
  EmbeddingModelSpec? spec,
}) async {
  final activeSpec = spec ?? FlutterEdgeAi.activeEmbedderSpec;
  if (activeSpec == null) {
    await clearEmbeddingCatalogProvenance();
    return null;
  }

  for (final model in catalog.EmbeddingModel.values) {
    if (_matchesCatalogSpec(activeSpec, model)) {
      await persistVerifiedEmbeddingCatalogSelection(model, spec: activeSpec);
      return model.ragProfileId;
    }
  }

  if (activeSpec.modelSource is! FileSource ||
      activeSpec.tokenizerSource is! FileSource) {
    await clearEmbeddingCatalogProvenance();
    return null;
  }

  final prefs = await SharedPreferences.getInstance();
  final encoded = prefs.getString(
    EmbeddingCatalogPreferencesKeys.activeProfileProvenance,
  );
  final record = _EmbeddingCatalogProvenance.tryDecode(encoded);
  if (record == null) {
    if (encoded != null) await clearEmbeddingCatalogProvenance();
    return null;
  }

  final model = _catalogModelForRecord(record);
  final activeFiles = activeSpec.files;
  final encodedCoreIdentity = prefs.getString(
    PreferencesKeys.activeEmbeddingIdentityRecord,
  );
  final coreIdentity = ActiveEmbeddingIdentityRecord.tryDecode(
    encodedCoreIdentity,
  );
  if (encodedCoreIdentity != null &&
      (coreIdentity == null || !coreIdentity.active)) {
    await clearEmbeddingCatalogProvenance();
    return null;
  }
  final persistedModelSource = coreIdentity?.active == true
      ? coreIdentity!.modelSource
      : prefs.getString(PreferencesKeys.activeEmbeddingSource);
  final persistedTokenizerSource = coreIdentity?.active == true
      ? coreIdentity!.tokenizerSource
      : prefs.getString(PreferencesKeys.activeEmbeddingTokenizerSource);
  final valid =
      model != null &&
      record == _EmbeddingCatalogProvenance.fromCatalog(model) &&
      activeFiles.length == 2 &&
      activeFiles[0].filename == record.modelFilename &&
      activeFiles[1].filename == record.tokenizerFilename &&
      (coreIdentity == null ||
          (coreIdentity.active &&
              coreIdentity.modelFilename == record.modelFilename &&
              coreIdentity.tokenizerFilename == record.tokenizerFilename)) &&
      persistedModelSource == record.modelSource &&
      persistedTokenizerSource == record.tokenizerSource;
  if (!valid) {
    await clearEmbeddingCatalogProvenance();
    return null;
  }
  return record.profileId;
}

Future<void> clearEmbeddingCatalogProvenance() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(EmbeddingCatalogPreferencesKeys.activeProfileProvenance);
}

bool _matchesCatalogSpec(
  EmbeddingModelSpec spec,
  catalog.EmbeddingModel model,
) {
  final files = spec.files;
  return files.length == 2 &&
      files[0].filename == model.filename &&
      files[1].filename == model.tokenizerFilename &&
      spec.modelSource.encode() ==
          _catalogSource(model.url, model.sourceType) &&
      spec.tokenizerSource.encode() ==
          _catalogSource(model.tokenizerUrl, model.sourceType);
}

String _catalogSource(String location, ModelSourceType sourceType) =>
    switch (sourceType) {
      ModelSourceType.network => ModelSource.network(location).encode(),
      ModelSourceType.asset => ModelSource.asset(location).encode(),
      ModelSourceType.bundled => ModelSource.bundled(location).encode(),
    };

catalog.EmbeddingModel? _catalogModelForRecord(
  _EmbeddingCatalogProvenance record,
) {
  for (final model in catalog.EmbeddingModel.values) {
    if (model.ragProfileId == record.profileId) return model;
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
  });

  factory _EmbeddingCatalogProvenance.fromCatalog(
    catalog.EmbeddingModel model,
  ) => _EmbeddingCatalogProvenance(
    schemaVersion: _provenanceSchemaVersion,
    profileId: model.ragProfileId,
    modelFilename: model.filename,
    tokenizerFilename: model.tokenizerFilename,
    modelSource: _catalogSource(model.url, model.sourceType),
    tokenizerSource: _catalogSource(model.tokenizerUrl, model.sourceType),
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
      if (schemaVersion is! int ||
          schemaVersion != _provenanceSchemaVersion ||
          profileId is! String ||
          modelFilename is! String ||
          tokenizerFilename is! String ||
          modelSource is! String ||
          tokenizerSource is! String) {
        return null;
      }
      return _EmbeddingCatalogProvenance(
        schemaVersion: schemaVersion,
        profileId: profileId,
        modelFilename: modelFilename,
        tokenizerFilename: tokenizerFilename,
        modelSource: modelSource,
        tokenizerSource: tokenizerSource,
      );
    } catch (_) {
      return null;
    }
  }

  final int schemaVersion;
  final String profileId;
  final String modelFilename;
  final String tokenizerFilename;
  final String modelSource;
  final String tokenizerSource;

  Map<String, Object> toJson() => {
    'schemaVersion': schemaVersion,
    'profileId': profileId,
    'modelFilename': modelFilename,
    'tokenizerFilename': tokenizerFilename,
    'modelSource': modelSource,
    'tokenizerSource': tokenizerSource,
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

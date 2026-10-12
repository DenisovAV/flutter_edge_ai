// RAG on device (R5 §10.1, D20): a location opened through
// FlutterEdgeAiActiveEmbedder.forActiveModel is bound to the installed model's
// files; after another model of the SAME dimension is installed, its derived
// id differs and the location refuses it — the id is the only guard between
// two 768-dimensional embedding spaces. Plus: an explicit catalog id still
// works as before, and declaring images on a text-only model fails at open,
// before any store is created.
//
// The EmbeddingGemma 1 vs 2 leg: a location bound to the EmbeddingGemma 2
// profile refuses a 768-dimensional EmbeddingGemma 1 stand-in, and
// forActiveModel gives the two different ids.
//
// Models, all ungated and pinned: Gecko 110M seq64 and seq256 (768D, the
// stand-in for the gated EmbeddingGemma 1 — the binding logic only sees a
// different 768D model) and embeddinggemma-2-text-270m (`.litertlm`, 768D).
// Optional, as in embeddinggemma2_test.dart:
// --dart-define=EG2_MODEL_URL=<a copy of the same bytes>, or
// --dart-define=EG2_MODEL_FILE=<a path the app can read>; either must have the
// pinned SHA-256, which the EG2 leg checks before it binds anything.
//
// No setUp (Rule 6b): each test body calls the guarded helpers it needs.
//
// Run: flutter test integration_test/rag_active_embedder_binding_test.dart -d macos

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_example/models/embedding_model.dart' as catalog;
import 'package:flutter_edge_ai_example/services/embedding_catalog_install.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _namespace = 'rag-binding-test';

const _documents = {
  'grid': 'Renewable energy is reshaping the global power grid.',
  'pizza': 'A classic margherita pizza needs only flour, tomato, and basil.',
  'markets': 'Stock markets reacted sharply to the central bank announcement.',
};

Future<void> _install(catalog.EmbeddingModel model) async {
  await registerTestEngines();
  await withCatalogEmbedderSources(
    FlutterEdgeAi.installEmbedder(),
    model,
  ).install();
}

const _eg2 = catalog.EmbeddingModel.embeddingGemma2Text270m;
const _eg2UrlOverride = String.fromEnvironment('EG2_MODEL_URL');
const _eg2FileOverride = String.fromEnvironment('EG2_MODEL_FILE');
bool _eg2Verified = false;

/// Installs the pinned EmbeddingGemma 2 bundle (a no-op once installed) under
/// the catalog's file name — so its forActiveModel id does not depend on
/// where the bytes came from — and checks its SHA-256 once per run.
Future<void> _installEg2() async {
  await registerTestEngines();
  final builder = FlutterEdgeAi.installEmbedder();
  if (_eg2FileOverride.isNotEmpty) {
    builder.modelFromFile(_eg2FileOverride, filename: _eg2.filename);
  } else {
    builder.modelFromNetwork(
      _eg2UrlOverride.isEmpty ? _eg2.url : _eg2UrlOverride,
      filename: _eg2.filename,
    );
  }
  await builder.install();
  if (_eg2Verified) return;
  final path = await FlutterEdgeAi.getModelPath(_eg2.filename);
  final digest = await sha256.bind(File(path).openRead()).first;
  expect(
    '$digest',
    _eg2.sha256,
    reason: '$path is not the pinned embeddinggemma-2-text-270m.litertlm',
  );
  _eg2Verified = true;
}

Future<String> _freshLocation(String name) async {
  final dir = await getTemporaryDirectory();
  final path =
      '${dir.path}/${name}_${DateTime.now().microsecondsSinceEpoch}.db';
  addTearDown(() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  });
  return path;
}

final _rag = FlutterEdgeAiRag(providers: const [SqliteVectorStoreProvider()]);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'forActiveModel binds the location to the installed files; another '
    'model of the same dimension is refused',
    (_) async {
      final location = await _freshLocation('rag_binding');
      final spec = VectorStoreSpec(
        providerId: SqliteVectorStoreProvider.providerId,
        location: location,
      );

      await _install(catalog.EmbeddingModel.gecko64);
      final first = FlutterEdgeAiActiveEmbedder.forActiveModel(
        namespace: _namespace,
      );
      final index = await _rag.open(spec: spec, embedder: first);
      final boundId = index.embeddingProfile.id;
      expect(
        boundId,
        '$_namespace@${catalog.EmbeddingModel.gecko64.filename}'
        '+${catalog.EmbeddingModel.gecko64.tokenizerFilename}',
      );
      expect(index.embeddingProfile.dimension, 768);
      for (final MapEntry(key: id, value: text) in _documents.entries) {
        await index.add(id: id, document: EmbeddingInput.text(text));
      }
      final hits = await index.search(
        query: EmbeddingInput.text('pizza recipe'),
        topK: 1,
      );
      expect(hits.single.id, 'pizza');
      await index.dispose();

      await _install(catalog.EmbeddingModel.gecko256);
      final second = FlutterEdgeAiActiveEmbedder.forActiveModel(
        namespace: _namespace,
      );
      final secondProfile = await second.resolveProfile();
      expect(secondProfile.dimension, 768);
      expect(secondProfile.id, isNot(boundId));
      await expectLater(
        _rag.open(spec: spec, embedder: second),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('is bound to'), contains(boundId)),
          ),
        ),
      );
      await expectLater(
        first.embedDocument(EmbeddingInput.text('late')),
        throwsStateError,
        reason: 'the first adapter is pinned to the model it was made for',
      );

      // The explicit catalog id keeps working as before.
      final explicit = await _rag.open(
        spec: VectorStoreSpec(
          providerId: SqliteVectorStoreProvider.providerId,
          location: await _freshLocation('rag_binding_explicit'),
        ),
        embedder: FlutterEdgeAiActiveEmbedder(
          profileId: catalog.EmbeddingModel.gecko256.ragProfileId,
        ),
      );
      expect(
        explicit.embeddingProfile.id,
        catalog.EmbeddingModel.gecko256.ragProfileId,
      );
      await explicit.add(
        id: 'grid',
        document: EmbeddingInput.text(_documents['grid']!),
      );
      expect((await explicit.stats()).documentCount, 1);
      await explicit.dispose();
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  testWidgets(
    'EmbeddingGemma 2 vs a 768D EmbeddingGemma 1 stand-in: the EG2 location '
    'refuses it, and forActiveModel ids differ',
    (_) async {
      final shared = await _freshLocation('rag_binding_eg2_shared');
      final derived = await _freshLocation('rag_binding_eg2_derived');
      VectorStoreSpec spec(String location) => VectorStoreSpec(
        providerId: SqliteVectorStoreProvider.providerId,
        location: location,
      );

      await _installEg2();
      // R5 §10.1: bind the EmbeddingGemma 2 profile (the catalog's shared
      // text id) ...
      final eg2 = await _rag.open(
        spec: spec(shared),
        embedder: FlutterEdgeAiActiveEmbedder(profileId: _eg2.ragProfileId),
      );
      expect(eg2.embeddingProfile.id, _eg2.ragProfileId);
      expect(eg2.embeddingProfile.dimension, 768);
      for (final MapEntry(key: id, value: text) in _documents.entries) {
        await eg2.add(id: id, document: EmbeddingInput.text(text));
      }
      final hits = await eg2.search(
        query: EmbeddingInput.text('pizza recipe'),
        topK: 1,
      );
      expect(hits.single.id, 'pizza');
      await eg2.dispose();
      // ... and one through forActiveModel.
      final eg2Derived = FlutterEdgeAiActiveEmbedder.forActiveModel(
        namespace: _namespace,
      );
      final eg2Id = (await eg2Derived.resolveProfile()).id;
      expect(eg2Id, '$_namespace@${_eg2.filename}');
      await (await _rag.open(
        spec: spec(derived),
        embedder: eg2Derived,
      )).dispose();

      // The EmbeddingGemma 1 stand-in: another 768D model.
      const eg1 = catalog.EmbeddingModel.gecko64;
      await _install(eg1);
      final eg1Derived = FlutterEdgeAiActiveEmbedder.forActiveModel(
        namespace: _namespace,
      );
      final eg1Profile = await eg1Derived.resolveProfile();
      expect(eg1Profile.dimension, 768, reason: 'same dimension as EG2');
      expect(eg1Profile.id, isNot(eg2Id));

      // Reopening the EG2 location with the EG1 profile is refused ...
      await expectLater(
        _rag.open(
          spec: spec(shared),
          embedder: FlutterEdgeAiActiveEmbedder(profileId: eg1.ragProfileId),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('is bound to'), contains(_eg2.ragProfileId)),
          ),
        ),
      );
      // ... and so is the forActiveModel location: the derived id changed.
      await expectLater(
        _rag.open(spec: spec(derived), embedder: eg1Derived),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('is bound to'), contains(eg2Id)),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  testWidgets(
    'declaring images on a text-only model fails at open, before any store',
    (_) async {
      await _install(catalog.EmbeddingModel.gecko64);
      final location = await _freshLocation('rag_binding_images');

      await expectLater(
        _rag.open(
          spec: VectorStoreSpec(
            providerId: SqliteVectorStoreProvider.providerId,
            location: location,
            documents: EmbeddingModality.image,
          ),
          embedder: FlutterEdgeAiActiveEmbedder(
            profileId: 'gecko-images-v1',
            supportImage: true,
          ),
        ),
        throwsA(isA<EmbeddingLoadException>()),
      );
      expect(
        File(location).existsSync(),
        isFalse,
        reason: 'the model refused before the store was created',
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

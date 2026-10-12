// A store written by the PUBLISHED flutter_edge_ai_sqlite 2.0.1 (with
// flutter_edge_ai_rag 1.0.0) opens in this version as a text binding, searches,
// and is left byte for byte as it was (R5 §6.5, §6.6).
//
// test/fixtures/v2_0_1/text_store.db was written once by
// tool/rag_store_compat/generate_v2_0_1_fixtures.sh against the hosted
// packages — profile `fixture-text-v1`, 4 dimensions, documents doc-a
// ([1,0,0,0], "alpha") and doc-b ([0,1,0,0], "beta"). Regenerate it only with
// that script.

import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vec0_locator.dart';

const _fixture = 'test/fixtures/v2_0_1/text_store.db';
final _profile = EmbeddingProfile(id: 'fixture-text-v1', dimension: 4);

void main() {
  final skip = vec0SkipReason;

  /// A private copy, so a store that did write would not damage the fixture.
  String copyFixture() {
    final source = File(_fixture);
    expect(
      source.existsSync(),
      isTrue,
      reason: 'run from the package directory ($_fixture)',
    );
    final temp = Directory.systemTemp.createTempSync('sqlite_v2_0_1_fixture');
    addTearDown(() => temp.deleteSync(recursive: true));
    return (source.copySync('${temp.path}/text_store.db')).path;
  }

  test('reads as a text binding, searches, and writes nothing', () async {
    useHostNativeLibraries();
    final path = copyFixture();
    final before = File(path).readAsBytesSync();

    final store = SqliteVectorStore();
    await store.initialize(path);
    expect(await store.readBinding(), VectorStoreBinding(profile: _profile));
    expect(
      await store.getStats(),
      const VectorStoreStats(documentCount: 2, vectorDimension: 4),
    );
    await store.close();

    final rag = FlutterEdgeAiRag(
      providers: const [SqliteVectorStoreProvider()],
    );
    final index = await rag.openVectors(
      spec: VectorStoreSpec(
        providerId: SqliteVectorStoreProvider.providerId,
        location: path,
      ),
      profile: _profile,
    );
    expect(index.documents, EmbeddingModality.text);
    final hits = await index.searchVector(embedding: const [0, 1, 0, 0]);
    expect(hits.map((hit) => hit.id), ['doc-b', 'doc-a']);
    expect(hits.first.content, 'beta');
    expect(hits.first.metadata, '{"lang":"de"}');
    await index.dispose();

    expect(
      File(path).readAsBytesSync(),
      before,
      reason: 'opening and searching a 2.0.1 store must not rewrite it',
    );
    expect(File('$path-journal').existsSync(), isFalse);
  }, skip: skip);

  test('refuses to reopen it for images or another profile', () async {
    useHostNativeLibraries();
    final path = copyFixture();
    final before = File(path).readAsBytesSync();
    final rag = FlutterEdgeAiRag(
      providers: const [SqliteVectorStoreProvider()],
    );

    for (final (documents, profile) in [
      (EmbeddingModality.image, _profile),
      (EmbeddingModality.text, EmbeddingProfile(id: 'other-v1', dimension: 4)),
    ]) {
      await expectLater(
        rag.openVectors(
          spec: VectorStoreSpec(
            providerId: SqliteVectorStoreProvider.providerId,
            location: path,
            documents: documents,
          ),
          profile: profile,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains(
              'is bound to VectorStoreBinding(profile: '
              'EmbeddingProfile(id: fixture-text-v1',
            ),
          ),
        ),
      );
    }
    expect(File(path).readAsBytesSync(), before);
  }, skip: skip);
}

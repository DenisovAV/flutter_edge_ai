// A store written by the PUBLISHED flutter_edge_ai_qdrant 2.0.1 (with
// flutter_edge_ai_rag 1.0.0) opens in this version as a text binding,
// searches, and this package writes nothing to it: its records and the shard's
// edge_config.json are left byte for byte as they were (R5 §6.5, §6.6).
//
// The shard's own files are the engine's. Qdrant Edge 0.9 (qdrant_edge
// 0.9.0-dev.1) brings a shard written by an older engine to its current
// layout when it opens it (it resizes segment storage files and records the
// WAL's first index), so `segments/` and `wal/` are not compared byte for
// byte; that the data survives is what the binding, count and search checks
// below assert.
//
// test/fixtures/v2_0_1/text_store.tar.gz was written once by
// tool/rag_store_compat/generate_v2_0_1_fixtures.sh against the hosted
// packages — profile `fixture-text-v1`, 4 dimensions, documents doc-a
// ([1,0,0,0], "alpha") and doc-b ([0,1,0,0], "beta"). It is a tarball
// because qdrant preallocates 32 MB WAL and storage files that are almost all
// zeros. Regenerate it only with that script.

import 'dart:io';

import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:qdrant_edge/qdrant_edge.dart' as qe;

const _fixture = 'test/fixtures/v2_0_1/text_store.tar.gz';
final _profile = EmbeddingProfile(id: 'fixture-text-v1', dimension: 4);

const _bindingRecord = 'qdrant_edge_v1/.flutter_edge_ai_rag.binding.v2';

void main() {
  /// Extracts a private copy of the store; returns its location.
  Future<String> extractFixture() async {
    expect(
      File(_fixture).existsSync(),
      isTrue,
      reason: 'run from the package directory ($_fixture)',
    );
    final temp = Directory.systemTemp.createTempSync('qdrant_v2_0_1_fixture');
    addTearDown(() => temp.deleteSync(recursive: true));
    final tar = await Process.run('tar', [
      '-xzf',
      File(_fixture).absolute.path,
      '-C',
      temp.path,
    ]);
    expect(tar.exitCode, 0, reason: '${tar.stdout}\n${tar.stderr}');
    return p.join(temp.path, 'text_store');
  }

  /// Every file of [location] outside the engine's `segments/` and `wal/`
  /// against a pristine extraction, byte for byte.
  Future<void> expectUnchanged(String location) async {
    final pristine = await extractFixture();
    bool engineOwned(String relative) {
      final parts = p.split(relative);
      return parts.length > 1 && (parts[1] == 'segments' || parts[1] == 'wal');
    }

    List<String> files(String root) => [
      for (final file in Directory(root).listSync(recursive: true))
        if (file is File && !engineOwned(p.relative(file.path, from: root)))
          p.relative(file.path, from: root),
    ]..sort();
    expect(files(location), files(pristine));
    for (final file in files(pristine)) {
      expect(
        File(p.join(location, file)).readAsBytesSync(),
        File(p.join(pristine, file)).readAsBytesSync(),
        reason: '$file changed',
      );
    }
  }

  test('reads as a text binding, searches, and writes nothing', () async {
    final location = await extractFixture();

    final store = QdrantVectorStore();
    await store.initialize(location);
    expect(await store.readBinding(), VectorStoreBinding(profile: _profile));
    expect((await store.getStats()).documentCount, 2);
    await store.close();

    final rag = FlutterEdgeAiRag(
      providers: const [QdrantVectorStoreProvider()],
    );
    final index = await rag.openVectors(
      spec: VectorStoreSpec(providerId: 'qdrant', location: location),
      profile: _profile,
    );
    expect(index.documents, EmbeddingModality.text);
    final hits = await index.searchVector(embedding: const [0, 1, 0, 0]);
    expect(hits.map((hit) => hit.id), ['doc-b', 'doc-a']);
    expect(hits.first.content, 'beta');
    expect(hits.first.metadata, '{"lang":"de"}');
    await index.dispose();

    await expectUnchanged(location);
    expect(Directory(p.join(location, _bindingRecord)).existsSync(), isFalse);

    // segments/ and wal/ are not compared, so check the one thing this
    // package could still write into them: no open without enableTextSearch
    // may give the shard a payload index.
    final shard = qe.EdgeShard.load(
      path: p.join(location, 'qdrant_edge_v1'),
      config: null,
    );
    addTearDown(shard.unload);
    expect(shard.info().payloadSchema, isEmpty);
  });

  test('refuses to reopen it for images or another profile', () async {
    final location = await extractFixture();
    final rag = FlutterEdgeAiRag(
      providers: const [QdrantVectorStoreProvider()],
    );

    for (final (documents, profile) in [
      (EmbeddingModality.audio, _profile),
      (EmbeddingModality.text, EmbeddingProfile(id: 'other-v1', dimension: 4)),
    ]) {
      await expectLater(
        rag.openVectors(
          spec: VectorStoreSpec(
            providerId: 'qdrant',
            location: location,
            documents: documents,
          ),
          profile: profile,
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('EmbeddingProfile(id: fixture-text-v1'),
          ),
        ),
      );
    }
    await expectUnchanged(location);
  });
}

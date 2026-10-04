// One filter, one document set, two stores — the same answer, or a failure.
//
// WHY THIS FILE EXISTS
//
// The two RAG backends are supposed to be interchangeable: `VectorStoreRepository`
// promises the same `Filter` means the same thing on sqlite-vec/vec0 and on
// qdrant-edge. Three review passes over PR #442 found nine ways that was false,
// and every one of them was invisible to the tests that existed, for one reason:
//
//   the tests compared each codec's OUTPUT to a string in the same file.
//
// `filter_to_vec0_test.dart` asserts generated SQL. `filter_codec_test.dart`
// asserts JSON shape. Both are restatements of their own implementation, so a
// codec and its test can be wrong together and stay green forever — and both
// were. Worse, neither package's tests could even see the other backend, so
// "parity" was a word in a group name, not a thing being checked.
//
// This file asserts on ROWS returned by both REAL stores. It cannot pass by
// agreeing with a comment.
//
// HOW BOTH BACKENDS GET HERE
//
// qdrant-edge needs no local Rust build and no environment variable. Its
// native library arrives via the official `qdrant_edge` SDK's own Native
// Assets build hook — this package dev-depends on rag_qdrant, so `flutter
// test` here resolves it like any other native asset, exactly like LiteRT's.
// There is no override to set: QdrantVectorStore opens straight from the
// asset the hook registered.
//
// vec0 is the one that still needs $VEC0_DYLIB, because SqliteVectorStore
// resolves it as `vec0.framework/vec0` — a path that exists only inside a built
// app. tool/test_all.sh exports it; vec0_locator.dart is the gate.
//
// If qdrant does NOT initialize, this file fails rather than skipping. That is
// the point: three review passes found nine cross-backend defects, every one of
// them invisible because no test ran both stores, and a suite that silently
// checks half of what it claims is the very defect it exists to catch.
//
//   flutter test test/cross_backend_parity_test.dart
import 'dart:io';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_qdrant/flutter_edge_ai_qdrant.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'vec0_locator.dart';

import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart';

void main() {
  final vec0Skip = vec0SkipReason;

  group('cross-backend filter parity', () {
    late Directory tmp;
    late SqliteVectorStore sqlite;
    QdrantVectorStore? qdrant;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('parity_');

      // vec0 is pointed at its library explicitly — see core's
      // host_native_library.dart / vec0_locator.dart. It has no automatic
      // resolution outside a built app.
      // ignore: invalid_use_of_visible_for_testing_member
      SqliteVectorStore.debugOverrideDylibPath = vec0Path;
      sqlite = SqliteVectorStore();
      sqlite.configure(schema);
      await sqlite.initialize('${tmp.path}/vec.db');
      final profile = EmbeddingProfile(
        id: 'cross-backend-parity-v1',
        dimension: embedding.length,
      );
      await sqlite.bindEmbeddingProfile(profile);

      // qdrant needs no override: the official qdrant_edge SDK's own Native
      // Assets build hook resolves its native library automatically.
      final q = QdrantVectorStore();
      q.configure(schema);
      await q.initialize('${tmp.path}/shard');
      await q.bindEmbeddingProfile(profile);
      qdrant = q;

      for (final doc in docs) {
        await sqlite.addDocument(
          id: doc.id,
          content: doc.id,
          embedding: embedding,
          metadata: doc.metadata,
        );
        await qdrant?.addDocument(
          id: doc.id,
          content: doc.id,
          embedding: embedding,
          metadata: doc.metadata,
        );
      }
    });

    tearDown(() async {
      await sqlite.close();
      await qdrant?.close();
      qdrant = null;
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<List<String>> ids(VectorStoreRepository store, Filter f) async {
      final hits = await store.searchSimilar(
        queryEmbedding: embedding,
        topK: docs.length,
        filter: f,
      );
      return hits.map((h) => h.id).toList()..sort();
    }

    for (final c in cases) {
      test(c.name, () async {
        final want = [...c.expected]..sort();

        // The sqlite half always runs, so the table is asserted even on a
        // machine without the qdrant dylib.
        expect(await ids(sqlite, c.filter), want, reason: 'sqlite-vec');

        final q = qdrant;
        if (q == null) return;
        expect(await ids(q, c.filter), want, reason: 'qdrant-edge');
      });
    }
  }, skip: vec0Skip);

  // Not a decoration. Three review passes found nine cross-backend defects, and
  // the reason none was caught earlier is that no test ran both stores. So the
  // file states, as an assertion rather than as a comment, that both halves
  // actually executed.
  //
  // The qdrant half needs no guard of its own: setUp initializes the store
  // unconditionally with no locator/override step of its own (the SDK's
  // Native Assets hook resolves its library automatically), so a missing
  // native asset fails every case above with a loud error rather than a
  // silent skip. This test covers the other half — vec0, which really can be
  // absent, and whose absence would otherwise skip the group and leave the
  // file looking green.
  test('the shared table is not empty', () {
    // See the twin in the web suite. Both files do `for (final c in cases)`,
    // and they now read ONE fixture — so an empty `cases` generates zero tests
    // in both at once, which is the drift centralising it was meant to prevent,
    // relocated rather than removed.
    expect(cases, hasLength(20));
    expect(docs, hasLength(7));
  });

  test('both backends were actually exercised', () {
    expect(
      vec0SkipReason,
      isNull,
      reason:
          'the sqlite-vec half did not run, so nothing in this file was '
          'compared across backends: $vec0SkipReason',
    );
  });
}

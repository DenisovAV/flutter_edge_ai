/// The web arm of `sqlite-vec` must return the same rows as the native arm.
///
/// Run with:
///   chromedriver --port=4444 &          # must match your Chrome major version
///   cd packages/flutter_edge_ai/example
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/rag_sqlite_web_parity_test.dart \
///     -d web-server --browser-name=chrome --headless
///
/// WHY THIS FILE EXISTS
///
/// `flutter_edge_ai_sqlite`'s README says both arms "speak the same `vec0` SQL
/// dialect, so KNN and `Filter` behave identically across all six platforms".
/// Until this file that was an assertion nobody checked: every one of the
/// package's VM tests ran on the VM, and the web arm had none. Metadata
/// ENCODING is shared (`FilterToVec0.declaredColumnValues`); what is separate,
/// and what drifted, is SQL emission, value binding and row mapping.
///
/// It is not a hypothetical drift. 1.2.0 shipped a fix for "the web arm
/// rejecting integer metadata the native arm accepts", and 1.3.0 fixed three
/// more that the web arm had been shipping since 1.2.0 — every one of them
/// found by reading, because nothing ran the web arm.
///
/// The `Filter` -> SQL codec IS shared (`filter_to_vec0.dart`, imported by both
/// arms), so this suite deliberately does NOT assert generated SQL — that would
/// be a restatement of one implementation. It asserts ROWS, over the corpus in
/// `parity_cases.dart`, which is the same table the native suite runs. A case
/// added there is automatically checked on both arms; a case that passes here
/// and fails natively (or the reverse) is exactly the drift this exists for.
///
/// The fixture lives in the package's `lib/src/testing/` and is `.pubignore`d,
/// because the two suites are in different packages: `test/` has no `package:`
/// URI, and a `../../..` path out of the example is not something to build a
/// shared contract on. (An earlier note here blamed dart2js for refusing such
/// an import. That was wrong — it compiles — so whatever broke the first
/// attempt was something else and stays undiagnosed.)
@TestOn('chrome')
library;

import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:flutter_edge_ai_sqlite/src/testing/parity_cases.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // NO setUp. A setUp that throws inside a group under `flutter drive` on web
  // is reported as "All tests passed" — not as an error, not as a skip. This
  // suite went green twice over a corpus it had failed to insert before that
  // was noticed, and only a mutation of the shared expectations exposed it.
  // Building the store inside each test makes an ingest failure a test failure.
  Future<WebSqliteVectorStore> seededStore() async {
    final store = WebSqliteVectorStore();
    // configure BEFORE initialize, exactly as the native suite does — the
    // declared columns are what the vec0 table is built from.
    store.configure(schema);
    // A fresh IndexedDB name per test keeps one case's corpus out of another's.
    await store.initialize('parity_${DateTime.now().microsecondsSinceEpoch}');
    await store.bindEmbeddingProfile(
      EmbeddingProfile(id: 'web-parity-v1', dimension: embedding.length),
    );
    // NOT catchError: close() propagates, and 1.3.0's third fix was a
    // close() gated on a flag the failure path clears. Swallowing a close
    // error here would make a regression of it invisible by construction.
    addTearDown(store.close);
    for (final d in docs) {
      await store.addDocument(
        id: d.id,
        content: d.id,
        embedding: embedding,
        metadata: d.metadata,
      );
    }
    return store;
  }

  group('web filter parity', () {
    for (final c in cases) {
      testWidgets(c.name, (tester) async {
        final store = await seededStore();
        final rows = await store.searchSimilar(
          queryEmbedding: embedding,
          topK: docs.length,
          filter: c.filter,
        );
        final got = rows.map((h) => h.id).toList()..sort();
        expect(
          got,
          [...c.expected]..sort(),
          reason:
              'web returned ${got.join(", ")} where the shared table says '
              '${c.expected.join(", ")} — the two arms disagree on "${c.name}"',
        );
      });
    }

    testWidgets('the shared table is not empty', (tester) async {
      // Both suites do `for (final c in cases)`. An empty `cases` generates
      // ZERO tests and leaves only the guard below — which is itself `0 == 0`
      // when `docs` is empty. One bad edit to the shared fixture would gut both
      // arms at once, which is the drift the fixture was centralised to prevent,
      // relocated rather than removed.
      expect(cases, hasLength(20));
      expect(docs, hasLength(7));
    });

    testWidgets('the web store was actually exercised', (tester) async {
      // Sixteen of the cases expect a non-empty result and would fail loudly on
      // an empty corpus, so this is not the only thing standing between the
      // group and a false green — but it is the one that says so directly,
      // rather than leaving it to be inferred from the expectations.
      final store = await seededStore();
      final stats = await store.getStats();
      expect(
        stats.documentCount,
        docs.length,
        reason:
            'the corpus did not land, so every filter case above was comparing '
            'one empty list against another',
      );
      final all = await store.searchSimilar(
        queryEmbedding: embedding,
        topK: docs.length,
      );
      expect(all, hasLength(docs.length));
    });
  });

  testWidgets('profile binding persists and survives clear', (tester) async {
    final location = 'profile_${DateTime.now().microsecondsSinceEpoch}';
    final profile = EmbeddingProfile(id: 'web-profile-v1', dimension: 4);
    final first = WebSqliteVectorStore();
    addTearDown(first.close);
    await first.initialize(location);
    expect(await first.readEmbeddingProfile(), isNull);
    await first.bindEmbeddingProfile(profile);
    await first.addDocument(
      id: 'doc',
      content: 'document',
      embedding: const [1, 0, 0, 0],
    );
    await first.clear();
    expect(await first.readEmbeddingProfile(), profile);
    await first.close();

    final second = WebSqliteVectorStore();
    addTearDown(second.close);
    await second.initialize(location);
    expect(await second.readEmbeddingProfile(), profile);
    expect((await second.getStats()).documentCount, 0);
    await expectLater(
      second.bindEmbeddingProfile(
        EmbeddingProfile(id: 'other-web-profile-v1', dimension: 4),
      ),
      throwsA(isA<VectorStoreException>()),
    );
  });

  testWidgets('provider opens the web implementation without kIsWeb', (
    tester,
  ) async {
    final location = 'provider_${DateTime.now().microsecondsSinceEpoch}';
    final profile = EmbeddingProfile(id: 'web-provider-v1', dimension: 4);
    final rag = FlutterEdgeAiRag(
      providers: [const SqliteVectorStoreProvider()],
    );
    final index = await rag.open(
      spec: VectorStoreSpec(providerId: 'sqlite', location: location),
      embeddingProfile: profile,
    );
    addTearDown(index.dispose);
    await index.addVector(
      id: 'doc',
      content: 'document',
      embedding: const [1, 0, 0, 0],
    );
    expect((await index.stats()).documentCount, 1);
  });
}

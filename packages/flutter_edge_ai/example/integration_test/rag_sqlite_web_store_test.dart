/// Web integration test for `WebSqliteVectorStore` (rag_sqlite 1.3.0+).
///
/// Run with:
///   chromedriver --port=4444 &
///   cd packages/flutter_edge_ai/example
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/rag_sqlite_web_store_test.dart \
///     -d chrome
///
/// For headless CI: `-d web-server` instead of `-d chrome`.
///
/// WHY THIS FILE EXISTS
///
/// 1.2.0 shipped three defects on BOTH arms. 1.3.0 fixed all three on each
/// side in one change; what it did not have was any way to notice the web half — a re-initialize inheriting the
/// previous database's vector width, a swallowed detection error that let the
/// store report ready over a corpus it could not read, and a `close()` gated on
/// a flag the failure path clears. Four review passes found them; no test did,
/// because this package had no browser suite at all while declaring `web` a
/// supported platform.
///
/// The two tests below are the web twins of the native ones in
/// `flutter_edge_ai_sqlite/test/sqlite_vector_store_test.dart`, and both fail
/// against the 1.2.0 web arm.
///
/// The wasm this drives is the example's own `web/rag/sqlite3.wasm` — the
/// vec0-linked build the package ships and asks apps to copy — so this also
/// covers the copy actually being in place.
@TestOn('chrome')
library;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/wasm.dart';

/// Mirrors `WebSqliteVectorStore`'s own IndexedDB naming so a test can reach
/// the same database the store will open. Deliberately duplicated rather than
/// exported: if the store changes how it names the VFS, the planted table lands
/// somewhere the store never looks, `initialize()` succeeds, and the test goes
/// green while covering nothing. Keeping the string here means that change has
/// to be made twice — and the second edit is this comment.
String _idbName(String databasePath) => 'flutter_gemma_rag_$databasePath';

const _dbFile = '/database';
const _wasmUrl = 'rag/sqlite3.wasm';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('WebSqliteVectorStore', () {
    testWidgets('re-initializing onto another database forgets the old '
        'dimension', (tester) async {
      // `_detectExistingTable()` returned early without resetting
      // `_detectedDimension`, so a store moved from a populated database to an
      // empty one kept the first one's width — and then rejected the first
      // vector it was given against a shape the new database never had.
      // Unique IndexedDB names per run. IndexedDB persists per browser profile,
      // so fixed names meant run 2 found run 1's 8-wide vector in the "empty"
      // database, and even the unfixed code then read the right width and
      // passed.
      final store = WebSqliteVectorStore();
      addTearDown(store.close);

      final run = DateTime.now().microsecondsSinceEpoch;
      await store.initialize('redim_a_$run');
      await store.addDocument(
        id: 'a',
        content: 'x',
        embedding: List<double>.filled(4, 1),
      );

      await store.initialize('redim_b_$run');
      expect(
        (await store.getStats()).vectorDimension,
        0,
        reason:
            'the second database must be EMPTY or this test proves nothing — '
            'the bug is that an empty one inherited the first one\'s width, and '
            'a database left over from an earlier run reports its own width and '
            'passes with the regression intact',
      );
      await expectLater(
        store.addDocument(
          id: 'b',
          content: 'y',
          embedding: List<double>.filled(8, 1),
        ),
        completes,
        reason:
            'the store carried the first database 4-wide shape into a second, '
            'empty one and rejected an 8-wide vector against it',
      );
    });

    testWidgets('an unreadable corpus is refused, not reported as empty', (
      tester,
    ) async {
      // THE one that loses data silently. `_detectExistingTable()` caught and
      // only logged, so `initialize()` went on to set the ready flag with no
      // dimension: `searchSimilar` returned [], `getStats` reported
      // documentCount 0, and `removeDocument` reported success while deleting
      // nothing — over a corpus that was present and merely unreadable. In a
      // release build the only trace was a `gemmaLog` that does not exist.
      //
      // The planted table is a `vec_documents` the store cannot read as vec0.
      // The closest real-world shape is an app that MIGRATES a database made by
      // the vec0-linked wasm onto the stock one — a first-run app instead fails
      // loudly at CREATE VIRTUAL TABLE with `no such module: vec0`.
      const path = 'unreadable_corpus';

      final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse(_wasmUrl));
      final idb = await IndexedDbFileSystem.open(dbName: _idbName(path));
      sqlite3.registerVirtualFileSystem(idb, makeDefault: true);
      final raw = sqlite3.open(_dbFile);
      raw.execute('DROP TABLE IF EXISTS vec_documents');
      raw.execute('CREATE TABLE vec_documents (id TEXT, nonsense INTEGER)');
      raw.execute("INSERT INTO vec_documents VALUES ('kept', 1)");
      raw.close();
      await idb.close(); // flush to IndexedDB before the store reopens it

      final store = WebSqliteVectorStore();
      addTearDown(store.close);

      await expectLater(
        store.initialize(path),
        throwsA(isA<VectorStoreException>()),
        reason:
            'the store swallowed the detection error and reported itself ready '
            'over a corpus it could not read',
      );
      expect(
        store.isInitialized,
        isFalse,
        reason: 'an initialize() that threw reported the store as ready',
      );

      // NOT asserted here: that the WASM instance and its VFS were released.
      // Note the failure path does NOT clear them — it clears `_db` only, which
      // is exactly why `close()` names `_sqlite3` in its guard. What cannot be
      // asserted is the RELEASE: sqlite tolerates concurrent connections, so a
      // leaked handle is not observable from a second open on the same path and
      // a test written that way passes with the leak intact. The native suite
      // left the same assertion out, measured on FFI sqlite.
    });
  });
}

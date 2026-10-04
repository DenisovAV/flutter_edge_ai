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

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_edge_ai_sqlite/flutter_edge_ai_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqlite3/wasm.dart';
import 'package:web/web.dart' as web;

/// Mirrors `WebSqliteVectorStore`'s own IndexedDB naming so a test can reach
/// the same database the store will open. Deliberately duplicated rather than
/// exported: if the store changes how it names the VFS, the planted table lands
/// somewhere the store never looks, `initialize()` succeeds, and the test goes
/// green while covering nothing. Keeping the string here means that change has
/// to be made twice — and the second edit is this comment.
String _idbName(String databasePath) => 'flutter_gemma_rag_$databasePath';

const _dbFile = '/database';
const _wasmUrl = 'rag/sqlite3.wasm';

Future<bool> _workerCanAcquire(web.Worker worker, String lockName) {
  final result = Completer<bool>();
  worker.onmessage = ((web.MessageEvent event) {
    final message = event.data.dartify();
    if (message is! Map) {
      result.completeError(StateError('Worker returned a non-object response'));
      return;
    }
    final error = message['error'];
    if (error != null) {
      result.completeError(
        StateError('Worker Web Locks request failed: $error'),
      );
      return;
    }
    final acquired = message['acquired'];
    if (acquired is! bool) {
      result.completeError(StateError('Worker omitted its acquired result'));
      return;
    }
    result.complete(acquired);
  }).toJS;
  worker.onerror = ((web.Event event) {
    if (!result.isCompleted) {
      result.completeError(StateError('Web Worker failed to load or execute'));
    }
  }).toJS;
  worker.postMessage({'lockName': lockName}.jsify());
  return result.future.timeout(const Duration(seconds: 10));
}

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
      await store.bindEmbeddingProfile(
        EmbeddingProfile(id: 'redim-a-v1', dimension: 4),
      );
      await store.addDocument(
        id: 'a',
        content: 'x',
        embedding: List<double>.filled(4, 1),
      );

      await store.initialize('redim_b_$run');
      await store.bindEmbeddingProfile(
        EmbeddingProfile(id: 'redim-b-v1', dimension: 8),
      );
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

      // Resource cleanup is covered separately by the exclusive-location test:
      // after a failed or closed store, a new owner must acquire the same path.
    });

    testWidgets('one location has exactly one lifetime owner', (tester) async {
      final location = 'exclusive_${DateTime.now().microsecondsSinceEpoch}';
      final first = WebSqliteVectorStore();
      final second = WebSqliteVectorStore();
      addTearDown(first.close);
      addTearDown(second.close);

      Future<Object?> tryOpen(WebSqliteVectorStore store) async {
        try {
          await store.initialize(location);
          return null;
        } catch (error) {
          return error;
        }
      }

      final outcomes = await Future.wait([tryOpen(first), tryOpen(second)]);
      expect(
        outcomes.where((outcome) => outcome == null),
        hasLength(1),
        reason: 'exactly one concurrent open must own the persistent snapshot',
      );
      final failure = outcomes.singleWhere((outcome) => outcome != null);
      expect(failure, isA<VectorStoreException>());
      expect(failure.toString(), contains('already open'));
      expect(failure.toString(), contains('Close the existing'));

      final winner = outcomes.first == null ? first : second;
      final loser = identical(winner, first) ? second : first;
      await winner.close();
      await expectLater(loser.initialize(location), completes);
      expect(loser.isInitialized, isTrue);
    });

    testWidgets('concurrent initialize calls are FIFO and leak no leases', (
      tester,
    ) async {
      final run = DateTime.now().microsecondsSinceEpoch;
      final firstLocation = 'lane_a_$run';
      final secondLocation = 'lane_b_$run';
      final store = WebSqliteVectorStore();
      addTearDown(store.close);

      final firstInitialize = store.initialize(firstLocation);
      final secondInitialize = store.initialize(secondLocation);
      expect(
        store.isInitialized,
        isFalse,
        reason: 'queued lifecycle work must hide the previous/live snapshot',
      );
      await expectLater(store.getStats(), throwsStateError);
      await Future.wait([firstInitialize, secondInitialize]);
      expect(store.isInitialized, isTrue);

      // FIFO makes the second request the defined final owner. The first lease
      // must already be released; the second must still be exclusively held.
      final firstProbe = WebSqliteVectorStore();
      final secondProbe = WebSqliteVectorStore();
      addTearDown(firstProbe.close);
      addTearDown(secondProbe.close);
      await expectLater(firstProbe.initialize(firstLocation), completes);
      await expectLater(
        secondProbe.initialize(secondLocation),
        throwsA(isA<VectorStoreException>()),
      );

      final closing = store.close();
      expect(store.isInitialized, isFalse);
      await expectLater(store.getStats(), throwsStateError);
      await closing;
      await firstProbe.close();
      final reopenedFirst = WebSqliteVectorStore();
      final reopenedSecond = WebSqliteVectorStore();
      addTearDown(reopenedFirst.close);
      addTearDown(reopenedSecond.close);
      await Future.wait([
        reopenedFirst.initialize(firstLocation),
        reopenedSecond.initialize(secondLocation),
      ]);
      expect(reopenedFirst.isInitialized, isTrue);
      expect(reopenedSecond.isInitialized, isTrue);
    });

    testWidgets('Web Lock excludes a real worker until store close', (
      tester,
    ) async {
      final location = 'worker_${DateTime.now().microsecondsSinceEpoch}';
      final lockName = 'flutter-edge-ai-sqlite:$location';
      final store = WebSqliteVectorStore();
      addTearDown(store.close);
      await store.initialize(location);

      final worker = web.Worker('rag_lock_worker.js'.toJS);
      addTearDown(() => worker.terminate());
      expect(
        await _workerCanAcquire(worker, lockName),
        isFalse,
        reason: 'a distinct worker acquired the store lifetime lock',
      );

      await store.close();
      expect(
        await _workerCanAcquire(worker, lockName),
        isTrue,
        reason: 'the store did not release its browser-wide lifetime lock',
      );
    });

    testWidgets('failed profile durability fence poisons the store', (
      tester,
    ) async {
      final location = 'fence_${DateTime.now().microsecondsSinceEpoch}';
      final store = WebSqliteVectorStore(
        durabilityFenceForTesting: () async {
          throw StateError('deterministic durability-fence failure');
        },
      );
      addTearDown(store.close);
      await store.initialize(location);

      await expectLater(
        store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'fence-profile-v1', dimension: 4),
        ),
        throwsA(
          isA<VectorStoreException>().having(
            (error) => error.message,
            'message',
            contains('could not be made durable'),
          ),
        ),
      );
      expect(store.isInitialized, isFalse);
      await expectLater(store.readEmbeddingProfile(), throwsStateError);
      await expectLater(
        store.bindEmbeddingProfile(
          EmbeddingProfile(id: 'second-profile-v1', dimension: 4),
        ),
        throwsStateError,
      );
      await expectLater(
        store.addDocument(
          id: 'unsafe',
          content: 'unsafe',
          embedding: const [1, 0, 0, 0],
        ),
        throwsStateError,
      );
      await expectLater(
        store.searchSimilar(queryEmbedding: const [1, 0, 0, 0], topK: 1),
        throwsStateError,
      );

      // Poisoning also releases the lifetime lease, so recovery starts from a
      // fresh handle rather than the uncertain live snapshot.
      final reopened = WebSqliteVectorStore();
      addTearDown(reopened.close);
      await expectLater(reopened.initialize(location), completes);
    });

    testWidgets('close waits for an active profile durability fence', (
      tester,
    ) async {
      final location = 'close_fence_${DateTime.now().microsecondsSinceEpoch}';
      final fenceEntered = Completer<void>();
      final releaseFence = Completer<void>();
      final store = WebSqliteVectorStore(
        durabilityFenceForTesting: () async {
          fenceEntered.complete();
          await releaseFence.future;
        },
      );
      addTearDown(store.close);
      await store.initialize(location);

      final binding = store.bindEmbeddingProfile(
        EmbeddingProfile(id: 'close-fence-v1', dimension: 4),
      );
      await fenceEntered.future;
      var closeCompleted = false;
      final closing = store.close().then((_) => closeCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(store.isInitialized, isFalse);
      expect(
        closeCompleted,
        isFalse,
        reason: 'close overtook a durability fence already in flight',
      );
      await expectLater(store.getStats(), throwsStateError);

      releaseFence.complete();
      await binding;
      await closing;
      expect(closeCompleted, isTrue);

      final reopened = WebSqliteVectorStore();
      addTearDown(reopened.close);
      await expectLater(reopened.initialize(location), completes);
    });

    testWidgets('missing Web Locks fails closed before opening storage', (
      tester,
    ) async {
      final location = 'no_locks_${DateTime.now().microsecondsSinceEpoch}';
      final unsupported = WebSqliteVectorStore(
        forceBrowserLocksUnavailableForTesting: true,
      );
      addTearDown(unsupported.close);

      await expectLater(
        unsupported.initialize(location),
        throwsA(
          isA<VectorStoreException>()
              .having(
                (error) => error.message,
                'message',
                contains('requires the Web Locks API'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('No database was opened'),
              ),
        ),
      );
      expect(unsupported.isInitialized, isFalse);

      // A failed capability check must not leak the same-context guard.
      final supported = WebSqliteVectorStore();
      addTearDown(supported.close);
      await expectLater(supported.initialize(location), completes);
    });
  });
}

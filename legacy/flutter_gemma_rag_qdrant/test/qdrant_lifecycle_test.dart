// Lifecycle and on-disk-format regressions for the 2.0 UniFFI migration.
//
// Every test here pins a failure that the 82-test suite next door could not
// see, because all of those live inside one process against a `setUp`-fresh
// directory: they never open a store a different session — or a different
// package version — wrote, and never run two operations at once.
//
// Most cases below were observed failing on the migration commit before the
// fix. Two are not regression pins and say so at their own site: one guards a
// fix against OVER-correcting (the cold-store case, which the pre-fix code also
// passed — for the wrong reason), and one pins an outcome that more than one
// mechanism delivers. Both were checked by mutation; the distinction is written
// down because "every test here failed before" is the kind of blanket claim
// that quietly stops being true.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_rag_qdrant/flutter_gemma_rag_qdrant.dart';
import 'package:flutter_gemma_rag_qdrant/src/point_id_hasher.dart';
import 'package:flutter_gemma_rag_qdrant/src/qdrant_edge_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qdrant_edge/qdrant_edge.dart' as qe;

/// The owned, format-scoped subdirectory this release keeps its shard in.
const storeDirName = 'qdrant_edge_v1';

List<double> vec(int dim, double seed) => List<double>.filled(dim, seed);

/// Lays out the three entries a 1.x (crate 0.7.x) shard wrote directly at the
/// caller's databasePath, before this package owned a versioned subdirectory.
void writeLegacyStore(String databasePath) {
  // The real shard config, not a placeholder. `{}` used to be enough to be
  // classified as our store — which is exactly how a caller's own
  // `edge_config.json` got their `wal/` and `segments/` deleted. The unnamed
  // "" vector field is the part that says "this package wrote it".
  // `on_disk_payload` is false here because that is what the 1.x Rust shim
  // wrote (build_edge_config in the deleted native/qdrant_edge). The probe does
  // not read that key — the proof of ownership is the unnamed "" vector field —
  // but a fixture that claims to be what 1.x wrote should be it.
  File('$databasePath/edge_config.json').writeAsStringSync(
    '{"on_disk_payload":false,'
    '"vectors":{"":{"size":4,"distance":"Cosine","on_disk":false}},'
    '"sparse_vectors":{}}',
  );
  Directory('$databasePath/wal').createSync(recursive: true);
  Directory('$databasePath/segments').createSync(recursive: true);
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('qdrant_lifecycle'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('concurrent open', () {
    test(
      'parallel addDocument calls share one open instead of racing',
      () async {
        // Before: both callers saw `_client == null`, both opened the shard, and
        // qdrant's exclusive WAL lock failed the loser with
        // `Can't init WAL: Kind(WouldBlock)` — losing that document.
        // `Future.wait(docs.map(store.addDocument))` is how you index a corpus.
        final store = QdrantVectorStore();
        await store.initialize(tmp.path);
        await Future.wait([
          for (var i = 0; i < 8; i++)
            store.addDocument(
              id: 'doc$i',
              content: 'content $i',
              embedding: vec(4, i + 1.0),
            ),
        ]);
        expect((await store.getStats()).documentCount, 8);
        await store.close();
      },
    );

    test(
      'close() during an in-flight open does not resurrect the store',
      () async {
        // Before: the in-flight open re-installed its client AFTER close(), so
        // `isInitialized` was false while the store still answered reads, the
        // shard was never unloaded, and its WAL lock was held until the process
        // exited — every later initialize() on that path failed permanently.
        final store = QdrantVectorStore();
        await store.initialize(tmp.path);
        final write = store.addDocument(
          id: 'a',
          content: 'a',
          embedding: vec(4, 1),
        );
        await store.close();
        try {
          await write;
        } catch (_) {
          // Either outcome is fine; what must NOT happen is a live client.
        }
        expect(store.isInitialized, isFalse);

        // The decisive part: the lock must be gone, so a fresh store can open.
        final second = QdrantVectorStore();
        await second.initialize(tmp.path);
        await second.addDocument(id: 'b', content: 'b', embedding: vec(4, 2));
        expect((await second.getStats()).documentCount, greaterThan(0));
        await second.close();
      },
    );
  });

  group('reopening an existing store', () {
    test('reports its contents before anything writes to it', () async {
      // Before: the client opened lazily on the first addDocument, so a store
      // re-opened after an app restart reported 0 documents and 0 hits until
      // something happened to write — retrieval silently returned nothing.
      final first = QdrantVectorStore();
      await first.initialize(tmp.path);
      for (var i = 0; i < 5; i++) {
        await first.addDocument(
          id: 'doc$i',
          content: 'content $i',
          embedding: vec(4, i + 1.0),
        );
      }
      await first.close();

      final reopened = QdrantVectorStore();
      await reopened.initialize(tmp.path);
      expect((await reopened.getStats()).documentCount, 5);
      expect(
        await reopened.searchSimilar(queryEmbedding: vec(4, 1), topK: 10),
        isNotEmpty,
      );
      await reopened.close();
    });

    test('a delete issued before the first write is not dropped', () async {
      // Before: removeDocument() returned early with only a log line when the
      // client had not been opened yet, and the document survived.
      final first = QdrantVectorStore();
      await first.initialize(tmp.path);
      await first.addDocument(id: 'keep', content: 'k', embedding: vec(4, 1));
      await first.addDocument(id: 'drop', content: 'd', embedding: vec(4, 2));
      await first.close();

      final reopened = QdrantVectorStore();
      await reopened.initialize(tmp.path);
      await reopened.removeDocument(id: 'drop');
      expect((await reopened.getStats()).documentCount, 1);
      await reopened.close();
    });
  });

  group('a store written by 1.x', () {
    test('initialize() itself refuses, not just the first write', () async {
      // Before: 2.0 only ever looks under its owned subdir, so a 1.x shard was
      // invisible — no error, no log, an empty index, and the old corpus still
      // occupying disk.
      //
      // The check has to be HERE and not on the write path. A read-only
      // session — open the app, ask a question — never writes, so a write-path
      // check let initialize() succeed, searchSimilar return nothing, and the
      // model answer without the corpus that was on disk the whole time.
      writeLegacyStore(tmp.path);
      final store = QdrantVectorStore();
      await expectLater(
        store.initialize(tmp.path),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => e.toString(),
            'message',
            contains('1.x'),
          ),
        ),
      );
    });

    test(
      'a failed initialize() does not leave the store reading as empty',
      () async {
        // The hole the first version of this fix left open. initialize() arms
        // `_databasePath` BEFORE it throws, so that clear() stays reachable —
        // but it set no latch, so `_assertUsable` saw a perfectly healthy store.
        // A caller that logged the exception and carried on, or any other code
        // path that read, got 0 documents and no hits over an intact 1.x corpus:
        // the exact defect this release removes, in the one case it is about.
        writeLegacyStore(tmp.path);
        final store = QdrantVectorStore();
        await expectLater(
          store.initialize(tmp.path),
          throwsA(isA<VectorStoreException>()),
        );

        expect(
          store.isInitialized,
          isFalse,
          reason: 'a store whose initialize() threw reported itself ready',
        );
        await expectLater(
          store.getStats(),
          throwsA(isA<VectorStoreException>()),
          reason: 'reported 0 documents over a 1.x corpus still on disk',
        );
        await expectLater(
          store.searchSimilar(queryEmbedding: vec(4, 1), topK: 5),
          throwsA(isA<VectorStoreException>()),
          reason: 'answered with no hits over a 1.x corpus still on disk',
        );
        await expectLater(
          store.removeDocument(id: 'x'),
          throwsA(isA<VectorStoreException>()),
        );
      },
    );
  });

  group('an unreadable shard is not an empty one', () {
    test('a held WAL is reported, not answered as zero documents', () async {
      // qdrant-edge holds the WAL exclusively. A second store on the same path
      // — a second isolate, a second app process, a store the caller forgot to
      // close — cannot adopt the shard. Before: adoption failure went to
      // gemmaLog, which is `if (!kDebugMode) return;`, so a RELEASE build told
      // nobody and every read answered "empty" over an intact corpus.
      final holder = QdrantVectorStore();
      await holder.initialize(tmp.path);
      await holder.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      addTearDown(holder.close);

      final second = QdrantVectorStore();
      addTearDown(second.close);
      // The contract says initialize() throws when initialization fails, and
      // this failed: a shard is on disk and the WAL is held elsewhere.
      await expectLater(
        second.initialize(tmp.path),
        throwsA(isA<VectorStoreException>()),
      );

      await expectLater(
        second.getStats(),
        throwsA(isA<VectorStoreException>()),
        reason: 'a shard it could not open was reported as 0 documents',
      );
      await expectLater(
        second.searchSimilar(queryEmbedding: vec(4, 1), topK: 5),
        throwsA(isA<VectorStoreException>()),
        reason: 'a shard it could not open was reported as no hits',
      );
    });

    test('a genuinely cold store stays quiet', () async {
      // NOT a regression pin: the pre-fix code passes this too, because back
      // then adoption threw, was swallowed into gemmaLog, and getStats()
      // returned 0 — which is what this asserts. What it actually guards is
      // the fix OVER-correcting. qdrant-edge raises the same error for
      // "nothing here" as for "here but unreadable", so a latch that keyed on
      // "adoption threw" would make every read on an empty store refuse.
      // Removing the openExisting gate kills this test, at the second half;
      // the first half (a fresh store) asserts nothing and is kept only as the
      // baseline the second half is read against.
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      expect((await store.getStats()).documentCount, 0);
      expect(
        await store.searchSimilar(queryEmbedding: vec(4, 1), topK: 5),
        isEmpty,
      );
      await store.close();

      Directory('${tmp.path}/qdrant_edge_v1').createSync(recursive: true);
      final overLeftover = QdrantVectorStore();
      await overLeftover.initialize(tmp.path);
      expect(
        (await overLeftover.getStats()).documentCount,
        0,
        reason: 'an abandoned empty shard directory was treated as unreadable',
      );
      await overLeftover.close();
    });
  });

  group('an unreadable shard is not an empty one (review round 2)', () {
    test('a shard whose edge_config.json is gone is still adopted', () async {
      // The marker gate this fix originally shipped required `edge_config.json`
      // and returned "no shard" without it. Measured: the engine loads that
      // directory FINE — `wal/` and `segments/` are the data, the config is
      // not — so a store with a full corpus reported zero documents until an
      // unrelated write made it reappear. `clear()` dying after unlinking the
      // marker but before `segments/` reaches exactly this state, and the
      // re-initialize its own fail-closed path prescribes laundered it into a
      // confident zero.
      final seed = QdrantVectorStore();
      await seed.initialize(tmp.path);
      await seed.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      await seed.addDocument(id: 'b', content: 'y', embedding: vec(4, 2));
      await seed.close();

      File('${tmp.path}/$storeDirName/edge_config.json').deleteSync();

      final reopened = QdrantVectorStore();
      await reopened.initialize(tmp.path);
      expect(
        (await reopened.getStats()).documentCount,
        2,
        reason: 'a readable shard was reported as an empty store',
      );
      await reopened.close();
    });

    test('addDocument refuses over a shard it could not read', () async {
      // Before: the write path never consulted the latch, and any successful
      // open cleared it — so the one signal a user gets that their corpus is
      // unreadable was erasable by an ordinary addDocument, which then merged
      // into the very shard just reported as empty.
      final holder = QdrantVectorStore();
      await holder.initialize(tmp.path);
      await holder.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      addTearDown(holder.close);

      final second = QdrantVectorStore();
      addTearDown(second.close);
      await expectLater(
        second.initialize(tmp.path), // WAL held by holder
        throwsA(isA<VectorStoreException>()),
      );

      await expectLater(
        second.addDocument(id: 'b', content: 'y', embedding: vec(4, 2)),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => e.toString(),
            'message',
            // The type alone is not enough: without the latch this write still
            // throws, because the WAL is held — a different failure a bare
            // isA<VectorStoreException>() cannot tell apart. Only _assertUsable
            // says "addDocument refused"; a failed open says "Failed to open
            // qdrant shard at". Verified by mutation: dropping the assertion
            // changes the message, not the throw.
            contains('addDocument refused'),
          ),
        ),
      );
      await expectLater(
        second.getStats(),
        throwsA(isA<VectorStoreException>()),
        reason: 'a write cleared the latch and the store reported itself fine',
      );
    });

    test(
      'a failure for one path does not latch a store armed at another',
      () async {
        // An outcome test, deliberately: it does not care WHICH mechanism
        // keeps the latch from leaking. Today it is the lifecycle lane — the
        // second initialize() cannot start until the first has finished, and
        // it clears the latch as it arms the new path. Removing the generation
        // check in initialize()'s catch leaves this passing, and that is the
        // truth about the check rather than a gap here.
        final other = Directory.systemTemp.createTempSync('qdrant_other');
        addTearDown(() {
          try {
            other.deleteSync(recursive: true);
          } catch (_) {}
        });
        final holder = QdrantVectorStore();
        await holder.initialize(tmp.path);
        await holder.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
        addTearDown(holder.close);

        final store = QdrantVectorStore();
        addTearDown(store.close);
        final toLocked = store.initialize(tmp.path); // fails: WAL held
        final toFresh = store.initialize(other.path); // succeeds
        await toLocked.catchError((_) {});
        await toFresh.catchError((_) {});

        expect(
          (await store.getStats()).documentCount,
          0,
          reason: 'the latch leaked from the path the store no longer uses',
        );
      },
    );

    test('two overlapping initialize() calls adopt the corpus', () async {
      // A provider rebuilt, an initState firing twice. Both calls raced
      // qdrant's exclusive WAL: one won, the other caught WouldBlock and
      // latched the store unreadable over an intact corpus — while BOTH
      // reported success.
      final seed = QdrantVectorStore();
      await seed.initialize(tmp.path);
      await seed.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      await seed.addDocument(id: 'b', content: 'y', embedding: vec(4, 2));
      await seed.close();

      final store = QdrantVectorStore();
      addTearDown(store.close);
      await Future.wait([
        store.initialize(tmp.path),
        store.initialize(tmp.path),
      ]);

      expect(store.isInitialized, isTrue);
      expect(
        (await store.getStats()).documentCount,
        2,
        reason: 'a double init left the store unreadable over its own corpus',
      );
    });
  });

  group('a 1.x store is refused, and nothing of it is deleted', () {
    test('clear() refuses and names the files to remove', () async {
      // The whole sweep this group used to cover is gone. clear() no longer
      // deletes anything: it empties the shard in place through the SDK, and a
      // 1.x layout cannot be emptied in place because this release cannot open
      // it. So the remedy is a refusal that says exactly what to remove — and
      // with no destructive path left, the class of bug that twice deleted
      // files this package did not write cannot recur.
      writeLegacyStore(tmp.path);
      File('${tmp.path}/user_notes.txt').writeAsStringSync('keep me');
      final store = QdrantVectorStore();
      addTearDown(store.close);

      await expectLater(
        store.initialize(tmp.path),
        throwsA(isA<QdrantLegacyStoreException>()),
      );
      await expectLater(
        store.clear(),
        throwsA(
          isA<QdrantLegacyStoreException>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('edge_config.json'), contains('wal')),
          ),
        ),
      );

      for (final name in ['edge_config.json', 'wal', 'segments']) {
        final at = '${tmp.path}/$name';
        expect(
          File(at).existsSync() || Directory(at).existsSync(),
          isTrue,
          reason: 'clear() deleted $name — it must only refuse',
        );
      }
      expect(File('${tmp.path}/user_notes.txt').existsSync(), isTrue);
    });
  });

  group('the latch must lift as well as fall', () {
    test('an EMPTY owned directory is not evidence of a shard', () async {
      // A first open that failed leaves the owned directory behind with
      // nothing in it. That must stay quiet, or every read on a store that
      // never held data would refuse.
      //
      // Note what changed with SDK 0.8.0-dev.3: this package used to decide
      // "is there a shard here" by looking at file names, and deliberately did
      // not count `wal/`. `probeShard` now decides, and it calls a lone `wal/`
      // *incomplete* rather than absent — a stricter answer than the one this
      // package invented, and the SDK's to make.
      Directory('${tmp.path}/$storeDirName').createSync(recursive: true);
      final store = QdrantVectorStore();
      addTearDown(store.close);
      await store.initialize(tmp.path);
      expect(
        (await store.getStats()).documentCount,
        0,
        reason: 'an abandoned empty shard directory was treated as unreadable',
      );
    });
  });

  group('the 1.x probe reads the marker, not just its name', () {
    test(
      'a same-named file that is not our config is not a 1.x store',
      () async {
        // The probe is content-gated because a false positive is destructive:
        // the store refuses to run and clear() — the remedy its own error names
        // — deletes what it matched. Every existing test writes a valid '{}', so
        // dropping the content check passed the whole suite.
        File('${tmp.path}/edge_config.json').writeAsStringSync('not our file');
        final store = QdrantVectorStore();
        addTearDown(store.close);
        await store.initialize(tmp.path);
        await store.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
        expect((await store.getStats()).documentCount, 1);
        expect(
          File('${tmp.path}/edge_config.json').readAsStringSync(),
          'not our file',
          reason: "someone else's file was treated as our 1.x store",
        );
      },
    );

    test('a marker we cannot READ counts as present, not as absent', () async {
      // The blanket `catch (_)` put "unreadable" in the same bucket as "not
      // ours", so a genuine 1.x store whose marker could not be read came up
      // as an empty index with no error — back in the silent bucket.
      writeLegacyStore(tmp.path);
      final marker = File('${tmp.path}/edge_config.json');
      Process.runSync('chmod', ['000', marker.path]);
      addTearDown(() => Process.runSync('chmod', ['600', marker.path]));

      final store = QdrantVectorStore();
      addTearDown(store.close);
      await expectLater(
        store.initialize(tmp.path),
        throwsA(isA<VectorStoreException>()),
        reason: 'an unreadable 1.x marker was read as "no legacy store"',
      );
    }, skip: Platform.isWindows ? 'chmod semantics differ' : false);
  });

  group('a shard we did not write', () {
    test('is reported, not treated as no shard at all', () async {
      // The one branch with POSITIVE proof a shard is present — it loaded, we
      // read its config — and it used to discard that and return null, so the
      // store came up empty over data it had just seen. Reachable from a shard
      // written by another tool, or by a future format of ours.
      final storeDir = Directory('${tmp.path}/$storeDirName')
        ..createSync(recursive: true);
      qe.EdgeShard.load(
        path: storeDir.path,
        config: qe.EdgeConfig(
          vectorData: {
            'text': qe.VectorDataConfig(size: 8, distance: qe.Distance.cosine),
          },
        ),
      ).unload();

      final store = QdrantVectorStore();
      addTearDown(store.close);
      await expectLater(
        store.initialize(tmp.path),
        throwsA(
          isA<VectorStoreException>().having(
            (e) => '$e',
            'message',
            // The reason must survive the trip out — `_rethrow` used to wrap
            // this, our own exception, again as an "unexpected error".
            allOf(
              contains('not written by this package'),
              isNot(contains('unexpected error')),
            ),
          ),
        ),
        reason: 'a shard it had just loaded was reported as an empty store',
      );
      await expectLater(store.getStats(), throwsA(isA<VectorStoreException>()));
    });
  });

  group('the documented no-ops', () {
    test(
      'removeDocument on an initialized, never-written store is a no-op',
      () async {
        // The contract says removing a document that does not exist does not
        // throw. Distinct from the two refusals around it — uninitialized is a
        // StateError, unreadable is a VectorStoreException — and nothing pinned
        // which of the three this is.
        final store = QdrantVectorStore();
        addTearDown(store.close);
        await store.initialize(tmp.path);
        await expectLater(store.removeDocument(id: 'never-added'), completes);
      },
    );
  });

  group('a write racing a lifecycle transition', () {
    test(
      'addDocument during clear() fails loudly and leaves a usable store',
      () async {
        // The lifecycle lane serializes initialize/clear/close against each
        // other, but NOT against the write path — _ensureClient stays outside it
        // so bulk indexing is not funnelled through one queue. That leaves a
        // window where a write can hold a client clear() is closing. The
        // requirement is not that the write succeed; it is that it never
        // succeed QUIETLY into a store being erased, and that what is left
        // behind is usable.
        final store = QdrantVectorStore();
        addTearDown(store.close);
        await store.initialize(tmp.path);
        await store.addDocument(id: 'seed', content: 's', embedding: vec(4, 1));

        final outcomes = await Future.wait([
          store.clear().then((_) => 'ok').catchError((Object e) => 'threw'),
          store
              .addDocument(id: 'a', content: 'x', embedding: vec(4, 2))
              .then((_) => 'ok')
              .catchError((Object e) => 'threw'),
        ]);

        expect(outcomes.first, 'ok');
        expect(store.isInitialized, isTrue);
        // Either the write landed before the erase or it was refused — never a
        // silent no-op, and never a wedged store.
        expect((await store.getStats()).documentCount, anyOf(0, 1));
        await store.addDocument(id: 'b', content: 'y', embedding: vec(4, 3));
        expect((await store.getStats()).documentCount, greaterThan(0));
      },
    );

    test('addDocument during close() does not leak the WAL lock', () async {
      // The worst outcome here is invisible: a store the caller closed keeps
      // qdrant's exclusive WAL for the process lifetime, and every later
      // store on that path fails WouldBlock — which this release now latches,
      // so it would present as "your corpus is unreadable" forever.
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      await Future.wait([
        store.close().catchError((Object e) {}),
        store
            .addDocument(id: 'a', content: 'x', embedding: vec(4, 1))
            .catchError((Object e) {}),
      ]);

      final reopened = QdrantVectorStore();
      addTearDown(reopened.close);
      await reopened.initialize(tmp.path);
      await expectLater(
        reopened.getStats(),
        completes,
        reason: 'the closed store kept its WAL lock',
      );
    });
  });

  group('a lifecycle failure nobody awaited', () {
    test('still reaches the zone', () async {
      // `initState()` cannot await, so `store.initialize(dir);` is the ordinary
      // shape — and the one the lane's own comment cites. Advancing the lane
      // with `run.then((_) {}, onError: (_) {})` registered a listener on the
      // CALLER's future, which marks the error handled globally: no zone
      // error, no FlutterError.onError, no crash reporter, and gemmaLog is
      // debug-only. The release's headline error went nowhere at all, and the
      // same lane ate clear()'s partial-delete report — which throws instead
      // of logging for exactly that reason.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        // Control: prove the zone is actually catching in this test.
        unawaited(Future<void>(() => throw StateError('control')));
        writeLegacyStore(tmp.path);
        QdrantVectorStore().initialize(tmp.path); // deliberately not awaited
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }, (e, _) => errors.add(e));

      expect(errors.whereType<StateError>(), hasLength(1), reason: 'control');
      expect(
        errors.whereType<VectorStoreException>(),
        hasLength(1),
        reason: 'an unawaited lifecycle failure was reported to nobody',
      );
    });

    test('an awaited failure is not reported twice', () async {
      // The other half: the lane must not ALSO push the error to the zone when
      // the caller handled it. Two of the three shapes I tried failed one side
      // or the other.
      final errors = <Object>[];
      await runZonedGuarded(() async {
        writeLegacyStore(tmp.path);
        final store = QdrantVectorStore();
        await expectLater(
          store.initialize(tmp.path),
          throwsA(isA<VectorStoreException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }, (e, _) => errors.add(e));
      expect(errors, isEmpty, reason: 'a handled failure was double-reported');
    });
  });

  group('evidence good enough to refuse is not evidence good enough to delete', () {
    test(
      "an unreadable marker does not cost the caller its directories",
      () async {
        // Round 1 through a new door. A marker we cannot READ is either a real
        // 1.x store (refuse, or the app comes up empty over the corpus) or
        // someone else's file beside directories the caller happens to have
        // named `wal` and `segments`. We cannot tell — that is what "cannot
        // read" means — so it gets the safe half of each: refuse to start, never
        // delete. Answering a plain `true` deleted both of the caller's
        // directories and returned from clear() NORMALLY.
        final marker = File('${tmp.path}/edge_config.json')
          ..writeAsStringSync('not our file');
        Directory('${tmp.path}/wal').createSync();
        File('${tmp.path}/wal/caller.txt').writeAsStringSync('mine');
        Directory('${tmp.path}/segments').createSync();
        File('${tmp.path}/segments/caller.txt').writeAsStringSync('mine');
        Process.runSync('chmod', ['000', marker.path]);
        addTearDown(() => Process.runSync('chmod', ['600', marker.path]));

        final store = QdrantVectorStore();
        addTearDown(store.close);
        await expectLater(
          store.initialize(tmp.path),
          throwsA(isA<VectorStoreException>()),
        );
        await expectLater(
          store.clear(),
          throwsA(isA<VectorStoreException>()),
          reason: 'clear() reported success while deleting the caller\'s data',
        );
        expect(Directory('${tmp.path}/wal').existsSync(), isTrue);
        expect(Directory('${tmp.path}/segments').existsSync(), isTrue);
      },
      skip: Platform.isWindows ? 'chmod semantics differ' : false,
    );

    test(
      "a readable config we did not write is refused but never deleted",
      () async {
        // The destructive false positive, reopened a second time through the
        // door the previous fix left ajar. "It parses as a JSON object" was
        // treated as proof of ownership, so a caller whose own
        // `edge_config.json` held `{}` — beside their own `wal/` and
        // `segments/` — had both directories deleted by clear(), which then
        // returned normally.
        //
        // The proof-of-ownership machinery that used to gate deletion is gone
        // with the deletion itself: clear() empties the shard in place through
        // the SDK and never removes a file. We still refuse — it could be a 1.x
        // layout — but there is no destructive branch left for the evidence to
        // authorise, which retires this class of bug rather than narrowing it.
        File('${tmp.path}/edge_config.json').writeAsStringSync('{}');
        Directory('${tmp.path}/wal').createSync();
        File('${tmp.path}/wal/caller.txt').writeAsStringSync('mine');
        Directory('${tmp.path}/segments').createSync();
        File('${tmp.path}/segments/caller.txt').writeAsStringSync('mine');

        final store = QdrantVectorStore();
        addTearDown(store.close);
        // NOT the legacy type. That type is the one the README tells callers
        // to catch and act on — "e.message names what to remove" — so throwing
        // it for data we could not identify hands the destructive instruction
        // to someone whose files merely share those names. The type is part of
        // the contract, not just the text.
        await expectLater(
          store.initialize(tmp.path),
          throwsA(
            allOf(
              isA<VectorStoreException>(),
              isNot(isA<QdrantLegacyStoreException>()),
            ),
          ),
        );
        await expectLater(
          store.clear(),
          throwsA(
            allOf(
              isA<VectorStoreException>(),
              isNot(isA<QdrantLegacyStoreException>()),
              isA<VectorStoreException>().having(
                (e) => e.message,
                'message',
                isNot(contains('remove "edge_config.json"')),
              ),
            ),
          ),
          reason: "clear() told the caller to delete files that may be theirs",
        );
        expect(File('${tmp.path}/wal/caller.txt').existsSync(), isTrue);
        expect(File('${tmp.path}/segments/caller.txt').existsSync(), isTrue);

        // And — the half that survived the destructive path being removed —
        // the message must not tell the CALLER to delete them either. Naming
        // files to remove is an instruction that destroys data just as well as
        // a deleteSync does, and we cannot tell whose files these are.
        try {
          await store.initialize(tmp.path);
          fail('initialize() accepted a directory it does not own');
        } on VectorStoreException catch (e) {
          expect(e.message, contains('did not write'));
        }
      },
    );

    test('a marker with no payload beside it is not a store', () async {
      // What a sweep leaves when it removes `wal/` and `segments/` and then
      // cannot unlink the marker. Treating that as a store made initialize()
      // refuse forever over nothing and clear() fail forever on the one file
      // it had already failed to remove — a loop whose only exit was the call
      // that was looping.
      File('${tmp.path}/edge_config.json').writeAsStringSync('{}');
      final store = QdrantVectorStore();
      addTearDown(store.close);
      await store.initialize(tmp.path);
      await store.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));
      expect((await store.getStats()).documentCount, 1);
    });
  });

  group('the latch must lift as well as fall', () {
    test('a latch clears once the shard can actually be opened', () async {
      // Deleted by mistake with the destructive-clear cleanup: its subject —
      // a store that failed to adopt, then succeeds after the cause is gone —
      // has nothing to do with deleting directories. A sticky latch is a WORSE
      // failure than the silent zero it replaced: every read refusing forever
      // on a store that is now perfectly healthy.
      //
      // It pins an OUTCOME, not one line: two sites clear the latch — the
      // reset at the top of initialize() and the adoption-success path — and
      // removing either alone leaves this green. Removing BOTH kills it.
      final holder = QdrantVectorStore();
      await holder.initialize(tmp.path);
      await holder.addDocument(id: 'a', content: 'x', embedding: vec(4, 1));

      final second = QdrantVectorStore();
      addTearDown(second.close);
      await expectLater(
        second.initialize(tmp.path), // WAL held by holder
        throwsA(isA<VectorStoreException>()),
      );
      await expectLater(
        second.getStats(),
        throwsA(isA<VectorStoreException>()),
      );

      await holder.close(); // the cause goes away
      await second.initialize(tmp.path); // the message says to do this

      expect(second.isInitialized, isTrue);
      expect(
        (await second.getStats()).documentCount,
        1,
        reason: 'the latch outlived the condition that set it',
      );
    });
  });

  group('uninitialized store', () {
    test(
      'reads throw StateError, as VectorStoreRepository documents',
      () async {
        // The interface documents `StateError` for all three, and the sibling
        // sqlite store throws it. This one returned empty results and dropped
        // removeDocument to a debug-only log line — so the same caller mistake
        // was loud in one implementation and invisible in the other.
        final store = QdrantVectorStore();
        await expectLater(store.getStats(), throwsStateError);
        await expectLater(
          store.searchSimilar(queryEmbedding: vec(4, 1), topK: 5),
          throwsStateError,
        );
        await expectLater(store.removeDocument(id: 'x'), throwsStateError);
      },
    );
  });

  group('reserved payload keys', () {
    test('configure() rejects a filter field that would overwrite one', () {
      // Declared fields are promoted to TOP-LEVEL payload keys — the same map
      // that carries the id, content and metadata. Before: a String collision
      // silently swapped the id/body of every hit; a non-String one escaped
      // searchSimilar as a raw _TypeError.
      final store = QdrantVectorStore();
      for (final reserved in const [
        '__flutter_gemma_id',
        '__flutter_gemma_content',
        '__flutter_gemma_metadata',
      ]) {
        expect(
          () => store.configure(
            FilterSchema(
              fields: [
                FilterField(name: reserved, type: FilterFieldType.string),
              ],
            ),
          ),
          throwsArgumentError,
          reason: '$reserved must not be accepted as a filter field',
        );
      }
    });

    test(
      'the stored key names are pinned — they ARE the on-disk format',
      () async {
        // Renaming any of these silently orphans every shard written by an
        // earlier build: searchSimilar falls back to `?? hit.id` / `?? ''`, so
        // hits come back with a UUID for an id and empty content, with no error.
        // The sibling constant (the UUIDv5 namespace) already has a golden test;
        // this is the same instinct applied to the keys next to it.
        final store = QdrantVectorStore();
        await store.initialize(tmp.path);
        await store.addDocument(
          id: 'doc-1',
          content: 'the body',
          embedding: vec(4, 1),
          metadata: jsonEncode({'k': 'v'}),
        );
        await store.close();

        // Read the payload back through a raw client, bypassing the store's own
        // constants — otherwise a rename is invisible, because writes and reads
        // would both use the renamed key.
        final client = await QdrantEdgeClient.open(
          path: '${tmp.path}/qdrant_edge_v1',
          dim: 4,
        );
        final hits = await client.search(queryVector: vec(4, 1), topK: 1);
        expect(hits, hasLength(1));
        final payload = hits.single.payload!;
        expect(payload['__flutter_gemma_id'], 'doc-1');
        expect(payload['__flutter_gemma_content'], 'the body');
        expect(jsonDecode(payload['__flutter_gemma_metadata'] as String), {
          'k': 'v',
        });
        // The point id is the UUIDv5 of the caller's id, not the id itself.
        expect(hits.single.id, PointIdHasher.hash('doc-1'));
        await client.close();
      },
    );
  });

  group('flush', () {
    // #492: the package never called EdgeShard.flush(), so points added through
    // addDocument stayed in the shard's in-RAM segment. A corpus indexed in one
    // session was gone in the next and had to be embedded again — and the
    // reporter's Android trace named the missing piece exactly:
    // "Failed to load ID tracker mappings".
    //
    // Two of these pin the fix, from opposite ends. `close()` persists too, so
    // a written-then-closed store cannot tell a working flush from a missing
    // one — which rules out the obvious test. Instead:
    //   * the id-tracker files, named by the reporter's own trace, are checked
    //     directly (white-box, tied to this engine's on-disk layout);
    //   * a copy of the shard taken mid-session is reopened (black-box, tied
    //     only to the contract — it reproduces #492 inside one process).
    // The second is the one that survives an engine that renames its files.
    Future<void> write(QdrantVectorStore store, int n) async {
      for (var i = 0; i < n; i++) {
        await store.addDocument(
          id: 'doc$i',
          content: 'content $i',
          embedding: vec(4, i + 1.0),
        );
      }
    }

    List<String> idTrackerFiles(Directory root) {
      final segments = Directory('${root.path}/$storeDirName/segments');
      if (!segments.existsSync()) return const [];
      return segments
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((name) => name.startsWith('mutable_id_tracker.'))
          .toList()
        ..sort();
    }

    test('writes the id tracker the next open needs', () async {
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      await write(store, 20);

      // `idTrackerFiles` answers `const []` for a missing directory, so assert
      // the directory is THERE first — otherwise the isEmpty below would pass
      // on a store that never wrote anything at all, which is the opposite of
      // what this test is for.
      expect(
        Directory('${tmp.path}/$storeDirName/segments').existsSync(),
        isTrue,
        reason: 'the segment directory should exist before the flush',
      );

      // Not a weaker "the directory grew": the segment directory is populated
      // well before this — vector storage, payload storage and segment.json are
      // all already on disk. These two files are the ones that are not.
      expect(
        idTrackerFiles(tmp),
        isEmpty,
        reason: 'unflushed points should not have reached the id tracker yet',
      );

      await store.flush();

      expect(idTrackerFiles(tmp), [
        'mutable_id_tracker.mappings',
        'mutable_id_tracker.versions',
      ]);
      await store.close();
    });

    test('a shard copied mid-session is readable only after a flush', () async {
      // The black-box half, and the one that reproduces #492 inside a single
      // process. A copy of the directory taken BEFORE the flush is what a
      // process killed mid-session leaves on disk — and it reopens EMPTY, with
      // no error, which is exactly what the reporter saw. Taken after, the same
      // copy carries every document.
      //
      // This asserts the contract's outcome rather than this engine's file
      // names, so it survives a qdrant release that reorganises its segments.
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      await write(store, 20);

      Future<Directory> snapshot(String suffix) async {
        final dir = Directory('${tmp.path}_$suffix')..createSync();
        addTearDown(() {
          try {
            dir.deleteSync(recursive: true);
          } catch (_) {}
        });
        final result = await Process.run('cp', [
          '-R',
          '${tmp.path}/$storeDirName',
          '${dir.path}/$storeDirName',
        ]);
        expect(result.exitCode, 0, reason: 'cp failed: ${result.stderr}');
        return dir;
      }

      final beforeFlush = await snapshot('before');
      await store.flush();
      final afterFlush = await snapshot('after');
      await store.close();

      final unflushed = QdrantVectorStore();
      await unflushed.initialize(beforeFlush.path);
      expect(
        (await unflushed.getStats()).documentCount,
        0,
        reason: 'this is #492: an unflushed shard reopens empty, and quietly',
      );
      await unflushed.close();

      final flushed = QdrantVectorStore();
      await flushed.initialize(afterFlush.path);
      expect((await flushed.getStats()).documentCount, 20);
      await flushed.close();
    }, skip: Platform.isWindows ? 'shells out to cp' : null);

    test('leaves the store usable — it is not a close', () async {
      // Scope, stated because it is easy to over-read: this pins that the
      // SAME instance keeps serving after a flush, and nothing more. The
      // reopen at the end is a sanity check, NOT evidence that flush
      // persisted anything — `close()` persists too, so this test still
      // passes with the flush call deleted. The id-tracker test above is the
      // one that pins persistence, and it is the one mutation-checked.
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      await write(store, 5);
      await store.flush();

      expect((await store.getStats()).documentCount, 5);
      await store.addDocument(id: 'after', content: 'a', embedding: vec(4, 9));
      expect((await store.getStats()).documentCount, 6);
      await store.close();

      final reopened = QdrantVectorStore();
      await reopened.initialize(tmp.path);
      expect((await reopened.getStats()).documentCount, 6);
      await reopened.close();
    });

    test('is quiet on a store that was never initialized', () async {
      // Callers flush from lifecycle callbacks they cannot make conditional, so
      // "nothing to persist" must not be an exception they have to catch.
      await expectLater(QdrantVectorStore().flush(), completes);
    });

    test(
      'a failure surfaces as VectorStoreException, not QdrantException',
      () async {
        // The type matters as much as the throw. `QdrantException` is not a
        // `VectorStoreException` and is not exported from this package's barrel,
        // so a caller writing the catch the contract asks for — `on
        // VectorStoreException` — would miss every flush failure if the raw type
        // leaked. Every other method here translates; this one has to as well.
        final store = QdrantVectorStore();
        await store.initialize(tmp.path);
        await write(store, 5);

        // Pull the shard directory out from under the open store. The engine
        // then fails writing `mutable_id_tracker.mappings` — the same file the
        // #492 report could not read on its device.
        Directory('${tmp.path}/$storeDirName').deleteSync(recursive: true);

        await expectLater(store.flush(), throwsA(isA<VectorStoreException>()));
        try {
          await store.close();
        } catch (_) {}
      },
      skip: Platform.isWindows ? 'deleteSync fails on the mmapped shard' : null,
    );

    test('is quiet after close, and when called twice', () async {
      final store = QdrantVectorStore();
      await store.initialize(tmp.path);
      await write(store, 3);
      await expectLater(store.flush(), completes);
      await expectLater(store.flush(), completes);
      await store.close();
      await expectLater(store.flush(), completes);
    });
  });
}

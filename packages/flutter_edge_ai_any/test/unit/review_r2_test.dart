// The fixes of implementation review round 2 (FIXES-r2.md D-R1..D-R13) on
// the fake. D-R1 is in review_fixes_test.dart (D3 group), D-R3 in
// scenarios.dart with a mutation check.
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/jobs.dart';
import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

bool hasPageApply(Map<String, Object?> ops) =>
    (ops['ops'] as List).any((o) => (o as Map)['key'] == 'lastPull');

Future<(AnySyncAccount, AnySyncLocation, RagIndex)> solo(
  World w, {
  Uint8List? key,
}) async {
  final a = await w.open('a', localEncryptionKey: key);
  final s = await a.createSpace('s');
  final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
  return (a, loc, await openVectors(a, loc));
}

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  test('D-R2 a rebuild whose replay cannot read a winner restarts, and '
      'never swaps with keys missing', () async {
    final (a, loc, i) = await solo(w);
    final space = w.device('a').space(loc.spaceId);
    final h = leafKeyOf(profile4);
    final old = craftDoc(
      space,
      indexName: 'n',
      key: 'k',
      rev: 10,
      content: 'old',
      vecs: {
        h: leafValue([1, 0, 0, 0], 'old'),
      },
    );
    final fresh = craftDoc(
      space,
      indexName: 'n',
      key: 'k',
      rev: 20,
      content: 'new',
      vecs: {
        h: leafValue([1, 0, 0, 0], 'new'),
      },
    );
    await a.pull(loc);
    space.rebuildSdkDb();
    var once = false;
    space.onTypePage = (after) {
      if (once) return;
      once = true;
      // After page 1: the winner goes, and the older one cannot be read by
      // id this round.
      fresh.deleted = true;
      space.change(fresh.id, deleted: true);
      space.hiddenFromIdReads.add(old.id);
    };
    // Attempt 1's replay cannot read the fallback winner: it restarts;
    // attempt 2 pages the older object in and swaps a complete index.
    final r = await a.pull(loc);
    expect(r.rebuilt, isTrue);
    final hits = await i.searchVector(embedding: [1, 0, 0, 0], topK: 1);
    expect(hits.single.content, 'old');
  });

  group('D-R4 index errors by their native call', () {
    test('another key: keyMismatch; no key: keyMissing, retryable', () async {
      final k1 = Uint8List(32)..[0] = 1;
      final (a, loc, i) = await solo(w, key: k1);
      await i.dispose();
      await a.close();
      final a2 = await w.open('a', localEncryptionKey: Uint8List(32)..[0] = 2);
      await expectLater(
        openVectors(a2, loc),
        throwsA(
          isA<AnySyncLocalIndexException>()
              .having(
                (e) => e.kind,
                'kind',
                AnySyncLocalIndexErrorKind.keyMismatch,
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
      await a2.close();
      final a3 = await w.open('a');
      await expectLater(
        openVectors(a3, loc),
        throwsA(
          isA<AnySyncLocalIndexException>()
              .having(
                (e) => e.kind,
                'kind',
                AnySyncLocalIndexErrorKind.keyMissing,
              )
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test(
      'CORRUPT during a pull (through the SDK job) is a local index error',
      () async {
        final (a, loc, i) = await solo(w);
        FakeIndex.failApply = hasPageApply;
        FakeIndex.failApplyStatus = AnyShimStatus.corrupt;
        await expectLater(
          a.pull(loc),
          throwsA(
            isA<AnySyncLocalIndexException>().having(
              (e) => e.kind,
              'kind',
              AnySyncLocalIndexErrorKind.corrupt,
            ),
          ),
        );
        FakeIndex.failApply = null;
        await i.dispose();
      },
    );
  });

  group('D-R5 gc', () {
    test('after a swap the orphan is collected', () async {
      final (a, loc, i) = await solo(w);
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      w.device('a').space(loc.spaceId).rebuildSdkDb();
      expect((await a.pull(loc)).rebuilt, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final st = await a.locationStatus(loc);
      expect(st.orphanGenerations, 0);
      expect(st.lastGcError, isNull);
      expect(w.net.files.values.single.orphans, 0);
    });

    test('a failing gc is reported in locationStatus', () async {
      FakeIndex.gcError = AnyShimException(
        'any_shim_index_gc',
        AnyShimStatus.io.code,
        'disk',
      );
      final (a, loc, i) = await solo(w);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final st = await a.locationStatus(loc);
      expect(st.lastGcError, contains('disk'));
      expect(st.orphanGenerations, greaterThan(0));
    });
  });

  test(
    'D-R6 the events poller is restarted, reported once, watches kept',
    () async {
      final p = await pair(w);
      final rt = w.runtimeOf('b');
      final events = <AnySyncFollowerEvent>[];
      final sub = p.b.followerEvents().listen(events.add);
      addTearDown(sub.cancel);
      final started = rt.pollersStarted;
      rt.failEvents('poll failed');
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(rt.pollersStarted, started + 1);
      expect(events.where((e) => !e.recovered), hasLength(1));
      // The new poller still gets B's changes: the watch was not lost.
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      w.net.sync(p.da, p.db);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(await idsOf(p.ib, [1, 0, 0, 0]), ['x']);
    },
  );

  test(
    'D-R7 a failed watch is a follower error and retried on a timer',
    () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final events = <AnySyncFollowerEvent>[];
      final sub = a.followerEvents().listen(events.add);
      addTearDown(sub.cancel);
      w.runtimeOf('a').sdkImpl.failWatches = 1;
      final i = await openVectors(a, loc);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events.map((e) => e.error ?? '').join(' '), contains('watch'));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(w.device('a').watched, contains(s.id));
      await i.dispose();
    },
  );

  test('D-R8 every reopen publishes what the manifest lacks', () async {
    final (a, loc, i) = await solo(w);
    await i.dispose();
    final manifest = w
        .device('a')
        .space(loc.spaceId)
        .objects
        .values
        .firstWhere((o) => o.typeId == locRoot);
    manifest.leaves['profiles']!.clear();
    final again = await openVectors(a, loc);
    expect(manifest.leaves['profiles']!.keys, hasLength(1));
    await again.dispose();
  });

  test('D-R9 an account the open op returns after its deadline is closed '
      'again', () async {
    final rt = await w.net.native().start() as FakeRuntime;
    rt.sdkImpl.openReadyOnLastPoll = true;
    await expectLater(
      rt.sdk(
        openAccountJob({
          'dataDir': '/late',
          'ownerToken': 't',
          'mnemonic': 'm',
        }, max: const Duration(milliseconds: 50)),
      ),
      throwsA(
        isA<AnyShimException>().having(
          (e) => e.status,
          'status',
          AnyShimStatus.timeout,
        ),
      ),
    );
    expect(w.net.devices['/late']!.isOpen, isFalse);
  });

  group('D-R11 follower bookkeeping', () {
    test('a successful manual pull clears the error', () async {
      final (a, loc, i) = await solo(w);
      FakeIndex.failApply = hasPageApply;
      await expectLater(a.pull(loc), throwsA(isA<AnySyncException>()));
      w.device('a').space(loc.spaceId).change('nothing');
      await i
          .addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X')
          .catchError((_) {});
      // Background failure recorded by the catch-up of an event.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      FakeIndex.failApply = null;
      await a.pull(loc);
      expect((await a.locationStatus(loc)).lastFollowerError, isNull);
    });

    test('events wait for the backoff after a failure', () async {
      final p = await pair(w);
      FakeIndex.failApply = hasPageApply;
      await p.ia
          .addVector(id: 'w', embedding: [0, 1, 0, 0], content: 'W')
          .catchError((_) {});
      w.net.sync(p.da, p.db);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect((await p.b.locationStatus(p.loc)).lastFollowerError, isNotNull);
      FakeIndex.failApply = null;
      // A change event now does not pull before the 1 s retry.
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      w.net.sync(p.da, p.db);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await p.b.locationStatus(p.loc)).lastFollowerError, isNotNull);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect((await p.b.locationStatus(p.loc)).lastFollowerError, isNull);
    });
  });

  group('D-R12 smaller', () {
    test('createSpace carries stateSaveError', () async {
      final a = await w.open('a');
      w.device('a').stateSaveError = 'disk full';
      expect((await a.createSpace('s')).stateSaveError, 'disk full');
    });

    test('failed supersede deletes are counted', () async {
      final (a, loc, i) = await solo(w);
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v1');
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v2');
      w.runtimeOf('a').sdkImpl.failSyncState = true;
      await a.pull(loc);
      expect((await a.locationStatus(loc)).supersedeErrors, 1);
    });

    test('dropped filter values are summed, the clear record\'s bad revs '
        'counted', () async {
      final schema = FilterSchema(
        fields: [
          FilterField(name: 'a', type: FilterFieldType.number),
          FilterField(name: 'b', type: FilterFieldType.bool),
        ],
      );
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final i = await openVectors(a, loc, schema: schema);
      await i.addVector(
        id: 'x',
        embedding: [1, 0, 0, 0],
        content: 'X',
        metadata: '{"a":"no","b":"no"}',
      );
      final space = w.device('a').space(s.id);
      final m = space.objects.values.firstWhere((o) => o.typeId == locRoot);
      space.records.putIfAbsent((
        m.id,
        tombColl,
      ), () => {})['clear'] = FakeRecord('clear')
        ..revs.add(-3)
        ..applySeq = space.seq + 1;
      space.change(m.id);
      await a.pull(loc);
      final st = await a.locationStatus(loc);
      expect(st.droppedFilterValues, 2);
      expect(st.ignoredTombstones, 1);
    });
  });

  group('D-R13 native changes', () {
    test('index calls answering PENDING during a bind are retried', () async {
      var calls = 0;
      final host = FakeIndexHost(FakeNetwork());
      final r = await runIndexJob<int>((h) {
        if (++calls < 3) {
          throw AnyShimException(
            'any_shim_index_count',
            AnyShimStatus.pending.code,
            'index busy',
          );
        }
        return 7;
      }, host);
      expect(r, 7);
      expect(calls, 3);
    });

    test('a bind holds the index; a concurrent search waits for it', () async {
      final (a, loc, i) = await solo(w);
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      await i.dispose();
      FakeIndexHost.bindSlices = 3;
      final again = await openVectors(
        a,
        loc,
        schema: FilterSchema(
          fields: [FilterField(name: 'lang', type: FilterFieldType.string)],
        ),
      );
      expect(await idsOf(again, [1, 0, 0, 0]), ['x']);
      await again.dispose();
    });

    test('a directory whose previous close failed: previousInstanceFailed, '
        'not retryable', () async {
      final a = await w.open('a');
      await a.close();
      w.device('a').poisoned = true;
      await expectLater(
        w.open('a'),
        throwsA(
          isA<AnySyncBusyException>()
              .having(
                (e) => e.reason,
                'reason',
                AnySyncBusyReason.previousInstanceFailed,
              )
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
    });
  });
}

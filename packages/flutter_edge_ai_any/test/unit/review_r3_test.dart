// The fixes of implementation review round 3 (FIXES-r3.md D3-1..D3-9) on
// the fake.
import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/jobs.dart';
import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

bool hasPageApply(Map<String, Object?> ops) =>
    (ops['ops'] as List).any((o) => (o as Map)['key'] == 'lastPull');

Future<(AnySyncAccount, AnySyncLocation, RagIndex)> solo(World w) async {
  final a = await w.open('a');
  final s = await a.createSpace('s');
  final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
  return (a, loc, await openVectors(a, loc));
}

Future<void> until(bool Function() f, {int ms = 8000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!f()) {
    if (DateTime.now().isAfter(end)) fail('timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  group('D3-1 events', () {
    test('the poller never gives up; eventsDown stays through a pull and '
        'clears when events flow again', () async {
      debugEventsBackoffBase = const Duration(milliseconds: 1);
      final p = await pair(w);
      final rt = w.runtimeOf('b');
      // Pollers that never poll successfully: only a delivered event says
      // events flow again.
      rt.pollerReady = false;
      final events = <AnySyncFollowerEvent>[];
      final sub = p.b.followerEvents().listen(events.add);
      addTearDown(sub.cancel);
      for (var n = 0; n < 12; n++) {
        final started = rt.pollersStarted;
        rt.failEvents('poll failed $n');
        await until(() => rt.pollersStarted > started);
      }
      var st = await p.b.locationStatus(p.loc);
      expect(st.eventsDownSince, isNotNull);
      expect(st.eventsDownError, contains('poll failed 11'));
      expect(
        events.where((e) => e.location == null && !e.recovered),
        isNotEmpty,
      );
      await p.b.pull(p.loc);
      st = await p.b.locationStatus(p.loc);
      expect(st.eventsDownSince, isNotNull, reason: 'a pull does not clear');
      // The restarted poller delivers: up again.
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      w.net.sync(p.da, p.db);
      await until(
        () =>
            events.isNotEmpty &&
            events.last.location == null &&
            events.last.recovered,
      );
      expect((await p.b.locationStatus(p.loc)).eventsDownSince, isNull);
    });

    test(
      'suspend and resume inside the restart window start one new poller',
      () async {
        debugEventsBackoffBase = const Duration(milliseconds: 500);
        final p = await pair(w);
        final rt = w.runtimeOf('b');
        rt.failEvents('poll failed');
        await p.b.suspend();
        final started = rt.pollersStarted;
        await p.b.resume();
        expect(rt.pollersStarted, started + 1);
        await Future<void>.delayed(const Duration(milliseconds: 700));
        expect(rt.pollersStarted, started + 1, reason: 'the old timer is gone');
      },
    );
  });

  test('a restarted poller that polls successfully clears eventsDown, '
      'without any event', () async {
    debugEventsBackoffBase = const Duration(milliseconds: 1);
    final p = await pair(w);
    final rt = w.runtimeOf('b');
    final events = <AnySyncFollowerEvent>[];
    final sub = p.b.followerEvents().listen(events.add);
    addTearDown(sub.cancel);
    final started = rt.pollersStarted;
    rt.failEvents('poll failed');
    await until(() => rt.pollersStarted > started);
    await until(
      () =>
          events.isNotEmpty &&
          events.last.location == null &&
          events.last.recovered,
    );
    expect(
      events.where((e) => e.location == null && !e.recovered),
      hasLength(1),
    );
    expect((await p.b.locationStatus(p.loc)).eventsDownSince, isNull);
  });

  test('a failed conflict count never replaces the conflict', () async {
    final p = await pair(w);
    final manifest = p.sa.objects.values.firstWhere((o) => o.typeId == locRoot);
    manifest.leaves['core']!['image'] = FakeVal({'fmt': 1});
    p.sa.change(manifest.id);
    await p.a.pull(p.loc);
    FakeIndex.failScanPrefix = 'u/';
    await expectLater(
      p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
      throwsA(
        isA<AnySyncConflictException>().having(
          (e) => e.conflictingDocuments,
          'conflictingDocuments',
          0,
        ),
      ),
    );
  });

  group('D3-2 close errors are surfaced', () {
    test('account close and suspend throw after their cleanup', () async {
      final a = await w.open('a');
      w.runtimeOf('a').sdkImpl.failClose = true;
      await expectLater(
        a.suspend(),
        throwsA(
          isA<AnySyncException>().having(
            (e) => e.message,
            'message',
            contains('sdk close'),
          ),
        ),
      );
      await expectLater(
        a.createSpace('x'),
        throwsA(isA<AnySyncSuspendedException>()),
      );
      await a.resume();
      await expectLater(a.close(), throwsA(isA<AnySyncException>()));
      // Released anyway: the directory opens again.
      final again = await w.open('a');
      await again.close();
    });

    test('a store close reports a failed index close', () async {
      final (a, loc, i) = await solo(w);
      FakeIndex.failClose = true;
      await expectLater(i.dispose(), throwsA(isA<AnySyncException>()));
      FakeIndex.failClose = false;
      // The location opens again.
      await (await openVectors(a, loc)).dispose();
    });
  });

  group('D3-3 index busy', () {
    test(
      'a read waits a bounded time, then indexBusy with the message',
      () async {
        final (a, loc, i) = await solo(w);
        readPendingMax = const Duration(milliseconds: 300);
        final file = w.net.files.values.single;
        file.binding = 1 << 30;
        await expectLater(
          i.searchVector(embedding: [1, 0, 0, 0]),
          throwsA(
            isA<AnySyncNotReadyException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  AnySyncNotReadyReason.indexBusy,
                )
                .having((e) => e.spaceId, 'spaceId', loc.spaceId)
                .having((e) => e.message, 'message', contains('index busy')),
          ),
        );
        file.binding = 0;
        expect(await idsOf(i, [1, 0, 0, 0]), isEmpty);
      },
    );

    test('an SDK PENDING is loading only when it says so', () async {
      final (a, loc, i) = await solo(w);
      final sdk = w.runtimeOf('a').sdkImpl;
      sdk.failPatch = (t, ops) => t['create'] != null;
      sdk.failPatchStatus = AnyShimStatus.pending;
      sdk.failPatchMessage = 'space is loading';
      await expectLater(
        i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
        throwsA(
          isA<AnySyncNotReadyException>().having(
            (e) => e.reason,
            'reason',
            AnySyncNotReadyReason.loading,
          ),
        ),
      );
      sdk.failPatchMessage = 'something else';
      await expectLater(
        i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y'),
        throwsA(
          isA<AnySyncException>()
              .having((e) => e, 'type', isNot(isA<AnySyncNotReadyException>()))
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });
  });

  test(
    'D3-4 a page refused as a whole stalls; its vectors are not stripped',
    () async {
      final p = await pair(w);
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      FakeIndex.failApply = hasPageApply;
      FakeIndex.failApplyStatus = AnyShimStatus.invalidArgument;
      w.net.sync(p.da, p.db);
      await expectLater(p.b.pull(p.loc), throwsA(isA<AnySyncException>()));
      FakeIndex.failApply = null;
      await p.b.pull(p.loc);
      final st = await p.b.locationStatus(p.loc);
      expect(st.vectors, 1);
      expect(st.unindexable[AnySyncUnindexableReason.rejectedByIndex], isNull);
    },
  );

  test(
    'D3-5 a rebuild that keeps missing a winner names it when it gives up',
    () async {
      final (a, loc, i) = await solo(w);
      final space = w.device('a').space(loc.spaceId);
      final h = leafKeyOf(profile4);
      final x = craftDoc(
        space,
        indexName: 'n',
        key: 'k',
        rev: 10,
        content: 'x',
        vecs: {
          h: leafValue([1, 0, 0, 0], 'x'),
        },
      );
      var y = craftDoc(
        space,
        indexName: 'n',
        key: 'k',
        rev: 20,
        content: 'y',
        vecs: {
          h: leafValue([1, 0, 0, 0], 'y'),
        },
      );
      await a.pull(loc);
      space.hiddenFromIdReads.add(x.id);
      space.rebuildSdkDb();
      var rev = 30;
      space.onTypePage = (_) {
        // After each attempt's page: the winner it saw goes, and its
        // successor cannot be read by id either; x stays the winner the
        // replay needs and cannot read.
        y.deleted = true;
        space.change(y.id, deleted: true);
        y = craftDoc(space, indexName: 'n', key: 'k', rev: rev++, content: 'z');
        space.hiddenFromIdReads.add(y.id);
      };
      await expectLater(
        a.pull(loc),
        throwsA(
          isA<AnySyncException>().having(
            (e) => e.message,
            'message',
            allOf(contains('cannot be read'), contains(x.id)),
          ),
        ),
      );
    },
  );

  test(
    'D3-6 a failed sync status watch is the account\'s events being down',
    () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final i = await openVectors(a, loc);
      final sdk = w.runtimeOf('a').sdkImpl;
      final events = <AnySyncFollowerEvent>[];
      final sub = a.followerEvents().listen(events.add);
      addTearDown(sub.cancel);
      sdk.failStatusWatches = 2;
      await a.suspend();
      await a.resume();
      // Two failures (the account's events down), then the watch
      // registers and they are up again.
      await until(
        () =>
            events.any((e) => (e.error ?? '').contains('sync status')) &&
            events.last.recovered,
      );
      expect((await a.locationStatus(loc)).eventsDownSince, isNull);
      await i.dispose();
    },
  );

  group('D3-7 NOT_FOUND', () {
    test(
      '"has not synced" and an unknown space are readiness, with cause',
      () async {
        final (a, loc, i) = await solo(w);
        final sdk = w.runtimeOf('a').sdkImpl;
        sdk.failPatch = (t, ops) => t['create'] != null;
        sdk.failPatchStatus = AnyShimStatus.notFound;
        sdk.failPatchMessage = 'bundle x: property "doc" has not synced here';
        await expectLater(
          i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
          throwsA(
            isA<AnySyncNotReadyException>()
                .having(
                  (e) => e.reason,
                  'reason',
                  AnySyncNotReadyReason.definitionsNotSynced,
                )
                .having((e) => e.cause, 'cause', isA<AnyShimException>()),
          ),
        );
        sdk.failPatchMessage = 'space s is not known to this account';
        await expectLater(
          i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y'),
          throwsA(
            isA<AnySyncNotReadyException>().having(
              (e) => e.reason,
              'reason',
              AnySyncNotReadyReason.unknownSpace,
            ),
          ),
        );
      },
    );
  });

  group('D3-8', () {
    test('a change watch that comes back catches the follower up', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      w.runtimeOf('a').sdkImpl.failWatches = 1;
      final i = await openVectors(a, loc);
      // A peer's document arrives while nothing watches the space.
      craftDoc(
        w.device('a').space(s.id),
        indexName: 'n',
        key: 'peer',
        rev: 5,
        content: 'p',
        vecs: {
          leafKeyOf(profile4): leafValue([1, 0, 0, 0], 'p'),
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 1600));
      expect(await idsOf(i, [1, 0, 0, 0]), ['peer']);
      await i.dispose();
    });

    test('text search stays published on a reopen without the flag', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      await (await openVectors(a, loc, text: true)).dispose();
      final m = w
          .device('a')
          .space(s.id)
          .objects
          .values
          .firstWhere((o) => o.typeId == locRoot);
      m.leaves['textSearch']!.clear();
      await (await openVectors(a, loc)).dispose();
      expect(m.leaves['textSearch']!['on']!.value, true);
    });
  });

  group('D3-9', () {
    test('gc goes on past a failing step', () async {
      FakeIndex.gcError = AnyShimException(
        'any_shim_index_gc',
        AnyShimStatus.io.code,
        'orphan',
      );
      final (a, loc, i) = await solo(w);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect((await a.locationStatus(loc)).lastGcError, contains('orphan'));
      FakeIndex.gcError = null;
      await until(() => w.net.files.values.single.orphans == 0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final st = await a.locationStatus(loc);
      expect(st.lastGcError, isNull);
      expect(st.orphanGenerations, 0);
    });

    test('supersede errors count failing objects, not attempts', () async {
      final (a, loc, i) = await solo(w);
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v1');
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v2');
      w.runtimeOf('a').sdkImpl.failSyncState = true;
      await a.pull(loc);
      await a.pull(loc);
      final st = await a.locationStatus(loc);
      expect(st.supersedeErrors, 1);
      expect(st.lastSupersedeError, isNotNull);
    });

    test('an open after its deadline says it was closed again', () async {
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
            (e) => e.message,
            'message',
            contains('closed again'),
          ),
        ),
      );
    });
  });
}

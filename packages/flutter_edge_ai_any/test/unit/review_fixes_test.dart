// The fixes of implementation review round 1 (FIXES.md D1-D18, B1), one
// test or more each, on the fake. D1's rule is also in scenarios.dart with
// a mutation check; D10 is in lifecycle_test.dart (compact).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/formats.dart';
import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

final other = EmbeddingProfile(id: 'other-v1', dimension: 4);

bool hasPageApply(Map<String, Object?> ops) =>
    (ops['ops'] as List).any((o) => (o as Map)['key'] == 'lastPull');

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  group('D2 follower errors are visible and retried', () {
    test('a failing open catch-up is recorded, not thrown', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      FakeIndex.failApply = hasPageApply;
      final i = await openVectors(a, loc);
      final st = await a.locationStatus(loc);
      expect(st.lastFollowerError, contains('injected'));
      expect(st.lastFollowerErrorAt, isNotNull);
      FakeIndex.failApply = null;
      await i.dispose();
    });

    test(
      'a background failure reaches followerEvents; the retry clears it',
      () async {
        final p = await pair(w);
        final events = <AnySyncFollowerEvent>[];
        final sub = p.b.followerEvents().listen(events.add);
        addTearDown(sub.cancel);
        FakeIndex.failApply = hasPageApply;
        await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
        w.net.sync(p.da, p.db); // a change event wakes B's follower
        await Future<void>.delayed(const Duration(milliseconds: 600));
        final failed = events.where((e) => !e.recovered);
        expect(failed, isNotEmpty);
        expect(failed.first.location, p.loc);
        expect((await p.b.locationStatus(p.loc)).lastFollowerError, isNotNull);
        FakeIndex.failApply = null;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect((await p.b.locationStatus(p.loc)).lastFollowerError, isNull);
        expect(events.last.recovered, isTrue);
        expect(events.last.error, isNull);
        expect(await idsOf(p.ib, [1, 0, 0, 0]), ['x']);
      },
    );
  });

  group('D3 vector norms', () {
    test('an own vector whose squared norm overflows is refused', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      await expectLater(
        i.addVector(id: 'x', embedding: [1e19, 1e19, 1e19, 1e19], content: 'x'),
        throwsArgumentError,
      );
      expect(
        vectorProblem(Float32List.fromList([1e19, 0, 0, 0])),
        'norm too large',
      );
    });

    test(
      'a peer leaf with an overflowing norm is a text-only badVector',
      () async {
        final p = await pair(w);
        final big = Float32List.fromList([1e19, 1e19, 1e19, 1e19]);
        craftDoc(
          p.sa,
          indexName: p.loc.indexName,
          key: 'big',
          rev: 9,
          content: 'B',
          vecs: {leafKeyOf(profile4): LeafValue.encode(big, sha256Hex('B'))},
        );
        await p.a.pull(p.loc);
        final st = await p.a.locationStatus(p.loc);
        expect(st.unindexable[AnySyncUnindexableReason.badVector], 1);
        expect(st.textOnly, 1);
      },
    );

    test('D-R1: in a page of 10, only the object whose vector the index '
        'refuses loses it', () async {
      final p = await pair(w);
      for (var i = 0; i < 10; i++) {
        await p.ia.addVector(
          id: 'k$i',
          embedding: [1, i.toDouble(), 0, i == 4 ? 7 : 0],
          content: 'c$i',
        );
      }
      FakeIndex.refuseVector = (v) => v[3] == 7;
      await p.sync();
      FakeIndex.refuseVector = null;
      final st = await p.b.locationStatus(p.loc);
      expect(st.documents, 10);
      expect(st.vectors, 9);
      expect(st.unindexable[AnySyncUnindexableReason.rejectedByIndex], 1);
      expect(st.textOnly, 0, reason: 'not offered to backfill');
      expect((await p.b.missingVectors(p.loc)).items, isEmpty);
      expect(st.lastFollowerError, contains('refused'));
    });
  });

  test('D4 resume registers the change watches again', () async {
    final p = await pair(w);
    await p.b.suspend();
    await p.b.resume();
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    w.net.sync(p.da, p.db);
    // No explicit pull: B's follower runs on the change event.
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await idsOf(p.ib, [1, 0, 0, 0]), ['x']);
  });

  group('D5 opens and closes', () {
    test('a store reopened right after dispose waits for the close', () async {
      final a = await w.open('a', previousInstanceWait: Duration.zero);
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final i = await openVectors(a, loc);
      final closing = i.dispose();
      final again = await openVectors(a, loc);
      await closing;
      await again.dispose();
    });

    test('the fake answers like the shim: REFUSED for the same owner, BUSY '
        'for another', () {
      final host = FakeIndexHost(FakeNetwork());
      host.open({'path': '/x', 'ownerToken': 't'});
      expect(
        () => host.open({'path': '/x', 'ownerToken': 't'}),
        throwsA(
          isA<AnyShimException>().having(
            (e) => e.status,
            'status',
            AnyShimStatus.refused,
          ),
        ),
      );
      expect(
        () => host.open({'path': '/x', 'ownerToken': 'u'}),
        throwsA(
          isA<AnyShimException>().having(
            (e) => e.status,
            'status',
            AnyShimStatus.busy,
          ),
        ),
      );
    });
  });

  test(
    'D6 a bind that fails after index_bind leaves the location unbound',
    () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      FakeIndex.failApply = (ops) =>
          (ops['ops'] as List).any((o) => (o as Map)['key'] == 'binding');
      await expectLater(openVectors(a, loc), throwsA(isA<AnySyncException>()));
      FakeIndex.failApply = null;
      final store = await AnyVectorStoreProvider(a).createStore(specOf(loc));
      store.configure(FilterSchema.empty);
      await store.initialize(loc.value);
      expect(await store.readBinding(), isNull);
      await store.close();
      await (await openVectors(a, loc)).dispose();
    },
  );

  group('D7 schema changes on reopen', () {
    final lang = FilterField(name: 'lang', type: FilterFieldType.string);

    test('a new field rebuilds; textSearch.on is published', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final i = await openVectors(a, loc);
      await i.addVector(
        id: 'x',
        embedding: [1, 0, 0, 0],
        content: 'X',
        metadata: '{"lang":"en"}',
      );
      await i.dispose();
      final again = await openVectors(
        a,
        loc,
        schema: FilterSchema(fields: [lang]),
        text: true,
      );
      final hits = await again.searchVector(
        embedding: [1, 0, 0, 0],
        filter: Filter(
          must: [FieldEquals(key: 'lang', value: 'en')],
        ),
      );
      expect(hits.map((h) => h.id), ['x'], reason: 'rows normalised again');
      final m = (await a.locationStatus(loc)).manifest!;
      expect(m.fields.map((f) => f.name), ['lang']);
      expect(m.textSearch, isTrue);
      expect(
        w.net.files.values.single.state.containsKey('needsRebuild'),
        isFalse,
      );
      await again.dispose();
    });

    test('a field the location has with another type is a conflict', () async {
      final p = await pair(w, schemaA: FilterSchema(fields: [lang]));
      await p.ia.dispose();
      final a2 = await openVectors(
        p.a,
        p.loc,
        schema: FilterSchema(fields: [lang]),
      );
      await a2.dispose();
      await p.ib.dispose();
      await expectLater(
        openVectors(
          p.b,
          p.loc,
          schema: FilterSchema(
            fields: [FilterField(name: 'lang', type: FilterFieldType.number)],
          ),
        ),
        throwsA(isA<AnySyncConflictException>()),
      );
    });
  });

  group('D8 the publish gate', () {
    test(
      'a creator whose account state did not save may not publish',
      () async {
        final a = await w.open('a');
        final s = await a.createSpace('s');
        w.device('a').stateSaveError = 'disk full';
        await expectLater(
          openVectors(a, AnySyncLocation(spaceId: s.id, indexName: 'n')),
          throwsA(
            isA<AnySyncNotReadyException>().having(
              (e) => e.reason,
              'reason',
              AnySyncNotReadyReason.manifestNotSynced,
            ),
          ),
        );
      },
    );

    test('a reachable peer is asked first: its manifest is used', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final b = await w.open('b');
      w.net.link(w.device('a'), w.device('b'));
      await b.spaces(sync: true);
      final ib = await openVectors(b, loc, profile: other);
      await ib.dispose();
      // A created the space and never synced it here before: without the
      // round first it would publish blindly.
      final ia = await openVectors(a, loc);
      final m = (await a.locationStatus(loc)).manifest!;
      expect(m.profiles.map((x) => x.id).toSet(), {other.id, profile4.id});
      await ia.dispose();
    });
  });

  test('D9 suspend lets space loads finish and does not cancel', () async {
    final a = await w.open('a');
    final rt = w.runtimeOf('a');
    await a.suspend();
    expect(rt.sdkImpl.lastCloseWaitLoadsMs, 25000);
    await a.resume();
    await a.close();
    expect(rt.sdkImpl.lastCloseWaitLoadsMs, 0);
  });

  test('D11 the manifest id is computed, never written', () async {
    final p = await pair(w);
    final manifests = p.sb.objects.values.where((o) => o.typeId == locRoot);
    expect(manifests, hasLength(1));
  });

  group('D12 committed leaf writes', () {
    bool upsertOf(Map<String, Object?> ops, String id) => (ops['ops'] as List)
        .any((o) => (o as Map)['op'] == 'upsert' && o['id'] == id);

    test('a leaf-only add whose local apply fails is committed', () async {
      final p = await pair(w, profileB: other);
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      await p.sync();
      FakeIndex.failApply = (ops) => upsertOf(ops, 'x');
      await expectLater(
        p.ib.addVector(id: 'x', embedding: [0, 1, 0, 0], content: 'X'),
        throwsA(
          isA<AnySyncCommittedException>().having((e) => e.rev, 'rev', isNull),
        ),
      );
      FakeIndex.failApply = null;
      await p.b.pull(p.loc);
      expect(await idsOf(p.ib, [0, 1, 0, 0]), ['x']);
    });

    test('so is writeMissingVectors', () async {
      final p = await pair(w, profileB: other);
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      await p.sync();
      final item = (await p.b.missingVectors(p.loc)).items.single;
      FakeIndex.failApply = (ops) => upsertOf(ops, 'x');
      await expectLater(
        p.b.writeMissingVectors(p.loc, [
          AnySyncVectorItem(item, Float32List.fromList([0, 1, 0, 0])),
        ]),
        throwsA(isA<AnySyncCommittedException>()),
      );
    });
  });

  test('D13 and B1: two core leaves are a conflict; its documents are '
      'counted', () async {
    final p = await pair(w);
    craftDoc(p.sa, indexName: p.loc.indexName, key: 'i', rev: 3, mod: 'image');
    final manifest = p.sa.objects.values.firstWhere((o) => o.typeId == locRoot);
    expect(manifest.leaves['core']!.keys, ['text']);
    expect(manifest.leaves['core']!['text']!.value, {'fmt': 1});
    manifest.leaves['core']!['image'] = FakeVal({'fmt': 1});
    p.sa.change(manifest.id);
    await p.a.pull(p.loc);
    final st = await p.a.locationStatus(p.loc);
    expect(st.conflict!.reasons, contains('documents'));
    expect(st.conflict!.conflictingDocuments, 1);
    await expectLater(
      p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
      throwsA(
        isA<AnySyncConflictException>().having(
          (e) => e.conflictingDocuments,
          'conflictingDocuments',
          1,
        ),
      ),
    );
  });

  test('B1: textSearch is the leaf textSearch.on', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final i = await openVectors(
      a,
      AnySyncLocation(spaceId: s.id, indexName: 'n'),
      text: true,
    );
    final m = w
        .device('a')
        .space(s.id)
        .objects
        .values
        .firstWhere((o) => o.typeId == locRoot);
    expect(m.leaves['textSearch']!['on']!.value, true);
    await i.dispose();
  });

  test('D14 local-only account calls work while suspended', () async {
    final p = await pair(w, profileB: other);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    await p.sync();
    await p.b.suspend();
    expect((await p.b.locationStatus(p.loc)).documents, 1);
    expect((await p.b.missingVectors(p.loc)).items, hasLength(1));
    await expectLater(
      p.b.pull(p.loc),
      throwsA(isA<AnySyncSuspendedException>()),
    );
  });

  group('D15 error mapping', () {
    test('NOT_FOUND from object_patch is definitionsNotSynced', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      final sdk = w.runtimeOf('a').sdkImpl;
      sdk.failPatch = (t, ops) => t['create'] != null;
      sdk.failPatchStatus = AnyShimStatus.notFound;
      sdk.failPatchMessage =
          'the definitions of type docroot have not synced here (property "doc")';
      await expectLater(
        i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
        throwsA(
          isA<AnySyncNotReadyException>().having(
            (e) => e.reason,
            'reason',
            AnySyncNotReadyReason.definitionsNotSynced,
          ),
        ),
      );
      // An object that is not here is not a readiness question (D-R12).
      sdk.failPatchMessage = 'object docroot is not here';
      await expectLater(
        i.addVector(id: 'z', embedding: [1, 0, 0, 0], content: 'Z'),
        throwsA(
          isA<AnySyncException>()
              .having((e) => e, 'type', isNot(isA<AnySyncNotReadyException>()))
              .having((e) => e.cause, 'cause', isA<AnyShimException>()),
        ),
      );
      sdk.failPatchStatus = AnyShimStatus.io;
      await expectLater(
        i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y'),
        throwsA(
          isA<AnySyncException>()
              .having(
                (e) => e,
                'not a local index error',
                isNot(isA<AnySyncLocalIndexException>()),
              )
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
    });

    test('BUSY names another process when the shim says so', () async {
      await w.open('a');
      final d = w.device('a');
      final a2 = await () async {
        try {
          return await w.open('a');
        } on AnySyncBusyException catch (e) {
          return e;
        }
      }();
      expect(a2, isA<AnySyncBusyException>());
      expect(d.isOpen, isTrue);
    });
  });

  test('D16 an account call joining an in-flight store open still needs '
      'the local file', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final opening = openVectors(a, loc);
    await expectLater(a.missingVectors(loc), throwsStateError);
    await (await opening).dispose();
  });

  group('D17 formats', () {
    test('a newer leaf with a non-string ch is newerFormat', () {
      expect(
        LeafValue.parse({'fmt': 9, 'ch': 3}, 4).kind,
        LeafKind.newerFormat,
      );
    });

    test(
      'out-of-range tombstone revs and dropped filter values are counted',
      () async {
        final schema = FilterSchema(
          fields: [FilterField(name: 'year', type: FilterFieldType.number)],
        );
        final p = await pair(w, schemaA: schema);
        await p.ia.addVector(
          id: 'x',
          embedding: [1, 0, 0, 0],
          content: 'X',
          metadata: '{"year":"soon"}',
        );
        final manifest = p.sa.objects.values.firstWhere(
          (o) => o.typeId == locRoot,
        );
        p.sa.records.putIfAbsent((manifest.id, tombColl), () => {})[sha256Hex(
          'q',
        )] = FakeRecord(sha256Hex('q'))
          ..key = FakeVal('q')
          ..revs.addAll([-1, maxRev + 5])
          ..applySeq = p.sa.seq + 1;
        p.sa.change(manifest.id);
        await p.a.pull(p.loc);
        final st = await p.a.locationStatus(p.loc);
        expect(st.droppedFilterValues, 1);
        expect(st.ignoredTombstones, 2);
      },
    );

    test('a leaf whose ch is not the content hash is text-only', () async {
      final p = await pair(w);
      craftDoc(
        p.sa,
        indexName: p.loc.indexName,
        key: 'k',
        rev: 4,
        content: 'now',
        vecs: {
          leafKeyOf(profile4): leafValue([1, 0, 0, 0], 'before'),
        },
      );
      await p.a.pull(p.loc);
      expect((await p.a.missingVectors(p.loc)).items.single.key, 'k');
    });
  });

  group('D18 robustness', () {
    test(
      'spaces(sync:) at its deadline returns the local list, timed out',
      () async {
        final a = await w.open('a');
        final s = await a.createSpace('mine');
        w.runtimeOf('a').sdkImpl.listSyncHangs = true;
        final r = await a.spaces(
          sync: true,
          timeout: const Duration(milliseconds: 1),
        );
        expect(r.timedOut, isTrue);
        expect(r.spaces.map((x) => x.id), [s.id]);
      },
    );

    test('an inputFor error is the app\'s, rethrown', () async {
      final p = await pair(w, profileB: other);
      await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      await p.sync();
      await expectLater(
        p.b.backfillVectors(
          p.loc,
          FakeEmbedder(profile: other),
          inputFor: (i) => throw StateError('app bug'),
        ),
        throwsStateError,
      );
    });

    test('a blank-body mark that fails reports the committed write', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      w.runtimeOf('a').sdkImpl.failBodies = true;
      FakeIndex.failApply = (ops) => (ops['ops'] as List).any(
        (o) => ((o as Map)['key'] as String? ?? '').startsWith('b/'),
      );
      await expectLater(
        i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
        throwsA(isA<AnySyncCommittedException>()),
      );
    });

    test('text search drops NULs', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
        text: true,
      );
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'rocket');
      expect(
        (await i.searchText(text: 'roc\u0000ket rocket')).map((h) => h.id),
        ['x'],
      );
      expect(jsonEncode('ok'), '"ok"');
    });
  });
}

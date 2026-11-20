// The synced-data rules of design §2 on two fake devices.
import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/formats.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import 'scenarios.dart';

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  group('key rules', () {
    for (final MapEntry(key: name, value: (scenario, _)) in scenarios.entries) {
      test(name, () => scenario(w));
    }
  });

  test('a later update survives a remove it never saw (LWW by HLC)', () async {
    final p = await pair(w);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v1');
    await p.sync();
    await p.ib.remove(id: 'x');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v2');
    await p.sync();
    for (final i in [p.ia, p.ib]) {
      final hits = await i.searchVector(embedding: [1, 0, 0, 0], topK: 1);
      expect(hits.single.content, 'v2');
    }
  });

  test('S1 leaf-only: equal content under another profile adds a leaf, '
      'no object', () async {
    final other = EmbeddingProfile(id: 'other-v1', dimension: 4);
    final p = await pair(w, profileB: other);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    await p.sync();
    expect((await p.b.missingVectors(p.loc)).items.map((i) => i.key), ['x']);
    await p.ib.addVector(id: 'x', embedding: [0, 1, 0, 0], content: 'X');
    expect(docObjects(p.sb), hasLength(1));
    expect(docObjects(p.sb).single.leaves['vecs']!.keys, hasLength(2));
    expect((await p.b.missingVectors(p.loc)).items, isEmpty);
    expect(await idsOf(p.ib, [0, 1, 0, 0]), ['x']);
    await p.sync();
    expect(docObjects(p.sa), hasLength(1));
    expect(await idsOf(p.ia, [1, 0, 0, 0]), ['x']);
  });

  test('S1 no-op on one device: nothing written at all', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final i = await openVectors(a, loc);
    await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    final seq = w.device('a').space(s.id).seq;
    await i.addVector(id: 'x', embedding: [0, 1, 0, 0], content: 'X');
    expect(w.device('a').space(s.id).seq, seq);
    // Another meta is a change.
    await i.addVector(
      id: 'x',
      embedding: [1, 0, 0, 0],
      content: 'X',
      metadata: '{"a":1}',
    );
    expect(docObjects(w.device('a').space(s.id)), hasLength(2));
  });

  test(
    'read-your-writes: add, remove and clear are local within the call',
    () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
      expect(await idsOf(i, [1, 0, 0, 0]), ['x']);
      await i.remove(id: 'x');
      expect(await idsOf(i, [1, 0, 0, 0]), isEmpty);
      await i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y');
      await i.clear();
      expect(await idsOf(i, [1, 0, 0, 0]), isEmpty);
    },
  );

  test('a clock at 2^53 - 2 refuses the next write', () async {
    final p = await pair(w);
    craftDoc(p.sb, indexName: p.loc.indexName, key: 'z', rev: maxRev);
    await p.sync();
    await expectLater(
      p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
      throwsA(isA<AnySyncClockExhaustedException>()),
    );
  });

  test('the HLC is persisted before the space write', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final i = await openVectors(a, loc);
    final sdk = w.runtimeOf('a').sdkImpl;
    sdk.failPatch = (t, ops) => t['create'] != null;
    await expectLater(
      i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
      throwsA(isA<AnySyncException>()),
    );
    final file = w.net.files.values.single;
    final allocated = int.parse(file.state['hlc']!);
    sdk.failPatch = null;
    await i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y');
    expect(
      revOf(docObjects(w.device('a').space(s.id)).single),
      greaterThan(allocated),
    );
  });

  test('firstPullPending: a new file takes writes only after its first '
      'full pull', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final ia = await openVectors(a, loc);
    await ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    final b = await w.open('b');
    w.net.link(w.device('a'), w.device('b'));
    await b.spaces(sync: true);
    FakeIndex.failApply = (ops) =>
        (ops['ops'] as List).any((o) => (o as Map)['key'] == 'lastPull');
    final ib = await openVectors(b, loc);
    await expectLater(
      ib.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'Y'),
      throwsA(
        isA<AnySyncNotReadyException>().having(
          (e) => e.reason,
          'reason',
          AnySyncNotReadyReason.firstPullPending,
        ),
      ),
    );
    expect((await b.locationStatus(loc)).firstPullPending, isTrue);
    FakeIndex.failApply = null;
    await b.pull(loc);
    await ib.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'Y');
    expect(await idsOf(ib, [1, 0, 0, 0]), ['x', 'y']);
  });

  test(
    'AnySyncCommittedException: committed, applied later by the follower',
    () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
      final i = await openVectors(a, loc);
      FakeIndex.failApply = (ops) => (ops['ops'] as List).any(
        (o) => (o as Map)['op'] == 'upsert' && o['id'] == 'x',
      );
      await expectLater(
        i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
        throwsA(
          isA<AnySyncCommittedException>()
              .having((e) => e.key, 'key', 'x')
              .having((e) => e.retryable, 'retryable', false),
        ),
      );
      expect(docObjects(w.device('a').space(s.id)), hasLength(1));
      FakeIndex.failApply = null;
      await a.pull(loc);
      expect(await idsOf(i, [1, 0, 0, 0]), ['x']);
    },
  );

  test('rebuild: a generation change rebuilds, an insert below `after` '
      'is replayed', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final i = await openVectors(a, loc);
    for (final k in ['p', 'q', 'r']) {
      await i.addVector(id: k, embedding: [1, 0, 0, 0], content: k);
    }
    final space = w.device('a').space(s.id);
    space.rebuildSdkDb();
    var inserted = false;
    space.onTypePage = (after) {
      if (inserted) return;
      inserted = true;
      craftDoc(
        space,
        indexName: 'n',
        key: 'early',
        rev: 5,
        id: 'obj00000000',
        content: 'early',
        vecs: {
          leafKeyOf(profile4): leafValue([0, 1, 0, 0], 'early'),
        },
      );
    };
    final pull = await a.pull(loc);
    expect(pull.rebuilt, isTrue);
    expect(inserted, isTrue);
    expect((await idsOf(i, [1, 0, 0, 0])).toSet(), {'p', 'q', 'r', 'early'});
    final st = await a.locationStatus(loc);
    expect(st.rebuilding, isFalse);
    // Own objects stay own across the swap: an update still supersedes.
    await i.addVector(id: 'p', embedding: [1, 0, 0, 0], content: 'p2');
    expect((await a.locationStatus(loc)).pendingSupersedeDeletes, 1);
  });

  test(
    'schema union: field names with ".", "*" and "_x" on two devices',
    () async {
      final p = await pair(
        w,
        schemaA: FilterSchema(
          fields: [FilterField(name: 'a.b', type: FilterFieldType.string)],
        ),
        schemaB: FilterSchema(
          fields: [
            FilterField(name: '*', type: FilterFieldType.number),
            FilterField(name: '_x', type: FilterFieldType.bool),
          ],
        ),
      );
      await p.sync();
      final m = (await p.a.locationStatus(p.loc)).manifest!;
      expect(m.fields.map((f) => f.name).toSet(), {'a.b', '*', '_x'});
      expect(m.ignoredLeaves, 0);
      await p.ia.addVector(
        id: 'k',
        embedding: [1, 0, 0, 0],
        content: 'k',
        metadata: '{"a.b":"v","*":3,"_x":true}',
      );
      await p.ia.addVector(
        id: 'l',
        embedding: [1, 0, 0, 0],
        content: 'l',
        metadata: '{"a.b":"w"}',
      );
      final hits = await p.ia.searchVector(
        embedding: [1, 0, 0, 0],
        filter: Filter(
          must: [FieldEquals(key: 'a.b', value: 'v')],
        ),
      );
      expect(hits.map((h) => h.id), ['k']);
      await p.sync();
      final onB = await p.ib.searchVector(
        embedding: [1, 0, 0, 0],
        filter: Filter(
          must: [
            FieldRange(key: '*', gte: 2),
            FieldEquals(key: '_x', value: true),
          ],
        ),
      );
      expect(onB.map((h) => h.id), ['k']);
    },
  );

  test('a profile id with another dimension is a conflict', () async {
    final p = await pair(w);
    final c = await w.open('c');
    w.net.link(w.device('a'), w.device('c'));
    await c.spaces(sync: true);
    await expectLater(
      openVectors(
        c,
        p.loc,
        profile: EmbeddingProfile(id: profile4.id, dimension: 8),
      ),
      throwsA(
        isA<AnySyncConflictException>().having(
          (e) => e.reasons,
          'reasons',
          contains('profile:${profile4.id}'),
        ),
      ),
    );
  });

  test('another modality is a conflict; such documents are '
      'conflictingBinding', () async {
    final p = await pair(w);
    final c = await w.open('c');
    w.net.link(w.device('a'), w.device('c'));
    await c.spaces(sync: true);
    await expectLater(
      openVectors(c, p.loc, documents: EmbeddingModality.image),
      throwsA(isA<AnySyncConflictException>()),
    );
    craftDoc(
      p.sa,
      indexName: p.loc.indexName,
      key: 'img',
      rev: 7,
      mod: 'image',
    );
    await p.a.pull(p.loc);
    final st = await p.a.locationStatus(p.loc);
    expect(st.unindexable[AnySyncUnindexableReason.conflictingBinding], 1);
    expect(await idsOf(p.ia, [1, 0, 0, 0]), isEmpty);
  });

  test(
    'unindexable: malformed, newer format, bad vector (text-only)',
    () async {
      final p = await pair(w);
      final n = p.loc.indexName;
      craftDoc(
        p.sa,
        indexName: n,
        key: 'm',
        rev: 1,
        docOverride: '{"fmt":1,"loc":"$n","key":"m","rev":"x"}',
      );
      craftDoc(p.sa, indexName: n, key: 'f', rev: 2, fmt: 2);
      craftDoc(
        p.sa,
        indexName: n,
        key: 'v',
        rev: 3,
        content: 'V',
        vecs: {
          leafKeyOf(profile4): {
            'fmt': 1,
            'dim': 4,
            'enc': 'f32le-b64',
            'ch': 'c',
            'vec': '!!',
          },
        },
      );
      await p.a.pull(p.loc);
      final st = await p.a.locationStatus(p.loc);
      expect(st.unindexable[AnySyncUnindexableReason.malformed], 1);
      expect(st.unindexable[AnySyncUnindexableReason.newerFormat], 1);
      expect(st.unindexable[AnySyncUnindexableReason.badVector], 1);
      expect(st.textOnly, 1);
      expect((await p.a.missingVectors(p.loc)).items.single.key, 'v');
      expect(await idsOf(p.ia, [1, 0, 0, 0]), isEmpty);
    },
  );

  test(
    'a manifest leaf whose value does not hash to its key is ignored',
    () async {
      final p = await pair(w);
      final manifest = p.sa.objects.values.firstWhere(
        (o) => o.typeId == locRoot,
      );
      manifest.leaves.putIfAbsent('fields', () => {})['deadbeef-string'] =
          FakeVal({'fmt': 1, 'name': 'forged', 'type': 'string'});
      p.sa.change(manifest.id);
      await p.a.pull(p.loc);
      final m = (await p.a.locationStatus(p.loc)).manifest!;
      expect(m.ignoredLeaves, 1);
      expect(m.fields.map((f) => f.name), isNot(contains('forged')));
    },
  );

  test('a tombstone record whose id is not sha256(key) is ignored', () async {
    final p = await pair(w);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    final manifest = p.sa.objects.values.firstWhere((o) => o.typeId == locRoot);
    final rec = FakeRecord('0' * 64)
      ..key = FakeVal('x')
      ..revs.add(DateTime.now().millisecondsSinceEpoch + 100000)
      ..applySeq = p.sa.seq + 1;
    p.sa.records.putIfAbsent((manifest.id, tombColl), () => {})['0' * 64] = rec;
    p.sa.change(manifest.id);
    await p.a.pull(p.loc);
    expect(await idsOf(p.ia, [1, 0, 0, 0]), ['x']);
  });
}

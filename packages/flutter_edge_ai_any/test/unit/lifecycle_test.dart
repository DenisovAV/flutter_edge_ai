// Account lifecycle and readiness (design §1 exceptions, §2.1 gate, §4).
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/native/any_native.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Matcher notReady(AnySyncNotReadyReason r) => throwsA(
  isA<AnySyncNotReadyException>()
      .having((e) => e.reason, 'reason', r)
      .having((e) => e.retryable, 'retryable', true),
);

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  test('one account per directory per process', () async {
    await w.open('a');
    await expectLater(
      w.open('a'),
      throwsA(
        isA<AnySyncBusyException>().having(
          (e) => e.reason,
          'reason',
          AnySyncBusyReason.alreadyOpenInProcess,
        ),
      ),
    );
  });

  test('a directory a previous instance holds: waits, then '
      'previousInstanceClosing', () async {
    final a = await w.open('a');
    await a.close();
    // A previous hot-restart generation still holds it.
    w.device('a')
      ..isOpen = true
      ..ownerToken = 'previous generation';
    await expectLater(
      w.open('a'),
      throwsA(
        isA<AnySyncBusyException>()
            .having(
              (e) => e.reason,
              'reason',
              AnySyncBusyReason.previousInstanceClosing,
            )
            .having((e) => e.retryable, 'retryable', true),
      ),
    );
    // Released while the open waits: the open succeeds.
    Future<void>.delayed(
      const Duration(milliseconds: 100),
      () => w.device('a').isOpen = false,
    );
    final again = await w.open(
      'a',
      previousInstanceWait: const Duration(seconds: 3),
    );
    await again.close();
  });

  test('a 31-byte key is refused', () async {
    debugAnyNativeOverride = w.net.native();
    await expectLater(
      AnySyncAccount.open(
        dataDirectory: '${w.root}/k/sdk',
        indexDirectory: '${w.root}/k/index',
        mnemonic: 'm',
        deviceKey: 'd',
        nodeConfYaml: nodeConf,
        localEncryptionKey: Uint8List(31),
      ),
      throwsArgumentError,
    );
  });

  test('suspend: the SDK is closed, local search goes on; resume', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final i = await openVectors(a, loc);
    await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    expect(await a.suspend(), AnySyncAccountState.suspended);
    expect(await a.suspend(), AnySyncAccountState.suspended);
    expect(w.device('a').isOpen, isFalse);
    expect(await idsOf(i, [1, 0, 0, 0]), ['x']);
    await expectLater(
      i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y'),
      throwsA(
        isA<AnySyncSuspendedException>().having(
          (e) => e.retryable,
          'retryable',
          true,
        ),
      ),
    );
    await expectLater(
      a.createSpace('t'),
      throwsA(isA<AnySyncSuspendedException>()),
    );
    expect(await a.resume(), AnySyncAccountState.open);
    await i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y');
    await i.dispose();
    await a.close();
    await expectLater(
      a.createSpace('u'),
      throwsA(isA<AnySyncClosedException>()),
    );
    expect(await a.resume(), AnySyncAccountState.closed);
  });

  test('the account closes before its store: search works until the store '
      'closes', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final i = await openVectors(
      a,
      AnySyncLocation(spaceId: s.id, indexName: 'n'),
    );
    await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    await a.close();
    expect(await idsOf(i, [1, 0, 0, 0]), ['x']);
    await expectLater(
      i.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'Y'),
      throwsA(isA<AnySyncClosedException>()),
    );
    await i.dispose();
    expect(w.runtimeOf('a').disposed, isTrue);
  });

  test('unknown and loading spaces are not ready', () async {
    final a = await w.open('a');
    await expectLater(
      openVectors(a, AnySyncLocation(spaceId: 'nosuch.space', indexName: 'n')),
      notReady(AnySyncNotReadyReason.unknownSpace),
    );
    final s = await a.createSpace('s');
    w.device('a').loading.add(s.id);
    await expectLater(
      openVectors(a, AnySyncLocation(spaceId: s.id, indexName: 'n')),
      notReady(AnySyncNotReadyReason.loading),
    );
    w.device('a').loading.remove(s.id);
    await (await openVectors(
      a,
      AnySyncLocation(spaceId: s.id, indexName: 'n'),
    )).dispose();
  });

  group('the publish gate', () {
    test('a device that synced with a peer once, alone now, may not '
        'publish', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      final b = await w.open('b');
      w.net.link(w.device('a'), w.device('b'));
      await b.spaces(sync: true);
      await b.spaceStatus(s.id);
      w.net.sync(w.device('a'), w.device('b'));
      w.net.unlink(w.device('a'), w.device('b'));
      expect((await b.spaceStatus(s.id)).everPeerSynced, isTrue);
      await expectLater(
        openVectors(b, AnySyncLocation(spaceId: s.id, indexName: 'n')),
        notReady(AnySyncNotReadyReason.manifestNotSynced),
      );
      // A converged round with the peer: nobody has the manifest, publish.
      w.net.link(w.device('a'), w.device('b'));
      final i = await openVectors(
        b,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      await i.dispose();
    });

    test('the creator binds alone (S3)', () async {
      final a = await w.open('a');
      final s = await a.createSpace('s');
      expect((await a.spaceStatus(s.id)).createdHere, isTrue);
      final i = await openVectors(
        a,
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      );
      final m = (await a.locationStatus(
        AnySyncLocation(spaceId: s.id, indexName: 'n'),
      )).manifest!;
      expect(m.documents, EmbeddingModality.text);
      expect(m.profiles.single.id, profile4.id);
      await i.dispose();
    });

    test('a converged peer manifest is used, not overwritten', () async {
      final p = await pair(w);
      final m = (await p.b.locationStatus(p.loc)).manifest!;
      expect(m.profiles, hasLength(1));
    });
  });

  test(
    'a reader binds when nothing needs publishing, and cannot write',
    () async {
      final p = await pair(w);
      await p.ib.dispose();
      final c = await w.open('c');
      w.net.link(w.device('a'), w.device('c'));
      await c.spaces(sync: true);
      w.device('c').readOnly = true;
      final ic = await openVectors(c, p.loc);
      await expectLater(
        ic.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X'),
        throwsA(isA<AnySyncReadOnlyException>()),
      );
      await expectLater(
        openVectors(
          c,
          AnySyncLocation(spaceId: p.loc.spaceId, indexName: 'other'),
        ),
        throwsA(isA<AnySyncReadOnlyException>()),
      );
      await ic.dispose();
    },
  );

  test('compact deletes dominated objects, keeps a superseded one whose '
      'successor has not synced (D10), repairs blank bodies', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    final loc = AnySyncLocation(spaceId: s.id, indexName: 'n');
    final i = await openVectors(a, loc);
    final space = w.device('a').space(s.id);
    w.runtimeOf('a').sdkImpl.failBodies = true;
    await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v1');
    w.runtimeOf('a').sdkImpl.failBodies = false;
    await i.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v2');
    await i.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'Y');
    w.runtimeOf('a').sdkImpl.failBodies = true;
    await i.addVector(id: 'z', embedding: [0, 1, 0, 0], content: 'Z');
    w.runtimeOf('a').sdkImpl.failBodies = false;
    // A peer's older version of y: dominated, and no supersede waits on it.
    craftDoc(space, indexName: 'n', key: 'y', rev: 5, content: 'old y');
    await a.pull(loc);
    var st = await a.locationStatus(loc);
    expect(st.dominatedObjects, 2);
    expect(st.pendingSupersedeDeletes, 1);
    expect(st.blankBodies, 2);
    final c = await a.compact(loc);
    expect(c.deleted, 1, reason: 'the peer object; v1 waits for v2 to sync');
    expect(c.bodiesRepaired, 1, reason: 'the superseded one gets none');
    expect(docObjects(space).map(contentOf).toSet(), {'v1', 'v2', 'Y', 'Z'});
    expect(docObjects(space).firstWhere((o) => contentOf(o) == 'Z').body, 'Z');
    st = await a.locationStatus(loc);
    expect(st.dominatedObjects, 1);
    expect(st.pendingSupersedeDeletes, 1);
    // v1 keeps its mark: it may be the winner again (D-R12).
    expect(st.blankBodies, 1);
    expect(await idsOf(i, [1, 0, 0, 0]), containsAll(['x', 'y', 'z']));
  });

  test('locationStatus reports totals', () async {
    final p = await pair(w);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    await p.ia.remove(id: 'x');
    final st = await p.a.locationStatus(p.loc);
    expect(st.documents, 0);
    expect(st.tombstones, 1);
    expect(st.lastPull, isNotNull);
    expect(st.rebuilding, isFalse);
    expect(st.conflict, isNull);
    expect(st.firstPullPending, isFalse);
  });

  test('syncNow reports the peer round and the pull', () async {
    final p = await pair(w);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
    final r = await p.b.syncNow(p.loc);
    expect(r.reachedPeer, isTrue);
    expect(r.timedOut, isFalse);
    expect(r.pull.applied, 1);
    expect(await idsOf(p.ib, [1, 0, 0, 0]), ['x']);
  });

  test('spaces: local and with peers', () async {
    final a = await w.open('a');
    final s = await a.createSpace('notes');
    final b = await w.open('b');
    expect((await b.spaces()).spaces, isEmpty);
    w.net.link(w.device('a'), w.device('b'));
    final list = await b.spaces(sync: true);
    expect(list.spaces.map((x) => x.id), [s.id]);
    expect(list.timedOut, isFalse);
  });
}

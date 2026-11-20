// missingVectors, writeMissingVectors and backfillVectors (design §1
// Vector writes, S2), on a location bound by two profiles.
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

final other = EmbeddingProfile(id: 'other-v1', dimension: 4);

void main() {
  late World w;
  setUp(() => w = World());
  tearDown(() => w.dispose());

  test('missing items carry content; written, changed and gone are told '
      'apart', () async {
    final p = await pair(w, profileB: other);
    for (final k in ['x', 'y', 'z']) {
      await p.ia.addVector(
        id: k,
        embedding: [1, 0, 0, 0],
        content: 'content $k',
        metadata: '{"k":"$k"}',
      );
    }
    await p.sync();
    final page = await p.b.missingVectors(p.loc);
    expect(page.items.map((i) => i.key), ['x', 'y', 'z']);
    final y = page.items[1];
    expect(y.content, 'content y');
    expect(y.meta, '{"k":"y"}');
    expect(y.modality, EmbeddingModality.text);
    expect((await p.b.locationStatus(p.loc)).textOnly, 3);
    expect((await p.ib.stats()).documentCount, 0, reason: 'vector rows only');

    await p.ia.addVector(id: 'y', embedding: [1, 0, 0, 0], content: 'new y');
    await p.ia.remove(id: 'z');
    await p.sync();

    final r = await p.b.writeMissingVectors(p.loc, [
      for (final i in page.items)
        AnySyncVectorItem(i, Float32List.fromList([0, 0, 1, 0])),
    ]);
    expect(r.written, 1);
    expect(r.skippedChanged, 1);
    expect(r.skippedGone, 1);
    expect(r.failed, isEmpty);
    expect(await idsOf(p.ib, [0, 0, 1, 0]), ['x']);
    // The write took no rev and made no object: only a leaf.
    final xObj = docObjects(
      p.sb,
    ).firstWhere((o) => contentOf(o) == 'content x');
    expect(xObj.leaves['vecs']!.keys, hasLength(2));
    await p.sync();
    expect(await idsOf(p.ia, [1, 0, 0, 0]), contains('x'));
  });

  test('a vector of another dimension or not finite fails per item', () async {
    final p = await pair(w, profileB: other);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'x');
    await p.sync();
    final item = (await p.b.missingVectors(p.loc)).items.single;
    final r = await p.b.writeMissingVectors(p.loc, [
      AnySyncVectorItem(item, Float32List.fromList([1, 0])),
      AnySyncVectorItem(item, Float32List.fromList([double.nan, 0, 0, 0])),
    ]);
    expect(r.failed, hasLength(2));
    expect(r.written, 0);
  });

  test('backfill embeds inputFor(item), pages, and stops at an embedder '
      'failure with the partial result', () async {
    final p = await pair(w, profileB: other);
    for (final k in ['k1', 'k2', 'k3bad', 'k4']) {
      await p.ia.addVector(id: k, embedding: [1, 0, 0, 0], content: 'c-$k');
    }
    await p.sync();
    final seen = <String>[];
    final e = FakeEmbedder(profile: other, failOn: 'bad');
    final first = await p.b.backfillVectors(
      p.loc,
      e,
      inputFor: (i) {
        seen.add(i.key);
        return EmbeddingInput.text('${i.content} as embedded');
      },
      limit: 10,
    );
    expect(seen, ['k1', 'k2', 'k3bad']);
    expect(first.written, 2);
    expect(first.failed.single.key, 'k3bad');
    expect(first.next, 'k2', reason: 'the next call offers k3bad again');
    final paged = await p.b.backfillVectors(
      p.loc,
      FakeEmbedder(profile: other),
      inputFor: (i) => EmbeddingInput.text(i.content),
      limit: 1,
      after: first.next,
    );
    expect(paged.written, 1);
    expect(paged.next, 'k3bad');
    expect((await p.b.missingVectors(p.loc)).items.map((i) => i.key), ['k4']);
  });

  test('backfill refuses an embedder of another profile', () async {
    final p = await pair(w, profileB: other);
    await expectLater(
      p.b.backfillVectors(
        p.loc,
        FakeEmbedder(profile: profile4),
        inputFor: (i) => EmbeddingInput.text(i.content),
      ),
      throwsArgumentError,
    );
  });

  test('account calls on a location this device never opened', () async {
    final a = await w.open('a');
    final s = await a.createSpace('s');
    await expectLater(
      a.missingVectors(AnySyncLocation(spaceId: s.id, indexName: 'none')),
      throwsStateError,
    );
  });

  test('an account call shares the core with an open store', () async {
    final p = await pair(w, profileB: other);
    await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'x');
    await p.sync();
    final st = await p.b.locationStatus(p.loc);
    expect(st.documents, 1);
    // The store still works after the account call released its reference.
    expect((await p.ib.stats()).documentCount, 0);
  });
}

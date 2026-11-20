// The key rules of design §2, each as one scenario on two fake devices.
// sync_rules_test.dart runs them; mutation_test.dart runs each with its
// rule disabled (engine.dart, debugEngineMutations) and expects it to
// fail, so a rule that stops being enforced cannot keep a green suite.
import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_any/src/logic/formats.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

typedef Scenario = Future<void> Function(World w);

/// S1: an unchanged re-add writes nothing, so it cannot override a remove
/// this device has not received.
Future<void> s1UnchangedReAddDoesNotResurrect(World w) async {
  final p = await pair(w);
  await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
  await p.sync();
  expect(await idsOf(p.ib, [1, 0, 0, 0]), ['x']);
  await p.ib.remove(id: 'x'); // A has not seen this yet
  final before = docObjects(p.sa).length;
  await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
  expect(docObjects(p.sa).length, before, reason: 'S1: nothing written');
  await p.sync();
  expect(await idsOf(p.ia, [1, 0, 0, 0]), isEmpty);
  expect(await idsOf(p.ib, [1, 0, 0, 0]), isEmpty);
}

/// A remove hides every document of the key with a lower rev.
Future<void> tombstoneHidesOlder(World w) async {
  final p = await pair(w);
  await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
  await p.sync();
  await p.ib.remove(id: 'x');
  await p.sync();
  expect(await idsOf(p.ia, [1, 0, 0, 0]), isEmpty);
}

/// A clear hides every document with a lower rev, also ones the clearing
/// device never saw (so it could not delete their objects).
Future<void> clearHidesOlder(World w) async {
  final p = await pair(w);
  await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'X');
  await p.sync();
  await p.ia.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'Y');
  await Future<void>.delayed(const Duration(milliseconds: 5));
  await p.ib.clear(); // B never received y
  await p.sync();
  expect(docObjects(p.sa).length, 1, reason: "y's object is still there");
  expect(await idsOf(p.ia, [1, 0, 0, 0]), isEmpty);
  expect((await p.a.locationStatus(p.loc)).documents, 0);
}

/// Equal revs: the smaller object id wins, on every device.
Future<void> tieBreakSmallerId(World w) async {
  final p = await pair(w);
  final h = leafKeyOf(profile4);
  craftDoc(
    p.sa,
    indexName: p.loc.indexName,
    key: 't',
    rev: 1000,
    content: 'large',
    id: 'objz',
    vecs: {
      h: leafValue([1, 0, 0, 0], 'large'),
    },
  );
  craftDoc(
    p.sa,
    indexName: p.loc.indexName,
    key: 't',
    rev: 1000,
    content: 'small',
    id: 'obja',
    vecs: {
      h: leafValue([1, 0, 0, 0], 'small'),
    },
  );
  await p.sync();
  for (final i in [p.ia, p.ib]) {
    final hits = await i.searchVector(embedding: [1, 0, 0, 0], topK: 1);
    expect(hits.single.content, 'small');
  }
}

/// Copy-on-write: an update is a new object, and the superseded one is
/// deleted only once a peer acknowledged the new one (C3).
Future<void> supersedeWaitsForSync(World w) async {
  final a = await w.open('a');
  final space = await a.createSpace('s');
  final loc = AnySyncLocation(spaceId: space.id, indexName: 'notes');
  final ia = await openVectors(a, loc);
  await ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v1');
  await ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'v2');
  await a.pull(loc); // the follower's sweep runs here; alone, it waits
  final s = w.device('a').space(space.id);
  expect(docObjects(s), hasLength(2), reason: 'alone: the old one waits');
  final st = await a.locationStatus(loc);
  expect(st.pendingSupersedeDeletes, 1);
  expect(st.dominatedObjects, 1);
  final b = await w.open('b');
  w.net.link(w.device('a'), w.device('b'));
  await b.spaces(sync: true);
  w.net.sync(w.device('a'), w.device('b'));
  await a.pull(loc);
  expect(docObjects(s), hasLength(1));
  expect(contentOf(docObjects(s).single), 'v2');
  expect((await a.locationStatus(loc)).pendingSupersedeDeletes, 0);
}

/// Every rev read feeds the HLC: a later write here beats a peer's rev
/// ahead of this clock, and the lead is counted.
Future<void> hlcFeedsFromReads(World w) async {
  final p = await pair(w);
  final ahead = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
  final h = leafKeyOf(profile4);
  craftDoc(
    p.sb,
    indexName: p.loc.indexName,
    key: 'x',
    rev: ahead,
    content: 'peer',
    vecs: {
      h: leafValue([1, 0, 0, 0], 'peer'),
    },
  );
  await p.sync();
  await p.ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'mine');
  final mine = docObjects(p.sa).firstWhere((o) => contentOf(o) == 'mine');
  expect(revOf(mine), greaterThan(ahead));
  final hits = await p.ia.searchVector(embedding: [1, 0, 0, 0], topK: 1);
  expect(hits.single.content, 'mine');
  final st = await p.a.locationStatus(p.loc);
  expect(st.revsAheadOfClock, greaterThanOrEqualTo(1));
  expect(st.largestClockLead, greaterThan(const Duration(minutes: 50)));
  await p.sync();
  final onB = await p.ib.searchVector(embedding: [1, 0, 0, 0], topK: 1);
  expect(onB.single.content, 'mine');
}

/// D1: a winner the page did not carry is read and applied: when the
/// visible winner is deleted, the older object takes the row again.
Future<void> fallbackWinnerIsRead(World w) async {
  final p = await pair(w);
  final h = leafKeyOf(profile4);
  final n = p.loc.indexName;
  craftDoc(
    p.sa,
    indexName: n,
    key: 'k',
    rev: 10,
    content: 'old',
    vecs: {
      h: leafValue([1, 0, 0, 0], 'old'),
    },
  );
  await p.a.pull(p.loc);
  final fresh = craftDoc(
    p.sa,
    indexName: n,
    key: 'k',
    rev: 20,
    content: 'new',
    vecs: {
      h: leafValue([1, 0, 0, 0], 'new'),
    },
  );
  await p.a.pull(p.loc);
  expect(
    (await p.ia.searchVector(embedding: [1, 0, 0, 0], topK: 1)).single.content,
    'new',
  );
  fresh.deleted = true;
  p.sa.change(fresh.id, deleted: true);
  try {
    await p.a.pull(p.loc);
  } catch (e) {
    fail('the pull did not converge: $e');
  }
  expect(
    (await p.ia.searchVector(embedding: [1, 0, 0, 0], topK: 1)).single.content,
    'old',
  );
}

final scenarios = <String, (Scenario, String)>{
  'D1: a deleted winner falls back to the object the page lacked': (
    fallbackWinnerIsRead,
    'extrasNotApplied',
  ),
  'S1: an unchanged re-add does not resurrect an unseen remove': (
    s1UnchangedReAddDoesNotResurrect,
    'noS1',
  ),
  'a tombstone hides lower revs': (tombstoneHidesOlder, 'ignoreTombstone'),
  'a clear hides lower revs': (clearHidesOlder, 'ignoreClear'),
  'equal revs: the smaller object id wins': (
    tieBreakSmallerId,
    'tieBreakLargerId',
  ),
  'supersede deletes wait until the new object synced': (
    supersedeWaitsForSync,
    'supersedeBeforeSync',
  ),
  'the HLC takes in every rev read': (hlcFeedsFromReads, 'hlcIgnoresReads'),
};

/// Keeps formats.dart imported for scenarios that read raw values.
const maxRevForTests = maxRev;

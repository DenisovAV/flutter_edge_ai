// Two devices of one TEST account in one process, through RagIndex, over
// LAN p2p only (mDNS + QUIC on this machine; a random mDNS service type, a
// nodeconf whose nodes are all on a closed port). Tagged `lan`: skipped by
// default (dart_test.yaml), because it needs local multicast and minutes
// (a first space load can wait ~60 s for the SDK's re-handshake). Run:
//
//   flutter test -t lan --run-skipped test/lan
@Tags(['lan'])
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_edge_ai_any/flutter_edge_ai_any.dart';
import 'package:flutter_edge_ai_rag/flutter_edge_ai_rag.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/native_library.dart';

final profile = EmbeddingProfile(id: 'lan-test-v1', dimension: 4);

Future<T> retry<T>(
  Future<T> Function() f, {
  Duration max = const Duration(seconds: 150),
}) async {
  final end = DateTime.now().add(max);
  while (true) {
    try {
      return await f();
    } on AnySyncException catch (e) {
      if (!e.retryable || DateTime.now().isAfter(end)) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }
}

Future<void> until(
  Future<bool> Function() f, {
  Duration max = const Duration(seconds: 150),
  required String what,
}) async {
  final end = DateTime.now().add(max);
  while (!await f()) {
    if (DateTime.now().isAfter(end)) fail('timed out: $what');
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

void main() {
  final skip = nativeSkipReason();

  test(
    'A writes, B indexes it; S1 and the C3 ordering over LAN',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
    () async {
      final dir = Directory.systemTemp.createTempSync('any_lan').path;
      final mnemonic = await AnySyncAccount.newMnemonic();
      final service =
          '_fea${Random.secure().nextInt(1 << 30).toRadixString(16)}._tcp';
      Future<AnySyncAccount> device(String who) async => AnySyncAccount.open(
        dataDirectory: '$dir/$who/sdk',
        indexDirectory: '$dir/$who/index',
        mnemonic: mnemonic,
        deviceKey: await AnySyncAccount.newDeviceKey(),
        nodeConfYaml: deadNodeConf(),
        p2p: AnySyncP2p.lan(serviceName: service),
        spaceOpenWait: const Duration(seconds: 90),
      );
      final a = await device('a');
      final b = await device('b');
      addTearDown(() async {
        await a.close();
        await b.close();
        Directory(dir).deleteSync(recursive: true);
      });
      Future<RagIndex> open(AnySyncAccount acc, AnySyncLocation loc) =>
          FlutterEdgeAiRag(
            providers: [AnyVectorStoreProvider(acc)],
          ).openVectors(
            spec: VectorStoreSpec(
              providerId: AnyVectorStoreProvider.providerId,
              location: loc.value,
              enableTextSearch: true,
            ),
            profile: profile,
          );

      final space = await a.createSpace('flutter_edge_ai LAN test');
      final loc = AnySyncLocation(spaceId: space.id, indexName: 'notes');
      final ia = await open(a, loc);
      await ia.addVector(id: 'x', embedding: [1, 0, 0, 0], content: 'rocket');
      await ia.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'bread');

      await until(
        () async =>
            (await b.spaces(sync: true)).spaces.any((s) => s.id == space.id),
        what: 'B learns the space',
      );
      final ib = await retry(() => open(b, loc));
      await until(() async {
        await b.syncNow(loc, timeout: const Duration(seconds: 5));
        return (await ib.stats()).documentCount == 2;
      }, what: 'B indexes both documents');
      expect((await ib.searchText(text: 'rocket')).map((h) => h.id), ['x']);

      // C3: A updates x; B never loses x on the way (the new object arrives
      // before the old one is deleted).
      await ia.addVector(
        id: 'x',
        embedding: [1, 0, 0, 0],
        content: 'rocket v2',
      );
      await until(() async {
        await b.pull(loc);
        final hits = await ib.searchVector(embedding: [1, 0, 0, 0], topK: 1);
        expect(hits, isNotEmpty, reason: 'x vanished between the versions');
        return hits.single.content == 'rocket v2';
      }, what: 'B sees the update');
      await until(() async {
        await a.syncNow(loc, timeout: const Duration(seconds: 5));
        return (await a.locationStatus(loc)).pendingSupersedeDeletes == 0;
      }, what: 'the superseded object is deleted once synced');

      // S1: B removes y while A re-adds it unchanged: no resurrection.
      await ib.remove(id: 'y');
      await ia.addVector(id: 'y', embedding: [0, 1, 0, 0], content: 'bread');
      await until(() async {
        await a.syncNow(loc, timeout: const Duration(seconds: 5));
        await b.pull(loc);
        return (await ia.stats()).documentCount == 1;
      }, what: 'A applies the remove');
      expect((await ib.stats()).documentCount, 1);
      await ia.dispose();
      await ib.dispose();
    },
  );
}

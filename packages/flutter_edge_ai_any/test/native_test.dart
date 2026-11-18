// libany_shim through the Dart wrapper, offline: one account with p2p off
// and a nodeconf whose nodes are all on a closed port, so nothing leaves
// the process. The LAN case is test/lan/lan_sync_test.dart.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/src/ffi/any_shim.dart';
import 'package:test/test.dart';

import 'support/native_library.dart';

Matcher throwsStatus(AnyShimStatus s) =>
    throwsA(isA<AnyShimException>().having((e) => e.status, 'status', s));

Float32List vec(List<double> v) => Float32List.fromList(v);

void main() {
  final skip = nativeSkipReason();
  late Directory tmp;

  setUpAll(() {
    if (skip != null) return;
    AnyShim.checkAbi();
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('any_shim_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AnyShimAccount openAccount() => AnyShimAccount.open({
    'dataDir': '${tmp.path}/sdk',
    'mnemonic': AnyShim.newMnemonic(),
    'deviceKeyHex': AnyShim.newDeviceKey(),
    'nodeConfYaml': deadNodeConf(),
    'p2p': {'enabled': false},
  });

  group('process-wide', skip: skip, () {
    test('version names the pinned SDK', () {
      final v = AnyShim.version();
      expect(v['abi'], 1);
      expect(
        (v['modules'] as Map)['github.com/anyproto/any-sync-sdk'],
        'v0.7.4',
      );
    });

    test('mnemonics are 12 words, device keys differ', () {
      expect(AnyShim.newMnemonic().split(' '), hasLength(12));
      expect(AnyShim.newDeviceKey(), isNot(AnyShim.newDeviceKey()));
    });

    test('the production network is refused', () {
      final prod = deadNodeConf().replaceFirst(
        'N4N1wDHFpFpovXBqdbq2TDXE9tXdXbtV1eTJFpKJW4YeaJqR',
        'N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU',
      );
      expect(
        () => AnyShimAccount.open({
          'dataDir': '${tmp.path}/sdk',
          'mnemonic': AnyShim.newMnemonic(),
          'deviceKeyHex': AnyShim.newDeviceKey(),
          'nodeConfYaml': prod,
        }),
        throwsStatus(AnyShimStatus.refused),
      );
    });

    test('a stale handle is closed, not a crash', () {
      expect(
        () => AnyShimAccount.fromHandle(1 << 50).info(),
        throwsStatus(AnyShimStatus.closed),
      );
      expect(
        () => AnyShimIndex.fromHandle(1 << 50).count(),
        throwsStatus(AnyShimStatus.closed),
      );
    });
  });

  group('account', skip: skip, () {
    test('documents, feed, files and close', () {
      final a = openAccount();
      final info = a.info();
      expect((info['p2p'] as Map)['enabled'], false);

      final space = a.createSpace('notes');
      expect(a.listSpaces().map((s) => s['id']), contains(space));

      final put = a.putObject(space, {
        'seed': 'doc-1',
        'name': 'Titan',
        'text': 'methane lakes\nnitrogen air',
        'meta': {'cat': 'space'},
      });
      expect(put['created'], true);
      final again = a.putObject(space, {
        'seed': 'doc-1',
        'name': 'Titan',
        'text': 'v2',
      });
      expect(again, {'id': put['id'], 'created': false});

      final id = put['id']! as String;
      final doc = a.getObject(space, id);
      expect(doc['isDocument'], true);
      expect(doc['text'], 'v2');
      expect(doc['meta'], isNull, reason: 'the second put set no meta');

      expect(
        () => a.putObject(space, {'name': 'x', 'colour': 'red'}),
        throwsStatus(AnyShimStatus.invalidArgument),
      );

      final feed = a.changesSince(space, 0);
      expect(feed['generation'], isNotEmpty);
      final changes = (feed['changes']! as List).cast<Map>();
      expect(changes.map((c) => c['objectId']), contains(id));

      final src = File('${tmp.path}/blob.bin')
        ..writeAsBytesSync(List.generate(50000, (i) => i & 0xff));
      final fi = a.attachFile(space, id, src.path);
      expect(fi['size'], 50000);
      expect(a.listFiles(space, objectId: id), hasLength(1));
      final out = '${tmp.path}/out.bin';
      expect(
        a.readFile(
          space,
          fi['fileId']! as String,
          out,
          timeout: const Duration(seconds: 10),
        ),
        50000,
      );
      expect(File(out).readAsBytesSync(), src.readAsBytesSync());

      // A seeded (derived) object is never deleted; a created one is.
      expect(
        () => a.deleteObject(space, id),
        throwsStatus(AnyShimStatus.refused),
      );
      final plain =
          a.putObject(space, {'name': 'n', 'text': 't'})['id']! as String;
      a.deleteObject(space, plain);
      expect(
        () => a.getObject(space, plain),
        throwsA(
          isA<AnyShimException>().having(
            (e) => e.status,
            'status',
            anyOf(AnyShimStatus.deleted, AnyShimStatus.notFound),
          ),
        ),
      );

      a.close();
      expect(() => a.info(), throwsStatus(AnyShimStatus.closed));
      expect(() => a.close(), throwsStatus(AnyShimStatus.closed));
    });

    test(
      'a watch delivers changes; close wakes a poller on another isolate',
      () async {
        final a = openAccount();
        final space = a.createSpace('w');
        final watch = a.watchChanges(space);
        final id = a.putObject(space, {'name': 'n', 'text': 't'})['id'];
        final seen = <Object?>{};
        final end = DateTime.now().add(const Duration(seconds: 5));
        while (!seen.contains(id) && DateTime.now().isBefore(end)) {
          for (final ev in a.pollEvents(
            timeout: const Duration(milliseconds: 200),
          )) {
            if (ev['kind'] == 'change' && ev['watch'] == watch) {
              seen.add(ev['objectId']);
            }
          }
        }
        expect(seen, contains(id));
        a.unwatch(watch);
        expect(() => a.unwatch(watch), throwsStatus(AnyShimStatus.notFound));

        final handle = a.handle;
        final poller = Isolate.run(() {
          try {
            AnyShimAccount.fromHandle(
              handle,
            ).pollEvents(timeout: const Duration(seconds: 30));
            return 'returned';
          } on AnyShimException catch (e) {
            return e.status.name;
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final sw = Stopwatch()..start();
        a.close();
        expect(await poller, 'closed');
        expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      },
    );
  });

  group('index', skip: skip, () {
    test('exact knn, filter, BM25, state, delete', () {
      final x = AnyShimIndex.open({
        'path': '${tmp.path}/idx.db',
        'dim': 3,
        'filterFields': ['cat'],
      });
      x.upsert({
        'id': 'a',
        'name': 'Rocket',
        'text': 'kerosene and oxygen',
        'meta': {'cat': 'space'},
      }, vec([1, 0, 0]));
      x.upsert({
        'id': 'b',
        'name': 'Bread',
        'text': 'flour and water',
        'meta': {'cat': 'food'},
      }, vec([0, 1, 0]));
      x.upsert({
        'id': 'c',
        'name': 'Rover',
        'text': 'rock samples',
        'meta': {'cat': 'space'},
      }, vec([0.9, 0.1, 0]));
      expect(x.count(), 3);

      List<Object?> ids(Map<String, Object?> r) =>
          (r['results']! as List).map((m) => (m as Map)['id']).toList();
      expect(ids(x.knn(vec([1, 0, 0]), 2)), ['a', 'c']);
      expect(ids(x.knn(vec([1, 0, 0]), 3, filter: {'meta.cat': 'food'})), [
        'b',
      ]);
      expect(ids(x.text('kerosene', 5)), ['a']);
      expect(
        () => x.upsert({'id': 'd'}, vec([1, 0])),
        throwsStatus(AnyShimStatus.invalidArgument),
      );

      expect(x.getState('cursor'), isNull);
      x.setState('cursor', '17');
      expect(x.getState('cursor'), '17');

      expect(x.delete('a'), true);
      expect(x.delete('a'), false);
      x.close();
      expect(() => x.count(), throwsStatus(AnyShimStatus.closed));

      expect(
        () => AnyShimIndex.open({'path': '${tmp.path}/idx.db', 'dim': 4}),
        throwsStatus(AnyShimStatus.invalidArgument),
      );
      expect(
        () => AnyShimIndex.open({
          'path': '${tmp.path}/other.db',
          'dim': 4,
          'mode': 'ivfsq',
        }),
        throwsStatus(AnyShimStatus.refused),
      );
    });
  });
}

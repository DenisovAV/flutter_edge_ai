// libany_shim (ABI 2) through the Dart wrapper, offline: one account with
// p2p off and a nodeconf whose nodes are all on a closed port, so nothing
// leaves the process. Skipped, with the reason, when no ABI-2 library is
// loadable here (support/native_library.dart). The LAN case is
// test/lan/lan_sync_test.dart; the provider over the real library is
// test/native_provider_test.dart.
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/src/ffi/any_shim.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/native_library.dart';

Matcher throwsStatus(AnyShimStatus s) =>
    throwsA(isA<AnyShimException>().having((e) => e.status, 'status', s));

Float32List vec(List<double> v) => Float32List.fromList(v);

/// Waits for an op in slices, as the provider does.
Map<String, Object?> waitOp(
  int op, {
  Duration max = const Duration(seconds: 30),
}) {
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    final p = AnyShim.opWait(op, 250);
    if (p.done) return p.result!;
  }
  AnyShim.opCancel(op);
  throw TimeoutException('op $op');
}

/// any_shim_account_open_start, then its op (H1).
AnyShimAccount openAccountNow(Map<String, Object?> options) =>
    AnyShimAccount.fromOpenResult(waitOp(AnyShimAccount.openStart(options)));

/// index close and bind are ops (H3).
void closeIndex(AnyShimIndex x) => waitOp(x.closeStart());

Map<String, Object?> bindIndex(AnyShimIndex x, Map<String, Object?> cfg) =>
    waitOp(x.bindStart(cfg));

final class TimeoutException implements Exception {
  TimeoutException(this.what);
  final String what;
}

void main() {
  final skip = nativeSkipReason();
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('any_shim_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  AnyShimAccount openAccount() {
    final a = openAccountNow({
      'dataDir': '${tmp.path}/sdk',
      'indexDir': '${tmp.path}/index',
      'ownerToken': 'native-test',
      'mnemonic': AnyShim.newMnemonic(),
      'deviceKeyHex': AnyShim.newDeviceKey(),
      'nodeConfYaml': deadNodeConf(),
      'p2p': {'enabled': false},
    });
    addTearDown(() {
      try {
        waitOp(a.closeStart());
      } on AnyShimException catch (e) {
        if (e.status != AnyShimStatus.closed) rethrow;
      }
    });
    return a;
  }

  group('process-wide', skip: skip, () {
    test('version names ABI 2 and the pinned SDK', () {
      final v = AnyShim.version();
      expect(v['abi'], 2);
      expect(
        (v['modules'] as Map)['github.com/anyproto/any-sync-sdk'],
        'v0.7.4',
      );
    });

    test('the production network is refused', () {
      final prod = deadNodeConf().replaceFirst(
        'N4N1wDHFpFpovXBqdbq2TDXE9tXdXbtV1eTJFpKJW4YeaJqR',
        'N83gJpVd9MuNRZAuJLZ7LiMntTThhPc6DtzWWVjb1M3PouVU',
      );
      expect(
        () => openAccountNow({
          'dataDir': '${tmp.path}/sdk',
          'indexDir': '${tmp.path}/index',
          'ownerToken': 't',
          'mnemonic': AnyShim.newMnemonic(),
          'deviceKeyHex': AnyShim.newDeviceKey(),
          'nodeConfYaml': prod,
        }),
        throwsStatus(AnyShimStatus.refused),
      );
    });

    test('a stale handle is closed; release of one is a no-op', () {
      expect(
        () => AnyShimAccount.fromHandle(1 << 50).info(),
        throwsStatus(AnyShimStatus.closed),
      );
      expect(
        () => AnyShimIndex.fromHandle(1 << 50).count(),
        throwsStatus(AnyShimStatus.closed),
      );
      AnyShim.accountRelease(1 << 50);
      AnyShim.indexRelease(1 << 50);
    });

    test('arguments C cannot carry are refused in Dart', () {
      final a = openAccount();
      final space = a.spaceCreate('args')['id']! as String;
      expect(() => a.spaceCreate('a\u0000b'), throwsArgumentError);
      expect(() => a.changesSince(space, -1), throwsA(isA<RangeError>()));
      expect(() => a.syncHeadsStart(space, -1), throwsA(isA<RangeError>()));
    });
  });

  group('account', skip: skip, () {
    test('the same directory under the same token is refused', () {
      openAccount();
      expect(
        () => openAccountNow({
          'dataDir': '${tmp.path}/sdk',
          'indexDir': '${tmp.path}/index2',
          'ownerToken': 'native-test',
          'mnemonic': AnyShim.newMnemonic(),
          'deviceKeyHex': AnyShim.newDeviceKey(),
          'nodeConfYaml': deadNodeConf(),
          'p2p': {'enabled': false},
        }),
        throwsStatus(AnyShimStatus.refused),
      );
    });

    test('bundles, a document, the feed, tombstones', () {
      final a = openAccount();
      final space = a.spaceCreate('notes')['id']! as String;
      waitOp(a.spaceResolveStart(space));
      final status = a.spaceStatus(space);
      expect(status['everPeerSynced'], false);
      final b = a.ragBundles(space, ensure: true);
      final docRoot = (b['document']! as Map)['rootId']! as String;
      final loc = (b['location']! as Map).cast<String, Object?>();
      expect(a.ragBundles(space, ensure: false), b);

      final created = a.objectPatch(
        space,
        {
          'create': {'type': docRoot},
        },
        [
          {'xkey': 'doc', 'value': '{"fmt":1}'},
          {
            'xkey': 'vecs',
            'leaf': 'abc-1',
            'value': {'fmt': 1},
          },
        ],
      );
      expect(created['created'], true);
      final id = created['id']! as String;
      expect(
        () => a.objectPatch(
          space,
          {'id': id},
          [
            {'xkey': 'nosuch', 'value': 1},
          ],
        ),
        throwsStatus(AnyShimStatus.invalidArgument),
      );
      final read = a.objectRead(space, {
        'ids': [id],
        'xkeys': ['doc', 'vecs'],
      });
      final item = (read['items']! as List).single as Map;
      expect(item['typeId'], docRoot);
      expect((item['props'] as Map)['doc'], '{"fmt":1}');
      expect((read['anchor'] as Map)['generation'], isNotEmpty);

      final feed = a.changesSince(space, 0);
      expect(
        (feed['changes']! as List).map((c) => (c as Map)['objectId']),
        contains(id),
      );
      expect(a.objectSyncState(space, id)['state'], isNot('synced'));

      final manifest =
          a.objectPatch(space, {
                'derive': {
                  'seed': 'flutter_edge_ai.rag/manifest/n',
                  'type': loc['rootId'],
                },
              }, const [])['id']!
              as String;
      // H5: the same id without a write.
      expect(
        a.objectDeriveId(
          space,
          'flutter_edge_ai.rag/manifest/n',
          loc['rootId']! as String,
        )['id'],
        manifest,
      );
      a.recordsModify(space, manifest, loc['tombstones']! as String, [
        {
          'id': 'clear',
          'addToSet': {'revs': 7},
        },
      ]);
      final recs = a.recordsRead(space, manifest, loc['tombstones']! as String);
      expect(((recs['records']! as List).single as Map)['revs'], [7]);

      a.objectDelete(space, id);
      a.objectDelete(space, id); // already deleted: OK
      expect(
        () => a.objectDelete(space, manifest),
        throwsStatus(AnyShimStatus.refused),
      );
    });

    test('cancel wakes a poller on another isolate; close ends it', () async {
      final a = openAccount();
      final handle = a.handle;
      final started = ReceivePort();
      final port = started.sendPort;
      final poller = Isolate.run(() {
        final acc = AnyShimAccount.fromHandle(handle);
        port.send(null);
        while (true) {
          try {
            acc.pollEvents(timeoutMs: 250);
          } on AnyShimException catch (e) {
            return e.status.name;
          }
        }
      });
      await started.first;
      waitOp(a.closeStart());
      expect(await poller, 'closed');
    });
  });

  group('index', skip: skip, () {
    test('bind, apply with vector slots and CAS, knn, text, state', () {
      final x = AnyShimIndex.open({
        'path': '${tmp.path}/idx/index.anystore',
        'ownerToken': 'native-test',
      });
      addTearDown(() {
        try {
          closeIndex(x);
        } on AnyShimException {
          // closed by the test
        }
      });
      expect(x.info(), isEmpty);
      final bound = bindIndex(x, {
        'dim': 3,
        'metric': 'cosine',
        'fields': [
          {'key': 'k1-string', 'type': 'string'},
        ],
        'textSearch': true,
      });
      expect(bound['dim'], 3);
      expect(
        () => bindIndex(x, {
          'dim': 4,
          'metric': 'cosine',
          'fields': [],
          'textSearch': true,
        }),
        throwsStatus(AnyShimStatus.conflict),
      );
      x.apply({
        'cas': [
          {'key': 'cursor', 'expect': null},
        ],
        'ops': [
          {
            'op': 'upsert',
            'coll': 'docs',
            'id': 'a',
            'text': 'kerosene and oxygen',
            'meta': null,
            'f': {'k1-string': 'space'},
            'vector': {'offset': 0, 'dim': 3},
          },
          {
            'op': 'upsert',
            'coll': 'docs',
            'id': 'b',
            'text': 'flour and water',
            'meta': '{"m":1}',
            'f': {'k1-string': 'food'},
            'vector': {'offset': 3, 'dim': 3},
          },
          {
            'op': 'upsert',
            'coll': 'docs',
            'id': 'c',
            'text': 'text only row',
            'meta': null,
            'f': {},
            'vector': null,
          },
          {'op': 'stateSet', 'coll': 'state', 'key': 'cursor', 'value': '1'},
        ],
      }, vec([1, 0, 0, 0, 1, 0]));
      expect(x.count(), 3);
      expect(x.countVectors(), 2);
      expect(
        () => x.apply({
          'cas': [
            {'key': 'cursor', 'expect': null},
          ],
          'ops': [
            {'op': 'delete', 'coll': 'docs', 'id': 'a'},
          ],
        }, Float32List(0)),
        throwsStatus(AnyShimStatus.conflict),
      );
      expect(
        () => x.apply({
          'ops': [
            {
              'op': 'upsert',
              'coll': 'docs',
              'id': 'd',
              'text': '',
              'meta': null,
              'f': {},
              'vector': {'offset': 0, 'dim': 3},
            },
          ],
        }, vec([double.nan, 0, 0])),
        throwsStatus(AnyShimStatus.invalidArgument),
      );
      List<Object?> ids(Map<String, Object?> r) =>
          (r['results']! as List).map((m) => (m as Map)['id']).toList();
      expect(ids(x.knn(vec([1, 0, 0]), 5)), ['a', 'b']);
      expect(
        ids(
          x.knn(
            vec([1, 0, 0]),
            5,
            filter: {
              'f.k1-string': {r'$eq': 'food'},
            },
          ),
        ),
        ['b'],
      );
      expect(ids(x.text('"kerosene"', 5)), ['a']);
      expect(x.get('state', 'cursor'), {'key': 'cursor', 'value': '1'});
      expect(x.get('state', 'nosuch'), isNull);
      expect((x.get('docs', 'b')! as Map)['meta'], '{"m":1}');
      final scan = x.scan('state', prefix: 'cur');
      expect((scan['items']! as List), hasLength(1));
      // H4: a swap leaves an orphan that gc drops in bounded rounds.
      x.apply({
        'ops': [
          {'op': 'shadowBegin'},
          {'op': 'shadowSwap'},
        ],
      }, Float32List(0));
      var done = false;
      for (var i = 0; i < 100 && !done; i++) {
        done = x.gc(100)['done'] == true;
      }
      expect(done, isTrue);
      closeIndex(x);
      expect(() => x.count(), throwsStatus(AnyShimStatus.closed));
    });

    test('the keycheck tells another key from a corrupt file', () {
      final path = '${tmp.path}/k/index.anystore';
      final key = 'ab' * 32;
      closeIndex(
        AnyShimIndex.open({'path': path, 'keyHex': key, 'ownerToken': 't'}),
      );
      expect(
        () => AnyShimIndex.open({'path': path, 'ownerToken': 't'}),
        throwsStatus(AnyShimStatus.keyMissing),
      );
      expect(
        () => AnyShimIndex.open({
          'path': path,
          'keyHex': 'cd' * 32,
          'ownerToken': 't',
        }),
        throwsStatus(AnyShimStatus.keyMismatch),
      );
      closeIndex(
        AnyShimIndex.open({'path': path, 'keyHex': key, 'ownerToken': 't'}),
      );
    });
  });
}

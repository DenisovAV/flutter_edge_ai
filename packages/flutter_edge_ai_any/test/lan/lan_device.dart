// One device of the two-device LAN test (lan_sync_test.dart starts two of
// these as separate processes). Both open the same TEST account, with their
// own device keys and data dirs, a nodeconf whose nodes are all on a closed
// port and a random mDNS service type, so they sync over LAN p2p only and
// nothing else on the network can pair with them.
//
//   dart run test/lan/lan_device.dart a <dir> <n>   creates the space and n
//       documents (+ a file on the first), then waits for <dir>/stop,
//       reporting the document B writes back
//   dart run test/lan/lan_device.dart b <dir> <n>   pulls the space, indexes
//       every document into a local index through the change feed, searches
//       it, fetches the file from A, writes one document back, exits
//
// Every stdout line is one JSON event; the last one of B is {"ev":"result"}.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_edge_ai_any/src/ffi/any_shim.dart';

final _sw = Stopwatch()..start();

void log(String ev, [Map<String, Object?> f = const {}]) =>
    stdout.writeln(jsonEncode({'t': _sw.elapsedMilliseconds, 'ev': ev, ...f}));

/// A deterministic stand-in for an embedder: hashed character trigrams,
/// L2-normalised. Not semantic; enough to check the plumbing.
const dim = 64;
Float32List embed(String text) {
  final v = Float32List(dim);
  final s = ' ${text.toLowerCase()} ';
  for (var i = 0; i + 3 <= s.length; i++) {
    var h = 2166136261;
    for (final c in s.substring(i, i + 3).codeUnits) {
      h = ((h ^ c) * 16777619) & 0xffffffff;
    }
    v[h % dim] += (h >> 16).isEven ? 1 : -1;
  }
  var n = 0.0;
  for (final x in v) {
    n += x * x;
  }
  n = sqrt(n);
  for (var i = 0; i < dim && n > 0; i++) {
    v[i] /= n;
  }
  return v;
}

const corpus = [
  (
    'Rocket engines',
    'Liquid rocket engines burn kerosene with liquid oxygen.',
    'space',
  ),
  ('Sourdough', 'A sourdough starter is a culture of wild yeast.', 'food'),
  ('Tide pools', 'Tide pools hold anemones, crabs and sea stars.', 'nature'),
  (
    'Espresso',
    'Espresso forces hot water through finely ground coffee.',
    'food',
  ),
  ('Mars rover', 'The Mars rover drills rock samples for return.', 'space'),
  ('Beekeeping', 'Honey bees store nectar in wax cells.', 'nature'),
];

List<int> filePayload() => List.generate(64 * 1024, (i) => (i * 31) & 0xff);

AnyShimAccount openDevice(String dir, String who) {
  final acc = jsonDecode(File('$dir/account.json').readAsStringSync()) as Map;
  return AnyShimAccount.open({
    'dataDir': '$dir/$who',
    'mnemonic': acc['mnemonic'],
    'deviceKeyHex': acc['device_$who'],
    'nodeConfYaml': acc['nodeConfYaml'],
    'p2p': {'serviceName': acc['serviceName']},
    'logLevel': Platform.environment['ANY_SHIM_LOG'] ?? 'error',
  });
}

bool waitUntil(
  Duration max,
  bool Function() f, {
  Duration every = const Duration(milliseconds: 100),
}) {
  final end = DateTime.now().add(max);
  while (DateTime.now().isBefore(end)) {
    if (f()) return true;
    sleep(every);
  }
  return false;
}

void main(List<String> args) {
  AnyShim.checkAbi();
  final role = args[0], dir = args[1], n = int.parse(args[2]);
  try {
    role == 'a' ? runA(dir, n) : runB(dir, n);
  } catch (e, st) {
    log('error', {'error': '$e', 'stack': '$st'});
    exit(1);
  }
  exit(0);
}

void runA(String dir, int n) {
  final a = openDevice(dir, 'a');
  final space = a.createSpace('flutter_edge_ai LAN test');
  for (var i = 0; i < n; i++) {
    final (name, text, cat) = corpus[i % corpus.length];
    final id =
        a.putObject(space, {
              'seed': 'doc-$i',
              'name': name,
              'text': text,
              'meta': {'cat': cat, 'i': i, 'from': 'a'},
            })['id']!
            as String;
    if (i == 0) {
      final f = File('$dir/payload.bin')..writeAsBytesSync(filePayload());
      a.attachFile(space, id, f.path, name: 'payload.bin');
    }
  }
  final watch = a.watchChanges(space);
  File('$dir/space_id').writeAsStringSync(space);
  log('a_ready', {'space': space, 'peerId': a.info()['peerId']});

  var gotB = false;
  while (!File('$dir/stop').existsSync()) {
    for (final ev in a.pollEvents(timeout: const Duration(milliseconds: 200))) {
      if (gotB || ev['kind'] != 'change' || ev['watch'] != watch) continue;
      try {
        final d = a.getObject(space, ev['objectId']! as String);
        if ((d['meta'] as String?)?.contains('"from":"b"') ?? false) {
          gotB = true;
          log('a_got_b_doc', {'name': d['name']});
        }
      } on AnyShimException {
        // Not materialised yet; a later event names it again.
      }
    }
  }
  log('a_done', {'gotB': gotB});
  a.close();
}

void runB(String dir, int n) {
  final space = File('$dir/space_id').readAsStringSync();
  final b = openDevice(dir, 'b');
  final t0 = _sw.elapsedMilliseconds;
  final learned = waitUntil(
    const Duration(seconds: 150),
    () => (b.listSpaces(sync: true)['spaces']! as List).any(
      (s) => (s as Map)['id'] == space,
    ),
    every: const Duration(milliseconds: 250),
  );
  log('b_learned_space', {'ok': learned, 'ms': _sw.elapsedMilliseconds - t0});
  if (!learned) throw StateError('B never learned the space over LAN');

  // The first open of a space can wait for the SDK's 60 s re-handshake
  // (seen in 2 of 11 spike runs); logged so a slow run says why.
  final tOpen = _sw.elapsedMilliseconds;
  final watch = b.watchChanges(space);
  log('b_opened_space', {'ms': _sw.elapsedMilliseconds - tOpen});
  final index = AnyShimIndex.open({
    'path': '$dir/b_index.db',
    'dim': dim,
    'filterFields': ['cat'],
  });
  var cursor = int.parse(index.getState('cursor') ?? '0');
  // id -> whether its metadata had arrived when it was last indexed. An
  // object's body and its properties can arrive in separate changes; each
  // shows up in the feed again, so the follower simply re-indexes it.
  final complete = <String, bool>{};

  // The follower: replay the durable feed from the cursor; events only
  // wake it up, so a dropped one costs nothing.
  void follow() {
    final feed = b.changesSince(space, cursor);
    for (final c in (feed['changes']! as List).cast<Map>()) {
      final id = c['objectId']! as String;
      if (c['deleted'] == true) {
        index.delete(id);
        complete.remove(id);
      } else {
        try {
          final d = b.getObject(space, id);
          if (d['isDocument'] == true) {
            final meta = d['meta'] == null
                ? null
                : jsonDecode(d['meta']! as String);
            index.upsert({
              'id': id,
              'name': d['name'],
              'text': d['text'],
              'meta': meta,
            }, embed('${d['name']} ${d['text']}'));
            complete[id] = meta != null;
          }
        } on AnyShimException catch (e) {
          if (e.status != AnyShimStatus.notFound) rethrow;
        }
      }
      cursor = c['applySeq']! as int;
    }
    index.setState('cursor', '$cursor');
  }

  final t1 = _sw.elapsedMilliseconds;
  final indexed = waitUntil(const Duration(seconds: 150), () {
    b.pollEvents(timeout: const Duration(milliseconds: 200));
    follow();
    return complete.length >= n && complete.values.every((ok) => ok);
  }, every: Duration.zero);
  log('b_indexed', {
    'ok': indexed,
    'count': index.count(),
    'ms': _sw.elapsedMilliseconds - t1,
  });

  List<Object?> ids(Map<String, Object?> r) =>
      (r['results']! as List).map((m) => (m as Map)['name']).toList();
  final knnTop = ids(
    index.knn(
      embed(
        'Rocket engines Liquid rocket engines burn kerosene with liquid oxygen.',
      ),
      1,
    ),
  );
  final textHit = ids(index.text('sourdough', 3));
  final food = ids(
    index.knn(embed('coffee'), 10, filter: {'meta.cat': 'food'}),
  );

  final tFiles = _sw.elapsedMilliseconds;
  final files = b.listFiles(space);
  var fileOk = false;
  if (files.isNotEmpty) {
    final out = '$dir/b_payload.bin';
    b.readFile(
      space,
      files.first['fileId']! as String,
      out,
      timeout: const Duration(seconds: 60),
    );
    final got = File(out).readAsBytesSync();
    final want = filePayload();
    fileOk =
        got.length == want.length &&
        List.generate(want.length, (i) => got[i] == want[i]).every((x) => x);
  }

  log('b_file', {'ok': fileOk, 'ms': _sw.elapsedMilliseconds - tFiles});
  b.putObject(space, {
    'name': 'From B',
    'text': 'written on device B',
    'meta': {'from': 'b'},
  });
  // Give A a moment to receive it before B's process goes away.
  sleep(const Duration(seconds: 3));
  b.unwatch(watch);
  log('result', {
    'learned': learned,
    'indexed': indexed,
    'count': index.count(),
    'knnTop': knnTop,
    'textHit': textHit,
    'food': food,
    'files': files.length,
    'fileOk': fileOk,
  });
  index.close();
  b.close();
}

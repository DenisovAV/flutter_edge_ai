// Two processes, two devices of one TEST account, LAN p2p only (mDNS +
// QUIC on this machine), no node reachable. Tagged `lan`: dart_test.yaml
// skips it by default because it needs local multicast and up to a few
// minutes (a first open can wait ~60 s for the SDK's re-handshake). Run:
//
//   dart test -t lan --run-skipped
@Tags(['lan'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_edge_ai_any/src/ffi/any_shim.dart';
import 'package:test/test.dart';

import '../support/native_library.dart';

Future<Process> _device(String role, String dir, int n) => Process.start(
  Platform.resolvedExecutable,
  ['run', 'test/lan/lan_device.dart', role, dir, '$n'],
);

Future<List<Map<String, Object?>>> _lines(Stream<List<int>> s, IOSink log) => s
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .map((l) {
      log.writeln(l);
      return l;
    })
    .where((l) => l.startsWith('{'))
    .map((l) => (jsonDecode(l) as Map).cast<String, Object?>())
    .toList();

void main() {
  final skip = nativeSkipReason();

  test(
    'a space syncs from A to B over LAN, and B indexes it',
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
    () async {
      AnyShim.checkAbi();
      const n = 6;
      final dir = Directory.systemTemp.createTempSync('any_shim_lan').path;
      var passed = false;
      // Registered first, so it runs last (tear-downs run in reverse):
      // after the devices are gone. A failed run keeps its logs.
      addTearDown(() {
        if (passed) Directory(dir).deleteSync(recursive: true);
      });
      File('$dir/account.json').writeAsStringSync(
        jsonEncode({
          'note': 'TEST account, dead nodeconf, LAN only',
          'mnemonic': AnyShim.newMnemonic(),
          'device_a': AnyShim.newDeviceKey(),
          'device_b': AnyShim.newDeviceKey(),
          'serviceName':
              '_fea${Random.secure().nextInt(1 << 30).toRadixString(16)}._tcp',
          'nodeConfYaml': deadNodeConf(),
        }),
      );
      final aLog = File('$dir/a.log').openWrite();
      final bLog = File('$dir/b.log').openWrite();
      final processes = <Process>[];
      final drains = <Future<void>>[];
      // Runs on success and failure alike: no device outlives the test
      // (A would otherwise wait for its stop file forever, LAN ports open),
      // and both logs are fully written before they are closed.
      addTearDown(() async {
        File('$dir/stop').writeAsStringSync('');
        for (final p in processes) {
          p.kill();
          await p.exitCode;
        }
        await Future.wait(drains).timeout(const Duration(seconds: 10));
        await aLog.close();
        await bLog.close();
      });

      final a = await _device('a', dir, n);
      processes.add(a);
      final aOut = _lines(a.stdout, aLog);
      drains.add(a.stderr.forEach(aLog.add));
      // B starts once A has written its space, so the two `dart run`s do
      // not run the build hook at the same time.
      final end = DateTime.now().add(const Duration(minutes: 2));
      while (!File('$dir/space_id').existsSync()) {
        if (DateTime.now().isAfter(end)) {
          fail('A never created its space; see $dir/a.log');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final b = await _device('b', dir, n);
      processes.add(b);
      final bOut = _lines(b.stdout, bLog);
      drains.add(b.stderr.forEach(bLog.add));

      final bCode = await b.exitCode;
      File('$dir/stop').writeAsStringSync('');
      final aCode = await a.exitCode.timeout(const Duration(seconds: 30));
      final bEvents = await bOut;
      final aEvents = await aOut;
      drains.addAll([aOut, bOut]);
      printOnFailure('logs: $dir');

      expect(bCode, 0, reason: 'B failed; see $dir/b.log');
      expect(aCode, 0, reason: 'A failed; see $dir/a.log');
      final result = bEvents.lastWhere((e) => e['ev'] == 'result');
      expect(result['learned'], true);
      expect(result['indexed'], true);
      expect(result['count'], n);
      expect(result['knnTop'], ['Rocket engines']);
      expect(result['textHit'], ['Sourdough']);
      expect((result['food']! as List).toSet(), {'Sourdough', 'Espresso'});
      expect(result['fileOk'], true, reason: 'the file fetched from A differs');
      final aDone = aEvents.lastWhere((e) => e['ev'] == 'a_done');
      expect(aDone['gotB'], true, reason: "B's document never reached A");
      final learned = bEvents.firstWhere((e) => e['ev'] == 'b_learned_space');
      final indexed = bEvents.firstWhere((e) => e['ev'] == 'b_indexed');
      print(
        'learned the space in ${learned['ms']} ms, indexed $n docs in ${indexed['ms']} ms',
      );
      for (final e in [...aEvents, ...bEvents]) {
        print(jsonEncode(e));
      }
      passed = true;
    },
  );
}

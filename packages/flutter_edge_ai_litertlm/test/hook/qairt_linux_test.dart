import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai_litertlm/src/hook/qairt_linux.dart';
import 'package:flutter_edge_ai_litertlm/src/hook/qnn_runtime.dart';
import 'package:flutter_edge_ai_litertlm/src/npu_stacks.dart';
import 'package:flutter_test/flutter_test.dart';

import 'zip_fixture.dart';

/// Distinct bytes per file, so a mix-up between two entries shows.
Map<String, Uint8List> _libs() => {
  for (final f in qairtLinuxFileNames)
    f: Uint8List.fromList(utf8.encode('elf:$f')),
};

Map<String, String> _pinsOf(Map<String, Uint8List> libs) => {
  for (final e in libs.entries) e.key: sha256.convert(e.value).toString(),
};

/// A QAIRT-shaped zip: every library at its SDK path, the notices, and some
/// of the 12 000 entries the stack does not take.
Uint8List _fakeQairt(Map<String, Uint8List> libs) => buildZip({
  for (final e in libs.entries) qairtEntryPath(e.key): e.value,
  for (final f in qairtNoticeFiles) qairtEntryPath(f): utf8.encode('n:$f'),
  'qairt/$qairtBuild/lib/aarch64-oe-linux-gcc11.2/libQnnHtpPrepare.so': [1, 2],
  'qairt/$qairtBuild/lib/aarch64-android/libQnnHtp.so': [3, 4],
});

/// Serves [archive] the way Qualcomm's gateway does: a redirect at `/start`,
/// byte ranges at `/file`. [override] can answer a request instead.
Future<({HttpServer server, List<String> log})> _serve(
  Uint8List archive, {
  int? reportedTotal,
  bool Function(HttpRequest request, int hit)? override,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final log = <String>[];
  var hits = 0;
  server.listen((request) async {
    hits++;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    log.add('${request.uri.path} $range');
    if (override != null && override(request, hits)) return;
    final res = request.response;
    if (request.uri.path == '/start') {
      res
        ..statusCode = HttpStatus.found
        ..headers.set(HttpHeaders.locationHeader, '/file');
      await res.close();
      return;
    }
    final m = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
    if (m == null) {
      res.statusCode = HttpStatus.ok;
      res.add(archive);
      await res.close();
      return;
    }
    final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
    res
      ..statusCode = HttpStatus.partialContent
      ..headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $a-$b/${reportedTotal ?? archive.length}',
      )
      ..add(Uint8List.sublistView(archive, a, b + 1));
    await res.close();
  });
  return (server: server, log: log);
}

Uri _url(HttpServer s, String path) =>
    Uri.parse('http://${s.address.address}:${s.port}$path');

void main() {
  test('the Linux build is the release the Android runtime pins', () {
    // The dispatch is built against one QAIRT release; both platforms' QNN
    // runtimes must be that release, or one of them fails on hardware.
    expect(qairtBuild, startsWith('$qnnRuntimeVersion.'));
  });

  test('every Linux library has a pin, and nothing else does', () {
    expect(qairtLinuxSha256.keys.toSet(), qairtLinuxFileNames.toSet());
    for (final h in qairtLinuxSha256.values) {
      expect(h, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });

  test('the stack is our two libraries plus the QNN runtime', () {
    expect(qualcommNpuLibsFor('linux'), [
      qualcommDispatchLib,
      cdsprpcShimLib,
      ...qairtLinuxLibs,
    ]);
    expect(qualcommNpuLibsFor('android'), qualcommNpuLibs);
    expect(qualcommNpuLibsFor('macos'), isEmpty);
    // Every Stub needs its Skel: a Stub alone opens a session to nothing.
    for (final lib in qairtLinuxLibs.where((l) => l.endsWith('Stub'))) {
      expect(qairtLinuxLibs, contains(lib.replaceFirst('Stub', 'Skel')));
    }
  });

  test('SDK paths: OpenEmbedded host libraries, unsigned Hexagon Skels', () {
    expect(
      qairtEntryPath('libQnnHtpV75Stub.so'),
      'qairt/$qairtBuild/lib/aarch64-oe-linux-gcc11.2/libQnnHtpV75Stub.so',
    );
    expect(
      qairtEntryPath('libQnnHtpV75Skel.so'),
      'qairt/$qairtBuild/lib/hexagon-v75/unsigned/libQnnHtpV75Skel.so',
    );
    expect(qairtEntryPath('LICENSE.pdf'), 'qairt/$qairtBuild/LICENSE.pdf');
  });

  group('qairtFilesFrom', () {
    test('returns every library and the notices', () {
      final libs = _libs();
      final entries = extractZipEntries(_fakeQairt(libs), qairtEntryPaths);
      final files = qairtFilesFrom(entries, pins: _pinsOf(libs));
      expect(files.libraries.keys.toSet(), qairtLinuxFileNames.toSet());
      expect(
        files.libraries['libQnnHtpV81Skel.so'],
        libs['libQnnHtpV81Skel.so'],
      );
      expect(files.notices.keys.toSet(), qairtNoticeFiles.toSet());
    });

    test('a library that is not the pinned one fails the build', () {
      final libs = _libs();
      final pins = _pinsOf(libs)..['libQnnHtpV73Skel.so'] = '0' * 64;
      final entries = extractZipEntries(_fakeQairt(libs), qairtEntryPaths);
      expect(
        () => qairtFilesFrom(entries, pins: pins),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('libQnnHtpV73Skel.so'),
          ),
        ),
      );
    });

    test('the real pins refuse other bytes', () {
      final entries = extractZipEntries(_fakeQairt(_libs()), qairtEntryPaths);
      expect(() => qairtFilesFrom(entries), throwsStateError);
    });

    test('a local zip of the wrong size is refused before reading', () {
      final dir = Directory.systemTemp.createTempSync('qairt');
      addTearDown(() => dir.deleteSync(recursive: true));
      final zip = File('${dir.path}/v$qairtBuild.zip')
        ..writeAsBytesSync(_fakeQairt(_libs()));
      expect(
        () => qairtFilesFromZip(zip),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('$qairtZipLength'),
          ),
        ),
      );
    });
  });

  group('extractZipEntriesAsync', () {
    test('reads the same bytes as the sync reader, in parallel', () async {
      final archive = _fakeQairt(_libs());
      var inFlight = 0, peak = 0;
      final got = await extractZipEntriesAsync(
        (o, n) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(Duration.zero);
          inFlight--;
          return Uint8List.sublistView(archive, o, o + n);
        },
        archive.length,
        qairtEntryPaths,
      );
      final want = extractZipEntries(archive, qairtEntryPaths);
      expect(got.keys.toSet(), want.keys.toSet());
      for (final k in want.keys) {
        expect(got[k], want[k], reason: k);
      }
      expect(peak, greaterThan(1), reason: 'entries are independent reads');
      expect(peak, lessThanOrEqualTo(4));
    });

    test('a missing entry fails before any entry is read', () async {
      final archive = buildZip({
        'a': [1],
      });
      var reads = 0;
      await expectLater(
        extractZipEntriesAsync(
          (o, n) async {
            reads++;
            return Uint8List.sublistView(archive, o, o + n);
          },
          archive.length,
          {'a', 'b'},
        ),
        throwsFormatException,
      );
      expect(reads, 2, reason: 'the tail and the central directory only');
    });
  });

  group('httpRangeReader', () {
    test('follows the redirect once, then reads ranges directly', () async {
      final libs = _libs();
      final archive = _fakeQairt(libs);
      final s = await _serve(archive);
      addTearDown(() => s.server.close(force: true));

      final read = httpRangeReader(
        _url(s.server, '/start'),
        expectedLength: archive.length,
        backoff: Duration.zero,
      );
      final files = qairtFilesFrom(
        await extractZipEntriesAsync(read, archive.length, qairtEntryPaths),
        pins: _pinsOf(libs),
      );
      expect(files.libraries, hasLength(qairtLinuxFileNames.length));
      expect(s.log.where((l) => l.startsWith('/start')), hasLength(1));
      expect(
        s.log.every((l) => l.contains('bytes=')),
        isTrue,
        reason: 'every request, the redirected one too, carries the range',
      );
    });

    test('a server that ignores the range is refused, not read', () async {
      final archive = buildZip({'a': List.filled(1000, 1)});
      final s = await _serve(
        archive,
        override: (req, _) {
          req.response
            ..statusCode = HttpStatus.ok
            ..add(archive)
            ..close();
          return true;
        },
      );
      addTearDown(() => s.server.close(force: true));
      final read = httpRangeReader(
        _url(s.server, '/file'),
        expectedLength: archive.length,
        backoff: Duration.zero,
      );
      await expectLater(
        read(0, 10),
        throwsA(
          isA<HttpException>().having(
            (e) => e.message,
            'message',
            contains('does not serve byte ranges'),
          ),
        ),
      );
      expect(s.log, hasLength(1), reason: 'not a transient failure');
    });

    test('a file of another size is refused', () async {
      final archive = buildZip({'a': List.filled(1000, 1)});
      final s = await _serve(archive, reportedTotal: archive.length + 1);
      addTearDown(() => s.server.close(force: true));
      final read = httpRangeReader(
        _url(s.server, '/file'),
        expectedLength: archive.length,
        backoff: Duration.zero,
      );
      await expectLater(
        read(0, 10),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('a different file'),
          ),
        ),
      );
    });

    test('a 503 is retried', () async {
      final archive = buildZip({'a': List.filled(1000, 1)});
      final s = await _serve(
        archive,
        override: (req, hit) {
          if (hit > 1) return false;
          req.response
            ..statusCode = HttpStatus.serviceUnavailable
            ..close();
          return true;
        },
      );
      addTearDown(() => s.server.close(force: true));
      final read = httpRangeReader(
        _url(s.server, '/file'),
        expectedLength: archive.length,
        backoff: Duration.zero,
      );
      expect(await read(5, 10), Uint8List.sublistView(archive, 5, 15));
      expect(s.log, hasLength(2));
    });

    test('a range outside the file is a caller bug', () {
      final read = httpRangeReader(
        Uri.parse('http://127.0.0.1:9/'),
        expectedLength: 100,
      );
      expect(() => read(95, 10), throwsRangeError);
    });
  });

  test('the Linux cache entry holds exactly the Linux libraries', () {
    final root = Directory.systemTemp.createTempSync('qnn-linux');
    addTearDown(() => root.deleteSync(recursive: true));
    final libs = _libs();
    final entry = writeQnnCacheEntry(
      root,
      qairtCacheEntryName(),
      qairtLinuxFileNames,
      () => libs,
      () => {'LICENSE.pdf': Uint8List.fromList(utf8.encode('%PDF'))},
    );
    expect(isCompleteQnnCache(entry, fileNames: qairtLinuxFileNames), isTrue);
    expect(File('${entry.path}/LICENSE.pdf').existsSync(), isTrue);
    // A second build reuses the entry without asking for the bytes again.
    final again = writeQnnCacheEntry(
      root,
      qairtCacheEntryName(),
      qairtLinuxFileNames,
      () => throw StateError('refetched'),
      () => throw StateError('refetched'),
    );
    expect(again.path, entry.path);
  });
}

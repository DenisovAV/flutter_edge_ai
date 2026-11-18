import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai_onnx/src/hook/archive_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late File dest;
  final good = utf8.encode('the pinned archive');
  final goodSha = sha256.convert(good).toString();
  final official = Uri.parse('https://github.com/microsoft/onnxruntime/a.tgz');
  final mirror = Uri.parse(
    'https://github.com/DenisovAV/flutter_edge_ai/a.tgz',
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('archive_sources_test');
    dest = File('${tmp.path}/a.tgz');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A fetcher serving [bodies] by URL; a URL that is absent answers 404.
  ArchiveFetch serving(Map<Uri, List<int>> bodies, List<Uri> asked) =>
      (url, file, log) async {
        asked.add(url);
        final body = bodies[url];
        if (body == null) {
          log('download failed (HTTP 404) for $url');
          return false;
        }
        file.writeAsBytesSync(body);
        return true;
      };

  test('an unavailable official URL falls through to the mirror', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({mirror: good}, asked),
      log: (_) {},
    );
    expect(result.ok, isTrue);
    expect(result.source, mirror);
    expect(asked, [official, mirror]);
    expect(dest.readAsBytesSync(), good);
  });

  test('the first source that serves the pinned bytes wins', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({official: good, mirror: good}, asked),
      log: (_) {},
    );
    expect(result.source, official);
    expect(asked, [official]);
  });

  test('different bytes are an error, and no later source is tried', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({official: utf8.encode('tampered'), mirror: good}, asked),
      log: (_) {},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('CHECKSUM MISMATCH'));
    expect(result.error, contains('$official'));
    expect(asked, [official]);
    expect(dest.existsSync(), isFalse);
  });

  test('no source serving the file names every source tried', () async {
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({}, []),
      log: (_) {},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('$official'));
    expect(result.error, contains('$mirror'));
    expect(dest.existsSync(), isFalse);
  });

  test('an empty source list is an error', () async {
    final result = await fetchPinnedArchive(
      sources: const [],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({}, []),
      log: (_) {},
    );
    expect(result.ok, isFalse);
  });

  group('httpArchiveFetch', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        switch (request.uri.path) {
          case '/a.tgz':
            request.response.add(good);
          case '/cut.tgz':
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.add(
              utf8.encode(
                'HTTP/1.1 200 OK\r\n'
                'Content-Length: ${good.length * 10}\r\n\r\n',
              ),
            );
            socket.add(good);
            await socket.flush();
            socket.destroy();
            return;
          case '/moved.tgz':
            request.response
              ..statusCode = HttpStatus.found
              ..headers.set(HttpHeaders.locationHeader, '/a.tgz');
          default:
            request.response.statusCode = HttpStatus.notFound;
        }
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('200 writes the body', () async {
      expect(
        await httpArchiveFetch(base.resolve('/a.tgz'), dest, (_) {}),
        isTrue,
      );
      expect(dest.readAsBytesSync(), good);
    });

    test('a redirect is followed', () async {
      expect(
        await httpArchiveFetch(base.resolve('/moved.tgz'), dest, (_) {}),
        isTrue,
      );
      expect(dest.readAsBytesSync(), good);
    });

    test('404 is an unavailable source, and no file is left', () async {
      final log = <String>[];
      expect(
        await httpArchiveFetch(base.resolve('/gone.tgz'), dest, log.add),
        isFalse,
      );
      expect(dest.existsSync(), isFalse);
      expect(log.single, contains('HTTP 404'));
    });

    test('a body cut short is an unavailable source, no file left', () async {
      final log = <String>[];
      expect(
        await httpArchiveFetch(base.resolve('/cut.tgz'), dest, log.add),
        isFalse,
      );
      expect(dest.existsSync(), isFalse);
      expect(log.single, contains('interrupted'));
    });

    test('a refused connection is an unavailable source', () async {
      final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = closed.port;
      await closed.close();
      expect(
        await httpArchiveFetch(
          Uri.parse('http://127.0.0.1:$port/a.tgz'),
          dest,
          (_) {},
        ),
        isFalse,
      );
    });

    test('a local write failure is thrown, not blamed on the source', () async {
      final unwritable = File('${tmp.path}/missing/dir/a.tgz');
      await expectLater(
        httpArchiveFetch(base.resolve('/a.tgz'), unwritable, (_) {}),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test(
    'every Microsoft archive in the hook is mirrored under its own name',
    () {
      // The hook lists Microsoft's release URL and, right after it, the same
      // file on this repository's mirror release; a URL list that names
      // Microsoft without the mirror would break with the next 404.
      final hook = File('hook/build.dart').readAsStringSync();
      final joined = hook.replaceAll(RegExp(r"'\s*\n\s*'"), '');
      final official = RegExp(
        r"https://github\.com/microsoft/(onnxruntime(?:-genai)?)/releases/"
        r"download/v([0-9.]+)/([^']+)'",
      ).allMatches(joined).toList();
      expect(official, isNotEmpty);
      for (final m in official) {
        final mirror =
            'https://github.com/DenisovAV/flutter_edge_ai/releases/download/'
            'mirror-${m[1]}-v${m[2]}/${m[3]}';
        final next = joined.substring(m.end, m.end + mirror.length + 40);
        expect(next, contains(mirror), reason: 'no mirror after ${m[3]}');
      }
    },
  );
}

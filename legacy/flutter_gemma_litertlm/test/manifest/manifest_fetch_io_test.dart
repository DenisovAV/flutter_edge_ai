// The dart:io default fetch against a loopback HttpServer: the status is read
// before the body (so a 404 whose body is not UTF-8 still reports 404), any
// 2xx is success (as on web), redirects are followed, headers go out verbatim,
// and a transport failure is a status-less ManifestFetchException.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_gemma_litertlm/src/manifest/manifest_fetch_io.dart';
import 'package:flutter_gemma_litertlm/src/manifest/manifest_fetch_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bytes no UTF-8 decoder accepts strictly: a lone continuation byte and an
/// unpaired lead byte around plain ASCII.
const _notUtf8 = [0x80, 0x7B, 0xC3, 0x7D];

void main() {
  late HttpServer server;
  late Uri base;
  HttpHeaders? lastRequestHeaders;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://${server.address.host}:${server.port}');
    lastRequestHeaders = null;
    server.listen((req) async {
      lastRequestHeaders = req.headers;
      final res = req.response;
      switch (req.uri.path) {
        case '/404-bad-bytes':
          res.statusCode = 404;
          res.add(_notUtf8);
        case '/500-bad-bytes':
          res.statusCode = 500;
          res.add(_notUtf8);
        case '/201':
          res.statusCode = 201;
          res.write('{"created":true}');
        case '/204':
          res.statusCode = 204;
        case '/307':
          res.statusCode = 307;
          res.headers.set('location', base.resolve('/ok').toString());
        case '/307-to-404':
          res.statusCode = 307;
          res.headers.set(
            'location',
            base.resolve('/404-bad-bytes').toString(),
          );
        case '/200-bad-bytes':
          res.statusCode = 200;
          res.add(_notUtf8);
        default:
          res.statusCode = 200;
          res.write('{"ok":true}');
      }
      await res.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('a non-2xx whose body is not UTF-8 still carries its status', () async {
    for (final (path, status) in [
      ('/404-bad-bytes', 404),
      ('/500-bad-bytes', 500),
    ]) {
      await expectLater(
        defaultManifestFetch(base.resolve(path), const {}),
        throwsA(
          isA<ManifestFetchException>()
              .having((e) => e.statusCode, 'statusCode', status)
              .having((e) => e.url.path, 'url', path),
        ),
        reason: path,
      );
    }
  });

  test('any 2xx is success, as on web', () async {
    expect(
      await defaultManifestFetch(base.resolve('/ok'), const {}),
      '{"ok":true}',
    );
    expect(
      await defaultManifestFetch(base.resolve('/201'), const {}),
      '{"created":true}',
    );
    expect(await defaultManifestFetch(base.resolve('/204'), const {}), '');
  });

  test(
    'a redirect is followed (Hugging Face 307s /resolve/ to its CDN)',
    () async {
      expect(
        await defaultManifestFetch(base.resolve('/307'), const {}),
        '{"ok":true}',
      );
    },
  );

  test('a redirect that lands on an error reports the final status', () async {
    await expectLater(
      defaultManifestFetch(base.resolve('/307-to-404'), const {}),
      throwsA(
        isA<ManifestFetchException>().having(
          (e) => e.statusCode,
          'statusCode',
          404,
        ),
      ),
    );
  });

  test('headers go out verbatim', () async {
    await defaultManifestFetch(base.resolve('/ok'), {
      'Authorization': 'Bearer hf_secret',
    });
    expect(lastRequestHeaders?.value('authorization'), 'Bearer hf_secret');
  });

  test('a 2xx body that is not UTF-8 decodes with replacement, like the '
      "browser's Response.text()", () async {
    final body = await defaultManifestFetch(
      base.resolve('/200-bad-bytes'),
      const {},
    );
    expect(body, contains('\u{FFFD}'));
    expect(body, contains('{'));
    // Not silently swallowed downstream either: it is not JSON.
    expect(() => jsonDecode(body), throwsFormatException);
  });

  test(
    'a transport failure is a ManifestFetchException without a status',
    () async {
      final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = Uri.parse('http://${closed.address.host}:${closed.port}/x');
      await closed.close(force: true);
      await expectLater(
        defaultManifestFetch(url, const {}),
        throwsA(
          isA<ManifestFetchException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
    },
  );
}

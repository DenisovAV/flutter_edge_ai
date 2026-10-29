// HttpRemoteSizeProbe against a local server: X-Linked-Size wins over
// Content-Length, redirects are followed, and the token goes to the origin
// host only. No TestWidgetsFlutterBinding here: it replaces HttpClient.

import 'dart:io';

import 'package:flutter_edge_ai/src/infrastructure/http_remote_size_probe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String base;
  final authorizations = <String, String?>{};

  setUp(() async {
    authorizations.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final r = request.response;
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      authorizations[request.uri.path] = auth;
      switch (request.uri.path) {
        case '/linked':
          // A Hugging Face resolve/ redirect: the file's size rides on it.
          r
            ..statusCode = 302
            ..headers.set('location', '/cdn/linked')
            ..headers.set('x-linked-size', '123456')
            ..contentLength = 0;
        case '/plain':
          r
            ..statusCode = 307
            ..headers.set('location', '/cdn/plain');
        case '/cdn/plain':
          r.contentLength = 777;
        case '/gated':
          if (auth != 'Bearer hf_secret') {
            r.statusCode = 401;
          } else {
            r.contentLength = 42;
          }
        default:
          r.statusCode = 404;
      }
      await r.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('X-Linked-Size is preferred over Content-Length', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/linked'), 123456);
  });

  test('a redirect without it is followed to the Content-Length', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/plain'), 777);
  });

  test('a gated file needs the token; an error is unknown, not 0', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/gated'), isNull);
    expect(
      await HttpRemoteSizeProbe().sizeOf('$base/gated', token: 'hf_secret'),
      42,
    );
    expect(await HttpRemoteSizeProbe().sizeOf('$base/missing'), isNull);
  });

  test('the token goes to the origin host only', () async {
    await HttpRemoteSizeProbe().sizeOf('$base/plain', token: 'hf_secret');
    expect(authorizations['/plain'], 'Bearer hf_secret');
    // Same host here, so it is sent; a redirect to another host would not
    // carry it (host compared with the origin's).
    expect(authorizations['/cdn/plain'], 'Bearer hf_secret');
  });
}

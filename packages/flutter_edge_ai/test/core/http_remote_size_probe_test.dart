// HttpRemoteSizeProbe against a local server: X-Linked-Size wins over
// Content-Length, redirects are followed, and the token goes to the origin
// host only. No TestWidgetsFlutterBinding here: it replaces HttpClient.

import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/src/infrastructure/http_remote_size_probe.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late HttpServer other;
  late String base;
  final authorizations = <String, String?>{};

  setUp(() async {
    authorizations.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    // Another origin: another host name and port (dual-stack, so
    // `localhost` reaches it over IPv4 or IPv6).
    other = await HttpServer.bind(InternetAddress.anyIPv6, 0);
    other.listen((request) async {
      authorizations['other${request.uri.path}'] = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      request.response.contentLength = 555;
      await request.response.close();
    });
    server.listen((request) async {
      final r = request.response;
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      authorizations[request.uri.path] = auth;
      switch (request.uri.path) {
        case '/linked':
          // The file's size named beside a Content-Length that is not it.
          r
            ..headers.set('x-linked-size', '123456')
            ..contentLength = 99;
        case '/linked-redirect':
          // A size on a redirect does not count: the answer that does is
          // the final 200, and this one's target is gone.
          r
            ..statusCode = 302
            ..headers.set('location', '/gone')
            ..headers.set('x-linked-size', '123456');
        case '/denied':
          r
            ..statusCode = 401
            ..contentLength = 99;
        case '/cross':
          r
            ..statusCode = 302
            ..headers.set('location', 'http://localhost:${other.port}/landing');
        case '/hang':
          // Never answers.
          await Completer<void>().future;
        case '/compressible':
          // As Hugging Face does for a small file: gzip when asked, and then
          // no Content-Length.
          if ((request.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
              .contains('gzip')) {
            r.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          } else {
            r.contentLength = 2071;
          }
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

  tearDown(() async {
    await server.close(force: true);
    await other.close(force: true);
  });

  test('X-Linked-Size is preferred over Content-Length', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/linked'), 123456);
  });

  test('X-Linked-Size on a redirect is not read', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/linked-redirect'), isNull);
  });

  test('a 401 with a Content-Length is unknown', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/denied'), isNull);
  });

  test('a redirect to another host and port carries no token', () async {
    final size = await HttpRemoteSizeProbe().sizeOf(
      '$base/cross',
      token: 'hf_secret',
    );
    expect(authorizations['/cross'], 'Bearer hf_secret');
    expect(authorizations.containsKey('other/landing'), isTrue);
    expect(authorizations['other/landing'], isNull);
    expect(size, 555);
  });

  test('the origin is scheme, host and port', () {
    bool same(String a, String b) =>
        HttpRemoteSizeProbe.sameOrigin(Uri.parse(a), Uri.parse(b));
    expect(same('https://hf.co/a', 'https://hf.co/b'), isTrue);
    expect(same('https://hf.co/a', 'http://hf.co/b'), isFalse);
    expect(same('https://hf.co/a', 'https://hf.co:8443/b'), isFalse);
    expect(same('https://hf.co/a', 'https://cdn.hf.co/b'), isFalse);
  });

  test('a cancel ends a request that hangs at once', () async {
    final cancel = CancelToken();
    final watch = Stopwatch()..start();
    final size = HttpRemoteSizeProbe().sizeOf(
      '$base/hang',
      cancelToken: cancel,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    cancel.cancel();
    expect(await size, isNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('the size is asked uncompressed', () async {
    expect(await HttpRemoteSizeProbe().sizeOf('$base/compressible'), 2071);
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

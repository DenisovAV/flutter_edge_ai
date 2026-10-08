import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../hook/src/download.dart';

void main() {
  test('redactUserInfoIn masks credentials where a URL carries them', () {
    final url = Uri.parse('https://ci-bot:s3cr%40t@nexus.example/maven2/x.aar');
    final error = HttpException(
      'Connection closed while receiving data',
      uri: url,
    );
    final text = redactUserInfoIn('$error', url);
    expect(text, isNot(contains('s3cr')));
    expect(text, contains('***@nexus.example'));
    // A short user name is not masked anywhere else in the message.
    expect(
      redactUserInfoIn('u@h then u again', Uri.parse('https://u@h/')),
      '***@h then u again',
    );
  });

  test(
    'a transfer that dies mid-body does not leak the mirror password',
    () async {
      // A raw socket: promise 1000 bytes, send 10, hang up — what a dropped
      // proxy connection looks like to HttpClient.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((socket) {
        socket.listen((_) {
          socket
            ..write('HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n')
            ..add(List.filled(10, 0));
          socket.flush().then((_) => socket.destroy());
        });
      });
      final dir = Directory.systemTemp.createTempSync('dl_test_');
      addTearDown(() async {
        await server.close();
        dir.deleteSync(recursive: true);
      });
      final url = Uri.parse(
        'http://bot:hunter2@127.0.0.1:${server.port}/x.aar',
      );

      Object? caught;
      try {
        await downloadVerified(
          url,
          File('${dir.path}/x.aar'),
          '0' * 64,
          attempts: 2,
          backoff: Duration.zero,
        );
      } on Object catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      expect('$caught', isNot(contains('hunter2')));
      expect('$caught', contains('after 2 attempts'));
      expect(File('${dir.path}/x.aar').existsSync(), isFalse);
    },
  );
}

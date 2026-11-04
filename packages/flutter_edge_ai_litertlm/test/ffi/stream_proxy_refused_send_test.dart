// A send LiteRT-LM refuses (send_message_stream returns non-OK) never calls
// back, so the StreamProxy's final chunk, which frees the proxy otherwise,
// never comes: the client frees it with stream_proxy_destroy_v1 (native
// b15d6358). An accepted send's proxy must not be freed here: native frees it
// with its final chunk, and a second free would corrupt the heap.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final proxy = Pointer<Void>.fromAddress(0x5eed);

  test('a refused send frees its proxy, once, whatever the status', () {
    for (final status in [3, 8, 13]) {
      final destroyed = <Pointer<Void>>[];
      releaseRefusedStreamProxy(status, proxy, destroyed.add);
      expect(destroyed, [proxy], reason: 'status $status');
    }
  });

  test('an accepted send leaves its proxy to native', () {
    final destroyed = <Pointer<Void>>[];
    releaseRefusedStreamProxy(0, proxy, destroyed.add);
    expect(destroyed, isEmpty);
  });

  test('no proxy, nothing to free', () {
    final destroyed = <Pointer<Void>>[];
    releaseRefusedStreamProxy(3, nullptr, destroyed.add);
    expect(destroyed, isEmpty);
  });

  test('the refused branch of the streamed send calls it, before anything '
      'else native', () {
    final client = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    expect(
      client,
      contains(
        '    if (result != 0) {\n'
        '      // No callback comes for a refused send: its proxy is freed here.\n'
        '      releaseRefusedStreamProxy(result, proxyData, _proxyDestroy!);\n',
      ),
    );
  });

  test('the entries the client requires are the release gate\'s', () {
    final gate = File(
      'native/litert_lm/check_embedding_exports.py',
    ).readAsStringSync();
    final listed = RegExp(
      r'STREAM_PROXY_SYMBOLS = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(gate)!.group(1)!;
    expect(
      {
        for (final m in RegExp(r'"([a-z_0-9]+)"').allMatches(listed))
          m.group(1)!,
      },
      {...streamProxyV1Entries, 'stream_proxy_free_string'},
    );
  });
}

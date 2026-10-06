import 'dart:convert';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/thinking_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The web path sent {"thinking": true}, a key no template reads, and only
  // when on; native and web now send the one map below.
  test('thinking goes under the key templates read, both ways', () {
    expect(thinkingContext(true), {'enable_thinking': true});
    expect(thinkingContext(false), {'enable_thinking': false});
  });

  test('native sends the same map as JSON', () {
    for (final on in [true, false]) {
      expect(jsonDecode(thinkingExtraContext(on)), thinkingContext(on));
    }
  });
}

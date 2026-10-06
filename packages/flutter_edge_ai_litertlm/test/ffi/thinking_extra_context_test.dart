import 'dart:convert';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Qwen3's chat template thinks unless `enable_thinking` is explicitly
  // false; an absent key is not enough. Sending nothing for "no thinking"
  // made every Qwen3 turn reason first.
  test('thinking off is sent as an explicit false', () {
    expect(jsonDecode(thinkingExtraContext(false)), {'enable_thinking': false});
  });

  test('thinking on is sent as true', () {
    expect(jsonDecode(thinkingExtraContext(true)), {'enable_thinking': true});
  });
}

import 'dart:ffi';

import 'package:flutter_gemma_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_gemma_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

// #379: a conversation deleted by model/handle/engine teardown must be dropped
// from the live-conversation registry so a late onCancel (the raw-stream hook
// `controller.onCancel = () => _cancelOn(conv)` or the virtual-turn path) no-ops
// via `_cancelOn`'s liveness guard instead of dereferencing the freed pointer —
// the SIGSEGV / use-after-free in native `Conversation::CancelProcess`.
void main() {
  test(
    'a deleted conversation leaves the live registry, so a late cancel no-ops',
    () {
      final client = LiteRtLmFfiClient();
      final conv = Pointer<LiteRtLmConversation>.fromAddress(0xC0FFEE);

      // Simulate a live conversation (what _createRawConversation registers).
      client.registerLiveForTest(conv);
      expect(client.isConversationLiveForTest(conv), isTrue);

      // Model/handle teardown deletes it.
      client.deleteConversationForTest(conv);

      expect(
        client.isConversationLiveForTest(conv),
        isFalse,
        reason: 'a late cancel now finds the conv dead and no-ops (no UAF)',
      );
    },
  );
}

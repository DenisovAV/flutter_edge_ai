import 'dart:ffi';

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_bindings.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/native_turns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('closing a virtual session while its turn runs ends that turn as '
      'closed under the consumer (B90), not as a stop', () async {
    final client = LiteRtLmFfiClient();
    final token = Object();
    final send = client.startVirtualTurnForTest(
      token,
      Pointer<LiteRtLmConversation>.fromAddress(0x10),
    );
    final text = send.stream.toList();
    send.chunk('Par');
    client.releaseVirtualConversation(token);
    // Native posts the cancelled end the close asked for.
    send.cancelled();
    await expectLater(text, throwsA(isA<LiteRtLmTurnClosedException>()));
  });

  test('a stop before the close keeps the clean end', () async {
    final client = LiteRtLmFfiClient();
    final token = Object();
    final send = client.startVirtualTurnForTest(
      token,
      Pointer<LiteRtLmConversation>.fromAddress(0x10),
    );
    final text = send.stream.toList();
    send.chunk('Par');
    client.cancelVirtualTurn(token);
    client.releaseVirtualConversation(token);
    send.cancelled();
    expect(await text, ['Par']);
  });
}

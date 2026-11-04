// A failed turn stays in a session's history (a rebuild replays it) unless
// native ended it context_full (section 23): that input was refused before
// the model saw it. Both conversation handles follow one rule.
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('only a context_full turn did not reach the model', () {
    for (final end in NativeLastTurnEnd.values) {
      expect(
        failedTurnReachedModel(end),
        end != NativeLastTurnEnd.contextFull,
        reason: '$end',
      );
    }
    expect(failedTurnReachedModel(null), isTrue);
  });

  test('the recovering handle and the virtual sessions both follow it', () {
    final source = File(
      'lib/src/ffi/ffi_inference_model.dart',
    ).readAsStringSync();
    expect(
      source,
      contains('if (!failed || failedTurnReachedModel(_live.lastTurnEnd)) {'),
      reason: 'RecoveringConversationHandle',
    );
    expect(
      source,
      contains('if (!failedTurnReachedModel(lastTurnEnd)) recorded = true;'),
      reason: '_VirtualConversationHandle',
    );
  });
}

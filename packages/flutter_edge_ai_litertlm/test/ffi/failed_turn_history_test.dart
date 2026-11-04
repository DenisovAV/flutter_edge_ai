// A failed turn stays in a session's history (a rebuild replays it) unless
// native ended it context_full (section 23): that input was refused before
// the model saw it. Both conversation handles follow one rule.
import 'dart:io';

import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'only a context_full turn and a refused send did not reach the model',
    () {
      for (final end in NativeLastTurnEnd.values) {
        expect(
          failedTurnReachedModel(end),
          end != NativeLastTurnEnd.contextFull &&
              end != NativeLastTurnEnd.refused,
          reason: '$end',
        );
      }
      expect(failedTurnReachedModel(null), isTrue);
    },
  );

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

  test('a virtual turn native ended context_full makes the next turn rebuild '
      'the shared conversation (it fails every send until rewound)', () {
    final source = File('lib/src/ffi/litert_lm_client.dart').readAsStringSync();
    expect(
      source,
      contains(
        'if (e is LiteRtLmTurnCancelledException ||\n'
        '                _lastTurnEnds[conv]?.end == NativeLastTurnEnd.contextFull) {\n'
        '              _virtualConvStopped = true;',
      ),
    );
  });
}

import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `LiteRtLmTurnEnd` in the patched `c/conversation.h`.
const _none = 0, _completed = 1, _cancelled = 2, _failed = 3, _running = 4;

void main() {
  test('0 after a cancelled send is a rewind', () {
    expect(
      stoppedTurnRewindOutcome(0, _cancelled, null),
      StoppedTurnRewind.rewound,
    );
  });

  test('0 after a send that ended by itself, or none, changes nothing', () {
    for (final end in [_completed, _none]) {
      expect(
        stoppedTurnRewindOutcome(0, end, null),
        StoppedTurnRewind.notCancelled,
      );
    }
  });

  test(
    'any other code is a conversation to rebuild, with how the send ended',
    () {
      for (final (code, end, expected) in [
        (13, _failed, NativeLastTurnEnd.failed),
        (4, _running, NativeLastTurnEnd.running),
        (5, _cancelled, NativeLastTurnEnd.cancelled),
        (9, _completed, NativeLastTurnEnd.completed),
      ]) {
        expect(
          () => stoppedTurnRewindOutcome(code, end, 'why'),
          throwsA(
            isA<StoppedTurnRewindException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.lastTurnEnd, 'lastTurnEnd', expected)
                .having((e) => e.message, 'message', 'why'),
          ),
        );
      }
    },
  );

  test('success with an end native never pairs with it is a rebuild: a '
      'library that did not write the end (-1), an undefined value, or a '
      'failed or running turn', () {
    for (final end in [-1, 99, _failed, _running]) {
      expect(
        () => stoppedTurnRewindOutcome(0, end, null),
        throwsA(isA<StoppedTurnRewindException>()),
        reason: 'end $end',
      );
    }
  });
}

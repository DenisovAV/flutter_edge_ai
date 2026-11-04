import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// `LiteRtLmTurnEnd` in the patched `c/conversation.h` (sections 16 and 23).
const _none = 0, _completed = 1, _cancelled = 2, _failed = 3, _running = 4;
const _outputLimit = 5, _contextLimit = 6, _contextFull = 7, _refused = 8;

void main() {
  test('NativeLastTurnEnd is in the C enum\'s order, and a code it does not '
      'know is none of them', () {
    expect(NativeLastTurnEnd.fromCode(_none), NativeLastTurnEnd.none);
    expect(NativeLastTurnEnd.fromCode(_completed), NativeLastTurnEnd.completed);
    expect(NativeLastTurnEnd.fromCode(_cancelled), NativeLastTurnEnd.cancelled);
    expect(NativeLastTurnEnd.fromCode(_failed), NativeLastTurnEnd.failed);
    expect(NativeLastTurnEnd.fromCode(_running), NativeLastTurnEnd.running);
    expect(
      NativeLastTurnEnd.fromCode(_outputLimit),
      NativeLastTurnEnd.outputLimit,
    );
    expect(
      NativeLastTurnEnd.fromCode(_contextLimit),
      NativeLastTurnEnd.contextLimit,
    );
    expect(
      NativeLastTurnEnd.fromCode(_contextFull),
      NativeLastTurnEnd.contextFull,
    );
    expect(NativeLastTurnEnd.fromCode(_refused), NativeLastTurnEnd.refused);
    expect(NativeLastTurnEnd.fromCode(9), isNull);
    expect(NativeLastTurnEnd.fromCode(-1), isNull);
  });

  test('0 with refused is a library outside the contract (a rewind reports '
      'the last send that started): rebuild', () {
    expect(
      () => stoppedTurnRewindOutcome(0, _refused, null),
      throwsA(
        isA<StoppedTurnRewindException>().having(
          (e) => e.lastTurnEnd,
          'lastTurnEnd',
          NativeLastTurnEnd.refused,
        ),
      ),
    );
  });

  test('0 after a context_full send is a rewind: the failed prefill is '
      'undone and the conversation answers again (section 23)', () {
    expect(
      stoppedTurnRewindOutcome(0, _contextFull, null),
      StoppedTurnRewind.rewound,
    );
  });

  test('0 after a send that hit the output or the context limit changes '
      'nothing: the reply is in the history, cut', () {
    for (final end in [_outputLimit, _contextLimit]) {
      expect(
        stoppedTurnRewindOutcome(0, end, null),
        StoppedTurnRewind.notCancelled,
      );
    }
  });

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

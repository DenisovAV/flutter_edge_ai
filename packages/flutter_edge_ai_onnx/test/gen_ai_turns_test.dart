// The real turn bookkeeping of the FFI engine (`lib/src/ffi/gen_ai_turns.dart`)
// over a scripted generator: what a settled turn leaves in the generator and
// in the history a rebuild replays — including where a rewind fails — and how
// a turn's end is told from what the generator says.
import 'package:flutter_edge_ai/engine.dart' show TurnEnd;
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_turns.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_worker.dart' show AfterTurn;
import 'package:flutter_test/flutter_test.dart';

/// A generator as a list of tokens; every call is logged, and a call can be
/// made to throw.
final class _Generator implements GeneratorOps {
  _Generator(this.tokens);

  final List<int> tokens;
  final List<String> calls = [];
  bool throwOnRewind = false;
  bool throwOnAppend = false;

  @override
  int get length => tokens.length;

  @override
  int tokenAt(int index) => tokens[index];

  @override
  void rewindTo(int length) {
    calls.add('rewindTo($length)');
    if (throwOnRewind) throw StateError('RewindTo is not supported for lfm2');
    tokens.removeRange(length, tokens.length);
  }

  @override
  void append(List<int> more) {
    calls.add('append($more)');
    if (throwOnAppend) throw StateError('append failed');
    tokens.addAll(more);
  }
}

const _end = 99;

void main() {
  late List<Object> failures;
  late SessionTurns turns;
  late _Generator generator;
  var dropped = 0;

  setUp(() {
    failures = [];
    dropped = 0;
    turns = SessionTurns(
      contextWindow: 20,
      endOfTurnToken: _end,
      onRewindFailure: failures.add,
    );
    turns.begin(1, system: 'be brief');
    generator = _Generator([1, 2, 3]); // the system message's tokens
  });

  /// One turn: [prompt] tokens prefilled, [reply] tokens generated.
  void runTurn(String user, List<int> prompt, List<int> reply, String text) {
    turns.started(1, generator.length);
    generator.tokens.addAll(prompt);
    turns.prefilled(1, user);
    generator.tokens.addAll(reply);
    turns.emitted(1, text);
  }

  bool settle(AfterTurn how) =>
      turns.settle(1, how, generator: generator, drop: () => dropped++);

  test('a kept turn stays in the generator and joins the history', () {
    runTurn('hi', [10, 11], [20, 21], 'hello');
    expect(settle(AfterTurn.keep), isTrue);
    expect(generator.tokens, [1, 2, 3, 10, 11, 20, 21]);
    expect(turns.history(1), [
      {'role': 'system', 'content': 'be brief'},
      {'role': 'user', 'content': 'hi'},
      {'role': 'assistant', 'content': 'hello'},
    ]);
  });

  test('a rewound turn goes from the generator and is never recorded', () {
    runTurn('hi', [10, 11], [20, 21], 'hello');
    expect(settle(AfterTurn.rewind), isTrue);
    expect(generator.tokens, [1, 2, 3]);
    expect(turns.history(1), hasLength(1));
  });

  test('a rewind that fails drops the generator; the history, without the '
      'turn, rebuilds it', () {
    runTurn('hi', [10, 11], [20, 21], 'hello');
    generator.throwOnRewind = true;
    expect(settle(AfterTurn.rewind), isFalse);
    expect(dropped, 1);
    expect(failures, hasLength(1));
    expect(turns.history(1), hasLength(1));
  });

  test('a stopped turn keeps its tokens, closed with the end-of-turn token, '
      'and joins the history', () {
    runTurn('story', [10, 11], [20, 21], 'Once upon');
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(generator.calls, ['rewindTo(6)', 'append([21, $_end])']);
    expect(generator.tokens, [1, 2, 3, 10, 11, 20, 21, _end]);
    expect(turns.history(1).last, {
      'role': 'assistant',
      'content': 'Once upon',
    });
  });

  test('a turn that filled the window is kept as it is: no room for the end '
      'token, and the generator is done at max_length', () {
    turns = SessionTurns(
      contextWindow: 7,
      endOfTurnToken: _end,
      onRewindFailure: failures.add,
    )..begin(1, system: 'be brief');
    runTurn('story', [10, 11], [20, 21], 'Once upon'); // 7 of 7
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(generator.calls, isEmpty);
    expect(generator.tokens, [1, 2, 3, 10, 11, 20, 21]);
    expect(turns.history(1).last, {
      'role': 'assistant',
      'content': 'Once upon',
    });
  });

  test('a cut turn one short of the window is closed: the end token fills '
      'it exactly', () {
    turns = SessionTurns(
      contextWindow: 8,
      endOfTurnToken: _end,
      onRewindFailure: failures.add,
    )..begin(1, system: 'be brief');
    runTurn('story', [10, 11], [20, 21], 'Once upon'); // 7 of 8
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(generator.tokens, [1, 2, 3, 10, 11, 20, 21, _end]);
  });

  test('a stopped turn with no end token known is rewound to its start', () {
    turns = SessionTurns(contextWindow: 20, onRewindFailure: failures.add)
      ..begin(1, system: 'be brief');
    runTurn('story', [10, 11], [20, 21], 'Once upon');
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(generator.tokens, [1, 2, 3]);
  });

  test('a stopped turn whose close fails drops the generator, and the '
      'history keeps the exchange for the rebuild', () {
    for (final throwOn in ['rewind', 'append']) {
      turns = SessionTurns(
        contextWindow: 20,
        endOfTurnToken: _end,
        onRewindFailure: failures.add,
      )..begin(1, system: 'be brief');
      generator = _Generator([1, 2, 3])
        ..throwOnRewind = throwOn == 'rewind'
        ..throwOnAppend = throwOn == 'append';
      dropped = 0;
      runTurn('story', [10, 11], [20, 21], 'Once upon');
      expect(settle(AfterTurn.keepStopped), isFalse, reason: throwOn);
      expect(dropped, 1, reason: throwOn);
      expect(turns.history(1).last, {
        'role': 'assistant',
        'content': 'Once upon',
      }, reason: throwOn);
    }
    expect(failures, hasLength(2));
  });

  test('the fallback of a stopped turn rewinds to the turn start, which the '
      'settle was given', () {
    turns = SessionTurns(contextWindow: 20, onRewindFailure: failures.add)
      ..begin(1);
    generator = _Generator([1, 2, 3]);
    runTurn('story', [10, 11], [20], 'Once');
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(generator.tokens, [1, 2, 3]);
  });

  test('a first turn starts the history again from its system message and '
      'seed', () {
    runTurn('hi', [10], [20], 'hello');
    settle(AfterTurn.keep);
    turns.begin(
      1,
      system: 'new',
      seed: [
        {'role': 'user', 'content': 'u'},
      ],
    );
    expect(turns.history(1), [
      {'role': 'system', 'content': 'new'},
      {'role': 'user', 'content': 'u'},
    ]);
    turns.forget(1);
    expect(turns.history(1), isEmpty);
  });

  test('a turn that never reached its prefill leaves nothing to settle', () {
    turns.started(1, generator.length);
    expect(settle(AfterTurn.keepStopped), isTrue);
    expect(settle(AfterTurn.rewind), isTrue);
    expect(generator.calls, isEmpty);
    expect(turns.history(1), hasLength(1));
  });

  group('classifyTurnEnd', () {
    test('a generator done with the whole window is a full context, not an '
        'end of sequence', () {
      expect(
        classifyTurnEnd(
          stopped: false,
          done: true,
          length: 512,
          contextWindow: 512,
        ),
        TurnEnd.contextLimit,
      );
      expect(
        classifyTurnEnd(
          stopped: false,
          done: true,
          length: 511,
          contextWindow: 512,
        ),
        TurnEnd.endOfSequence,
      );
    });

    test('not done is the cap; a stop wins over everything', () {
      expect(
        classifyTurnEnd(
          stopped: false,
          done: false,
          length: 100,
          contextWindow: 512,
        ),
        TurnEnd.outputLimit,
      );
      expect(
        classifyTurnEnd(
          stopped: true,
          done: true,
          length: 512,
          contextWindow: 512,
        ),
        TurnEnd.stopped,
      );
    });
  });
}

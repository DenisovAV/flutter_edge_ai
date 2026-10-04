import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';

class _ScriptChat extends InferenceChat {
  _ScriptChat(this._turns, {this._errorAfterTurns = const {}})
    : super(sessionCreator: null, maxTokens: 1024);
  final List<List<ModelResponse>> _turns;

  /// Turn indices whose stream THROWS after yielding its responses — models a
  /// native decode error mid-stream, AFTER a tool-call was parsed + committed to
  /// history by generateChatResponseAsync.
  final Set<int> _errorAfterTurns;
  int _i = 0;
  final List<Message> fedBack = [];

  /// When true, feeding a tool-RESPONSE throws — models an already-errored
  /// session rejecting the balancing feed (so a test can assert the ORIGINAL
  /// stream error still wins, not the balancing failure).
  bool failToolResponseFeed = false;

  /// Counts tool-response feed ATTEMPTS (incremented before the optional fail
  /// throw) so a test can prove balancing was actually attempted, not skipped.
  int toolResponseFeedAttempts = 0;

  @override
  Future<void> addQueryChunk(
    Message m, [
    bool noTool = false,
    bool prefix = false,
  ]) async {
    if (m.type == MessageType.toolResponse) {
      toolResponseFeedAttempts++;
      if (failToolResponseFeed) {
        throw StateError('session dead — cannot feed tool-response');
      }
    }
    fedBack.add(m);
  }

  @override
  Stream<ModelResponse> generateChatResponseAsync() async* {
    final turnIndex = _i;
    final turn = _i < _turns.length
        ? _turns[_i++]
        : const <ModelResponse>[TextResponse('done')];
    for (final r in turn) {
      yield r;
    }
    if (_errorAfterTurns.contains(turnIndex)) {
      throw StateError('native decode failed mid-stream');
    }
  }

  @override
  Future<void> stopGeneration() async {}
  @override
  Future<void> close() async {}
}

void main() {
  test(
    'runs onToolCall, feeds Message.toolResponse back, yields the final text',
    () async {
      final chat = _ScriptChat([
        const [
          FunctionCallResponse(name: 'get_time', args: {'tz': 'CST'}),
        ],
        const [TextResponse("It's "), TextResponse('9pm.')],
      ]);
      final calls = <FunctionCallResponse>[];
      final out = await chat
          .generateChatResponseWithTools(
            onToolCall: (c) {
              calls.add(c);
              return {'result': '9pm', 'status': 'ok'};
            },
          )
          .toList();

      expect(calls.single.name, 'get_time');
      expect(
        out.whereType<TextResponse>().map((t) => t.token).join(),
        "It's 9pm.",
      );
      expect(chat.fedBack.where((m) => m.toolName == 'get_time'), hasLength(1));
    },
  );

  test('parallel calls each get a tool response, in order', () async {
    final chat = _ScriptChat([
      const [
        ParallelFunctionCallResponse(
          calls: [
            FunctionCallResponse(name: 'a', args: {}),
            FunctionCallResponse(name: 'b', args: {}),
          ],
        ),
      ],
      const [TextResponse('ok')],
    ]);
    final names = <String>[];
    await chat
        .generateChatResponseWithTools(
          onToolCall: (c) {
            names.add(c.name);
            return {'result': 'x'};
          },
        )
        .toList();
    expect(names, ['a', 'b']);
  });

  test('isCancelled ends the loop before the next generation', () async {
    final chat = _ScriptChat([
      const [FunctionCallResponse(name: 'a', args: {})],
      const [TextResponse('unreachable')],
    ]);
    var cancel = false;
    final out = await chat
        .generateChatResponseWithTools(
          onToolCall: (c) {
            cancel = true;
            return {'result': 'x'};
          },
          isCancelled: () => cancel,
        )
        .toList();
    expect(out.whereType<TextResponse>(), isEmpty);
  });

  test('maxToolTurns caps a runaway loop', () async {
    final chat = _ScriptChat(
      List.filled(50, const [FunctionCallResponse(name: 'a', args: {})]),
    );
    var n = 0;
    await chat
        .generateChatResponseWithTools(
          onToolCall: (c) {
            n++;
            return {'result': 'x'};
          },
          maxToolTurns: 3,
        )
        .toList();
    expect(n, 3);
  });

  test('maxToolTurns < 1 throws (no silent empty-stream no-op)', () {
    final chat = _ScriptChat(const []);
    expect(
      () => chat
          .generateChatResponseWithTools(
            onToolCall: (c) => {'result': 'x'},
            maxToolTurns: 0,
          )
          .toList(),
      throwsA(isA<RangeError>()),
    );
  });

  test('onToolCall throwing balances the committed call then rethrows', () async {
    final chat = _ScriptChat([
      const [FunctionCallResponse(name: 'boom', args: {})],
    ]);
    await expectLater(
      chat
          .generateChatResponseWithTools(
            onToolCall: (c) => throw StateError('tool failed'),
          )
          .toList(),
      throwsA(isA<StateError>()),
    );
    // The committed tool-call must get a matching (error) tool-response so the
    // persistent chat is not left with a dangling call that poisons next turn.
    expect(
      chat.fedBack.where((m) => m.toolName == 'boom'),
      hasLength(1),
      reason: 'failed call must be answered to balance history',
    );
  });

  test(
    'cancel after generation balances the pending call before stopping',
    () async {
      final chat = _ScriptChat([
        const [FunctionCallResponse(name: 'a', args: {})],
        const [TextResponse('unreachable')],
      ]);
      var polls = 0;
      final out = await chat
          .generateChatResponseWithTools(
            onToolCall: (c) => {'result': 'x'},
            // false at the top-of-loop check, true right after generation — so the
            // cancel lands with a call already committed but not yet executed.
            isCancelled: () => ++polls > 1,
          )
          .toList();
      expect(out.whereType<TextResponse>(), isEmpty); // stopped, no 2nd turn
      expect(
        chat.fedBack.where((m) => m.toolName == 'a'),
        hasLength(1),
        reason: 'cancelled call must be answered to balance history',
      );
    },
  );

  test(
    'cancel BETWEEN parallel calls skips the rest, balances them, stops',
    () async {
      final chat = _ScriptChat([
        const [
          ParallelFunctionCallResponse(
            calls: [
              FunctionCallResponse(name: 'a', args: {}),
              FunctionCallResponse(name: 'b', args: {}),
            ],
          ),
        ],
        const [TextResponse('unreachable')],
      ]);
      var cancel = false;
      final ran = <String>[];
      final out = await chat
          .generateChatResponseWithTools(
            onToolCall: (c) {
              ran.add(c.name);
              cancel = true; // barge-in lands right after the FIRST call runs
              return {'result': 'x'};
            },
            isCancelled: () => cancel,
          )
          .toList();
      // Only the first call's side effect fired: the between-call check
      // (mirroring AgentLoop) stops the rest instead of running every tool's
      // side effect after barge-in.
      expect(ran, ['a'], reason: 'remaining tools must NOT run after barge-in');
      expect(out.whereType<TextResponse>(), isEmpty); // no 2nd turn
      // Both committed calls still get a tool-response (a: real, b: cancelled)
      // so neither is left dangling in the persistent chat.
      expect(chat.fedBack.where((m) => m.toolName == 'a'), hasLength(1));
      expect(
        chat.fedBack.where((m) => m.toolName == 'b'),
        hasLength(1),
        reason: 'the skipped call must be balanced with a cancelled response',
      );
    },
  );

  test('a mid-stream generation error after a committed call balances it then '
      'rethrows', () async {
    final chat = _ScriptChat(
      [
        const [FunctionCallResponse(name: 'boom', args: {})],
      ],
      // The stream commits the tool-call, then errors on a later token.
      errorAfterTurns: {0},
    );
    // The error MUST surface — never hidden.
    await expectLater(
      chat
          .generateChatResponseWithTools(onToolCall: (c) => {'result': 'x'})
          .toList(),
      throwsA(isA<StateError>()),
    );
    // ...and the committed call must be balanced (status: failed) so it does
    // not dangle in the persistent chat and poison the next turn.
    expect(
      chat.fedBack.where((m) => m.toolName == 'boom'),
      hasLength(1),
      reason: 'stream error must balance the committed call before rethrowing',
    );
    // ...carrying the honest failed marker (what the model replays next turn).
    expect(
      chat.fedBack.singleWhere((m) => m.toolName == 'boom').text,
      allOf(contains('failed'), contains('generation stream errored')),
    );
  });

  test(
    'if the balancing feed itself fails, the ORIGINAL stream error still wins',
    () async {
      final chat = _ScriptChat(
        [
          const [FunctionCallResponse(name: 'boom', args: {})],
        ],
        errorAfterTurns: {0},
      )..failToolResponseFeed = true;
      // The mid-stream decode error must surface — NOT the balancing failure,
      // which would mask the real cause.
      await expectLater(
        chat
            .generateChatResponseWithTools(onToolCall: (c) => {'result': 'x'})
            .toList(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('native decode failed'),
          ),
        ),
      );
      // Prove balancing was actually ATTEMPTED (not a false-green via an empty
      // pending list): the feed was tried once for the committed call.
      expect(chat.toolResponseFeedAttempts, greaterThanOrEqualTo(1));
    },
  );

  test(
    'a mid-stream error with NO committed call rethrows without over-balancing',
    () async {
      // A text-only turn (nothing committed) that then errors — the most common
      // real failure. Must rethrow and feed NO spurious tool-response.
      final chat = _ScriptChat(
        [
          const [TextResponse('partial')],
        ],
        errorAfterTurns: {0},
      );
      await expectLater(
        chat
            .generateChatResponseWithTools(onToolCall: (c) => {'result': 'x'})
            .toList(),
        throwsA(isA<StateError>()),
      );
      expect(
        chat.fedBack.where((m) => m.type == MessageType.toolResponse),
        isEmpty,
        reason: 'nothing was committed, so nothing may be balanced',
      );
    },
  );

  test(
    'a mid-stream error after PARALLEL committed calls balances every one',
    () async {
      final chat = _ScriptChat(
        [
          const [
            ParallelFunctionCallResponse(
              calls: [
                FunctionCallResponse(name: 'a', args: {}),
                FunctionCallResponse(name: 'b', args: {}),
              ],
            ),
          ],
        ],
        errorAfterTurns: {0},
      );
      await expectLater(
        chat
            .generateChatResponseWithTools(onToolCall: (c) => {'result': 'x'})
            .toList(),
        throwsA(isA<StateError>()),
      );
      // BOTH committed calls balanced — not just the first.
      expect(chat.fedBack.where((m) => m.toolName == 'a'), hasLength(1));
      expect(chat.fedBack.where((m) => m.toolName == 'b'), hasLength(1));
    },
  );

  test('a mid-stream error on a LATER turn balances only that turn without '
      'double-feeding the earlier one', () async {
    final chat = _ScriptChat(
      [
        const [FunctionCallResponse(name: 'a', args: {})], // turn 0: runs clean
        const [FunctionCallResponse(name: 'b', args: {})], // turn 1: errors
      ],
      errorAfterTurns: {1},
    );
    await expectLater(
      chat
          .generateChatResponseWithTools(onToolCall: (c) => {'result': 'x'})
          .toList(),
      throwsA(isA<StateError>()),
    );
    // 'a' got its real response (turn 0), 'b' got the failed balance (turn 1) —
    // each exactly once; per-turn `pending` reset means no carry-over/double.
    expect(chat.fedBack.where((m) => m.toolName == 'a'), hasLength(1));
    expect(chat.fedBack.where((m) => m.toolName == 'b'), hasLength(1));
  });

  test('onMaxToolTurns fires exactly once when the cap is hit', () async {
    // The model keeps calling a tool forever — never a call-free answer.
    final chat = _ScriptChat(
      List.filled(50, const [FunctionCallResponse(name: 'a', args: {})]),
    );
    var maxHit = 0;
    await chat
        .generateChatResponseWithTools(
          onToolCall: (c) => {'result': 'x'},
          maxToolTurns: 3,
          onMaxToolTurns: () => maxHit++,
        )
        .toList();
    expect(maxHit, 1, reason: 'fires once, only on maxToolTurns exhaustion');
  });

  test(
    'onMaxToolTurns does NOT fire when the model settles on an answer',
    () async {
      final chat = _ScriptChat([
        const [FunctionCallResponse(name: 'a', args: {})],
        const [TextResponse('done')],
      ]);
      var maxHit = 0;
      await chat
          .generateChatResponseWithTools(
            onToolCall: (c) => {'result': 'x'},
            maxToolTurns: 5,
            onMaxToolTurns: () => maxHit++,
          )
          .toList();
      expect(maxHit, 0);
    },
  );

  test('a cancel preempts onMaxToolTurns (cancelled before the cap)', () async {
    final chat = _ScriptChat(
      List.filled(50, const [FunctionCallResponse(name: 'a', args: {})]),
    );
    var maxHit = 0;
    var cancel = false;
    await chat
        .generateChatResponseWithTools(
          onToolCall: (c) {
            cancel = true; // barge-in after the first tool runs
            return {'result': 'x'};
          },
          maxToolTurns: 2,
          isCancelled: () => cancel,
          onMaxToolTurns: () => maxHit++,
        )
        .toList();
    // The next-turn cancel returns before the maxToolTurns exhaustion tail.
    expect(maxHit, 0);
  });
}

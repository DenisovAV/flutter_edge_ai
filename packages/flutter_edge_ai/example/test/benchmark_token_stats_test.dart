import 'package:flutter_edge_ai/flutter_edge_ai.dart' show SessionMetrics;
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/benchmark_token_stats.dart';

SessionMetrics _m(int input, int output, {double? tps}) => SessionMetrics(
  inputTokens: input,
  outputTokens: output,
  totalTokens: input + output,
  tokensPerSecond: tps,
);

void main() {
  test('one prompt is the difference between the two readings', () {
    final stats = tokenStatsBetween(
      _m(120, 80, tps: 11.0), // after earlier turns of the same chat
      _m(150, 140, tps: 14.5),
      sameSession: true,
      firstTokenMs: 1000,
      lastTokenMs: 5000,
    )!;

    expect(stats.inputTokens, 30);
    expect(stats.outputTokens, 60);
    expect(stats.nativeTokensPerSecond, 14.5);
    // 59 tokens after the first, over the 4 s after it.
    expect(stats.decodeTokensPerSecond, closeTo(14.75, 1e-9));
    expect(stats.readError, isNull);
  });

  test('bookkeeping after the last token is not decode time', () {
    // duration_ms would be 6000: the chat spent 2 s after the last token on
    // sizeInTokens and its history. The rate must not see that.
    final stats = tokenStatsBetween(
      _m(0, 0, tps: 50.0),
      _m(10, 101, tps: 50.0),
      sameSession: true,
      firstTokenMs: 1000,
      lastTokenMs: 3000,
    )!;

    expect(stats.decodeTokensPerSecond, closeTo(50.0, 1e-9)); // 100 / 2 s
  });

  test('an engine with no counters gives null, not zero tokens', () {
    expect(
      tokenStatsBetween(
        SessionMetrics(),
        SessionMetrics(),
        sameSession: true,
        firstTokenMs: 800,
        lastTokenMs: 5000,
      ),
      isNull,
    );
  });

  test('counters that went backwards are an error, not a negative rate', () {
    final stats = tokenStatsBetween(
      _m(200, 300),
      _m(10, 20),
      sameSession: true,
      firstTokenMs: 800,
      lastTokenMs: 5000,
    )!;

    expect(stats.readError, contains('backwards'));
    expect(stats.outputTokens, isNull);
    expect(stats.decodeTokensPerSecond, isNull);
  });

  test('no decode rate without a first token or with a single token', () {
    final noFirst = tokenStatsBetween(
      _m(0, 0),
      _m(10, 50, tps: 9.0),
      sameSession: true,
      firstTokenMs: -1,
      lastTokenMs: 5000,
    )!;
    expect(noFirst.decodeTokensPerSecond, isNull);
    expect(noFirst.outputTokens, 50, reason: 'the counters still count');

    final one = tokenStatsBetween(
      _m(0, 0),
      _m(10, 1, tps: 9.0),
      sameSession: true,
      firstTokenMs: 900,
      lastTokenMs: 900,
    )!;
    expect(one.decodeTokensPerSecond, isNull);
  });

  test('the native rate is dropped when this prompt produced no tokens', () {
    final stats = tokenStatsBetween(
      _m(10, 40, tps: 12.0),
      _m(25, 40, tps: 12.0), // prefill only: the rate is the previous turn's
      sameSession: true,
      firstTokenMs: -1,
      lastTokenMs: 2000,
    )!;

    expect(stats.outputTokens, 0);
    expect(stats.nativeTokensPerSecond, isNull);
  });

  test(
    'a recreated session is an error, even when its counters are higher',
    () {
      final stats = tokenStatsBetween(
        _m(10, 20, tps: 5.0),
        _m(500, 900, tps: 8.0), // the new session's counters, unrelated
        sameSession: false,
        firstTokenMs: 800,
        lastTokenMs: 5000,
      )!;

      expect(stats.readError, contains('recreated'));
      expect(stats.outputTokens, isNull);
      expect(stats.decodeTokensPerSecond, isNull);
    },
  );

  test('describe says why there is no number', () {
    expect(
      const TokenStats(readError: 'counters went backwards').describe(),
      contains('unreadable'),
    );
    expect(
      const TokenStats(
        outputTokens: 42,
        decodeTokensPerSecond: 17.34,
      ).describe(),
      '42 tokens, 17.3 tok/s decode',
    );
  });
}

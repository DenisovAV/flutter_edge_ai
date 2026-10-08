import 'package:flutter_edge_ai/flutter_edge_ai.dart' show SessionMetrics;

/// Tokens and generation speed of one benchmark prompt, from the engine's own
/// counters.
///
/// A session's counters add up across its turns (the multi-turn phase asks five
/// questions on one chat), so one prompt is the difference between the readings
/// taken before and after it. [nativeTokensPerSecond] is the engine's figure for
/// its last decode turn, which is this prompt's. [decodeTokensPerSecond] is ours:
/// the tokens after the first one over the time after the first token, so it
/// leaves out the prefill that [firstTokenMs] already measures. Null where the
/// value does not exist for this prompt; [readError] says when the counters
/// could not be trusted.
class TokenStats {
  const TokenStats({
    this.inputTokens,
    this.outputTokens,
    this.nativeTokensPerSecond,
    this.decodeTokensPerSecond,
    this.readError,
  });

  final int? inputTokens;
  final int? outputTokens;
  final double? nativeTokensPerSecond;
  final double? decodeTokensPerSecond;

  /// Set when the counters could not be used, with the reason.
  final String? readError;

  Map<String, dynamic> toJson() => {
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'native_tokens_per_second': nativeTokensPerSecond,
    'decode_tokens_per_second': decodeTokensPerSecond,
    'read_error': readError,
  };

  /// `42 tokens, 17.3 tok/s decode`, or why there is no number.
  String describe() {
    if (readError != null) return 'tokens unreadable ($readError)';
    final rate = decodeTokensPerSecond;
    return '$outputTokens tokens'
        '${rate == null ? '' : ', ${rate.toStringAsFixed(1)} tok/s decode'}';
  }
}

/// The stats of the prompt that ran between [before] and [after], or null when
/// the engine reports no counters at all (MediaPipe returns an empty
/// [SessionMetrics]). Null is "this engine does not say", not zero tokens.
/// [firstTokenMs] is -1 when no token arrived.
///
/// [sameSession] says the chat still held the session the [before] reading came
/// from. A chat can recreate its session mid-prompt; the new one's counters are
/// unrelated to the old one's, so their difference would be a wrong number that
/// looks right. That gives a `readError` instead, checked before anything else.
TokenStats? tokenStatsBetween(
  SessionMetrics before,
  SessionMetrics after, {
  required bool sameSession,
  required int durationMs,
  required int firstTokenMs,
}) {
  if (!sameSession) {
    return const TokenStats(
      readError: 'the chat recreated its session during the prompt',
    );
  }
  if (after.totalTokens == 0 && after.tokensPerSecond == null) return null;

  final input = after.inputTokens - before.inputTokens;
  final output = after.outputTokens - before.outputTokens;
  if (input < 0 || output < 0) {
    return const TokenStats(
      readError: 'counters went backwards, the session was probably recreated',
    );
  }

  final decodeMs = durationMs - firstTokenMs;
  final decodeRate = firstTokenMs >= 0 && output > 1 && decodeMs > 0
      ? (output - 1) / (decodeMs / 1000)
      : null;
  return TokenStats(
    inputTokens: input,
    outputTokens: output,
    nativeTokensPerSecond: output > 0 ? after.tokensPerSecond : null,
    decodeTokensPerSecond: decodeRate,
  );
}

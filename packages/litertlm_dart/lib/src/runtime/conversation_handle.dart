// What a conversation of either arm drives: the handle an [Engine] gives a
// `Conversation` (its own native conversation, a turn of a shared one, or a
// `@litert-lm/core` conversation on the web), how native's last send ended,
// and LiteRT-LM's benchmark record. No dart:ffi, no dart:io: the Conversation
// class over it is the same on every platform.

import 'dart:typed_data';

import 'send_options.dart';
import 'types.dart' show BenchmarkInfo;

/// What [ConversationHandle.rewindStoppedTurn] did.
enum StoppedTurnRewind {
  /// The conversation is back before the stopped turn, with that turn put back
  /// into its context, and answers again.
  rewound,

  /// Native's last send was not cancelled — it had ended by itself before the
  /// stop reached it — so nothing changed and the conversation answers as it
  /// is.
  notCancelled,

  /// This conversation cannot rewind: the loaded libLiteRtLm predates
  /// `patch_c_api.sh` section 16. Nothing was changed.
  unsupported,
}

/// How native's last send ended (`LiteRtLmTurnEnd` in the patched
/// `c/conversation.h`), as `litert_lm_conversation_get_last_turn_end` reports
/// it after a send (§23) and `litert_lm_conversation_rewind_cancelled_turn`
/// after waiting for one (§16). In the C enum's order: the index is the code.
enum NativeLastTurnEnd {
  /// Nothing was sent, or it was rewound.
  none,

  /// The reply ended by itself (end of sequence).
  completed,

  /// Cancelled; the conversation fails until it is rewound.
  cancelled,

  /// Ended with an error.
  failed,

  /// Had not ended when the wait timed out.
  running,

  /// The reply reached `max_output_tokens`.
  outputLimit,

  /// The decode filled the context window (`max_num_tokens`): the reply is
  /// cut.
  contextLimit,

  /// The input did not fit what the context window has left, or the window
  /// has no room for any prefill signature (status RESOURCE_EXHAUSTED). Only
  /// these context-window checks end a turn here (native 37d1ec59): any other
  /// RESOURCE_EXHAUSTED, a failed allocation for one, ends [failed] with
  /// status 8, which a rewind refuses. So status 8 alone is not a full
  /// context: read this end. The
  /// input is not in the history, and the conversation fails every later send
  /// until it is rewound to the turn's checkpoint.
  contextFull,

  /// The last send was refused before it started (a NULL argument, a message
  /// that is not JSON), with its status: nothing ran, and the conversation is
  /// as the send before it left it. Reported so that the end of that earlier
  /// send is never read as this one's; a rewind still decides by the last
  /// send that started.
  refused;

  /// The end native reported as [code], or null for a code this client does
  /// not know.
  static NativeLastTurnEnd? fromCode(int code) =>
      code >= 0 && code < values.length ? values[code] : null;
}

/// The stopped turn could not be rewound, so the conversation must be
/// rebuilt. [code] is the absl status code native returned (-1 when the call
/// itself failed), [lastTurnEnd] how native's last send had ended.
final class StoppedTurnRewindException implements Exception {
  const StoppedTurnRewindException(this.code, this.message, {this.lastTurnEnd});

  final int code;
  final String? message;
  final NativeLastTurnEnd? lastTurnEnd;

  @override
  String toString() {
    final end = lastTurnEnd == null ? '' : ', last turn ${lastTurnEnd!.name}';
    return 'StoppedTurnRewindException(code $code$end): '
        '${message ?? 'no message'}';
  }
}

/// Per-conversation operations a session needs from the FFI layer.
///
/// `LiteRtLmConversationHandle` is the real implementation backed by a
/// native `LiteRtLmConversation*`. Tests inject a fake implementing this
/// interface so `FfiInferenceModelSession` orchestration (query buffering,
/// raw-response capture, Gemma 4 tool-call extraction) can be exercised on
/// the host VM with no native engine.
abstract class ConversationHandle {
  /// Token count for [text] from the model's own tokenizer, or null when it
  /// cannot be obtained (no engine, native call failed). Callers must handle
  /// null rather than assume a number — this feeds context budgeting, and the
  /// four-chars-per-token estimate it replaced undercounts Chinese by more than
  /// half (measured 0.44x on gemma-4-E2B-it) while looking authoritative.
  Future<int?> tokenCount(String text);

  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking,
  });

  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking,
  });

  /// Streams raw SDK JSON for a prebuilt message. This is how tool results go
  /// back: [chatRaw] always sends role `user`, and a tool result has to be role
  /// `tool` for the model to read it as the answer to its call.
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking,
    SendOptions options,
  });

  void cancelGeneration();

  /// Makes the conversation answer again after [cancelGeneration] stopped its
  /// last turn: rewinds to before that turn, then puts the turn back — the
  /// message exactly as it was sent, media included, followed by
  /// [partialReply] — without generating, so the model keeps the exchange.
  /// With [partialReply] null the turn is taken out instead: rewound to
  /// before its message, with nothing put back (a turn stopped before it
  /// produced anything, or one whose input did not fit).
  ///
  /// [StoppedTurnRewind.unsupported] when this conversation cannot rewind;
  /// throws [StoppedTurnRewindException] when the native rewind failed.
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  );

  BenchmarkInfo getSessionMetrics();

  /// LiteRT-LM's benchmark record of this conversation, turn by turn; null
  /// when native gives none.
  NativeBenchmark? getNativeBenchmark();

  /// How native's last send on this conversation ended (§23's record, read
  /// when the send ended), or null before one has ended here.
  NativeLastTurnEnd? get lastTurnEnd;

  /// The absl status code native's last send ended with (§23's record):
  /// non-zero only for [NativeLastTurnEnd.failed] and
  /// [NativeLastTurnEnd.contextFull]; null when [lastTurnEnd] is.
  int? get lastTurnCode;

  /// Ends the conversation. Natively it may complete before the native
  /// delete, which waits for an operation still running on the conversation;
  /// on the web it completes once the generation has drained and the runtime
  /// conversation is deleted. Idempotent: a second call does not close twice.
  Future<void> close();
}

/// One prefill or decode turn of LiteRT-LM's benchmark record: its tokens
/// and its speed (0 when the turn has no measurable duration).
typedef NativeBenchmarkTurn = ({int tokens, double tokensPerSecond});

/// LiteRT-LM's benchmark record of a conversation (`LiteRtLmBenchmarkInfo`),
/// turn by turn: the engine's init time, the first token's latency, every
/// prefill and decode turn, and the context window the executor uses (0
/// before the first prefill).
typedef NativeBenchmark = ({
  double initSeconds,
  double timeToFirstTokenSeconds,
  List<NativeBenchmarkTurn> prefill,
  List<NativeBenchmarkTurn> decode,
  int maxNumTokens,
});

/// The [BenchmarkInfo] of [turns]: tokens summed over every turn, the last
/// decode's speed, times in milliseconds, and null for a time native did not
/// report.
BenchmarkInfo benchmarkInfoOf(NativeBenchmark turns) {
  final input = turns.prefill.fold(0, (sum, t) => sum + t.tokens);
  final output = turns.decode.fold(0, (sum, t) => sum + t.tokens);
  final lastDecode = turns.decode.isEmpty
      ? 0.0
      : turns.decode.last.tokensPerSecond;
  return BenchmarkInfo(
    inputTokens: input,
    outputTokens: output,
    totalTokens: input + output,
    timeToFirstTokenMs: turns.timeToFirstTokenSeconds > 0
        ? turns.timeToFirstTokenSeconds * 1000
        : null,
    tokensPerSecond: lastDecode > 0 ? lastDecode : null,
    initTimeMs: turns.initSeconds > 0 ? turns.initSeconds * 1000 : null,
  );
}

/// What Kotlin's and Swift's `Conversation` read from, or make of, a
/// conversation's own state: its KV cache's token count, the prompt its
/// template renders, and a copy. Implemented by the handles that can answer;
/// `Conversation` refuses the rest with an [UnsupportedError] naming why.
abstract interface class ConversationStateAccess {
  /// The tokens in the conversation's KV cache, prefill and decode
  /// (`litert_lm_conversation_get_token_count`).
  Future<int> kvTokenCount();

  /// [messageJson] as the conversation's template renders it
  /// (`litert_lm_conversation_render_message_to_string`).
  Future<String> renderMessage(String messageJson);

  /// The conversation's preface as its template renders it
  /// (`litert_lm_conversation_render_preface_to_string`).
  Future<String> renderPreface();

  /// A new handle holding this one's history and state
  /// (`litert_lm_conversation_clone` where the conversation is native).
  Future<ConversationHandle> cloneHandle();
}

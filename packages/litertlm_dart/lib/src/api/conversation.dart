// LiteRT-LM's Kotlin/Swift `Conversation`: messages in, a streamed reply out,
// over one of the conversation handles of `ffi/conversation_handles.dart`
// (its own native conversation, or a turn of the shared one).

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:meta/meta.dart' show internal, visibleForTesting;

import '../ffi/litert_lm_client.dart'
    show ConversationHandle, NativeLastTurnEnd;
import '../ffi/native_turns.dart'
    show LiteRtLmTurnCancelledException, LiteRtLmTurnClosedException;
import '../ffi/send_options.dart';
import '../runtime/errors.dart';
import '../runtime/types.dart' show BenchmarkInfo;
import 'config.dart';
import 'message.dart';

/// How a conversation's last turn ended, from native's own record.
enum TurnEnd {
  /// The turn is still generating.
  running,

  /// The model ended its reply.
  completed,

  /// The subscriber cancelled the turn.
  cancelled,

  /// Native failed the turn, or cancelled it unasked.
  failed,

  /// The reply reached `maxOutputTokens`.
  outputLimit,

  /// The reply filled the context window.
  contextLimit,

  /// The message did not fit what the context window had left; it was not
  /// added.
  contextFull,

  /// Native refused the message before generating.
  refused,
}

TurnEnd? _turnEndOf(NativeLastTurnEnd? end) => switch (end) {
  null || NativeLastTurnEnd.none => null,
  NativeLastTurnEnd.running => TurnEnd.running,
  NativeLastTurnEnd.completed => TurnEnd.completed,
  NativeLastTurnEnd.cancelled => TurnEnd.cancelled,
  NativeLastTurnEnd.failed => TurnEnd.failed,
  NativeLastTurnEnd.outputLimit => TurnEnd.outputLimit,
  NativeLastTurnEnd.contextLimit => TurnEnd.contextLimit,
  NativeLastTurnEnd.contextFull => TurnEnd.contextFull,
  NativeLastTurnEnd.refused => TurnEnd.refused,
};

/// The conversation, or its engine, was closed while a reply streamed. The
/// text that arrived before it stays in the conversation's history.
final class ConversationClosedException extends LiteRtLmException {
  const ConversationClosedException(super.message);
}

/// The message did not fit what the context window had left. The
/// conversation is restored to before it.
final class ContextFullException extends LiteRtLmException {
  const ContextFullException(super.message);
}

/// Native failed the turn, or cancelled it without being asked. The next
/// message rebuilds the conversation from its history.
final class TurnFailedException extends LiteRtLmException {
  const TurnFailedException(super.message, {this.cause});

  /// What failed underneath.
  final Object? cause;
}

/// A conversation with a loaded model.
///
/// One message at a time: a send while another reply is still being listened
/// to throws [StateError]. A reply whose subscription was cancelled does not
/// count: the next message waits for it to end. A reply streams as several [Message]s, each a piece of it
/// (text parts, a thought in `channels['thought']`, tool calls in
/// [Message.toolCalls]).
///
/// To stop a reply and keep what it produced, call [cancel]: the stream ends
/// normally. To stop it and drop the rest, cancel the subscription: the
/// Future that returns completes once native has ended the turn. Either way
/// the next message is sent after the conversation is recovered: a stopped
/// turn keeps its message and the part of the reply that was generated,
/// closed as a finished exchange; a turn that produced nothing, failed or did
/// not fit is taken back.
final class Conversation {
  @internal
  Conversation.internal(
    this._handle, {
    required this._config,
    required void Function() thinkingTokenBudgetCapsNothing,
    this._onClose,
  }) : _budgetCapsNothing = thinkingTokenBudgetCapsNothing;

  /// A conversation over [handle], for tests that drive it with a fake.
  @visibleForTesting
  factory Conversation.forTest(
    ConversationHandle handle, {
    ConversationConfig? config,
  }) => Conversation.internal(
    handle,
    config: config ?? ConversationConfig(),
    thinkingTokenBudgetCapsNothing: () {},
  );

  final ConversationHandle _handle;
  final ConversationConfig _config;
  final void Function() _budgetCapsNothing;
  final void Function()? _onClose;
  bool _sending = false;
  bool _closed = false;

  /// The handle under this conversation, for tests.
  @visibleForTesting
  ConversationHandle get handleForTest => _handle;

  /// Sends [message] and streams the reply.
  ///
  /// [thinkingConfig] overrides the conversation's for this message;
  /// [extraContext] adds template variables; [repetitionPenaltyConfig],
  /// [noRepeatNgramConfig] and [suppressTokens] shape this reply's decoding.
  ///
  /// The stream ends with an error for: [ContextFullException] (the message
  /// did not fit), [ConversationClosedException] (closed while streaming),
  /// [TurnFailedException] (native failed or cancelled unasked),
  /// [ConstraintUnsupportedException] (the response format was refused).
  Stream<Message> sendMessageStream(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    ThinkingConfig? thinkingConfig,
  }) {
    if (_closed) throw StateError('The conversation is closed.');
    if (_sending) {
      throw StateError(
        'A reply is still streaming; cancel it or wait for its end before '
        'sending the next message.',
      );
    }
    final thinking = thinkingConfig ?? _config.thinkingConfig;
    final enable = thinking?.enableThinking ?? false;
    final budget = enable ? thinking?.thinkingTokenBudget : null;
    if (budget != null && _config.responseFormat != null) {
      throw const ConstraintUnsupportedException(
        'LiteRT-LM cannot combine a response format with a thinking token '
        'budget.',
      );
    }
    if (budget != null) _budgetCapsNothing();
    final options = SendOptions(
      extraContext: {..._config.extraContext, ...?extraContext},
      repetitionPenalty: repetitionPenaltyConfig,
      noRepeatNgram: noRepeatNgramConfig,
      suppressTokens: suppressTokens == null
          ? null
          : List.unmodifiable(suppressTokens),
      thinkingTokenBudget: budget,
    );
    final json = jsonEncode(messageJson(message));
    _sending = true;
    late final StreamController<Message> controller;
    StreamSubscription<String>? inner;
    var cancelled = false;
    // The turn ended on its own: a done event also runs onCancel, and there
    // is nothing left to stop.
    var ended = false;
    void finish() => _sending = false;

    controller = StreamController<Message>(
      sync: true,
      onListen: () {
        inner = _handle
            .chatRawMessage(json, enableThinking: enable, options: options)
            .listen(
              (chunk) {
                if (!cancelled) controller.add(messageFromChunk(chunk));
              },
              onError: (Object error, StackTrace stack) {
                if (cancelled) return;
                controller.addError(_mapError(error), stack);
              },
              onDone: () {
                ended = true;
                finish();
                if (!controller.isClosed) controller.close();
              },
            );
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        if (ended) return null;
        cancelled = true;
        // The next message may be sent at once: it waits for this turn to
        // end and for the conversation's recovery before it is sent.
        finish();
        final sub = inner;
        if (sub == null) return null;
        // Ask native to stop, then wait for the turn to end on its own, as a
        // stop always has: the handle records and recovers a turn that ended,
        // and the native lock is released at that end, not at the cancel.
        _handle.cancelGeneration();
        final nativeEnded = Completer<void>();
        sub
          ..onData((_) {})
          ..onError((Object _, StackTrace _) {})
          ..onDone(() {
            ended = true;
            if (!nativeEnded.isCompleted) nativeEnded.complete();
          });
        if (sub.isPaused) sub.resume();
        return nativeEnded.future.timeout(
          const Duration(seconds: 5),
          onTimeout: sub.cancel,
        );
      },
    );
    return controller.stream;
  }

  /// Stops the reply in flight, keeping what was generated: native stops at
  /// its next token (a prefill in progress finishes first) and the stream
  /// then ends normally, with every piece produced before the stop. Swift's
  /// `cancel()`. Cancelling the subscription instead stops native too, but
  /// drops what has not reached the subscriber. A message still waiting for
  /// the turn before it is not sent.
  void cancel() => _handle.cancelGeneration();

  /// Sends [message] and returns the whole reply as one [Message].
  Future<Message> sendMessage(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    ThinkingConfig? thinkingConfig,
  }) async {
    final text = StringBuffer();
    final thought = StringBuffer();
    final calls = <ToolCall>[];
    await for (final piece in sendMessageStream(
      message,
      extraContext: extraContext,
      repetitionPenaltyConfig: repetitionPenaltyConfig,
      noRepeatNgramConfig: noRepeatNgramConfig,
      suppressTokens: suppressTokens,
      thinkingConfig: thinkingConfig,
    )) {
      text.write(piece.text);
      thought.write(piece.channels['thought'] ?? '');
      calls.addAll(piece.toolCalls);
    }
    return Message(
      role: Role.model,
      contents: [if (text.isNotEmpty) Content.text(text.toString())],
      toolCalls: calls,
      channels: {if (thought.isNotEmpty) 'thought': thought.toString()},
    );
  }

  Object _mapError(Object error) {
    if (error is LiteRtLmTurnClosedException) {
      return ConversationClosedException('$error');
    }
    if (error is LiteRtLmTurnCancelledException) {
      return TurnFailedException('$error', cause: error);
    }
    if (_handle.lastTurnEnd == NativeLastTurnEnd.contextFull) {
      return ContextFullException('$error');
    }
    return error;
  }

  /// How the last turn ended; null before the first one reached native.
  TurnEnd? get lastTurnEnd => _turnEndOf(_handle.lastTurnEnd);

  /// The absl status code native ended the last turn with: non-zero only for
  /// [TurnEnd.failed] and [TurnEnd.contextFull].
  int? get lastTurnCode => _handle.lastTurnCode;

  /// How many tokens [text] is, by the model's own tokenizer; null when the
  /// engine cannot tell (closed, or the native call failed).
  Future<int?> countTokens(String text) => _handle.tokenCount(text);

  /// What LiteRT-LM's benchmark reports about this conversation.
  BenchmarkInfo getBenchmarkInfo() => _handle.getSessionMetrics();

  /// Ends the conversation. A reply still streaming ends with
  /// [ConversationClosedException].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handle.close();
    _onClose?.call();
  }
}

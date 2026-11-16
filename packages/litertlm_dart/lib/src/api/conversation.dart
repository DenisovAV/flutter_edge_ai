// LiteRT-LM's Kotlin/Swift `Conversation`: messages in, a streamed reply out,
// over one of the conversation handles of `ffi/conversation_handles.dart`
// (its own native conversation, or a turn of the shared one).

import 'dart:async';
import 'dart:convert' show JsonUnsupportedObjectError, jsonEncode;

import '../ffi/litert_lm_client.dart'
    show ConversationHandle, NativeLastTurnEnd;
import '../ffi/native_turns.dart'
    show LiteRtLmTurnCancelledException, LiteRtLmTurnClosedException;
import '../ffi/send_options.dart';
import '../runtime/errors.dart';
import '../runtime/types.dart' show BenchmarkInfo;
import 'config.dart';
import 'message.dart';

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
  const TurnFailedException(super.message, {Object? cause}) : _cause = cause;

  final Object? _cause;
}

/// What failed under [e], for the Flutter adapter, which hands core the
/// error core's apps always caught; null when nothing did.
Object? turnFailureCause(TurnFailedException e) => e._cause;

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
  Conversation._(
    this._handle, {
    required this._config,
    required void Function() thinkingTokenBudgetCapsNothing,
  }) : _budgetCapsNothing = thinkingTokenBudgetCapsNothing;

  final ConversationHandle _handle;
  final ConversationConfig _config;
  final void Function() _budgetCapsNothing;
  // The turn whose reply is being listened to; a turn that ended, or was
  // let go by a cancel, clears it only while it is still the current one.
  Object? _sending;
  bool _closed = false;

  /// Sends [message] and streams the reply.
  ///
  /// [thinkingConfig] overrides the conversation's for this message;
  /// [extraContext] adds template variables (JSON values: an argument that is
  /// not is an [ArgumentError]); [repetitionPenaltyConfig],
  /// [noRepeatNgramConfig] and [suppressTokens] shape this reply's decoding.
  ///
  /// The message is sent when the stream is listened to. The stream ends with
  /// an error for: [ContextFullException] (the message did not fit),
  /// [ConversationClosedException] (closed before or while streaming),
  /// [ConstraintUnsupportedException] (the response format was refused, or
  /// combined with a thinking budget), and [TurnFailedException] for any
  /// other failure (native failed or cancelled unasked, a reply native wrote
  /// in a shape this release cannot read). Programming errors stay [Error]s.
  Stream<Message> sendMessageStream(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    ThinkingConfig? thinkingConfig,
  }) {
    if (_closed) throw StateError('The conversation is closed.');
    _checkNotSending();
    final thinking = thinkingConfig ?? _config.thinkingConfig;
    final enable = thinking?.enableThinking ?? false;
    final budget = enable ? thinking?.thinkingTokenBudget : null;
    final merged = {..._config.extraContext, ...?extraContext};
    try {
      jsonEncode(merged);
    } on JsonUnsupportedObjectError catch (e) {
      throw ArgumentError.value(
        extraContext,
        'extraContext',
        'holds a value that is not JSON: ${e.unsupportedObject}',
      );
    }
    final json = jsonEncode(messageJson(message));
    if (budget != null && _config.responseFormat != null) {
      return Stream.error(
        const ConstraintUnsupportedException(
          'LiteRT-LM cannot combine a response format with a thinking token '
          'budget.',
        ),
      );
    }
    if (budget != null) _budgetCapsNothing();
    final options = SendOptions(
      extraContext: merged,
      repetitionPenalty: repetitionPenaltyConfig,
      noRepeatNgram: noRepeatNgramConfig,
      suppressTokens: suppressTokens == null
          ? null
          : List.unmodifiable(suppressTokens),
      thinkingTokenBudget: budget,
    );
    late final StreamController<Message> controller;
    StreamSubscription<String>? inner;
    var cancelled = false;
    // The turn ended on its own (done, or the error the handle's stream ends
    // with): a done event, and a subscriber that cancels on the error, also
    // run onCancel, and there is nothing left to stop.
    var ended = false;
    final turn = Object();
    void release() {
      if (identical(_sending, turn)) _sending = null;
    }

    void endWith(Object error, StackTrace stack) {
      ended = true;
      controller
        ..addError(error, stack)
        ..close();
    }

    controller = StreamController<Message>(
      sync: true,
      onListen: () {
        if (_closed) {
          endWith(
            const ConversationClosedException(
              'The conversation was closed before its message was sent.',
            ),
            StackTrace.current,
          );
          return;
        }
        if (_sending != null) {
          endWith(StateError(_stillSending), StackTrace.current);
          return;
        }
        _sending = turn;

        inner = _handle
            .chatRawMessage(json, enableThinking: enable, options: options)
            .listen(
              (chunk) {
                if (cancelled) return;
                final Message piece;
                try {
                  piece = messageFromChunk(chunk);
                } on Object catch (e, st) {
                  if (e is! FormatException && e is! StateError) rethrow;
                  controller.addError(
                    TurnFailedException(
                      'LiteRT-LM sent a reply this release cannot read: $e',
                      cause: e,
                    ),
                    st,
                  );
                  return;
                }
                controller.add(piece);
              },
              onError: (Object error, StackTrace stack) {
                // The handle's stream ends with its error: this turn is over.
                ended = true;
                release();
                if (cancelled) return;
                controller.addError(_mapError(error), stack);
              },
              onDone: () {
                ended = true;
                release();
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
        release();
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
        // Bounded: the native turn layer already gives a stopped turn 2 s and
        // says so when it does not end; this only keeps the cancel from
        // waiting longer than that layer.
        return nativeEnded.future.timeout(
          const Duration(seconds: 5),
          onTimeout: sub.cancel,
        );
      },
    );
    return controller.stream;
  }

  static const _stillSending =
      'A reply is still streaming; cancel it or wait for its end before '
      'sending the next message.';

  void _checkNotSending() {
    if (_sending != null) throw StateError(_stillSending);
  }

  /// The current reply no longer holds the conversation: the next message
  /// may be sent, and the current turn's end no longer frees anything.
  void _letGo() => _sending = null;

  /// Stops the reply in flight, keeping what was generated: native stops at
  /// its next token (a prefill in progress finishes first) and the stream
  /// then ends normally, with every piece produced before the stop. Swift's
  /// `cancel()`. Cancelling the subscription instead stops native too, but
  /// drops what has not reached the subscriber. The next message may be sent
  /// at once: it waits for the stopped turn to end. A message still waiting
  /// for the turn before it is not sent.
  void cancel() {
    _letGo();
    _handle.cancelGeneration();
  }

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
    if (error is LiteRtLmException) return error;
    if (error is LiteRtLmTurnCancelledException) {
      return TurnFailedException('$error', cause: error);
    }
    // Native's record of this send: a message that did not fit.
    if (_handle.lastTurnEnd == NativeLastTurnEnd.contextFull) {
      return ContextFullException('$error');
    }
    if (error is Error) return error;
    return TurnFailedException('$error', cause: error);
  }

  /// What LiteRT-LM's benchmark reports about this conversation.
  BenchmarkInfo getBenchmarkInfo() => _handle.getSessionMetrics();

  /// Ends the conversation. A reply still streaming ends with
  /// [ConversationClosedException].
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _handle.close();
  }
}

/// A conversation over [handle], as [Engine] makes one.
Conversation newConversation(
  ConversationHandle handle, {
  required ConversationConfig config,
  required void Function() thinkingTokenBudgetCapsNothing,
}) => Conversation._(
  handle,
  config: config,
  thinkingTokenBudgetCapsNothing: thinkingTokenBudgetCapsNothing,
);

/// A conversation over [handle], for tests that drive it with a fake.
Conversation conversationForTest(
  ConversationHandle handle, {
  ConversationConfig? config,
}) => Conversation._(
  handle,
  config: config ?? ConversationConfig(),
  thinkingTokenBudgetCapsNothing: () {},
);

/// How many tokens [text] is, by [conversation]'s model's own tokenizer;
/// null when the engine cannot tell (closed, or the native call failed).
Future<int?> conversationTokenCount(Conversation conversation, String text) =>
    conversation._handle.tokenCount(text);

/// The handle under [conversation].
ConversationHandle conversationHandle(Conversation conversation) =>
    conversation._handle;

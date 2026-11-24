// LiteRT-LM's Kotlin/Swift `Conversation`: messages in, a streamed reply out,
// over one of the conversation handles of `ffi/conversation_handles.dart`
// (its own native conversation, or a turn of the shared one) or, on the web,
// over `web/web_conversation_handle.dart`. No dart:ffi, no dart:io: the same
// class on every platform.

import 'dart:async';
import 'dart:convert' show JsonUnsupportedObjectError, jsonEncode;

import '../ffi/native_turns.dart'
    show LiteRtLmTurnCancelledException, LiteRtLmTurnClosedException;
import '../runtime/conversation_handle.dart'
    show ConversationHandle, NativeBenchmark, NativeLastTurnEnd;
import '../runtime/send_options.dart';
import '../runtime/errors.dart';
import '../runtime/runtime_log.dart';
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

/// The most rounds of automatic tool calls one message may take: the reply
/// that still calls tools after them fails the send. Kotlin's and Swift's
/// `RECURRING_TOOL_CALL_LIMIT`. Internal: not exported.
const recurringToolCallLimit = 25;

/// Native failed the turn, or cancelled it without being asked, or the model
/// still called tools after 25 rounds of automatic tool calls. The
/// next message rebuilds the conversation from its history when native's
/// conversation needs it.
final class TurnFailedException extends LiteRtLmException {
  const TurnFailedException(super.message, {this._cause});

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
///
/// Tools with [Tool.execute] are run by the conversation itself
/// ([ConversationConfig.automaticToolCalling]): each round of calls and its
/// results is one more native send of the same message, and the reply
/// streams on with the model's next answer. A stop during a round stops that
/// round's reply and is recovered as any stopped reply; a stop while the tools
/// run ends the reply with their calls, whose results are not sent.
///
/// On the web the runtime refuses every send after a stop, so the next message
/// goes to a new runtime conversation built from the history, the stopped
/// exchange put back. Thinking and template variables are the conversation's
/// (a message that asks for others, or for a repetition penalty, a no-repeat
/// n-gram, suppressed tokens or a thinking budget, ends with an
/// [UnsupportedError]); there is no [ContextFullException] (the runtime's own
/// error is a [TurnFailedException]).
final class Conversation {
  Conversation._(
    this._handle, {
    required this._config,
    required void Function() thinkingTokenBudgetCapsNothing,
    required this._engineClosed,
  }) : _budgetCapsNothing = thinkingTokenBudgetCapsNothing,
       _automaticTools =
           _config.automaticToolCalling &&
               _config.tools.any((tool) => tool.execute != null)
           ? {for (final tool in _config.tools) tool.name: tool}
           : null;

  final ConversationHandle _handle;
  final ConversationConfig _config;

  /// The declared tools by name while the conversation runs tool calls
  /// itself: [ConversationConfig.automaticToolCalling] is on and some tool
  /// has [Tool.execute]. Null otherwise: every reply reaches the caller as
  /// native wrote it.
  final Map<String, Tool>? _automaticTools;
  final void Function() _budgetCapsNothing;
  final bool Function() _engineClosed;
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
  /// When the conversation runs tool calls itself
  /// ([ConversationConfig.automaticToolCalling]), the reply streams the text
  /// and thought of every round; the pieces with the calls it ran are not
  /// streamed. A reply whose calls it does not run streams them as native
  /// wrote them, and the reply ends there.
  ///
  /// The message is sent when the stream is listened to. The stream ends with
  /// an error for: [ContextFullException] (the message did not fit),
  /// [ConversationClosedException] (closed before or while streaming),
  /// [ConstraintUnsupportedException] (the response format was refused, or
  /// combined with a thinking budget), and [TurnFailedException] for any
  /// other failure (native failed or cancelled unasked, or the model still
  /// called tools after 25 automatic rounds). A chunk native wrote
  /// in a shape this release cannot read is a [TurnFailedException] event
  /// too, and the reply streams on after it. Programming errors stay [Error]s:
  /// a send on a conversation that is closed, or whose engine is closed, is a
  /// [StateError] thrown by this call.
  Stream<Message> sendMessageStream(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    ThinkingConfig? thinkingConfig,
  }) => _send(
    message,
    extraContext: extraContext,
    repetitionPenaltyConfig: repetitionPenaltyConfig,
    noRepeatNgramConfig: noRepeatNgramConfig,
    suppressTokens: suppressTokens,
    thinkingConfig: thinkingConfig,
  );

  /// [sendMessageStream], telling [onNextRound] each time an automatic round
  /// of tool calls has run and the model's next reply is about to stream.
  Stream<Message> _send(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    ThinkingConfig? thinkingConfig,
    void Function()? onNextRound,
  }) {
    if (_closed) throw StateError('The conversation is closed.');
    if (_engineClosed()) throw StateError('The engine is closed.');
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
    final automaticTools = _automaticTools;
    SendOptions optionsFor({required bool unconstrained}) => SendOptions(
      extraContext: merged,
      repetitionPenalty: repetitionPenaltyConfig,
      noRepeatNgram: noRepeatNgramConfig,
      suppressTokens: suppressTokens == null
          ? null
          : List.unmodifiable(suppressTokens),
      thinkingTokenBudget: budget,
      unconstrained: unconstrained,
    );
    // Kotlin's and Swift's rule: while automatic tools are pending, a
    // message that is not a tool response goes without the response format,
    // so that the model can call them; tool responses keep it.
    final options = optionsFor(
      unconstrained:
          automaticTools != null &&
          _config.responseFormat != null &&
          message.role != Role.tool,
    );
    late final StreamController<Message> controller;
    // The native send of the current round; null while tools run.
    StreamSubscription<String>? inner;
    var cancelled = false;
    // The rounds of tool calls run automatically so far.
    var rounds = 0;
    // The current round's pieces that carry tool calls, held back until the
    // round ends shows whether they are run or returned to the caller.
    var held = <Message>[];
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
        if (_closed || _engineClosed()) {
          endWith(
            ConversationClosedException(
              _closed
                  ? 'The conversation was closed before its message was sent.'
                  : 'The engine was closed before the message was sent.',
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

        void finish() {
          ended = true;
          release();
          if (!controller.isClosed) controller.close();
        }

        // Ends a turn that held the conversation with [error].
        void fail(Object error, StackTrace stack) {
          release();
          endWith(error, stack);
        }

        late void Function(String json, SendOptions options) round;

        // The tool calls of the round that just ended: run them and send
        // their results, return them to the caller, or fail the turn.
        void afterRound() {
          final pieces = held;
          held = [];
          final calls = [for (final piece in pieces) ...piece.toolCalls];
          final tools = automaticTools;
          if (calls.isEmpty || tools == null) return finish();
          // A stop (cancel()) let the turn go: no further round starts, and
          // the calls are returned unrun with what else was generated.
          final stopped = !identical(_sending, turn);
          final unrunnable = calls.any((call) {
            final tool = tools[call.name];
            return tool != null && tool.execute == null;
          });
          if (stopped || unrunnable) {
            for (final piece in pieces) {
              controller.add(piece);
            }
            return finish();
          }
          if (rounds == recurringToolCallLimit) {
            return fail(
              TurnFailedException(
                'The model still called tools after $recurringToolCallLimit '
                'rounds of automatic tool calls for one message (the '
                'recurring tool call limit, as in Kotlin and Swift).',
              ),
              StackTrace.current,
            );
          }
          rounds++;
          // The text and thought of the pieces that carried the calls.
          for (final piece in pieces) {
            if (piece.contents.isEmpty && piece.channels.isEmpty) continue;
            controller.add(
              Message(
                role: piece.role,
                contents: piece.contents,
                channels: piece.channels,
              ),
            );
          }
          _runTools(calls, tools).then(
            (responses) {
              // The subscription was cancelled while the tools ran: the
              // turn is over, and nothing is listening.
              if (cancelled) return;
              // Stopped while the tools ran: their results are not sent, and
              // the calls are returned as a stop before them would.
              if (!identical(_sending, turn)) {
                controller.add(Message(role: Role.model, toolCalls: calls));
                return finish();
              }
              if (_closed || _engineClosed()) {
                return fail(
                  ConversationClosedException(
                    _closed
                        ? 'The conversation was closed while its tools ran.'
                        : 'The engine was closed while the tools ran.',
                  ),
                  StackTrace.current,
                );
              }
              onNextRound?.call();
              round(
                jsonEncode(messageJson(Message.tool(responses))),
                optionsFor(unconstrained: false),
              );
            },
            onError: (Object e, StackTrace st) {
              if (cancelled) return;
              fail(
                TurnFailedException(
                  'Could not send the results of the automatic tool calls: '
                  '$e',
                  cause: e,
                ),
                st,
              );
            },
          );
        }

        round = (String json, SendOptions options) {
          final sub = _handle
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
                  if (automaticTools != null && piece.toolCalls.isNotEmpty) {
                    held.add(piece);
                    return;
                  }
                  controller.add(piece);
                },
                onError: (Object error, StackTrace stack) {
                  // The handle's stream ends with its error: this turn is
                  // over, with no further round.
                  ended = true;
                  release();
                  if (cancelled) return;
                  controller.addError(_mapError(error), stack);
                },
                onDone: () {
                  inner = null;
                  if (ended) return finish();
                  afterRound();
                },
              );
          inner = sub;
          if (controller.isPaused) sub.pause();
        };
        round(json, options);
      },
      onPause: () => inner?.pause(),
      onResume: () => inner?.resume(),
      onCancel: () {
        // Also while tools run (no native send then): the result of the
        // round is dropped, and no further round starts.
        if (ended) return null;
        cancelled = true;
        // A turn cancel() already let go was asked to stop then; asking
        // again now would stop whatever reply holds the conversation next.
        final holdsConversation = identical(_sending, turn);
        // The next message may be sent at once: it waits for this turn to
        // end and for the conversation's recovery before it is sent.
        release();
        final sub = inner;
        if (sub == null) return null;
        // Ask native to stop, then wait for the turn to end on its own, as a
        // stop always has: the handle records and recovers a turn that ended,
        // and the native lock is released at that end, not at the cancel.
        if (holdsConversation) _handle.cancelGeneration();
        final nativeEnded = Completer<void>();
        sub
          ..onData((_) {})
          ..onError((Object _, StackTrace _) {})
          ..onDone(() {
            ended = true;
            if (!nativeEnded.isCompleted) nativeEnded.complete();
          });
        if (sub.isPaused) sub.resume();
        // Bounded: the native turn layer gives a stopped turn 2 s and says so
        // when it does not end; this only keeps the cancel from waiting
        // longer than that. On the web the handle's own drain timer (30 s)
        // decides when a stopped generation is given up on, and the page
        // lock stays held until then: this bound only lets the cancel return.
        return nativeEnded.future.timeout(
          const Duration(seconds: 5),
          onTimeout: sub.cancel,
        );
      },
    );
    return controller.stream;
  }

  /// Runs [calls] in order with [tools] and returns one tool response per
  /// call. Never fails: a call to a name no tool declares, an `execute` that
  /// throws and a result that is not JSON are each answered with the error
  /// as text, as Kotlin's `ToolManager` answers them.
  static Future<List<Content>> _runTools(
    List<ToolCall> calls,
    Map<String, Tool> tools,
  ) async => [
    for (final call in calls)
      Content.toolResponse(call.name, await _runTool(call, tools[call.name])),
  ];

  static Future<Object?> _runTool(ToolCall call, Tool? tool) async {
    final execute = tool?.execute;
    if (execute == null) return 'Error: Tool not found: ${call.name}';
    final Object? result;
    try {
      result = await execute(call.arguments);
    } on Object catch (e) {
      runtimeLog(
        '[Conversation] tool ${call.name} threw; the model gets the error: $e',
      );
      return 'Error: $e';
    }
    try {
      jsonEncode(result);
    } on JsonUnsupportedObjectError catch (e) {
      runtimeLog(
        '[Conversation] tool ${call.name} returned a value that is not JSON; '
        'the model gets the error: ${e.unsupportedObject.runtimeType}',
      );
      return 'Error: the result of ${call.name} is not JSON '
          '(${e.unsupportedObject.runtimeType}).';
    }
    return result;
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
  ///
  /// When the conversation runs tool calls itself
  /// ([ConversationConfig.automaticToolCalling]), the reply is the model's
  /// last answer, the one after the final round of tool results, as Kotlin's
  /// and Swift's `sendMessage` return it; [sendMessageStream] streams the
  /// text and thought of every round.
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
    await for (final piece in _send(
      message,
      extraContext: extraContext,
      repetitionPenaltyConfig: repetitionPenaltyConfig,
      noRepeatNgramConfig: noRepeatNgramConfig,
      suppressTokens: suppressTokens,
      thinkingConfig: thinkingConfig,
      onNextRound: () {
        text.clear();
        thought.clear();
        calls.clear();
      },
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
    // A native call that failed during the turn (a rebuild that could not
    // reopen the conversation) is a failed turn, as any other.
    if (error is LiteRtLmNativeException) {
      return TurnFailedException('$error', cause: error);
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

  /// What LiteRT-LM's benchmark reports about this conversation. Refused on
  /// the web with an [UnsupportedError]: the runtime reports it only in its
  /// benchmark mode, which litertlm_dart does not turn on there.
  BenchmarkInfo getBenchmarkInfo() => _handle.getSessionMetrics();

  /// Ends the conversation. A reply still streaming ends with
  /// [ConversationClosedException]; a later send is a [StateError]. A second
  /// call completes when the first does.
  Future<void> close() {
    _closed = true;
    return _handle.close();
  }
}

/// A conversation over [handle], as `Engine` makes one.
Conversation newConversation(
  ConversationHandle handle, {
  required ConversationConfig config,
  required void Function() thinkingTokenBudgetCapsNothing,
  required bool Function() engineClosed,
}) => Conversation._(
  handle,
  config: config,
  thinkingTokenBudgetCapsNothing: thinkingTokenBudgetCapsNothing,
  engineClosed: engineClosed,
);

/// A conversation over [handle], for tests that drive it with a fake.
Conversation conversationForTest(
  ConversationHandle handle, {
  ConversationConfig? config,
  bool Function()? engineClosed,
}) => Conversation._(
  handle,
  config: config ?? ConversationConfig(),
  thinkingTokenBudgetCapsNothing: () {},
  engineClosed: engineClosed ?? () => false,
);

/// How many tokens [text] is, by [conversation]'s model's own tokenizer;
/// null when the engine cannot tell (closed, or the native call failed).
Future<int?> conversationTokenCount(Conversation conversation, String text) =>
    conversation._handle.tokenCount(text);

/// The handle under [conversation].
ConversationHandle conversationHandle(Conversation conversation) =>
    conversation._handle;

/// LiteRT-LM's benchmark record of [conversation], turn by turn; null when
/// native gives none. For `benchmark`.
NativeBenchmark? conversationNativeBenchmark(Conversation conversation) =>
    conversation._handle.getNativeBenchmark();

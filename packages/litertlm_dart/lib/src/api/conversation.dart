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
import '../runtime/tool_choice_json.dart';
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
/// round's reply and is recovered as any stopped reply. A stop while the tools
/// run ends the reply with their calls: the calls have run, only their
/// results were not sent to the model, so a caller must not run them again
/// blindly. A close while the tools run ends the reply at once with
/// [ConversationClosedException]; their late results are dropped, and the
/// calls after the one running are not run.
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
    required this._engineCloseListeners,
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

  /// Called by the engine's close, which sends nothing a turn whose tools are
  /// running could hear: each such turn is registered here while its tools
  /// run.
  final Set<void Function()> _engineCloseListeners;

  /// The turns whose tools are running: [close] and the engine's close end
  /// them at once, as they end a reply that is streaming.
  final _toolPhases = <void Function()>{};
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
    ToolChoice? toolChoice,
  }) => _send(
    message,
    extraContext: extraContext,
    repetitionPenaltyConfig: repetitionPenaltyConfig,
    noRepeatNgramConfig: noRepeatNgramConfig,
    suppressTokens: suppressTokens,
    thinkingConfig: thinkingConfig,
    toolChoice: toolChoice,
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
    ToolChoice? toolChoice,
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
    final choiceJson = toolChoiceJson(
      toolChoice,
      toolNames: [for (final tool in _config.tools) tool.name],
      hasResponseFormat: _config.responseFormat != null,
    );
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
    SendOptions optionsFor({
      required bool unconstrained,
      String? toolChoiceJson,
    }) => SendOptions(
      extraContext: merged,
      repetitionPenalty: repetitionPenaltyConfig,
      noRepeatNgram: noRepeatNgramConfig,
      suppressTokens: suppressTokens == null
          ? null
          : List.unmodifiable(suppressTokens),
      thinkingTokenBudget: budget,
      unconstrained: unconstrained,
      toolChoiceJson: toolChoiceJson,
    );
    // Kotlin's and Swift's rule: while automatic tools are pending, a
    // message that is not a tool response goes without the response format,
    // so that the model can call them; tool responses keep it.
    // The tool choice goes with the message's own send only, as in Kotlin
    // and Swift: the rounds that answer tool results run the default, so
    // `required` cannot loop.
    final options = optionsFor(
      unconstrained:
          automaticTools != null &&
          _config.responseFormat != null &&
          message.role != Role.tool,
      toolChoiceJson: choiceJson,
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
          ConversationClosedException? closedNow(String when) =>
              _closed || _engineClosed()
              ? ConversationClosedException(
                  _closed
                      ? 'The conversation was closed $when.'
                      : 'The engine was closed $when.',
                )
              : null;
          // Closed as native ended the round: no tool runs.
          if (closedNow('before its tools ran') case final closed?) {
            return fail(closed, StackTrace.current);
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
          // While the tools run no native send is active, so nothing else
          // would end the reply at a close: the close ends it here, and the
          // tools' late results are dropped.
          var over = false;
          late final void Function() closedWhileRunning;
          // An execute that never completes must not keep the turn
          // registered: the phase ends at the close too.
          void endPhase() {
            _toolPhases.remove(closedWhileRunning);
            _engineCloseListeners.remove(closedWhileRunning);
          }

          closedWhileRunning = () {
            endPhase();
            if (over || cancelled) return;
            over = true;
            fail(
              closedNow('while its tools ran') ??
                  const ConversationClosedException(
                    'The conversation was closed while its tools ran.',
                  ),
              StackTrace.current,
            );
          };

          _toolPhases.add(closedWhileRunning);
          _engineCloseListeners.add(closedWhileRunning);
          unawaited(() async {
            try {
              // A close, or a cancelled subscription, while a call runs
              // stops the calls after it: nobody will read their results.
              final responses = await _runTools(
                calls,
                tools,
                stopped: () => over || cancelled,
              );
              if (responses == null || over) return;
              over = true;
              // The subscription was cancelled while the tools ran: the
              // turn is over, and nothing is listening.
              if (cancelled) return;
              // Stopped while the tools ran: the calls ran, but their
              // results are not sent; the reply ends with the calls.
              if (!identical(_sending, turn)) {
                controller.add(Message(role: Role.model, toolCalls: calls));
                return finish();
              }
              if (closedNow('while its tools ran') case final closed?) {
                return fail(closed, StackTrace.current);
              }
              onNextRound?.call();
              round(
                jsonEncode(messageJson(Message.tool(responses))),
                optionsFor(unconstrained: false),
              );
            } on Object catch (e, st) {
              // Never left holding the conversation: a send that throws
              // (a handle that refuses it) ends the turn.
              if (cancelled || controller.isClosed) return;
              fail(
                TurnFailedException(
                  'Could not send the results of the automatic tool calls: '
                  '$e',
                  cause: e,
                ),
                st,
              );
            } finally {
              endPhase();
            }
          }());
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
                    // Only the calls wait for the round's end; the text and
                    // thought go out now, in native's order.
                    if (piece.contents.isEmpty && piece.channels.isEmpty) {
                      held.add(piece);
                    } else {
                      controller.add(
                        Message(
                          role: piece.role,
                          contents: piece.contents,
                          channels: piece.channels,
                        ),
                      );
                      held.add(
                        Message(role: piece.role, toolCalls: piece.toolCalls),
                      );
                    }
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
                  // The calls this round made before it failed reach the
                  // caller unrun, as they would without automatic calling.
                  for (final piece in held) {
                    controller.add(piece);
                  }
                  held = [];
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
  /// call. A call to a name no tool declares, an `execute` that throws and a
  /// result that is not JSON are each answered with the error as text
  /// (`Error: …`), as Kotlin's `ToolManager` answers them with its own text
  /// (`Error occured. …`), and printed as a warning, release builds included:
  /// the model gets the text, the developer needs the cause.
  ///
  /// Null when [stopped] became true before a call: that call and the ones
  /// after it are not run.
  static Future<List<Content>?> _runTools(
    List<ToolCall> calls,
    Map<String, Tool> tools, {
    required bool Function() stopped,
  }) async {
    final responses = <Content>[];
    for (final call in calls) {
      if (stopped()) return null;
      responses.add(
        Content.toolResponse(call.name, await _runTool(call, tools[call.name])),
      );
    }
    return responses;
  }

  static Future<Object?> _runTool(ToolCall call, Tool? tool) async {
    final execute = tool?.execute;
    if (execute == null) {
      final answer = 'Error: Tool not found: ${call.name}';
      _warnTool(
        'the model called ${call.name}, which no tool declares; it was '
        'answered "$answer".',
      );
      return answer;
    }
    final Object? result;
    try {
      result = await execute(call.arguments);
    } on Object catch (e, st) {
      final answer = 'Error: $e';
      _warnTool(
        'tool ${call.name} threw; the model was answered "$answer".\n$st',
      );
      return answer;
    }
    try {
      jsonEncode(result);
    } on JsonUnsupportedObjectError catch (e) {
      final answer =
          'Error: the result of ${call.name} is not JSON '
          '(${e.unsupportedObject.runtimeType}).';
      _warnTool(
        'tool ${call.name} returned a value that is not JSON '
        '(${e.unsupportedObject.runtimeType}); the model was answered '
        '"$answer".',
      );
      return answer;
    }
    return result;
  }

  /// A failed automatic tool call, printed in every build: runtimeLog is
  /// silent in a release build, where a failing tool gets reported.
  static void _warnTool(String message) {
    // ignore: avoid_print
    print('[litertlm_dart] WARNING: automatic tool calling: $message');
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
    ToolChoice? toolChoice,
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
      toolChoice: toolChoice,
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
    for (final end in _toolPhases.toList()) {
      end();
    }
    return _handle.close();
  }
}

/// A conversation over [handle], as `Engine` makes one. The engine calls
/// each of [engineCloseListeners] when it closes.
Conversation newConversation(
  ConversationHandle handle, {
  required ConversationConfig config,
  required void Function() thinkingTokenBudgetCapsNothing,
  required bool Function() engineClosed,
  required Set<void Function()> engineCloseListeners,
}) => Conversation._(
  handle,
  config: config,
  thinkingTokenBudgetCapsNothing: thinkingTokenBudgetCapsNothing,
  engineClosed: engineClosed,
  engineCloseListeners: engineCloseListeners,
);

/// A conversation over [handle], for tests that drive it with a fake; a test
/// calls [engineCloseListeners] as an engine's close would.
Conversation conversationForTest(
  ConversationHandle handle, {
  ConversationConfig? config,
  bool Function()? engineClosed,
  Set<void Function()>? engineCloseListeners,
}) => Conversation._(
  handle,
  config: config ?? ConversationConfig(),
  thinkingTokenBudgetCapsNothing: () {},
  engineClosed: engineClosed ?? () => false,
  engineCloseListeners: engineCloseListeners ?? {},
);

/// How many tokens [text] is, by [conversation]'s model's own tokenizer;
/// null when the engine cannot tell (closed, or the native call failed).
Future<int?> conversationTokenCount(Conversation conversation, String text) =>
    conversation._handle.tokenCount(text);

/// The handle under [conversation].
ConversationHandle conversationHandle(Conversation conversation) =>
    conversation._handle;

/// The config [conversation] was created with, for the adapter's tests.
ConversationConfig conversationConfig(Conversation conversation) =>
    conversation._config;

/// LiteRT-LM's benchmark record of [conversation], turn by turn; null when
/// native gives none. For `benchmark`.
NativeBenchmark? conversationNativeBenchmark(Conversation conversation) =>
    conversation._handle.getNativeBenchmark();

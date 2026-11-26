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
    show
        ConversationHandle,
        ConversationStateAccess,
        NativeBenchmark,
        NativeLastTurnEnd;
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
    this._constraintRefusal,
    this._toolChoiceRefusal,
  }) : _budgetCapsNothing = thinkingTokenBudgetCapsNothing,
       _automaticTools =
           _config.automaticToolCalling &&
               _config.tools.any((tool) => tool.execute != null)
           ? {for (final tool in _config.tools) tool.name: tool}
           : null;

  final ConversationHandle _handle;
  final ConversationConfig _config;

  /// Why the engine's host and backend refuse constrained decoding, which a
  /// tool choice other than auto is as much as a response format; null where
  /// it was qualified.
  final String? _constraintRefusal;

  /// Why a tool choice other than auto is refused for the engine's model
  /// family (LiteRT-LM drops it for most families); null where the family
  /// applies one.
  final String? _toolChoiceRefusal;

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
  /// [maxOutputTokens] caps this message's reply, thinking included, in place
  /// of [ConversationConfig.maxOutputTokens] (below 1 is an [ArgumentError]):
  /// Kotlin's `maxOutputToken` and Swift's `maxOutputTokens` on
  /// `sendMessage`/`sendMessageAsync`/`sendMessageStream`
  /// (Conversation.kt, Conversation.swift), sent with each round of the
  /// message, tool rounds included, as both do. On the web it is refused
  /// ([UnsupportedError]): `@litert-lm/core` 0.20.0 takes an output cap per
  /// conversation only (`SessionConfig.maxOutputTokens`).
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
  /// [StateError] thrown by this call; on the stream, before anything is
  /// sent, a tool response on a conversation that declares no tools is an
  /// [ArgumentError], and a [toolChoice] other than auto on a model family
  /// that does not apply one (LiteRT-LM 0.20.0 applies it for Gemma 3,
  /// Gemma 3n, Gemma 4 and FunctionGemma only) an [UnsupportedError].
  Stream<Message> sendMessageStream(
    Message message, {
    Map<String, Object?>? extraContext,
    RepetitionPenaltyConfig? repetitionPenaltyConfig,
    NoRepeatNgramConfig? noRepeatNgramConfig,
    List<int>? suppressTokens,
    int? maxOutputTokens,
    ThinkingConfig? thinkingConfig,
    ToolChoice? toolChoice,
  }) => _send(
    message,
    extraContext: extraContext,
    repetitionPenaltyConfig: repetitionPenaltyConfig,
    noRepeatNgramConfig: noRepeatNgramConfig,
    suppressTokens: suppressTokens,
    maxOutputTokens: maxOutputTokens,
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
    int? maxOutputTokens,
    ThinkingConfig? thinkingConfig,
    ToolChoice? toolChoice,
    void Function()? onNextRound,
  }) {
    if (_closed) throw StateError('The conversation is closed.');
    if (_engineClosed()) throw StateError('The engine is closed.');
    _checkNotSending();
    if (maxOutputTokens != null && maxOutputTokens < 1) {
      throw ArgumentError.value(
        maxOutputTokens,
        'maxOutputTokens',
        'must be 1 or more',
      );
    }
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
    // A tool choice, auto included (it builds the message's own constraint),
    // is refused as the conversation's other constraints are: on the stream,
    // before anything is sent.
    if (toolChoice != null) {
      if (_constraintRefusal case final refusal?) {
        return Stream.error(ConstraintUnsupportedException(refusal));
      }
      if (toolChoice is! ToolChoiceAuto) {
        if (_toolChoiceRefusal case final refusal?) {
          return Stream.error(UnsupportedError(refusal));
        }
      }
    }
    // A tool response with no tools declared answers nothing the model
    // asked: the runtime takes it and the web one answers it with an empty
    // reply, so it is refused before anything is sent.
    if (_config.tools.isEmpty &&
        (message.role == Role.tool ||
            message.contents.any((c) => c is ToolResponseContent))) {
      return Stream.error(
        ArgumentError.value(
          message,
          'message',
          'is a tool response, but this conversation declares no tools '
              '(ConversationConfig.tools)',
        ),
      );
    }
    final automaticTools = _automaticTools;
    // Kotlin's and Swift's rule (Kotlin's `resolveResponseFormat`,
    // Conversation.kt; Swift's `shouldApplyResponseFormat`,
    // Conversation.swift): while automatic tools are pending, a message that
    // is not a tool response goes without the response format, so that the
    // model can call them; tool responses keep it.
    final firstUnconstrained =
        automaticTools != null &&
        _config.responseFormat != null &&
        message.role != Role.tool;
    final String? choiceJson;
    try {
      choiceJson = toolChoiceJson(
        toolChoice,
        toolNames: [for (final tool in _config.tools) tool.name],
        // Only a send that carries the format refuses a choice: the first
        // send while automatic tools are pending goes without it, and there
        // the choice applies, as in Kotlin and Swift.
        hasResponseFormat:
            _config.responseFormat != null && !firstUnconstrained,
      );
    } on ArgumentError catch (e, stack) {
      return Stream.error(e, stack);
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
      maxOutputTokens: maxOutputTokens,
      visualTokenBudget: _config.visualTokenBudget,
    );
    // The tool choice goes with the message's own send only, as in Kotlin
    // and Swift: the rounds that answer tool results run the default, so
    // `required` cannot loop.
    final options = optionsFor(
      unconstrained: firstUnconstrained,
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
      // The call's id, when the reply gave one, goes back with its result.
      responses.add(
        Content.toolResponse(
          call.name,
          await _runTool(call, tools[call.name]),
          id: call.id,
        ),
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
    int? maxOutputTokens,
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
      maxOutputTokens: maxOutputTokens,
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

  /// The tokens in this conversation's KV cache, prefill and decode: Kotlin's
  /// and Swift's `Conversation.getTokenCount()` (Conversation.kt,
  /// Conversation.swift), over `litert_lm_conversation_get_token_count`. A
  /// preface (system instruction, tools, initial messages) is prefilled with
  /// the first message, so it counts from then on.
  ///
  /// Natively it waits for the turn before it and for the recovery of a
  /// stopped one. Where conversations share one native conversation by
  /// replay (see `Engine.createConversation`) it is an [UnsupportedError]:
  /// there is no KV cache of this conversation's own. On the web it is
  /// `@litert-lm/core`'s `Conversation.getTokenCount()`. A [StateError] while
  /// a reply streams, or once the conversation or its engine is closed.
  Future<int> getTokenCount() => _state((s) => s.kvTokenCount());

  /// [message] as this conversation's prompt template renders it, for tests
  /// and logs: Swift's `renderMessageIntoString(_:)` (Conversation.swift) and
  /// Kotlin's experimental one (Conversation.kt), over
  /// `litert_lm_conversation_render_message_to_string`, which takes no
  /// template variables: Kotlin's `extraContext` argument has no C API
  /// counterpart, so it is not here. Where conversations share one native
  /// conversation by replay, and on the web (`@litert-lm/core` 0.20.0 has no
  /// render call), an [UnsupportedError].
  Future<String> renderMessageIntoString(Message message) =>
      _state((s) => s.renderMessage(jsonEncode(messageJson(message))));

  /// This conversation's preface (system instruction, tools, initial
  /// messages) as its prompt template renders it: Swift's and Kotlin's
  /// `renderPrefaceIntoString()`, over
  /// `litert_lm_conversation_render_preface_to_string`. Refused as
  /// [renderMessageIntoString] is.
  Future<String> renderPrefaceIntoString() => _state((s) => s.renderPreface());

  /// A new conversation with this one's history, state and configuration,
  /// independent of it from then on: Kotlin's and Swift's
  /// `Conversation.clone()` (Conversation.kt, Conversation.swift), over
  /// `litert_lm_conversation_clone`, which copies the native conversation and
  /// its KV cache. Natively it waits for the turn before it and for the
  /// recovery of a stopped one. Where conversations share one native
  /// conversation by replay, the clone is a new conversation of the same
  /// configuration whose history is replayed when it first sends. On the
  /// web it is `@litert-lm/core`'s `Conversation.clone()`.
  ///
  /// A [StateError] while a reply streams, or once the conversation or its
  /// engine is closed.
  Future<Conversation> clone() async {
    final handle = await _state((s) => s.cloneHandle());
    if (_closed || _engineClosed()) {
      await handle.close();
      throw StateError(
        _closed ? 'The conversation is closed.' : 'The engine is closed.',
      );
    }
    return Conversation._(
      handle,
      config: _config,
      thinkingTokenBudgetCapsNothing: _budgetCapsNothing,
      engineClosed: _engineClosed,
      engineCloseListeners: _engineCloseListeners,
      constraintRefusal: _constraintRefusal,
      toolChoiceRefusal: _toolChoiceRefusal,
    );
  }

  /// Runs [op] over the handle's state, between replies.
  Future<T> _state<T>(Future<T> Function(ConversationStateAccess s) op) async {
    if (_closed) throw StateError('The conversation is closed.');
    if (_engineClosed()) throw StateError('The engine is closed.');
    _checkNotSending();
    final handle = _handle;
    if (handle is! ConversationStateAccess) {
      throw UnsupportedError('This conversation cannot read its own state.');
    }
    return op(handle as ConversationStateAccess);
  }

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
  String? constraintRefusal,
  String? toolChoiceRefusal,
}) => Conversation._(
  handle,
  config: config,
  thinkingTokenBudgetCapsNothing: thinkingTokenBudgetCapsNothing,
  engineClosed: engineClosed,
  engineCloseListeners: engineCloseListeners,
  constraintRefusal: constraintRefusal,
  toolChoiceRefusal: toolChoiceRefusal,
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

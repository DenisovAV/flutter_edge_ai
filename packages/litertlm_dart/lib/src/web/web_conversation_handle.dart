// The handle a web `Conversation` drives: one `@litert-lm/core` conversation
// ([JsLiteRtLmConversation]), its streamed reply read chunk by chunk from the
// JS async iterator and handed on as the JSON native streams, so the shared
// `Conversation` reads both arms the same way (`messageFromChunk`).
//
// What it decides, and why:
// - The page lock (page_lock.dart) is held from before `sendMessageStreaming`
//   until the JS stream has ENDED, not until the Dart listener stops: a
//   generation stays suspended inside the page's WebAssembly module for its
//   whole length, and the EmbeddingGemma 2 engine must not enter the module
//   meanwhile. A listener that cancels early leaves the pump reading the stream
//   to its end, emitting nothing.
// - The next message of the conversation waits on the same lock, so it is sent
//   only once the turn before it has ended: `@litert-lm/core` refuses a send
//   while its conversation is busy.
// - A stop ([cancelGeneration]) is `conversation.cancel()`; whatever the JS
//   stream then ends with, a chunk, done or an error, the turn ends normally,
//   as `Conversation.cancel` promises. A close ([close]) stops the same way;
//   a turn it cut short ends with [LiteRtLmTurnClosedException] unless a stop
//   was asked first, as natively.
// - The web runtime takes thinking and the template variables per
//   conversation (its `preface.extra_context`), not per message, and has no
//   per-message decoding options: a send that asks for either differently is
//   an [UnsupportedError], never silently ignored. Images and audio are
//   refused the same way: the web `Engine` loads no vision or audio executor.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../ffi/native_turns.dart' show LiteRtLmTurnClosedException;
import 'package:meta/meta.dart' show visibleForTesting;

import '../api/message.dart' show messageFromChunk;
import '../runtime/conversation_handle.dart';
import '../runtime/errors.dart' show LiteRtLmNativeException;
import '../runtime/response_text.dart';
import '../runtime/runtime_log.dart';
import '../runtime/send_options.dart';
import '../runtime/types.dart' show BenchmarkInfo;
import 'litert_lm_js.dart';
import 'page_lock.dart';
import 'web_runtime_version.dart';

/// A [ConversationHandle] over one `@litert-lm/core` conversation.
final class WebConversationHandle implements ConversationHandle {
  WebConversationHandle(
    this._conversation, {
    required this._enableThinking,
    required this._extraContext,
    required this._onGeneration,
    required this._rebuild,
    this._onClose,
    LiteRtLmPageLock? pageLock,
  }) : _pageLock = pageLock ?? liteRtLmPageLock;

  JsLiteRtLmConversation _conversation;

  /// A new runtime conversation, set up as this one was, whose history is
  /// [history]: what replaces a conversation the runtime refuses after a
  /// stop. Runs while this handle holds the page lock, so it takes none.
  final Future<JsLiteRtLmConversation> Function(List<Object?> history) _rebuild;
  final bool _enableThinking;
  final Map<String, Object?> _extraContext;
  final void Function() _onGeneration;
  final void Function()? _onClose;
  final LiteRtLmPageLock _pageLock;

  bool _closed = false;

  /// The turns asked for and not ended yet, oldest first: the one streaming
  /// and those queued behind it on the page lock. A stop marks every one of
  /// them, so a queued turn is never sent and the streaming one ends normally
  /// however the runtime ends it.
  final _liveTurns = <_Turn>[];

  /// The turn holding the page, and the lease it holds; null between turns.
  _Turn? _streaming;

  /// `conversation.cancel()` was called: the runtime fails every later send
  /// on this conversation with "Task cancelled" (0.18.0 and 0.19.0, measured
  /// 2026-11-23), so the next turn first replaces it ([_rebuildConversation]).
  bool _mustRebuild = false;

  /// The exchange a stop cut short, kept as natively: its message and the
  /// reply generated before the stop, put back after the runtime's history
  /// (which drops a cancelled turn). Null when the stopped turn produced
  /// nothing: it is taken back.
  ({Map<String, Object?> message, String reply})? _stopped;

  /// Completes once [close] has drained the last generation and deleted the
  /// JS conversation.
  Future<void> get closed => _closedFuture ?? Future<void>.value();
  Future<void>? _closedFuture;

  /// How long [close] waits for a cancelled generation to end; a test
  /// shortens it.
  @visibleForTesting
  static Duration closeDrainTimeout = const Duration(seconds: 30);

  /// The JS `JSON.stringify`, looked up once.
  static final JSObject _json = globalContext.getProperty<JSObject>(
    'JSON'.toJS,
  );

  static String _stringify(JSAny value) =>
      _json.callMethod<JSString>('stringify'.toJS, value).toDart;

  /// Null on the web: the runtime counts a conversation's tokens
  /// (`getTokenCount()`), but has no tokenizer for a text.
  @override
  Future<int?> tokenCount(String text) => Future.value(null);

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => chatRaw(
    text,
    imageBytes: imageBytes,
    audioBytes: audioBytes,
    enableThinking: enableThinking,
  ).map(extractResponseText).where((text) => text.isNotEmpty);

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    if ((imageBytes?.isNotEmpty ?? false) || audioBytes != null) {
      return Stream.error(_unsupportedMedia());
    }
    return chatRawMessage(
      jsonEncode({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      }),
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) {
    if (_closed) throw StateError('Conversation handle is closed');
    final refusal = _refusal(messageJson, enableThinking, options);
    if (refusal != null) return Stream.error(refusal);
    final message = _jsMessage(messageJson);
    final turn = _Turn(jsonDecode(messageJson) as Map<String, Object?>);
    _liveTurns.add(turn);

    final controller = StreamController<String>();
    // The listener let go of the reply: the pump reads the JS stream to its
    // end, emitting nothing, and only then lets the next lock holder in.
    var listenerGone = false;

    void finish({Object? error, StackTrace? stack}) {
      if (turn.sent && turn.stopAsked && turn.reply.isNotEmpty) {
        _stopped = (message: turn.message, reply: turn.reply.toString());
      }
      _liveTurns.remove(turn);
      if (identical(_streaming, turn)) _streaming = null;
      turn.release();
      if (controller.isClosed) return;
      if (error != null && !listenerGone) controller.addError(error, stack);
      controller.close();
    }

    // How a turn that was asked to end ended: normally after a stop, with
    // [LiteRtLmTurnClosedException] after a close that came first.
    void finishAsked(StackTrace stack) => finish(
      error: turn.stopAsked ? null : LiteRtLmTurnClosedException(),
      stack: stack,
    );

    void start() {
      final stream = _conversation.sendMessageStreaming(message);
      turn.sent = true;
      _onGeneration();
      final asyncIterator = globalContext
          .getProperty<JSObject>('Symbol'.toJS)
          .getProperty<JSAny>('asyncIterator'.toJS);
      final iterator =
          (stream.getProperty<JSFunction?>(asyncIterator) != null
                  ? stream.callMethod<JSObject>(asyncIterator)
                  : stream) // Already an iterator.
              as JsAsyncIterator;

      void pump() {
        // Every path ends in [finish] or another [pump]: a callback that
        // threw would otherwise keep the page lock, and with it every LLM and
        // EmbeddingGemma 2 call on the page, for good.
        void onStep(JSObject step) {
          try {
            final done = step.getProperty<JSAny?>('done'.toJS);
            if (!done.isA<JSBoolean>()) {
              // A runtime fault, not the caller's: a failed turn.
              throw LiteRtLmNativeException(
                '$liteRtLmWebRuntime streamed a step without a boolean `done`: '
                '${_stringify(step)}',
              );
            }
            if ((done as JSBoolean).toDart) {
              if (turn.asked) {
                finishAsked(StackTrace.current);
              } else {
                finish();
              }
              return;
            }
            final value = step.getProperty<JSAny?>('value'.toJS);
            if (value != null) {
              final json = _stringify(value);
              turn.reply.write(messageFromChunk(json).text);
              if (!listenerGone && !controller.isClosed) controller.add(json);
            }
          } catch (e, st) {
            if (turn.asked) {
              finishAsked(st);
            } else {
              finish(error: e, stack: st);
            }
            return;
          }
          pump();
        }

        void onError(Object error, StackTrace stack) {
          if (turn.asked) {
            // How the runtime ends a stopped generation (0.19.0 rejects the
            // stream) is its business: the turn was asked to end, and it did.
            runtimeLog(
              '[WebConversationHandle] the stopped generation ended with '
              '$error',
            );
            finishAsked(stack);
            return;
          }
          finish(error: error, stack: stack);
        }

        try {
          iterator.next().toDart.then(onStep, onError: onError);
        } catch (e, st) {
          onError(e, st);
        }
      }

      pump();
    }

    controller.onListen = () async {
      try {
        turn.lease = await _pageLock.acquire();
      } catch (e, st) {
        // A poisoned page: nothing more runs on it.
        finish(error: e, stack: st);
        return;
      }
      if (turn.asked || listenerGone) {
        // Stopped, closed or let go while it waited: never sent.
        if (turn.asked) {
          finishAsked(StackTrace.current);
        } else {
          finish();
        }
        return;
      }
      // From here the turn holds the page until its stream ends; close()
      // waits for that (a turn still queued above has nothing to wait for).
      _streaming = turn;
      try {
        if (_mustRebuild) await _rebuildConversation();
        if (turn.asked) {
          finishAsked(StackTrace.current);
          return;
        }
        start();
      } catch (e, st) {
        // Nothing reached the stream's end if the send threw: no drain.
        finish(error: e, stack: st);
      }
    };
    controller.onCancel = () {
      listenerGone = true;
    };
    return controller.stream;
  }

  /// Why the web runtime cannot send [messageJson] with these options; null
  /// when it can.
  Object? _refusal(
    String messageJson,
    bool enableThinking,
    SendOptions options,
  ) {
    if (enableThinking != _enableThinking) {
      return UnsupportedError(
        'On the web ($liteRtLmWebRuntime) thinking is set per conversation, '
        'in its ConversationConfig.thinkingConfig; this conversation has it '
        '${_enableThinking ? 'on' : 'off'}, so a message cannot turn it '
        '${enableThinking ? 'on' : 'off'}.',
      );
    }
    if (!_jsonEquals(options.extraContext, _extraContext)) {
      return UnsupportedError(
        'On the web ($liteRtLmWebRuntime) template variables are set per '
        'conversation, in its ConversationConfig.extraContext; a message '
        'cannot add or change them.',
      );
    }
    final perMessage = [
      if (options.repetitionPenalty != null) 'repetitionPenaltyConfig',
      if (options.noRepeatNgram != null) 'noRepeatNgramConfig',
      if (options.suppressTokens != null) 'suppressTokens',
      if (options.thinkingTokenBudget != null) 'a thinking token budget',
    ];
    if (perMessage.isNotEmpty) {
      return UnsupportedError(
        'The web runtime ($liteRtLmWebRuntime) has no ${perMessage.join(', ')} '
        'for a message.',
      );
    }
    final json = jsonDecode(messageJson);
    if (json case {'content': final List<Object?> parts}) {
      for (final part in parts) {
        if (part case {'type': 'image' || 'audio'}) return _unsupportedMedia();
      }
    }
    return null;
  }

  static UnsupportedError _unsupportedMedia() =>
      UnsupportedError(webNoMediaMessage);

  /// The message as `sendMessageStreaming` takes it: a user message of one
  /// text part as its bare string, which `@litert-lm/core` turns into a user
  /// message of that text; anything else (a tool result) as the object.
  static JSAny _jsMessage(String messageJson) {
    final json = jsonDecode(messageJson) as Map<String, Object?>;
    if (json case {
      'role': 'user',
      'content': [{'type': 'text', 'text': final String text}],
    } when json.length == 2) {
      return text.toJS;
    }
    return json.jsify()!;
  }

  @override
  void cancelGeneration() {
    for (final turn in _liveTurns) {
      turn.stopAsked = true;
    }
    _cancelJs();
  }

  void _cancelJs() {
    _mustRebuild = true;
    try {
      _conversation.cancel();
    } catch (e) {
      // It may throw when nothing is in flight.
      runtimeLog('[WebConversationHandle] conversation.cancel() threw: $e');
    }
  }

  /// Replaces the conversation the runtime refuses after a cancel by one
  /// rebuilt from its history, the stopped exchange put back after it, and
  /// deletes the old one. Runs holding the page lock.
  Future<void> _rebuildConversation() async {
    final history = [
      for (final message in (await _conversation.getHistory().toDart).toDart)
        message.dartify(),
    ];
    if (_stopped case (:final message, :final reply)) {
      history
        ..add(message)
        ..add({
          'role': 'assistant',
          'content': [
            {'type': 'text', 'text': reply},
          ],
        });
    }
    final next = await _rebuild(history);
    final old = _conversation;
    _conversation = next;
    _mustRebuild = false;
    _stopped = null;
    runtimeLog(
      '[WebConversationHandle] rebuilt the conversation after a stop '
      '(${history.length} messages replayed)',
    );
    try {
      await old.delete().toDart;
    } catch (e) {
      runtimeLog('[WebConversationHandle] deleting the stopped one: $e');
    }
  }

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) => Future.value(StoppedTurnRewind.unsupported);

  /// Refused on the web: the runtime reports a conversation's benchmark
  /// only in its benchmark mode (`benchmarkEnabled`), which litertlm_dart
  /// does not turn on there.
  @override
  BenchmarkInfo getSessionMetrics() => throw UnsupportedError(
    'On the web $liteRtLmWebRuntime reports a conversation\'s benchmark only '
    'in its benchmark mode, which litertlm_dart does not turn on.',
  );

  @override
  NativeBenchmark? getNativeBenchmark() => null;

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;

  /// Stops the generation in flight and every turn queued behind it, waits
  /// for its JS stream to end, and deletes the JS conversation. A stream
  /// that does not end within [closeDrainTimeout] poisons the page lock
  /// ([LiteRtLmPageLock.poisonFor]): the module may still be suspended in
  /// it, so nothing else may enter, and the returned future fails with that
  /// error. The conversation is then left to the page.
  @override
  Future<void> close() => _closedFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final turn in _liveTurns) {
      turn.closeAsked = true;
    }
    // Abort the JS generation before the engine is torn down: deleting the
    // engine while an iterator's next() still resolves against this
    // conversation would free what it reads.
    _cancelJs();
    try {
      final streaming = _streaming;
      if (streaming != null) {
        final drained = await streaming.ended.future
            .then((_) => true)
            .timeout(closeDrainTimeout, onTimeout: () => false);
        if (!drained) {
          _pageLock.poisonFor(
            streaming.lease!,
            'A stopped $liteRtLmWebRuntime generation did not end within '
            '${closeDrainTimeout.inSeconds} s of its conversation\'s close.',
          );
          throw _pageLock.poison!;
        }
      }
      try {
        await _conversation.delete().toDart;
      } catch (e) {
        runtimeLog('[WebConversationHandle] conversation.delete() failed: $e');
      }
    } finally {
      _onClose?.call();
    }
  }
}

/// One turn of a [WebConversationHandle]: whether it was asked to end, and
/// the page lease it holds while its stream runs.
final class _Turn {
  _Turn(this.message);

  /// The message, as the conversation API JSON.
  final Map<String, Object?> message;

  /// The text the runtime streamed for it so far.
  final reply = StringBuffer();

  /// `sendMessageStreaming` was called for it.
  bool sent = false;

  bool stopAsked = false;
  bool closeAsked = false;
  bool get asked => stopAsked || closeAsked;

  LiteRtLmPageLease? lease;

  /// Completes when the turn has let go of the page.
  final ended = Completer<void>();

  void release() {
    lease?.release();
    if (!ended.isCompleted) ended.complete();
  }
}

/// Whether two JSON values are equal, maps whatever their key order.
bool _jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _jsonEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

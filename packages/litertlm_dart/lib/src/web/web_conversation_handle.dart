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
//   was asked first, as natively. A stopped generation that does not end
//   within [WebConversationHandle.drainTimeout] poisons the page lock, stop
//   or close alike: the module may still be suspended in it.
// - A stream that rejects keeps the page until a call on the engine's
//   executor mutex (`getTokenCount()`) resolves: 0.19.0 rejects from its
//   chunk callback, before the generation has left the module. Chrome 157
//   runs the JSPI build, where that is harmless; the Asyncify builds (no
//   JSPI) hold one suspended call per module, and another call entering then
//   would corrupt it.
// - A generation stopped before its end leaves the runtime conversation
//   refusing every later send ("Task cancelled"); the next turn replaces it
//   by one built from the preface, the exchanges kept so far and
//   `getHistory()` (which holds no preface), the stopped exchange put back.
// - The web runtime takes thinking and the template variables per
//   conversation (its `preface.extra_context`), not per message, and has no
//   per-message decoding options: a send that asks for either differently is
//   an [UnsupportedError], never silently ignored. Images and audio go as
//   their bytes in base64 (`blob`), the form 0.19.0 takes in a message and in
//   a preface (measured 2026-11-23); a file path is refused, and so is media
//   for an encoder the engine did not load.

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
import '../runtime/tool_calls.dart';
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
    this._preface = const [],
    this._vision = false,
    this._maxImages,
    this._audio = false,
    this.toolCallsOf = nativeToolCalls,
    this._onClose,
    LiteRtLmPageLock? pageLock,
  }) : _pageLock = pageLock ?? liteRtLmPageLock;

  JsLiteRtLmConversation _conversation;

  /// A new runtime conversation, set up as this one was, whose messages after
  /// [_preface] are [replay]: what replaces a conversation the runtime
  /// refuses after a stop. Runs while this handle holds the page lock, so it
  /// takes none. Fails with a [LiteRtLmNativeException].
  final Future<JsLiteRtLmConversation> Function(List<Object?> replay) _rebuild;

  /// The messages the conversation was created with (system instruction and
  /// initial messages), as sent in its preface.
  final List<Object?> _preface;

  /// The messages replayed after [_preface] into the current runtime
  /// conversation: the exchanges of the conversations it replaced.
  List<Object?> _replayed = const [];

  /// The engine loaded a vision, an audio encoder.
  final bool _vision;

  /// The images a conversation of this engine holds at most (its
  /// `maxNumImages`, whose space the model reserves per conversation); null
  /// without a vision encoder.
  final int? _maxImages;

  /// The images the current runtime conversation holds: its preface's, its
  /// replayed exchanges' and every message sent on it since. A turn that
  /// failed or was stopped still counts until the rebuild it forces recounts
  /// what the new conversation holds.
  late int _images = _imagesIn(_preface);

  /// The message of the last turn the runtime failed (not a stop): the
  /// runtime keeps it at the end of its history with no reply (M1, N1,
  /// 0.19.0), and the rebuild leaves it out.
  Map<String, Object?>? _failed;

  /// Why the conversation must be rebuilt, for the errors of a rebuild.
  String _rebuildCause = 'a stopped reply';
  final bool _audio;

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

  /// A generation on this conversation ended by rejection (a stop before its
  /// end, a runtime error, or a local fault that cancelled it): the runtime
  /// then fails every later send on it, so the next turn first replaces it
  /// ([_rebuildConversation]).
  bool _mustRebuild = false;

  /// The exchange a stop cut short, kept as natively: its message and what
  /// was generated before the stop ([assistantTurnMessage]: the tool calls
  /// it made, else its text without thoughts), put back after the runtime's
  /// history (which drops a cancelled turn). Null when the stopped turn
  /// streamed nothing: it is taken back.
  ({Map<String, Object?> message, Map<String, Object?> reply})? _stopped;

  /// Reads a stopped reply's tool calls ([createWebEngine]'s `toolCallsOf`).
  final ToolCallReader toolCallsOf;

  Future<void>? _closedFuture;

  /// How long a stopped generation may take to end before the page lock is
  /// poisoned; a test shortens it.
  @visibleForTesting
  static Duration drainTimeout = const Duration(seconds: 30);

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
    return chatRawMessage(
      jsonEncode({
        'role': 'user',
        'content': [
          for (final image in imageBytes ?? const <Uint8List>[])
            {'type': 'image', 'blob': base64Encode(image)},
          if (audioBytes != null)
            {'type': 'audio', 'blob': base64Encode(audioBytes)},
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
    if (_closed) {
      return Stream.error(StateError('Conversation handle is closed'));
    }
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
      if (turn.finished) return;
      turn.finished = true;
      _liveTurns.remove(turn);
      if (identical(_streaming, turn)) _streaming = null;
      turn.release();
      if (controller.isClosed) return;
      if (error != null && !listenerGone) controller.addError(error, stack);
      controller.close();
    }

    turn.abort = (error) => finish(error: error, stack: StackTrace.current);

    // How a turn that was asked to end, or that failed here, ended: with the
    // local fault, normally after a stop, with [LiteRtLmTurnClosedException]
    // after a close that came first.
    void finishAsked(StackTrace stack) {
      if (turn.fault case (final error, final faultStack)) {
        finish(error: error, stack: faultStack);
      } else {
        finish(
          error: turn.stopAsked ? null : LiteRtLmTurnClosedException(),
          stack: stack,
        );
      }
    }

    void start() {
      final stream = _conversation.sendMessageStreaming(message);
      turn.sent = true;
      _images += _imagesIn([turn.message]);
      final JsAsyncIterator iterator;
      try {
        _onGeneration();
        final asyncIterator = globalContext
            .getProperty<JSObject>('Symbol'.toJS)
            .getProperty<JSAny>('asyncIterator'.toJS);
        iterator =
            (stream.getProperty<JSFunction?>(asyncIterator) != null
                    ? stream.callMethod<JSObject>(asyncIterator)
                    : stream) // Already an iterator.
                as JsAsyncIterator;
      } catch (e, st) {
        // Sent, but its stream cannot be read: stop the generation, and let
        // the page go only once it has left the module.
        turn.fault = (
          LiteRtLmNativeException(
            'litertlm_dart could not read the reply stream of '
            '$liteRtLmWebRuntime: $e',
          ),
          st,
        );
        _mustRebuild = true;
        _rebuildCause = 'a reply stream litertlm_dart could not read';
        _stopJs(turn, 'its reply stream could not be read');
        _fence().then((_) => finishAsked(StackTrace.current));
        return;
      }

      void pump() {
        // Every path ends in [finish] or another [pump]: a callback that
        // threw would otherwise keep the page lock, and with it every LLM and
        // EmbeddingGemma 2 call on the page, for good.
        void onStep(JSObject step) {
          // Given up on (the page was poisoned): nothing more is read.
          if (turn.finished) return;
          final done = step.getProperty<JSAny?>('done'.toJS);
          if (!done.isA<JSBoolean>()) {
            // The iterator broke its contract: where the generation is, and
            // whether it ever ends, cannot be known. The module may still be
            // in it, so nothing else may enter.
            final error = LiteRtLmNativeException(
              '$liteRtLmWebRuntime streamed a step without a boolean `done`: '
              '${_stringifySafe(step)}',
            );
            _mustRebuild = true;
            _pageLock.poisonFor(
              turn.lease!,
              '$liteRtLmWebRuntime streamed a step without a boolean `done`.',
            );
            finish(error: error, stack: StackTrace.current);
            return;
          }
          if ((done as JSBoolean).toDart) {
            // Ended on its own: the runtime conversation keeps working (also
            // after a stop that came after the last chunk).
            if (turn.asked || turn.fault != null) {
              finishAsked(StackTrace.current);
            } else {
              finish();
            }
            return;
          }
          try {
            final value = step.getProperty<JSAny?>('value'.toJS);
            if (value != null && turn.fault == null) {
              final json = _stringify(value);
              // Bookkeeping for a stop only: a chunk it cannot read keeps
              // nothing, and the chunk still goes to the listener.
              turn.raw.write(json);
              try {
                // As natively: any chunk with text, a thought or a tool call
                // counts, and the kept reply is the text without thoughts.
                if (extractResponseText(json).isNotEmpty) turn.streamed = true;
                turn.reply.write(messageFromChunk(json).text);
              } catch (e) {
                runtimeLog('[WebConversationHandle] unreadable chunk: $e');
              }
              if (!listenerGone && !controller.isClosed) controller.add(json);
            }
          } catch (e, st) {
            // A fault here, not the runtime's: stop the generation and read
            // its stream to the end before the turn fails, so the page is
            // left only once the module has.
            if (turn.fault == null) {
              turn.fault = (
                LiteRtLmNativeException(
                  'litertlm_dart could not read a chunk of the reply from '
                  '$liteRtLmWebRuntime: $e',
                ),
                st,
              );
              _rebuildCause = 'a reply litertlm_dart could not read';
              _stopJs(turn, 'its turn failed in litertlm_dart ($e)');
            }
          }
          pump();
        }

        void onError(Object error, StackTrace stack) {
          if (turn.finished) return;
          // A rejected stream: the runtime conversation refuses every later
          // send ("Task cancelled" after a stop, measured on 0.18.0 and
          // 0.19.0).
          _mustRebuild = true;
          if (turn.stopAsked && turn.streamed) {
            _rebuildCause = 'a stopped reply';
            _stopped = (
              message: turn.message,
              reply: assistantTurnMessage(
                toolCallsOf,
                turn.reply.toString(),
                turn.raw.toString(),
              ),
            );
          } else if (!turn.asked && turn.fault == null) {
            _rebuildCause = 'a failed turn';
            _failed = turn.message;
          }
          // 0.19.0 rejects from inside the generation's chunk callback:
          // wait until it has left the module before the page is let go.
          _armDrain(turn, 'its stream failed');
          _fence().then((_) {
            if (turn.asked || turn.fault != null) {
              // How the runtime ends a stopped generation is its business:
              // the turn was asked to end, and it did.
              runtimeLog(
                '[WebConversationHandle] the stopped generation ended with '
                '$error',
              );
              finishAsked(stack);
            } else {
              finish(error: _typed(error), stack: stack);
            }
          });
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
      } catch (e, st) {
        if (turn.asked) {
          // Stopped meanwhile: the turn ends as stopped, and the rebuild's
          // failure is only said here; the next message tries again.
          runtimeLog('[WebConversationHandle] $e');
          finishAsked(st);
        } else {
          finish(error: e, stack: st);
        }
        return;
      }
      if (turn.asked) {
        finishAsked(StackTrace.current);
        return;
      }
      // Counted here, once a rebuild has settled what the conversation
      // holds, and after every turn queued before this one was sent.
      if (_imageRefusal(_imagesIn([turn.message])) case final refusal?) {
        finish(error: refusal, stack: StackTrace.current);
        return;
      }
      try {
        start();
      } catch (e, st) {
        // Nothing reached the stream's end if the send threw: no drain.
        finish(error: _typed(e), stack: st);
      }
    };
    controller.onCancel = () {
      listenerGone = true;
    };
    return controller.stream;
  }

  /// A runtime error as the typed exception the shared `Conversation` maps;
  /// errors already typed pass as they are.
  static Object _typed(Object error) =>
      error is Error || error is LiteRtLmNativeException
      ? error
      : LiteRtLmNativeException('$liteRtLmWebRuntime failed the turn: $error');

  static String _stringifySafe(JSAny value) {
    try {
      return _stringify(value);
    } catch (_) {
      return '$value';
    }
  }

  /// Completes once a call serialised on the engine's executor mutex has run:
  /// the generation that just rejected has then left the module. Its result
  /// and its failure do not matter; a fence that never completes is covered
  /// by the drain timer of a stop or close.
  Future<void> _fence() async {
    try {
      await _conversation.getTokenCount().toDart;
    } catch (_) {}
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
    // The images the conversation already holds are counted when the turn
    // is sent (onListen): a failed or stopped turn's are only settled by the
    // rebuild before it. A message that alone holds more never fits.
    if (_maxImages case final max? when _vision && _imagesIn([json]) > max) {
      return webImagesRefused(0, _imagesIn([json]), max);
    }
    if (json case {'content': final List<Object?> parts}) {
      for (final part in parts) {
        if (part case {'type': 'image' || 'audio', 'path': _}) {
          return UnsupportedError(webMediaPathMessage);
        }
        if (part case {'type': 'image'} when !_vision) {
          return UnsupportedError(
            'This engine loaded no vision encoder: create it with a '
            'visionBackend to send images.',
          );
        }
        if (part case {'type': 'audio'} when !_audio) {
          return UnsupportedError(
            'This engine loaded no audio encoder: create it with an '
            'audioBackend to send audio.',
          );
        }
      }
    }
    return null;
  }

  /// The refusal of a message of [adding] images on this conversation, or
  /// null when they fit in what its engine reserves.
  UnsupportedError? _imageRefusal(int adding) {
    if (!_vision || adding == 0) return null;
    if (_maxImages case final max? when _images + adding > max) {
      return webImagesRefused(_images, adding, max);
    }
    return null;
  }

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

  /// Marks every live turn stopped and stops the one streaming, if it was
  /// sent. With nothing in flight the runtime is not asked: a cancel there
  /// changes nothing (0.18.0 and 0.19.0, measured).
  @override
  void cancelGeneration() {
    for (final turn in _liveTurns) {
      turn.stopAsked = true;
    }
    if (_streaming case final turn? when turn.sent) {
      _stopJs(turn, 'it was stopped');
    }
  }

  /// `conversation.cancel()` for [turn], whose stream is running, with the
  /// drain timer armed: a generation that does not end within
  /// [drainTimeout] poisons the page lock, and [turn] fails with that error.
  void _stopJs(_Turn turn, String why) {
    try {
      _conversation.cancel();
    } catch (e) {
      runtimeLog('[WebConversationHandle] conversation.cancel() threw: $e');
    }
    _armDrain(turn, why);
  }

  /// Gives [turn] [drainTimeout] to end; if it has not, the page lock is
  /// poisoned and [turn] fails with that error. Armed once per turn.
  void _armDrain(_Turn turn, String why) {
    if (turn.drain != null) return;
    turn.drain = Timer(drainTimeout, () {
      if (turn.finished) return;
      _mustRebuild = true;
      _pageLock.poisonFor(
        turn.lease!,
        'A $liteRtLmWebRuntime generation did not end within '
        '${drainTimeout.inSeconds} s after $why.',
      );
      turn.abort!(_pageLock.poison!);
    });
  }

  /// Replaces the conversation the runtime refuses after a rejected stream
  /// by one rebuilt from the preface, the exchanges replayed so far and the
  /// runtime's history, the stopped exchange put back, and deletes the old
  /// one. Runs holding the page lock. Fails with a [LiteRtLmNativeException]
  /// and leaves the conversation as it was: the next message tries again.
  Future<void> _rebuildConversation() async {
    final List<Object?> history;
    try {
      history = [
        for (final message in (await _conversation.getHistory().toDart).toDart)
          _replayable(message.dartify()),
      ];
    } catch (e) {
      throw LiteRtLmNativeException(
        'Could not read the history of the conversation after '
        '$_rebuildCause ($e). $_untilRebuilt',
      );
    }
    // The runtime's history holds no preface (P1, 0.18.0 and 0.19.0
    // measured): it is the exchanges since this conversation was created. A
    // turn the runtime failed (not a stop) stays at its end as the user
    // message with no reply, and replaying it fails again (M1, 0.19.0: an
    // image past maxNumImages), while the history without it answers (N1):
    // that message, and only it, is left out.
    final exchanges = [...history];
    if (_failed case final failed?
        when exchanges.isNotEmpty &&
            _jsonEquals(_asSent(exchanges.last), _asSent(failed))) {
      exchanges.removeLast();
    }
    final replay = [
      ..._replayed,
      ...exchanges,
      if (_stopped case (:final message, :final reply)) ...[message, reply],
    ];
    final JsLiteRtLmConversation next;
    try {
      next = await _rebuild(replay);
    } catch (e) {
      throw LiteRtLmNativeException(
        'Could not rebuild the conversation after $_rebuildCause: '
        '${e is LiteRtLmNativeException ? e.message : e}. $_untilRebuilt',
      );
    }
    final old = _conversation;
    _conversation = next;
    _replayed = replay;
    _images = _imagesIn([..._preface, ...replay]);
    _mustRebuild = false;
    _stopped = null;
    _failed = null;
    runtimeLog(
      '[WebConversationHandle] rebuilt the conversation after $_rebuildCause '
      '(${_preface.length + replay.length} messages replayed)',
    );
    try {
      await awaitIfThenable(old.delete());
    } catch (e) {
      noteWebDeleteFailure('A stopped conversation', e);
    }
  }

  static const _untilRebuilt =
      'The runtime refuses every send on a conversation after a reply stopped '
      'mid-way or a failed turn, so it cannot be used until a rebuild '
      'succeeds; the next message tries again.';

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
  /// that does not end within [drainTimeout] poisons the page lock
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
    try {
      final streaming = _streaming;
      if (streaming != null) {
        // Abort the JS generation before the engine is torn down: deleting
        // the engine while an iterator's next() still resolves against this
        // conversation would free what it reads.
        if (streaming.sent) {
          _stopJs(streaming, 'its conversation closed');
        } else {
          // Still rebuilding the conversation inside the module.
          _armDrain(streaming, 'its conversation closed during a rebuild');
        }
        await streaming.ended.future;
        if (_pageLock.poison case final poison?) throw poison;
      }
      try {
        await awaitIfThenable(_conversation.delete());
      } catch (e) {
        noteWebDeleteFailure('A conversation', e);
      }
    } finally {
      _onClose?.call();
    }
  }
}

/// The image parts of [messages], conversation API JSON.
int _imagesIn(List<Object?> messages) => [
  for (final message in messages)
    if (message case {'content': final List<Object?> parts})
      for (final part in parts)
        if (part case {'type': 'image'}) part,
].length;

/// Whether [blob] is the runtime history's `{bytes: [...]}`.
bool _isBytes(Object? blob) =>
    blob is Map<Object?, Object?> && blob['bytes'] is List<Object?>;

/// [message] of a runtime history as a preface takes it. The bytes are
/// turned into base64 on this isolate: for a long history of large media
/// that is work on the UI thread at the next message. 0.19.0 returns an
/// image or audio part's bytes as `blob: {bytes: [...]}`, which a preface
/// aborts the module on; the base64 `blob` of a message replays it (measured
/// 2026-11-23, web_litertlm_runtime_probe_test.dart).
Object? _replayable(Object? message) {
  if (message case {'content': final List<Object?> parts}) {
    return {
      ...(message as Map),
      'content': [
        for (final part in parts)
          if (part case {
            'blob': final blob,
          } when blob is! String && !_isBytes(blob))
            throw FormatException(
              'A media part of the runtime history has a blob of an unknown '
              'shape (${blob.runtimeType}), which a rebuild cannot replay.',
            )
          else if (part case {'blob': {'bytes': final List<Object?> bytes}})
            {
              ...(part as Map),
              // dartify gives a JS number as a double under dart2wasm.
              'blob': base64Encode(
                Uint8List.fromList([
                  for (final b in bytes) (b! as num).toInt(),
                ]),
              ),
            }
          else
            part,
      ],
    };
  }
  return message;
}

/// The refusal of a message of [adding] images on a web conversation that
/// holds [held] of the [max] its engine reserves (`maxNumImages`).
UnsupportedError webImagesRefused(int held, int adding, int max) =>
    UnsupportedError(
      'This conversation holds $held of the $max images its engine '
      'reserves per conversation (maxNumImages: $max), and the message has '
      '$adding: on the web the model reserves their space up front, and an '
      'image past it fails ("Image index $max must be less than $max.", '
      '0.19.0). Load the model with a larger maxNumImages, or start a new '
      'conversation.',
    );

/// [message] (a history entry or a sent message) in one form for comparing:
/// a text content as its one text part, as the runtime's history gives a
/// message sent as a bare string. Anything that is not a message is itself.
Object? _asSent(Object? message) => switch (message) {
  {'role': final role, 'content': final String text} => {
    ...(message as Map),
    'role': role,
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
  _ => message,
};

/// One turn of a [WebConversationHandle]: whether it was asked to end, and
/// the page lease it holds while its stream runs.
final class _Turn {
  _Turn(this.message);

  /// The message, as the conversation API JSON.
  final Map<String, Object?> message;

  /// The text the runtime streamed for it so far, without thoughts.
  final reply = StringBuffer();

  /// Every chunk as the runtime sent it, for the tool calls of a stop.
  final raw = StringBuffer();

  /// A chunk with text, a thought or a tool call has arrived.
  bool streamed = false;

  /// `sendMessageStreaming` was called for it.
  bool sent = false;

  bool stopAsked = false;
  bool closeAsked = false;
  bool get asked => stopAsked || closeAsked;

  /// A fault in litertlm_dart while reading the stream: the turn fails with
  /// it once the stream has ended.
  (Object, StackTrace)? fault;

  /// The drain timer of a stop or close, armed once.
  Timer? drain;

  /// Ends the turn with an error now, whatever its stream does.
  void Function(Object error)? abort;

  /// [abort] or the stream's end has run.
  bool finished = false;

  LiteRtLmPageLease? lease;

  /// Completes when the turn has let go of the page.
  final ended = Completer<void>();

  void release() {
    drain?.cancel();
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

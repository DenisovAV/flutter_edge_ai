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
// - A stream that ends with no chunk on a turn nobody stopped is either an
//   empty reply or a send the runtime refused before it generated anything:
//   0.20.0's `sendMessageStreaming` drops the result of `sendMessageAsync`,
//   so such a refusal closes the stream empty instead of rejecting it, and
//   leaves the message at the end of the runtime's history with no reply.
//   `getHistory()` tells them apart, still under the turn's page lease: an
//   empty assistant entry after the message is an empty reply; anything else
//   is a refused send, which fails the turn with a [LiteRtLmNativeException]
//   and is left out of the conversation by the rebuild the next turn runs.
// - A generation stopped before its end leaves the runtime conversation
//   refusing every later send ("Task cancelled"); the next turn replaces it
//   by one built from the preface, the exchanges kept so far and
//   `getHistory()` (which holds no preface), the stopped exchange put back.
// - The web runtime takes thinking and the template variables per
//   conversation (its `preface.extra_context`), not per message, and has no
//   per-message decoding options: a send that asks for either differently is
//   an [UnsupportedError], never silently ignored. Images and audio go as
//   their bytes in base64 (`blob`), the form 0.19.0 and 0.20.0 take in a
//   message and in a preface (measured 2026-11-23 and 2026-11-25); a file
//   path is refused, and so is media
//   for an encoder the engine did not load.
// - A tool message goes as user text (web_tool_responses.dart): 0.20.0
//   and 0.21.0-nightly.20261125 answer a `role: 'tool'` message with nothing
//   under greedy decoding and on most seeds, and answer the same result
//   written as text. What is sent is what
//   the turn keeps ([_Turn.message]), so the runtime's history, which then
//   holds that user message, matches it wherever it is read: an empty reply
//   told from a refused send, a refused message left out of a rebuild, a
//   stopped exchange put back.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' show max;
import 'dart:typed_data';

import '../ffi/native_turns.dart' show LiteRtLmTurnClosedException;
import 'package:meta/meta.dart' show visibleForTesting;

import '../api/conversation.dart' show ContextFullException;
import '../api/message.dart' show messageFromChunk;
import '../runtime/conversation_handle.dart';
import '../runtime/errors.dart' show LiteRtLmNativeException;
import '../runtime/response_text.dart';
import '../runtime/runtime_log.dart';
import '../runtime/send_options.dart';
import '../runtime/tool_calls.dart';
import '../runtime/tool_choice_json.dart' show autoToolChoiceJson;
import '../runtime/types.dart' show BenchmarkInfo;
import 'litert_lm_js.dart';
import 'page_lock.dart';
import 'web_runtime_version.dart';
import 'web_tool_responses.dart';

/// A [ConversationHandle] over one `@litert-lm/core` conversation.
final class WebConversationHandle
    implements ConversationHandle, ConversationStateAccess {
  WebConversationHandle(
    this._conversation, {
    required this._enableThinking,
    required this._extraContext,
    required this._onGeneration,
    required this._rebuild,
    this._preface = const [],
    this._vision = false,
    this._maxImages,
    this._maxTokens = 0,
    this._audio = false,
    this.toolCallsOf = nativeToolCalls,
    this._onClose,
    this._cloneWith,
    LiteRtLmPageLock? pageLock,
  }) : _pageLock = pageLock ?? liteRtLmPageLock;

  /// A handle set up as this one, over [js]: what [cloneHandle] wraps the
  /// runtime's clone in (the engine registers it as one of its own); null
  /// refuses a clone.
  final WebConversationHandle Function(JsLiteRtLmConversation js)? _cloneWith;

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

  /// The engine's context window (`maxNumTokens`); 0 when unknown, which
  /// makes no conversation final for its size.
  final int _maxTokens;

  /// The tokens the conversation this one was rebuilt from held, read when
  /// it was replaced: the runtime prefills a preface only at the first send,
  /// so a new conversation counts 0 until then (N5, 0.19.0 and 0.20.0).
  int _replayedTokens = 0;

  /// The entries of the runtime conversation's history (`getHistory()`),
  /// kept here instead of read before every send: two per exchange it
  /// completed, one per message it refused and kept (M1, N5), none for a
  /// stopped turn, which it drops; 0 for a rebuilt conversation, whose
  /// replayed exchanges are its preface, which the history leaves out (P1).
  /// Set from the history itself when a reply with no chunk reads it.
  int _historyLength = 0;

  /// Whether the runtime conversation was rebuilt here: until something is
  /// prefilled on it (it counts 0 until then, N5), its first send prefills
  /// the replayed history with the message, and a refusal's count holds both
  /// (N7, 0.19.0 and 0.20.0).
  bool _rebuilt = false;

  /// Whether [_replayedTokens] is a count the runtime gave: set once a
  /// conversation this one replaced had prefilled (a count above 0, which
  /// holds the preface and the BOS token). Until then the size of what a
  /// rebuild replays is unknown, and a refusal teaches nothing.
  bool _replayedKnown = false;

  /// A lower bound on the tokens the chat template adds to a message, learnt
  /// from refusals (N7: "Input token ids are too long… X >= Y" counts what
  /// that call would prefill). The web cannot read the template, as natively
  /// the bundle's prefill lengths are read: the count less the message's
  /// UTF-8 bytes is at most the overhead, as no token spans less than a byte.
  int _overheadAtLeast = 0;

  /// The images the current runtime conversation holds: its preface's, its
  /// replayed exchanges' and every message sent on it since. A turn that
  /// failed or was stopped still counts until the rebuild it forces recounts
  /// what the new conversation holds.
  late int _images = _imagesIn(_preface);

  /// The message of the last turn the runtime failed (not a stop): the
  /// runtime keeps it at the end of its history with no reply (M1, N1,
  /// 0.19.0; a send 0.20.0 refuses before it generates, whose stream closes
  /// empty), and the rebuild leaves it out.
  Map<String, Object?>? _failed;

  /// Why the conversation must be rebuilt, for the errors of a rebuild.
  String _rebuildCause = 'a stopped reply';

  /// Set once the history alone fills the context window: the runtime
  /// refused a message for its size ("Max number of tokens reached, the
  /// context window is full." or "Input token ids are too long.", 0.19.0
  /// and 0.20.0)
  /// while the conversation already held [_maxTokens] tokens (N6: 128 of
  /// 128), so a rebuild replaying that history is refused too. Every later
  /// turn fails with [ContextFullException] without being sent, as natively
  /// a session with no room left ends every turn at the context limit;
  /// nothing is truncated. A message refused with room left is only left
  /// out (N5).
  String? _contextFull;

  /// Why the conversation cannot continue (a history no rebuild can
  /// replay): every later turn fails with it without being sent.
  String? _cannotContinue;

  /// How the last turn ended, where the web can tell: the context window
  /// full ([NativeLastTurnEnd.contextFull]), which is final; else null.
  NativeLastTurnEnd? _lastTurnEnd;

  /// The error a turn gets on a conversation that cannot take it, or null.
  Object? _deadEnd() {
    if (_contextFull case final why?) {
      _lastTurnEnd = NativeLastTurnEnd.contextFull;
      return ContextFullException(why);
    }
    if (_cannotContinue case final why?) return LiteRtLmNativeException(why);
    return null;
  }

  /// Whether, after the runtime refused [message] for its size, the history
  /// alone leaves no room for any message, as natively a conversation whose
  /// room is below its shortest prefill is (`liteRtLmPrefillFits`). [count]
  /// is what the conversation holds (`getTokenCount()`; the runtime does not
  /// count a refused message, N5). Final when the history fills the window,
  /// or when the room left is at most the template's overhead learnt from
  /// refusals plus one token, the least a message's text takes.
  bool _historyLeavesNoRoom(
    int? count,
    Map<String, Object?> message,
    Object error,
  ) {
    if (_maxTokens <= 0) return false;
    final held = max(count ?? 0, _rebuilt ? _replayedTokens : 0);
    // Learnt only where what precedes the message is a known count: a
    // rebuilt conversation's first call prefills the replayed history (the
    // preface and the BOS token included, as the count it was rebuilt from
    // has them), then the message. A conversation that never prefilled has
    // no such count, so neither its first call (its preface, the BOS token)
    // nor a rebuild of it teaches anything. Once a conversation has
    // prefilled, a count is the message alone, refused for being longer than
    // the window: with the replay taken off it bounds nothing (a token is at
    // least a byte), which is harmless.
    final counts = RegExp(r'(\d+) >= \d+').firstMatch('$error');
    if (counts != null && _rebuilt && _replayedKnown) {
      if (_textBytes(message) case final bytes?) {
        final turnTokens = int.parse(counts.group(1)!) - _replayedTokens;
        _overheadAtLeast = max(_overheadAtLeast, turnTokens - bytes);
      }
    }
    final room = _maxTokens - held;
    return room <= 0 || (_overheadAtLeast > 0 && room <= _overheadAtLeast + 1);
  }

  /// The UTF-8 bytes of [message]'s text, or null when it holds anything
  /// else (media, a tool response), whose tokens cannot be bounded here.
  static int? _textBytes(Map<String, Object?> message) {
    switch (message['content']) {
      case final String text:
        return utf8.encode(text).length;
      case final List<Object?> parts:
        var bytes = 0;
        for (final part in parts) {
          if (part case {'type': 'text', 'text': final String text}) {
            bytes += utf8.encode(text).length;
          } else {
            return null;
          }
        }
        return bytes;
      default:
        return null;
    }
  }

  static bool _isContextFull(Object error) =>
      '$error'.contains('Max number of tokens reached') ||
      '$error'.contains('Input token ids are too long');

  static String _tooLongMessage(Object error) =>
      'The message did not fit the room the context window has left: '
      '$liteRtLmWebRuntime refused it ($error), and it is left out of the '
      'conversation. Send a shorter message, or open a new conversation.';

  static String _contextFullMessage(Object error) =>
      'The context window of this conversation is full: $liteRtLmWebRuntime '
      'refused the message ($error) and refuses every later one, and its '
      'history would not fit a new conversation either. Open a new '
      'conversation, or load the model with a larger maxNumTokens.';
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

  /// Sends [messageJson], the conversation API JSON of a message.
  ///
  /// A tool message (`role: 'tool'`, the results of the calls a reply made)
  /// goes to `@litert-lm/core` as one user message of text instead, each
  /// result written `Tool <name> returned: <JSON>` (with a call id,
  /// `Tool <name> (call <id>) returned: <JSON>`), one per line. With Gemma 4
  /// E2B's GPU export the tool message got no text on 5 of 8 sampler seeds
  /// and under greedy decoding on 0.20.0 and 0.21.0-nightly.20261125 (the
  /// nightly ends the turn with `finish_reason: "stop"`), and on 3 of 8 seeds
  /// on 0.19.0 (greedy answered there); the same results as that text got a
  /// reply on all 8 seeds and under greedy decoding on all three (measured
  /// 2026-11-26, Chrome 158). It is done on every runtime: one older than
  /// 0.20.0, the only kind that could keep the tool message, lacks members
  /// this release calls and is refused before anything is sent. The
  /// runtime's history then holds the user message, and a conversation
  /// rebuilt from it replays that.
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
    final decoded = jsonDecode(messageJson) as Map<String, Object?>;
    final asText = webToolResponseAsUserText(decoded);
    if (asText != null) _noteToolResponsesAsText();
    // As text, the user message goes as the object (with its one text
    // part), the form measured; never as a bare string.
    final message = asText?.jsify() ?? _jsMessage(messageJson);
    final turn = _Turn(asText ?? decoded);
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
              // The stream ended `done`: the runtime completed the exchange
              // (a stop after its last chunk changes nothing).
              _historyLength += 2;
              finishAsked(StackTrace.current);
            } else if (!turn.chunked) {
              // An empty reply, or a send the runtime refused: its history
              // says which.
              _settleEmptyTurn(turn, finish, finishAsked);
            } else {
              _historyLength += 2;
              finish();
            }
            return;
          }
          try {
            final value = step.getProperty<JSAny?>('value'.toJS);
            if (value != null) turn.chunked = true;
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
          // send ("Task cancelled" after a stop, measured on 0.18.0, 0.19.0
          // and 0.20.0).
          _mustRebuild = true;
          if (turn.stopAsked) _rebuildCause = 'a stopped reply';
          if (turn.stopAsked && turn.streamed) {
            _stopped = (
              message: turn.message,
              reply: assistantTurnMessage(
                toolCallsOf,
                turn.reply.toString(),
                turn.raw.toString(),
              ),
            );
          } else if (!turn.asked && turn.fault == null) {
            // The runtime keeps a refused message at the end of its history
            // (M1, N5): the rebuild leaves it out.
            _failed = turn.message;
            _historyLength += 1;
            if (_isContextFull(error)) {
              _rebuildCause = 'a message too long for the context window';
              _lastTurnEnd = NativeLastTurnEnd.contextFull;
            } else {
              _rebuildCause = 'a failed turn';
            }
          }
          // 0.19.0 rejects from inside the generation's chunk callback:
          // wait until it has left the module before the page is let go.
          _armDrain(turn, 'its stream failed');
          _fence().then((count) {
            if (_lastTurnEnd == NativeLastTurnEnd.contextFull &&
                _historyLeavesNoRoom(count, turn.message, error)) {
              _contextFull = _contextFullMessage(error);
            }
            if (turn.asked || turn.fault != null) {
              // How the runtime ends a stopped generation is its business:
              // the turn was asked to end, and it did.
              runtimeLog(
                '[WebConversationHandle] the stopped generation ended with '
                '$error',
              );
              finishAsked(stack);
            } else {
              finish(
                error: _lastTurnEnd == NativeLastTurnEnd.contextFull
                    ? ContextFullException(
                        _contextFull ?? _tooLongMessage(error),
                      )
                    : _typed(error),
                stack: stack,
              );
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
      if (_contextFull == null) _lastTurnEnd = null;
      // A conversation at a dead end (also one reached while this turn was
      // queued) sends nothing more.
      if (_deadEnd() case final error?) {
        finish(error: error, stack: StackTrace.current);
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
      // The history's length before the send, kept here rather than read
      // from the runtime before every send: a reply that ends with no chunk
      // is the model's empty reply only if the history then grew by exactly
      // the message and an empty answer ([_settleEmptyTurn]).
      turn.historyBefore = _historyLength;
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

  /// Ends [turn], whose stream ended with no chunk and no stop, as an empty
  /// reply or as a refused send, from the runtime's history: an empty
  /// assistant entry right after the message is an empty reply ([finish]
  /// with nothing); anything else means the runtime generated nothing for it
  /// (0.20.0 closes a refused send's stream empty, the message kept at the
  /// end of its history), and the turn fails with a
  /// [LiteRtLmNativeException]; the next turn rebuilds the conversation
  /// without it. Runs while [turn] still holds the page; a history read that
  /// never ends poisons it, as a stopped generation does. A stop or close
  /// asked meanwhile ends the turn as asked ([finishAsked]).
  void _settleEmptyTurn(
    _Turn turn,
    void Function({Object? error, StackTrace? stack}) finish,
    void Function(StackTrace stack) finishAsked,
  ) {
    _armDrain(turn, 'its reply ended with no chunk');
    Future<List<Object?>> read() async => [
      for (final entry in (await _conversation.getHistory().toDart).toDart)
        entry.dartify(),
    ];
    read().then(
      (history) {
        if (turn.finished) return;
        // What the runtime holds, read anyway: the count kept here follows it.
        _historyLength = history.length;
        if (_isEmptyReply(history, turn.message, before: turn.historyBefore)) {
          if (turn.asked) {
            finishAsked(StackTrace.current);
          } else {
            finish();
          }
          return;
        }
        // The runtime refused the send: the conversation is rebuilt without
        // the message, which it may keep at the end of its history.
        _mustRebuild = true;
        _failed = turn.message;
        _rebuildCause = 'a message the runtime refused';
        if (turn.asked) {
          finishAsked(StackTrace.current);
          return;
        }
        finish(
          error: LiteRtLmNativeException(
            '$liteRtLmWebRuntime refused the message without a reason: its '
            'reply ended before any chunk, and the conversation\'s history '
            'holds no reply to it. The message is left out of the '
            'conversation.',
          ),
          stack: StackTrace.current,
        );
      },
      onError: (Object e, StackTrace st) {
        if (turn.finished) return;
        // Whether the runtime answered or refused the message cannot be
        // told: the next turn rebuilds the conversation from its history,
        // leaving the message out if it stands there unanswered.
        _mustRebuild = true;
        _failed = turn.message;
        _rebuildCause = 'a reply whose history could not be read';
        if (turn.asked) {
          finishAsked(st);
          return;
        }
        finish(
          error: LiteRtLmNativeException(
            'The reply of $liteRtLmWebRuntime ended before any chunk, and the '
            'conversation\'s history, which tells an empty reply from a '
            'refused message, could not be read: $e',
          ),
          stack: st,
        );
      },
    );
  }

  /// Whether [history] ends with [message] answered by an empty assistant
  /// entry (no text, no tool call): the model's own empty reply. With the
  /// history's length [before] the send known, it must have grown by exactly
  /// those two entries, so an earlier identical exchange is not read as this
  /// one.
  static bool _isEmptyReply(
    List<Object?> history,
    Map<String, Object?> message, {
    int? before,
  }) {
    if (history.length < 2) return false;
    if (before != null && history.length != before + 2) return false;
    final reply = history.last;
    if (reply is! Map || reply['role'] != 'assistant') return false;
    if (reply['tool_calls'] case final List<Object?> calls
        when calls.isNotEmpty) {
      return false;
    }
    final empty = switch (reply['content']) {
      null => true,
      final String text => text.isEmpty,
      final List<Object?> parts => parts.every(
        (part) => part is Map && part['type'] == 'text' && part['text'] == '',
      ),
      _ => false,
    };
    if (!empty) return false;
    final Object? sent;
    try {
      sent = _replayable(history[history.length - 2]);
    } on FormatException {
      return false;
    }
    return _jsonEquals(_asSent(sent), _asSent(message));
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
  /// the generation that just rejected has then left the module. Gives the
  /// tokens the conversation holds (`getTokenCount()`), or null when it
  /// failed; a fence that never completes is covered by the drain timer of a
  /// stop or close.
  Future<int?> _fence() async {
    try {
      final count = await _conversation.getTokenCount().toDart;
      // A JS number is a double under dart2wasm.
      return count.isA<JSNumber>() ? count.toDartDouble.toInt() : null;
    } catch (_) {
      return null;
    }
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
      // Its SessionConfig.maxOutputTokens is fixed when the conversation is
      // created.
      if (options.maxOutputTokens != null) 'maxOutputTokens',
      if (options.visualTokenBudget != null) 'visual token budget',
      // Auto is what the web's unconstrained decoding already is (text,
      // calls or both): taken. Every other choice needs a constraint the web
      // conversation does not build.
      if (options.toolChoiceJson case final choice?
          when choice != autoToolChoiceJson)
        'tool choice (toolChoice) other than auto',
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

  /// Says once per page, in the runtime log, that tool results go as text.
  static void _noteToolResponsesAsText() {
    if (_toolTextNoted) return;
    _toolTextNoted = true;
    runtimeLog(
      '[WebConversationHandle] tool results go to $liteRtLmWebRuntime as '
      'user text ("Tool <name> returned: <JSON>"): a tool message mostly '
      'gets no text.',
    );
  }

  static bool _toolTextNoted = false;

  /// Marks every live turn stopped and stops the one streaming, if it was
  /// sent. With nothing in flight the runtime is not asked: a cancel there
  /// changes nothing (0.18.0, 0.19.0 and 0.20.0, measured).
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
  /// and leaves the conversation as it was, so the next message tries again;
  /// except where no rebuild can succeed: a history it cannot replay ends
  /// the conversation, and a new conversation the runtime refuses because
  /// the history fills its context window is [ContextFullException].
  Future<void> _rebuildConversation() async {
    final List<Object?> history;
    try {
      history = [
        for (final message in (await _conversation.getHistory().toDart).toDart)
          _replayable(message.dartify()),
      ];
    } on FormatException catch (e) {
      // The same history every time: no later rebuild can replay it.
      throw LiteRtLmNativeException(
        _cannotContinue =
            'This conversation cannot continue: after $_rebuildCause its '
            'history holds what a rebuild cannot replay (${e.message}). Open a '
            'new conversation.',
      );
    } catch (e) {
      throw LiteRtLmNativeException(
        'Could not read the history of the conversation after '
        '$_rebuildCause ($e). $_untilRebuilt',
      );
    }
    // The runtime's history holds no preface (P1, 0.18.0, 0.19.0 and 0.20.0
    // measured): it is the exchanges since this conversation was created. A
    // turn the runtime failed (not a stop) stays at its end as the user
    // message with no reply, and replaying it fails again (M1, 0.19.0: an
    // image past maxNumImages, which 0.20.0 answers; a send 0.20.0 refuses
    // before it generates stays there too), while the history without it
    // answers (N1):
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
      if (_isContextFull(e)) {
        _lastTurnEnd = NativeLastTurnEnd.contextFull;
        throw ContextFullException(_contextFull = _contextFullMessage(e));
      }
      throw LiteRtLmNativeException(
        'Could not rebuild the conversation after $_rebuildCause: '
        '${e is LiteRtLmNativeException ? e.message : e}. $_untilRebuilt',
      );
    }
    final old = _conversation;
    // A conversation refused before anything was prefilled on it counts 0
    // (N5) but still holds the history it was rebuilt with: the count it was
    // rebuilt from stays. One that prefilled counts all of it (the history
    // only grows; a refused message is neither counted nor replayed).
    final replaced = await _fence() ?? 0;
    if (replaced > 0) {
      _replayedTokens = replaced;
      _replayedKnown = true;
    }
    _rebuilt = true;
    _conversation = next;
    // The replayed exchanges are its preface, which its history leaves out.
    _historyLength = 0;
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
  NativeLastTurnEnd? get lastTurnEnd => _lastTurnEnd;

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

  /// `@litert-lm/core`'s `Conversation.getTokenCount()`, holding the page
  /// lock, after the conversation is rebuilt from a stop or failure that left
  /// it refusing sends (as [cloneHandle] does). A rebuilt conversation counts
  /// 0 until its next message, which prefills the replayed history with it
  /// (N5): until then its count is the one of the conversation it replaced,
  /// which holds that history. A rebuild that fails fails this call with the
  /// rebuild's error, as it fails [cloneHandle] and the next send.
  @override
  Future<int> kvTokenCount() => _pageLock.run(() async {
    if (_closed) throw StateError('Conversation handle is closed');
    if (_mustRebuild && _deadEnd() == null) await _rebuildConversation();
    final count = await _conversation.getTokenCount().toDart;
    // A JS number is a double under dart2wasm.
    if (!count.isA<JSNumber>()) {
      throw LiteRtLmNativeException(
        '$liteRtLmWebRuntime gave a token count that is not a number.',
      );
    }
    final held = count.toDartDouble.toInt();
    return _rebuilt ? max(held, _replayedTokens) : held;
  });

  @override
  Future<String> renderMessage(String messageJson) async =>
      throw UnsupportedError(_noRender);

  @override
  Future<String> renderPreface() async => throw UnsupportedError(_noRender);

  static const _noRender =
      'The web runtime ($liteRtLmWebRuntime) has no render call: its '
      'Conversation renders a prompt only to send it.';

  /// `@litert-lm/core`'s `Conversation.clone()` of the runtime conversation,
  /// holding the page lock, after the conversation is rebuilt from a stop
  /// that left it refusing sends. The clone keeps what this handle knows of
  /// the conversation (its replayed history, the images it holds, a dead end
  /// it reached).
  @override
  Future<ConversationHandle> cloneHandle() async {
    final cloneWith = _cloneWith;
    if (cloneWith == null) {
      throw UnsupportedError('This conversation cannot be cloned.');
    }
    return _pageLock.run(() async {
      if (_closed) throw StateError('Conversation handle is closed');
      if (_deadEnd() case final error?) throw error;
      if (_mustRebuild) await _rebuildConversation();
      // clone() is checked when the conversation is created
      // (webConversationMembers).
      final JSObject cloned;
      try {
        cloned = await _conversation.clone().toDart;
      } catch (e) {
        throw LiteRtLmNativeException(
          '$liteRtLmWebRuntime could not clone the conversation: $e',
        );
      }
      final handle = cloneWith(cloned as JsLiteRtLmConversation)
        .._replayed = _replayed
        .._replayedTokens = _replayedTokens
        .._replayedKnown = _replayedKnown
        .._rebuilt = _rebuilt
        .._historyLength = _historyLength
        .._overheadAtLeast = _overheadAtLeast
        .._images = _images;
      return handle;
    });
  }

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
/// 2026-11-23, web_litertlm_runtime_probe_test.dart; the history's form and
/// the base64 replay again on 0.20.0, 2026-11-25).
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

  /// Any chunk has arrived, empty or not.
  bool chunked = false;

  /// `sendMessageStreaming` was called for it.
  bool sent = false;

  /// How many entries the runtime's history held right before the send
  /// ([WebConversationHandle._historyLength]).
  int? historyBefore;

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

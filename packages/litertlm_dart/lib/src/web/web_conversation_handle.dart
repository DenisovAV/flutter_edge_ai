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
import '../runtime/conversation_handle.dart';
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
    required Map<String, Object?> extraContext,
    required this._onGeneration,
    this._onClose,
    LiteRtLmPageLock? pageLock,
  }) : _extraContextJson = jsonEncode(extraContext),
       _pageLock = pageLock ?? liteRtLmPageLock;

  final JsLiteRtLmConversation _conversation;
  final bool _enableThinking;
  final String _extraContextJson;
  final void Function() _onGeneration;
  final void Function()? _onClose;
  final LiteRtLmPageLock _pageLock;

  bool _closed = false;

  /// A stop was asked during the current turn.
  bool _stopAsked = false;

  /// Completes when the generation that started last has read its JS stream
  /// to the end and released its page lease; null before the first one.
  Future<void>? _generationEnded;

  /// Releases that generation's page lease, for [close] when the stream does
  /// not end within [closeDrainTimeout].
  void Function()? _releaseGenerationPage;

  /// Completes once [close] has drained the last generation and deleted the
  /// JS conversation.
  Future<void> get closed => _closedFuture ?? Future<void>.value();
  Future<void>? _closedFuture;

  /// How long [close] waits for a cancelled generation to end.
  static const Duration closeDrainTimeout = Duration(seconds: 30);

  /// The JS `JSON.stringify`, looked up once.
  static final JSObject _json = globalContext.getProperty<JSObject>(
    'JSON'.toJS,
  );

  static String _stringify(JSAny value) =>
      _json.callMethod<JSString>('stringify'.toJS, value).toDart;

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
    _stopAsked = false;

    final controller = StreamController<String>();
    // The listener let go of the reply: the pump reads the JS stream to its
    // end, emitting nothing, and only then lets the next lock holder in.
    var listenerGone = false;
    LiteRtLmPageLease? lease;
    final ended = Completer<void>();
    void releasePage() {
      lease?.release();
      if (!ended.isCompleted) ended.complete();
    }

    void finish({Object? error, StackTrace? stack}) {
      releasePage();
      if (controller.isClosed) return;
      if (error != null && !listenerGone) controller.addError(error, stack);
      controller.close();
    }

    void start() {
      final stream = _conversation.sendMessageStreaming(message);
      _onGeneration();
      final asyncIterator = globalContext
          .getProperty<JSObject>('Symbol'.toJS)
          .getProperty<JSAny>('asyncIterator'.toJS);
      final iterator = stream.getProperty<JSFunction?>(asyncIterator) != null
          ? stream.callMethod<JSObject>(asyncIterator)
          : stream; // Already an iterator.

      void pump() {
        iterator.next().toDart.then(
          (step) {
            if (step.getProperty<JSBoolean>('done'.toJS).toDart) {
              // Closed with no stop asked: the reply was cut short.
              finish(
                error: _closed && !_stopAsked
                    ? LiteRtLmTurnClosedException()
                    : null,
                stack: StackTrace.current,
              );
              return;
            }
            final value = step.getProperty<JSAny?>('value'.toJS);
            if (value != null && !listenerGone && !controller.isClosed) {
              controller.add(_stringify(value));
            }
            pump();
          },
          onError: (Object error, StackTrace stack) {
            if (_stopAsked || _closed) {
              // How the runtime ends a stopped generation is its business:
              // the turn was asked to end, and it did.
              runtimeLog(
                '[WebConversationHandle] the stopped generation ended with '
                '$error',
              );
              finish(
                error: _closed && !_stopAsked
                    ? LiteRtLmTurnClosedException()
                    : null,
                stack: stack,
              );
              return;
            }
            finish(error: error, stack: stack);
          },
        );
      }

      pump();
    }

    controller.onListen = () async {
      try {
        lease = await _pageLock.acquire();
        if (_closed || listenerGone) {
          finish(
            error: _closed ? LiteRtLmTurnClosedException() : null,
            stack: StackTrace.current,
          );
          return;
        }
        // From here the stream holds the page until it ends; close() waits
        // for that (a generation still queued above has nothing to wait for).
        _generationEnded = ended.future;
        _releaseGenerationPage = releasePage;
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
    if (jsonEncode(options.extraContext) != _extraContextJson) {
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

  static UnsupportedError _unsupportedMedia() => UnsupportedError(
    'The web Engine ($liteRtLmWebRuntime) loads no vision or audio executor: '
    'send text only on the web.',
  );

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
    _stopAsked = true;
    _cancelJs();
  }

  void _cancelJs() {
    try {
      _conversation.cancel();
    } catch (e) {
      // It may throw when nothing is in flight.
      runtimeLog('[WebConversationHandle] conversation.cancel() threw: $e');
    }
  }

  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) => Future.value(StoppedTurnRewind.unsupported);

  @override
  BenchmarkInfo getSessionMetrics() => const BenchmarkInfo();

  @override
  NativeBenchmark? getNativeBenchmark() => null;

  @override
  NativeLastTurnEnd? get lastTurnEnd => null;

  @override
  int? get lastTurnCode => null;

  /// Stops the generation in flight, waits for its JS stream to end (at most
  /// [closeDrainTimeout], then lets the page lock go anyway), and deletes the
  /// JS conversation. [closed] completes when that is done.
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    // Abort the JS generation before the engine is torn down: deleting the
    // engine while an iterator's next() still resolves against this
    // conversation would free what it reads.
    _cancelJs();
    _closedFuture = _drainAndDelete().whenComplete(() => _onClose?.call());
  }

  Future<void> _drainAndDelete() async {
    final ended = _generationEnded;
    var drained = true;
    if (ended != null) {
      await ended.timeout(
        closeDrainTimeout,
        onTimeout: () {
          drained = false;
          runtimeLog(
            '[WebConversationHandle] the cancelled generation did not end '
            'within ${closeDrainTimeout.inSeconds} s; releasing the page lock '
            'anyway.',
          );
          _releaseGenerationPage?.call();
        },
      );
    }
    // `delete()` waits for the engine's executor, which a generation that
    // never ended still holds: the engine's own delete frees it instead.
    if (!drained) return;
    try {
      await _conversation.delete().toDart.timeout(closeDrainTimeout);
    } catch (e) {
      runtimeLog('[WebConversationHandle] conversation.delete() failed: $e');
    }
  }
}

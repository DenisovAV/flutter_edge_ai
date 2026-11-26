// The conversation handles of a session: a native conversation made to answer
// again after a stopped or context-full turn (RecoveringConversationHandle),
// and a session that shares the engine's one live conversation by replaying
// its history (VirtualConversationHandle). Both record their history as the
// full messages LiteRT-LM takes, media included. Which one a session gets is
// open_session_backing.dart's answer; the Flutter adapter
// (adapter/ffi_inference_model.dart) opens them.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart' show visibleForTesting;

import '../runtime/runtime_log.dart';
import '../runtime/types.dart';
import 'litert_lm_client.dart';
import 'native_turns.dart' show LiteRtLmTurnCancelledException;
import 'send_options.dart';
import '../runtime/tool_calls.dart';

export '../runtime/tool_calls.dart'
    show
        ToolCallReader,
        assistantTurnMessage,
        concatenatedJsonObjects,
        nativeToolCalls;

/// How long a turn waits for a stopped one to wind down before going ahead —
/// the same bound VoiceSession gives a stopped reply to drain.
const _windDownTimeout = Duration(seconds: 5);

/// How [LiteRtLmFfiClient.extractTextFromResponse] marks a thought chunk.
@visibleForTesting
const thoughtChunkPrefix = '<|channel>thought\n';

/// The handle of a session's own native conversation — [createSession]'s, and
/// each [openSession] session's where they are native
/// ([OpenSessionBacking.native]) — made to answer again after a turn is
/// stopped or its input did not fit.
///
/// A conversation whose generation was cancelled mid-turn answers every later
/// message with nothing — zero chunks in about a millisecond, on every turn
/// after, measured on native 0.16.0 through 0.17.1. So the first turn after a
/// stop first rewinds the conversation to before the stopped turn and puts that
/// turn back, partial reply included ([ConversationHandle.rewindStoppedTurn]):
/// the model keeps everything, images and audio too. Where it cannot — on the
/// NPU, whose executor rolls back one token at most, on a model with linear
/// attention state, which a rewind cannot restore, or on a libLiteRtLm without
/// the rewind — it replaces the conversation with a new one seeded with the
/// history this handle records, as a `messages_json` preface, including image
/// and audio parts.
///
/// A turn native ended `context_full` (§23: its input did not fit what the
/// window has left) leaves the conversation failing every later send. The
/// next turn first rewinds it to that turn's checkpoint, without the input
/// that did not fit, or rebuilds it where it cannot rewind. Nothing of the
/// history is dropped (core 2.6.0 design §6.4b, as decided for a raw
/// session): when the window has no room for any input left, every later
/// turn ends the same way, and the app decides — `InferenceChat` rotates its
/// session by its own token budget.
///
/// A cancel that arrives after a turn has finished does not count: Dart
/// delivers a stream's `done` by cancelling its subscription, which cancels
/// the native conversation on every normal turn, and that leaves it healthy.
///
/// Public, though nothing outside this library uses it, so that tests can drive
/// the recovery over fake handles with no engine.
class RecoveringConversationHandle
    implements ConversationHandle, ConversationStateAccess {
  RecoveringConversationHandle(
    this._live, {
    required this.reopen,
    required this.toolCallsOf,
    this.noRewindReason,
    this.freshConversationEachTurn = false,
    this.windDownTimeout = _windDownTimeout,
    this.mediaOrder = MediaOrder.imagesAudioText,
    List<Map<String, Object?>> history = const [],
  }) {
    _history.addAll(history);
  }

  /// The tool calls of a raw reply, for the assistant turn a rebuild replays.
  final ToolCallReader toolCallsOf;

  /// Each turn after the first runs in a fresh conversation that replays the
  /// history (`liteRtLmFreshConversationEachTurn`, LiteRT-LM #4256 on
  /// MediaTek): the conversation a turn was sent on is never sent a second
  /// message.
  final bool freshConversationEachTurn;

  /// A turn was sent on [_live] since it was opened.
  bool _liveSent = false;

  /// Why this conversation is never rewound and is rebuilt from history instead
  /// (the NPU, a model with linear attention state), or null when a stopped
  /// turn and a full context are rewound before falling back to a rebuild.
  final String? noRewindReason;

  /// Whether a stopped turn or a full context is rewound before falling back
  /// to a rebuild.
  bool get canRewind => noRewindReason == null;

  /// How long a turn waits for a stopped one to record itself. See [_turn].
  final Duration windDownTimeout;

  ConversationHandle _live;

  /// Opens a conversation with this session's config, seeded with
  /// [messagesJson] when given.
  final Future<ConversationHandle> Function(String? messagesJson) reopen;

  /// Where a rebuild puts each replayed message's images and audio.
  final MediaOrder mediaOrder;

  /// Every turn so far, as the messages a rebuild replays.
  final List<Map<String, Object?>> _history = [];

  /// True from the start of a turn — rebuild included — to the end of its
  /// `finally`.
  bool _inFlight = false;

  /// A cancel landed inside the current turn. Reset when the next turn starts.
  bool _stopRequested = false;

  /// Completes when the latest turn to start has run its `finally`: each turn
  /// waits for the one before it, so turns take the conversation one at a
  /// time, and a stopped turn's end is known before the next one decides how
  /// to recover.
  /// Stopped turns a later one gave up waiting for and rebuilt without: when
  /// one of them ends at last, it leaves the history alone.
  final _abandonedTurns = <Future<void>>{};

  Future<void>? _turnDone;

  /// The turn that holds the conversation — past its wait — and so owns
  /// [_inFlight], [_stopRequested] and the stop it may leave behind.
  Completer<void>? _current;

  /// Counts [cancelGeneration] calls, so a turn still waiting for the one
  /// before it can tell that a stop came meanwhile.
  int _stopEpoch = 0;

  /// Set when a turn that reached the model was cut off; the next turn
  /// recovers the conversation before it runs.
  bool _stopped = false;

  /// The reply the stopped turn had produced, which a rewind puts back after
  /// its message. Null when the next recovery must rebuild instead, unless
  /// [_takeBack] is set.
  Map<String, Object?>? _stoppedReply;

  /// The next recovery rewinds the last turn out, with nothing put back: a
  /// turn stopped before it produced anything (Rule A), or one whose input
  /// did not fit the window (§23). Where it cannot rewind, it rebuilds from
  /// the history, which the turn is not in.
  bool _takeBack = false;

  /// Why a conversation that can rewind is rebuilt instead.
  String? _rebuildBecause;

  /// True while the conversation is being rewound or rebuilt. Nothing is
  /// generating then, and a native cancel would abort the rewind's prefill.
  bool _recovering = false;

  bool _closed = false;

  Future<void> _rebuild() async {
    final afterStop = _stopped;
    // Deleted first: the old conversation's KV cache is freed before the new
    // one is allocated (and on LiteRT-LM 0.18, upstream #966, the engine held
    // one live conversation).
    _live.close();
    _live = await reopen(
      _history.isEmpty ? null : LiteRtLmFfiClient.buildHistoryJson(_history),
    );
    _liveSent = false;
    // Only now: a reopen that throws leaves the old conversation closed and
    // this set, so the next turn tries again instead of using a dead handle.
    _stopped = false;
    if (_closed) {
      _live.close();
      throw StateError('Conversation handle is closed');
    }
    runtimeLog(
      '[FfiInferenceModel] rebuilt the conversation '
      '${afterStop ? 'after a stopped turn or a full context' : 'for a new turn'} '
      '(${_history.length} messages replayed)',
    );
  }

  /// Opens the fresh conversation a turn of [freshConversationEachTurn] runs
  /// in, replaying every turn so far.
  Future<void> _freshen() async {
    _recovering = true;
    try {
      await _rebuild();
    } finally {
      _recovering = false;
    }
  }

  /// The recovery in progress. A turn that starts meanwhile waits for it, and
  /// its wind-down bound does not run out while a long rewind (an audio clip
  /// re-encoded on a phone CPU) still uses the conversation.
  Future<void>? _recovery;

  /// Makes the conversation answer again after a stopped turn: rewinds it when
  /// it can, and rebuilds it when it cannot or the rewind fails.
  Future<void> _recover() async {
    final reply = _stoppedReply;
    final takeBack = _takeBack;
    final rebuildBecause = _rebuildBecause;
    _stoppedReply = null;
    _takeBack = false;
    _rebuildBecause = null;
    _recovering = true;
    try {
      if (canRewind && (reply != null || takeBack)) {
        StoppedTurnRewind? result;
        StoppedTurnRewindException? failure;
        try {
          result = await _live.rewindStoppedTurn(takeBack ? null : reply);
        } on StoppedTurnRewindException catch (e) {
          failure = e;
        } catch (_) {
          // Not a rewind failure (a closed client, a bug): the conversation is
          // as the stop left it, so the next turn tries again from the start.
          _stoppedReply = reply;
          _takeBack = takeBack;
          _rebuildBecause = rebuildBecause;
          rethrow;
        }
        if (_closed) throw StateError('Conversation handle is closed');
        switch (result) {
          case StoppedTurnRewind.rewound:
            _stopped = false;
            runtimeLog(
              '[FfiInferenceModel] rewound the conversation after a stopped '
              'turn or a full context',
            );
            return;
          case StoppedTurnRewind.notCancelled when !takeBack:
            _stopped = false;
            runtimeLog(
              '[FfiInferenceModel] the stopped turn had ended natively before '
              'the stop; the conversation is kept as it is',
            );
            return;
          case StoppedTurnRewind.notCancelled:
            // The turn to take out had ended natively, so native keeps it:
            // only a rebuild leaves it out.
            break;
          case StoppedTurnRewind.unsupported:
          case null:
            break;
        }
        // Printed in release builds too. An unsupported rewind (an older
        // libLiteRtLm) is not a failure and rebuilds quietly.
        if (failure != null) {
          // ignore: avoid_print
          print(
            '[litertlm_dart] could not rewind the conversation '
            'after a stopped turn or a full context ($failure); rebuilding it',
          );
        }
      } else if (canRewind && rebuildBecause != null) {
        // ignore: avoid_print
        print(
          '[litertlm_dart] rebuilding the conversation: '
          '$rebuildBecause',
        );
      }
      await _rebuild();
    } finally {
      _recovering = false;
    }
  }

  /// Runs one turn on the live conversation, recovering it first if the
  /// previous turn was stopped, and records the turn for the next rebuild.
  /// [raw] says whether [send] yields raw SDK JSON or plain text.
  Stream<String> _turn(
    Map<String, Object?> message,
    Stream<String> Function(ConversationHandle live) send, {
    required bool raw,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    final epoch = _stopEpoch;
    final previous = _turnDone;
    final done = Completer<void>();
    _turnDone = done.future;
    // What the reply showed: thought chunks are left out, as native leaves a
    // finished turn's thoughts out of the context.
    final visible = StringBuffer();
    final rawReply = StringBuffer();
    // Any non-empty chunk, thoughts included, as core's chat counts text.
    var streamed = false;
    var sent = false;
    var finished = false;
    var failed = false;
    var poisoned = false;
    try {
      if (previous != null) {
        // The turn before this one decides whether this one recovers first,
        // and a rebuild must replay its exchange, so wait for its `finally`.
        // Bounded: a consumer that pauses a stream and never resumes it would
        // otherwise block every later turn. Past the bound, a stopped turn is
        // treated as having damaged the conversation, which is rebuilt without
        // its exchange; a turn that is still generating normally is left
        // alone, and the native lock queues this one behind it.
        // Under [freshConversationEachTurn] this turn closes the conversation
        // the previous one generates on, so it keeps waiting while that turn
        // is healthy: it is never cut off, and its exchange is in the history
        // the new conversation replays. A stop still gets the bound.
        var ended = false;
        while (!ended) {
          ended = true;
          await previous.timeout(
            windDownTimeout,
            onTimeout: () {
              if (!_stopRequested) {
                runtimeLog(
                  '[FfiInferenceModel] the previous turn is still generating '
                  'after ${windDownTimeout.inSeconds}s; this one waits for it',
                );
                if (freshConversationEachTurn) ended = false;
                return;
              }
              _stopped = true;
              _stoppedReply = null;
              _abandonedTurns.add(previous);
              _rebuildBecause =
                  'the previous turn did not wind down within '
                  '${windDownTimeout.inSeconds}s';
              runtimeLog(
                '[FfiInferenceModel] a stopped turn did not wind down within '
                '${windDownTimeout.inSeconds}s (is its stream paused?); '
                'rebuilding without it',
              );
            },
          );
        }
      }
      // A recovery cannot be cut short (native bounds it); one that started
      // while this turn waited is still using the conversation.
      for (var r = _recovery; r != null; r = _recovery) {
        await r.catchError((Object _) {});
      }
      if (_closed) throw StateError('Conversation handle is closed');
      _current = done;
      _inFlight = true;
      _stopRequested = false;
      _latestSent = false;
      if (_stopped || (freshConversationEachTurn && _liveSent)) {
        final recovery = _recovery = _stopped ? _recover() : _freshen();
        try {
          await recovery;
        } finally {
          if (identical(_recovery, recovery)) _recovery = null;
        }
      }
      // Stopped while this turn waited for the one before it, or while the
      // conversation was being recovered: nothing has reached the model, so
      // there is nothing to generate and nothing to record.
      if (_stopEpoch != epoch) return;
      sent = true;
      _latestSent = true;
      _liveSent = true;
      await for (final chunk in send(_live)) {
        final text = raw
            ? LiteRtLmFfiClient.extractTextFromResponse(chunk)
            : chunk;
        if (text.isNotEmpty) streamed = true;
        if (!text.startsWith(thoughtChunkPrefix)) visible.write(text);
        if (raw) rawReply.write(chunk);
        yield chunk;
      }
      finished = true;
    } on LiteRtLmTurnCancelledException {
      // Native cancelled a turn nobody stopped: an earlier cancel poisoned the
      // conversation. The model saw nothing of this turn; the next one rebuilds.
      poisoned = true;
      rethrow;
    } catch (_) {
      // An error after the consumer asked to stop is the stop's: the turn
      // ends cleanly as stopped, as core's reportedEngineTurn ends it (a stop
      // wins over a failure).
      if (_stopRequested) return;
      // Any other failure is taken back (decision W): see the `finally`.
      failed = true;
      rethrow;
    } finally {
      // A turn that winds down after the next one took the conversation (past
      // its bound) leaves the shared state to that one.
      final latest = identical(_current, done);
      if (latest) _inFlight = false;
      final abandoned = _abandonedTurns.remove(done.future);
      if (poisoned) {
        if (latest) {
          _stopped = true;
          _stoppedReply = null;
          _rebuildBecause = 'native cancelled a turn that was not stopped';
        }
      } else if (sent) {
        // Stopped by cancelGeneration, or abandoned mid-turn — which cancels
        // native the same way — leaves the conversation answering nothing.
        final stopped = _stopRequested || (!finished && !failed);
        final reply = assistantTurnMessage(
          toolCallsOf,
          visible.toString(),
          rawReply.toString(),
        );
        final end = _live.lastTurnEnd;
        if (failed) {
          // Decision W: a failed turn is taken back on both sides, never
          // replayed. One native ended context_full (section 23) is rewound
          // out (native drops its input; it fails every later send until
          // then); one native refused before it started left nothing to undo;
          // any other (a decode error, a resource other than the window) is
          // rebuilt without it, as native does not rewind a failed send.
          if (latest && end != NativeLastTurnEnd.refused) {
            _stopped = true;
            _stoppedReply = null;
            if (end == NativeLastTurnEnd.contextFull) {
              _takeBack = true;
              _rebuildBecause = 'the context window was full';
            } else {
              _rebuildBecause = 'the last turn failed';
            }
          }
        } else if (stopped && !streamed) {
          // Rule A: a turn stopped before it produced anything is taken back
          // on both sides, rewound out of the conversation.
          if (latest) {
            _stopped = true;
            _stoppedReply = null;
            _takeBack = true;
          }
        } else {
          if (stopped && latest) {
            _stopped = true;
            _stoppedReply = reply;
          }
          // The message reached the model, so it belongs in the history a
          // rebuild replays — with whatever of the reply was produced. Not a
          // stopped turn the next one gave up on past its bound: that one
          // rebuilt without it, so its exchange is not in the conversation,
          // and written now it would land after the newer one.
          if (!abandoned) {
            _history
              ..add(message)
              ..add(reply);
          }
        }
      }
      done.complete();
    }
  }

  /// Runs [op] on the live conversation between turns: after the turn before
  /// it has ended, and after the conversation is recovered from a stopped or
  /// refused one, as the next turn would recover it. A turn that starts
  /// meanwhile waits for [op].
  Future<T> _betweenTurns<T>(
    Future<T> Function(ConversationHandle live) op,
  ) async {
    if (_closed) throw StateError('Conversation handle is closed');
    final previous = _turnDone;
    final done = Completer<void>();
    _turnDone = done.future;
    try {
      await previous;
      for (var r = _recovery; r != null; r = _recovery) {
        await r.catchError((Object _) {});
      }
      if (_closed) throw StateError('Conversation handle is closed');
      if (_stopped) {
        final recovery = _recovery = _recover();
        try {
          await recovery;
        } finally {
          if (identical(_recovery, recovery)) _recovery = null;
        }
      }
      return await op(_live);
    } finally {
      done.complete();
    }
  }

  static ConversationStateAccess _access(ConversationHandle live) {
    if (live is ConversationStateAccess) return live as ConversationStateAccess;
    throw UnsupportedError('This conversation cannot read its own state.');
  }

  @override
  Future<int> kvTokenCount() =>
      _betweenTurns((live) => _access(live).kvTokenCount());

  @override
  Future<String> renderMessage(String messageJson) =>
      _betweenTurns((live) => _access(live).renderMessage(messageJson));

  @override
  Future<String> renderPreface() =>
      _betweenTurns((live) => _access(live).renderPreface());

  /// A native clone of the live conversation, recovered first, in a handle
  /// of its own that records the same history, so a rebuild of the clone
  /// replays what the clone holds.
  @override
  Future<ConversationHandle> cloneHandle() => _betweenTurns((live) async {
    final cloned = await _access(live).cloneHandle();
    return RecoveringConversationHandle(
      cloned,
      reopen: reopen,
      toolCallsOf: toolCallsOf,
      noRewindReason: noRewindReason,
      freshConversationEachTurn: freshConversationEachTurn,
      windDownTimeout: windDownTimeout,
      mediaOrder: mediaOrder,
      history: _history,
    ).._liveSent = _liveSent;
  });

  /// The complete user message a rebuild replays, including media.
  Map<String, Object?> _message(
    String text,
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
  ) =>
      jsonDecode(
            LiteRtLmFfiClient.buildMessageJson(
              text,
              imagesBytes: imageBytes,
              audioBytes: audioBytes,
              order: mediaOrder,
            ),
          )
          as Map<String, Object?>;

  @override
  Future<int?> tokenCount(String text) => _live.tokenCount(text);

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _message(text, imageBytes, audioBytes),
    (live) => live.chat(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: false,
  );

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) => _turn(
    _message(text, imageBytes, audioBytes),
    (live) => live.chatRaw(
      text,
      imageBytes: imageBytes,
      audioBytes: audioBytes,
      enableThinking: enableThinking,
    ),
    raw: true,
  );

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) => _turn(
    jsonDecode(messageJson) as Map<String, Object?>,
    (live) => live.chatRawMessage(
      messageJson,
      enableThinking: enableThinking,
      options: options,
    ),
    raw: true,
  );

  @override
  void cancelGeneration() {
    // A turn still waiting for the one before it hears of this and does not
    // start.
    _stopEpoch++;
    // Only a cancel that lands inside a turn damages the conversation. The
    // turn's `finally` turns this into a recovery if generation had begun.
    if (_inFlight) _stopRequested = true;
    // The turn returns after the recovery instead of generating.
    if (_recovering) return;
    _live.cancelGeneration();
  }

  /// Recovery after a stop is this handle's own job, done at the next turn.
  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  BenchmarkInfo getSessionMetrics() => _live.getSessionMetrics();

  @override
  NativeBenchmark? getNativeBenchmark() => _live.getNativeBenchmark();

  /// The latest turn reached its send, so native's record is that turn's
  /// end; a turn that failed before it (a recovery that threw) has none.
  bool _latestSent = false;

  @override
  NativeLastTurnEnd? get lastTurnEnd => _latestSent ? _live.lastTurnEnd : null;

  @override
  int? get lastTurnCode => _latestSent ? _live.lastTurnCode : null;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _history.clear();
    // The native handle waits for an operation still running on it (a rewind,
    // a generation) before it deletes the conversation.
    _live.close();
  }
}

/// A [ConversationHandle] backed by the virtual-session multiplexer.
///
/// On LiteRT-LM 0.18 the engine allowed only ONE live conversation at a time
/// (upstream #966); 0.19 lifts it, but only where several live conversations
/// were verified does an [openSession] session get its own
/// ([OpenSessionBacking.native]). Everywhere else each virtual handle keeps
/// its full multimodal turn history in Dart and, on every generate, asks the
/// client to (re)materialize the single shared conversation seeded with THIS
/// session's history via a `messages_json` preface. The client serializes turns
/// with a mutex, so the sessions are logically concurrent (independent
/// contexts) but inference is serialized (one generation at a time) — verified by the
/// session_switch / messages_preface smoke tests.
///
/// Same-session follow-up turns reuse the live conversation (no rebuild),
/// except under [freshConversationEachTurn]; only switching to a different
/// session pays the teardown+replay cost.
class VirtualConversationHandle
    implements ConversationHandle, ConversationStateAccess {
  VirtualConversationHandle({
    required this.client,
    required this.systemMessage,
    required this.toolsJson,
    required this.sampling,
    required this.samplingExplicit,
    required this.multimodalOrder,
    required this.filterChannelContent,
    required this.toolCallsOf,
    this.maxOutputTokens,
    this.constraint,
    this.extras = ConversationExtras.none,
    List<Map<String, Object?>> initialHistory = const [],
    this.freshConversationEachTurn = false,
  }) {
    _history.addAll(initialHistory);
  }

  /// The tool calls of a raw reply, for the assistant turn a switch replays.
  final ToolCallReader toolCallsOf;

  /// Every turn, this session's follow-ups included, rebuilds the shared
  /// conversation from the history (`liteRtLmFreshConversationEachTurn`).
  final bool freshConversationEachTurn;

  final LiteRtLmFfiClient client;
  final String? systemMessage;
  final String? toolsJson;
  final Sampler sampling;
  final bool samplingExplicit;
  final MediaOrder multimodalOrder;
  final int? maxOutputTokens;
  final Constraint? constraint;
  final ConversationExtras extras;
  final bool filterChannelContent;

  /// The tokenizer belongs to the engine, not to a conversation, so a virtual
  /// session answers this as accurately as a live one.
  @override
  Future<int?> tokenCount(String text) => client.tokenCount(text);

  /// Unique identity for this virtual session — the client uses it to tell
  /// whether the live conversation already holds this session's history.
  final Object token = Object();

  /// Completed turns, replayed as a `messages_json` preface to rebuild this
  /// session's context when it next becomes active. Whole messages rather than
  /// role and text, because a tool round is an assistant turn with
  /// `tool_calls` followed by a role-`tool` message, and neither survives being
  /// flattened to text.
  final List<Map<String, Object?>> _history = [];

  bool _closed = false;

  /// This session's own turn is running. See [cancelGeneration].
  bool _inFlight = false;

  /// A cancel landed inside this session's current turn.
  bool _stopRequested = false;

  /// Completes when the current turn has recorded its history.
  /// Counts the turns started: a turn compares its own number with it to
  /// tell whether a later one took over.
  int _generation = 0;

  Future<void>? _turnDone;

  /// Drive one turn through the multiplexer, then record the sent [message]
  /// and the generated assistant reply so the NEXT turn replays them as
  /// preface. [raw] decides what the caller gets per chunk (raw SDK JSON or its
  /// text); history records the reply the same way either way.
  Stream<String> _run(
    Map<String, Object?> message, {
    required bool raw,
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) async* {
    if (_closed) throw StateError('Conversation handle is closed');
    // After a stop the client rebuilds the conversation from this snapshot,
    // so a turn that starts before the stopped one has recorded itself waits
    // for it — otherwise the rebuild would leave the stopped exchange out.
    if (_stopRequested) {
      // Bounded for the reason given in RecoveringConversationHandle._turn.
      await _turnDone?.timeout(_windDownTimeout, onTimeout: () {});
    } else if (freshConversationEachTurn) {
      // The rebuild replays [_history], so the turn before this one must be in
      // it: wait while it is healthy, and as above once it is stopped.
      for (var waiting = true; waiting;) {
        waiting = false;
        await _turnDone?.timeout(
          _windDownTimeout,
          onTimeout: () => waiting = !_stopRequested,
        );
      }
    }
    final done = Completer<void>();
    _turnDone = done.future;
    _inFlight = true;
    _stopRequested = false;
    // This turn's place: a stopped turn that ends after a later one took
    // over (past the bound above) owns neither the busy flag nor the history.
    final generation = ++_generation;
    bool superseded() => generation != _generation;
    final messageJson = jsonEncode(message);
    final extraContext = sendExtraContext(enableThinking, options.extraContext);
    // Snapshot history BEFORE this turn — the live message is sent separately.
    final historySnapshot = List<Map<String, Object?>>.from(_history);
    final assistantText = StringBuffer();
    final assistantRaw = StringBuffer();
    var recorded = false;
    var failed = false;
    void record() {
      if (recorded || superseded()) return;
      recorded = true;
      // Record both turns so the next switch back replays the full context.
      _history.add(message);
      _history.add(
        assistantTurnMessage(
          toolCallsOf,
          assistantText.toString(),
          assistantRaw.toString(),
        ),
      );
    }

    _latestStarted = true;
    try {
      await for (final rawChunk in client.startVirtualTurn(
        conversationToken: token,
        messageJson: messageJson,
        history: historySnapshot,
        systemMessage: systemMessage,
        toolsJson: toolsJson,
        sampling: sampling,
        samplingExplicit: samplingExplicit,
        extraContext: extraContext,
        thinking: enableThinking,
        maxOutputTokens: maxOutputTokens,
        constraint: constraint,
        filterChannelContent: filterChannelContent,
        options: options,
        extras: extras,
        freshConversation: freshConversationEachTurn,
      )) {
        final chunkText = LiteRtLmFfiClient.extractTextFromResponse(rawChunk);
        assistantText.write(chunkText);
        assistantRaw.write(rawChunk);
        yield raw ? rawChunk : chunkText;
      }
      // A stop ends the stream cleanly: a stopped turn that produced nothing
      // is not recorded (Rule A).
      if (!_stopRequested || assistantText.isNotEmpty) record();
    } catch (_) {
      // Decision W: a failed turn is taken back on both sides; the shared
      // conversation is rebuilt from this history, which it is not in.
      failed = true;
      rethrow;
    } finally {
      // A stopped or abandoned turn keeps what it produced, as core's chat
      // does; one that produced nothing is taken back (Rule A).
      if (!failed && assistantText.isNotEmpty) record();
      // A superseded turn's exchange is not the conversation's stopped one:
      // the turn that took over settles its own stop.
      if (!superseded()) {
        client.finishVirtualStoppedTurn(
          token,
          messageJson: messageJson,
          // Decision W takes a failed turn back even if it streamed text.
          partialReply: failed || assistantText.isEmpty
              ? null
              : assistantTurnMessage(
                  toolCallsOf,
                  assistantText.toString(),
                  assistantRaw.toString(),
                ),
          extraContext: extraContext,
          freshConversation: freshConversationEachTurn,
        );
      }
      if (!superseded()) _inFlight = false;
      done.complete();
    }
  }

  @override
  Stream<String> chat(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _latestStarted = false;
    return _run(
      _userMessage(text, imageBytes, audioBytes),
      raw: false,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRaw(
    String text, {
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
    bool enableThinking = false,
  }) {
    _latestStarted = false;
    return _run(
      _userMessage(text, imageBytes, audioBytes),
      raw: true,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<String> chatRawMessage(
    String messageJson, {
    bool enableThinking = false,
    SendOptions options = SendOptions.none,
  }) => _run(
    jsonDecode(messageJson) as Map<String, Object?>,
    raw: true,
    enableThinking: enableThinking,
    options: options,
  );

  Map<String, Object?> _userMessage(
    String text,
    List<Uint8List>? imageBytes,
    Uint8List? audioBytes,
  ) =>
      jsonDecode(
            LiteRtLmFfiClient.buildMessageJson(
              text,
              imagesBytes: imageBytes,
              audioBytes: audioBytes,
              order: multimodalOrder,
            ),
          )
          as Map<String, Object?>;

  @override
  void cancelGeneration() {
    if (_inFlight) _stopRequested = true;
    client.cancelVirtualTurn(token);
  }

  /// The multiplexer rebuilds a stopped conversation from this session's full
  /// multimodal history at its next turn.
  @override
  Future<StoppedTurnRewind> rewindStoppedTurn(
    Map<String, Object?>? partialReply,
  ) async => StoppedTurnRewind.unsupported;

  @override
  BenchmarkInfo getSessionMetrics() => client.virtualSessionMetrics(token);

  @override
  NativeBenchmark? getNativeBenchmark() => client.virtualNativeBenchmark(token);

  /// The latest turn reached native; a turn refused before it has no end of
  /// its own to report.
  bool _latestStarted = false;

  @override
  NativeLastTurnEnd? get lastTurnEnd =>
      _latestStarted ? client.virtualLastTurnEnd(token) : null;

  @override
  int? get lastTurnCode =>
      _latestStarted ? client.virtualLastTurnCode(token) : null;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _history.clear();
    client.releaseVirtualConversation(token);
  }

  @override
  Future<int> kvTokenCount() async =>
      throw UnsupportedError('$_virtualStateRefusal to count.');

  @override
  Future<String> renderMessage(String messageJson) async =>
      throw UnsupportedError('$_virtualStateRefusal to render with.');

  @override
  Future<String> renderPreface() async =>
      throw UnsupportedError('$_virtualStateRefusal to render with.');

  /// A new virtual session with this one's configuration and history, after
  /// the turn in flight has recorded itself: the shared conversation replays
  /// that history when the clone first runs, so the clone holds what this
  /// session holds, rebuilt rather than copied.
  @override
  Future<ConversationHandle> cloneHandle() async {
    if (_closed) throw StateError('Conversation handle is closed');
    await _turnDone;
    if (_closed) throw StateError('Conversation handle is closed');
    return VirtualConversationHandle(
      client: client,
      systemMessage: systemMessage,
      toolsJson: toolsJson,
      sampling: sampling,
      samplingExplicit: samplingExplicit,
      multimodalOrder: multimodalOrder,
      filterChannelContent: filterChannelContent,
      toolCallsOf: toolCallsOf,
      maxOutputTokens: maxOutputTokens,
      constraint: constraint,
      extras: extras,
      initialHistory: _history,
      freshConversationEachTurn: freshConversationEachTurn,
    );
  }
}

/// Why a virtual session has no native state of its own to read.
const _virtualStateRefusal =
    'This conversation shares the engine\'s one native conversation by replay '
    '(several live native conversations are not verified on this host and '
    'backend), so it has no KV cache of its own';

/// Test seam for the history a virtual session would replay on its next turn.
@visibleForTesting
List<Map<String, Object?>> virtualConversationHistoryForTest(
  ConversationHandle handle,
) {
  if (handle is! VirtualConversationHandle) {
    throw ArgumentError.value(handle, 'handle', 'is not a virtual session');
  }
  return List.unmodifiable(handle._history);
}

/// Test seam for driving the client's side of a consumer cancellation without
/// calling [VirtualConversationHandle.cancelGeneration], which deliberately
/// marks the turn as an explicit stop instead.
@visibleForTesting
Object virtualConversationTokenForTest(ConversationHandle handle) {
  if (handle is! VirtualConversationHandle) {
    throw ArgumentError.value(handle, 'handle', 'is not a virtual session');
  }
  return handle.token;
}

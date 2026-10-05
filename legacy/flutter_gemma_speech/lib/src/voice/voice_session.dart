import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_gemma/flutter_gemma.dart'
    show
        FunctionCallResponse,
        InferenceChat,
        Message,
        ModelResponse,
        SpeechRecognizer,
        SpeechSynthesizer,
        TextResponse,
        GemmaLogLevel;
import 'package:flutter_gemma/core/utils/gemma_log.dart' show gemmaLog;
import 'package:meta/meta.dart' show visibleForTesting;

import 'clause_splitter.dart';
import 'voice_event.dart';
import 'voice_responder.dart';

/// On-device voice turn: PCM in → [VoiceEvent]s out. Pure orchestration — owns
/// NO microphone, NO player, and none of the injected components' lifecycles
/// (the caller creates + closes recognizer / chat / synthesizer). See the
/// design spec (`2026-07-29-voice-loop-design.md`) for the full contract.
class VoiceSession {
  /// General constructor — any LLM behind a [VoiceResponder].
  //
  // `this._recognizer` initializing formals with PRIVATE field names: Dart
  // de-underscores the leading `_`, so the public named params stay
  // `recognizer:`/`responder:`/`synthesizer:` while the backing fields remain
  // private (`_recognizer`/`_responder`/`_synthesizer`) — no initializer list
  // needed.
  VoiceSession.custom({
    required this._recognizer,
    required this._responder,
    required this._synthesizer,
    this._streamAudio = false,
  });

  /// Multi-turn conversational voice. Recommended default. Create the chat via
  /// `getActiveModel().createChat(...)` with a short `maxOutputTokens` and a
  /// "reply concisely, this will be spoken aloud" system instruction.
  ///
  /// When `chat.tools` is empty this is the plain text-only path. When
  /// `chat.tools` is non-empty, [onToolCall] MUST be supplied — it is the
  /// tool implementation (same as a text chat), and the turn is driven
  /// through core's `InferenceChat.generateChatResponseWithTools` (the
  /// reusable function-calling loop; see [maxToolTurns]). Without
  /// [onToolCall] there is nothing to run a tool call with, so a tools-chat
  /// throws (a real throw, not an assert — asserts are stripped in release —
  /// §12 B4).
  ///
  /// NOTE: the `chat.tools` check reads the (mutable, aliased) list once at
  /// construction — the requirement is lifetime-wide, not one-shot: mutating
  /// `chat.tools` after construction re-enters the unsupported state without
  /// this constructor catching it again.
  factory VoiceSession.fromChat({
    required SpeechRecognizer recognizer,
    required InferenceChat chat,
    required SpeechSynthesizer synthesizer,
    FutureOr<Map<String, dynamic>> Function(FunctionCallResponse call)?
    onToolCall,
    int maxToolTurns = 8,
    bool streamAudio = false,
  }) {
    if (chat.tools.isEmpty) {
      return VoiceSession.custom(
        recognizer: recognizer,
        responder: VoiceResponder(
          respond: (userText) => _chatRespond(chat, userText),
          stop: chat.stopGeneration,
        ),
        synthesizer: synthesizer,
        streamAudio: streamAudio,
      );
    }
    if (onToolCall == null) {
      throw ArgumentError.value(
        chat,
        'chat',
        'VoiceSession.fromChat: a chat with tools requires an onToolCall '
            'handler (the tool implementations, same as a text chat). '
            'Pass onToolCall.',
      );
    }
    // Tool-calling path: a thin wrapper over core's driver loop — no loop
    // lives here.
    //
    // Cancellation is PER-TURN: each respond() creates its own token and
    // stop() cancels only the currently-active one. A single shared boolean
    // that respond() resets to false would UN-cancel a prior turn's detached
    // (drain-timeout) tool loop, letting it resume tool calls on this same
    // chat concurrently with the new turn. A prior turn's token, once
    // cancelled, stays cancelled forever.
    _CancelToken? activeToken;
    Stream<String> respondWithTools(String userText) async* {
      final token = _CancelToken();
      activeToken = token;
      await chat.addQueryChunk(Message(text: userText, isUser: true));
      yield* textTokensOf(
        chat.generateChatResponseWithTools(
          onToolCall: onToolCall,
          maxToolTurns: maxToolTurns,
          isCancelled: () => token.cancelled,
        ),
      );
    }

    return VoiceSession.custom(
      recognizer: recognizer,
      responder: VoiceResponder(
        respond: respondWithTools,
        stop: () async {
          activeToken?.cancel();
          await chat.stopGeneration();
        },
      ),
      synthesizer: synthesizer,
      streamAudio: streamAudio,
    );
  }

  static Stream<String> _chatRespond(
    InferenceChat chat,
    String userText,
  ) async* {
    await chat.addQueryChunk(Message(text: userText, isUser: true));
    yield* textTokensOf(chat.generateChatResponseAsync());
  }

  /// Keep only [TextResponse] tokens from a chat response stream. Thinking and
  /// function-call parsing already happened inside the chat, so this neither
  /// double-filters nor drops (§12 note). Exposed for testing the mapping
  /// without a real InferenceChat.
  @visibleForTesting
  static Stream<String> textTokensOf(Stream<ModelResponse> responses) async* {
    await for (final r in responses) {
      if (r is TextResponse) yield r.token;
    }
  }

  final SpeechRecognizer _recognizer;
  final VoiceResponder _responder;
  final SpeechSynthesizer _synthesizer;

  /// When true, synthesize the reply clause-by-clause as the LLM streams (lower
  /// time-to-first-audio) — a series of `VoiceReplyAudioEvent(isFinal:false)`
  /// chunks then a final `isFinal:true` marker. When false (default), the reply
  /// is synthesized in one shot after the LLM finishes (a single `isFinal:true`
  /// chunk). Opt-in because consumers must play the chunks in sequence, and
  /// because per-clause synthesis has slightly flatter prosody at the clause
  /// joins than synthesizing the whole reply at once.
  final bool _streamAudio;

  /// Max time interrupt() waits for the LLM reply stream to drain after stop()
  /// before force-terminating the turn and detaching the (still-running)
  /// subscription (§12 B1). The subscription is never cancelled — the chat
  /// epilogue (token accounting + rotation + history append) must run.
  @visibleForTesting
  static const Duration drainTimeout = Duration(seconds: 5);

  // ---- Per-turn state (null/reset between turns) ----
  StreamController<VoiceEvent>? _activeController;
  bool _interruptRequested = false;
  Completer<void>? _turnDone; // completes when the turn reaches its terminal
  Completer<void>?
  _replyDrained; // completes when the LLM stream ends or times out
  Timer? _drainTimer;
  bool _drainForced = false; // true if the bounded-drain timeout fired
  // The controller of the turn a concurrent interrupt() is currently in
  // flight for. Turn-scoped (not a session-wide bool, N1): interrupt() for
  // turn A can be parked on a slow responder.stop() when A completes
  // naturally and the caller starts + barges in on turn B — that second
  // interrupt() must proceed (different controller), not silently no-op.
  StreamController<VoiceEvent>? _interruptingController;

  /// Sample rate of emitted reply audio (delegates to the synthesizer).
  int get replySampleRate => _synthesizer.sampleRate;

  /// True while a turn is in flight (a second [runTurn] would throw
  /// StateError, and [interrupt] is a genuine no-op only when this is false).
  bool get isTurnInFlight => _activeController != null;

  /// Run one push-to-talk turn on a recorded utterance (16 kHz mono 16-bit LE
  /// PCM — same contract as [SpeechRecognizer.transcribe]).
  ///
  /// Sequence: transcribe(pcm) → VoiceTranscriptEvent(final) →
  /// responder.respond(text) streamed as VoiceReplyTextEvent(s) → reply audio →
  /// VoiceTurnCompleteEvent. Reply audio is one VoiceReplyAudioEvent(isFinal)
  /// in one-shot mode (default), or a series of VoiceReplyAudioEvent(isFinal:
  /// false) chunks then a zero-byte VoiceReplyAudioEvent(isFinal) marker when
  /// streamAudio is set. A stage failure surfaces as a Dart stream error; an
  /// interrupted turn ends with VoiceTurnInterruptedEvent (no isFinal audio).
  ///
  /// WARNINGS:
  /// - Cancelling this stream's subscription is NOT a portable stop — to barge
  ///   in, call [interrupt].
  /// - Calling runTurn while a turn is in flight throws StateError.
  /// - STT truncates audio beyond its fixed window (~5 s for moonshine) and can
  ///   hallucinate text on near-silence — both are STT-model properties.
  Stream<VoiceEvent> runTurn(Uint8List pcm16kMono) {
    if (_activeController != null) {
      throw StateError('VoiceSession.runTurn called while a turn is in flight');
    }
    final controller = StreamController<VoiceEvent>();
    _activeController = controller;
    _interruptRequested = false;
    _drainForced = false;
    _turnDone = Completer<void>();
    controller.onListen = () {
      // Fire-and-forget driver — it is the SOLE writer of events (§12 B3).
      _drive(controller, pcm16kMono);
    };
    return controller.stream;
  }

  /// Barge-in. Idempotent (a genuine no-op when idle, and a concurrent second
  /// call targeting the SAME in-flight turn neither re-calls `stop()` nor
  /// re-arms the drain timer — it just awaits that turn's terminal via
  /// [_interruptingController]). A second call that targets a DIFFERENT
  /// (later) turn proceeds normally — see N1. Sets the interrupt flag, calls
  /// responder.stop() (caught if it throws), bounded-drains the reply stream,
  /// then awaits the driver's terminal. Never writes to the controller (§12 B3).
  Future<void> interrupt() async {
    final controller = _activeController;
    if (controller == null) return; // idle
    if (identical(_interruptingController, controller)) {
      // Concurrent interrupt() of the SAME turn: true no-op, just await the
      // in-flight terminal.
      final done = _turnDone;
      if (done != null) await done.future;
      return;
    }
    _interruptingController = controller;
    _interruptRequested = true;
    // Capture BEFORE the await responder.stop() below (F1): if the current
    // turn completes naturally while stop() is in flight and the caller
    // immediately starts turn B, reading _replyDrained/_turnDone AFTER the
    // await would attach this drain timer / await to turn B instead of
    // turn A, force-completing B's un-interrupted drain 5s later.
    final drained = _replyDrained;
    final done = _turnDone;
    try {
      await _responder.stop().timeout(drainTimeout);
    } on TimeoutException {
      gemmaLog(
        'VoiceSession: responder.stop() did not resolve within '
        '${drainTimeout.inSeconds}s during barge-in; proceeding to drain.',
        level: GemmaLogLevel.info,
      );
    } catch (e) {
      gemmaLog(
        'VoiceSession: responder.stop() threw during barge-in: $e',
        level: GemmaLogLevel.info,
      );
    }
    // Bounded drain: give the reply stream drainTimeout to end, else force it.
    if (drained != null) {
      _armBoundedDrain(
        drained,
        'barge-in drain exceeded ${drainTimeout.inSeconds}s',
      );
    }
    try {
      if (done != null) await done.future;
    } finally {
      // Only clear if THIS interrupt still owns the marker — a later turn's
      // interrupt() may have overwritten it; leave that one intact (N1).
      if (identical(_interruptingController, controller)) {
        _interruptingController = null;
      }
    }
  }

  /// Arm the bounded-drain timeout: give the (still-running) reply stream
  /// [drainTimeout] to end on its own, else force-complete [drained] and set
  /// [_drainForced] so the driver detaches the subscription (never cancels it —
  /// the chat epilogue must run). Shared by [interrupt] (barge-in) and the
  /// streaming synth-pump's error path.
  void _armBoundedDrain(Completer<void> drained, String reason) {
    if (drained.isCompleted) return;
    _drainTimer?.cancel();
    _drainTimer = Timer(drainTimeout, () {
      if (!drained.isCompleted) {
        _drainForced = true;
        gemmaLog(
          'VoiceSession: $reason; detaching LLM stream '
          '(generation finishes in background).',
          level: GemmaLogLevel.info,
        );
        drained.complete();
      }
    });
  }

  Future<void> _drive(
    StreamController<VoiceEvent> controller,
    Uint8List pcm,
  ) async {
    void finish(VoiceEvent terminal) {
      controller.add(terminal);
      _teardown(controller);
    }

    // Streaming-audio pump state, hoisted so the catch can always stop + join
    // the pump instead of leaving it parked on the clause queue.
    StreamController<String>? clauses;
    Future<void>? pumpDone;
    var stopPump = false;

    try {
      // ---- STT ----
      final transcript = await _recognizer.transcribe(pcm);
      controller.add(VoiceTranscriptEvent(transcript, isFinal: true));
      if (_interruptRequested) {
        finish(
          VoiceTurnInterruptedEvent(
            transcript: transcript,
            partialReplyText: '',
          ),
        );
        return;
      }
      if (transcript.trim().isEmpty) {
        finish(const VoiceTurnCompleteEvent('', ''));
        return;
      }

      // ---- LLM (subscription so interrupt() can stop + bounded-drain) ----
      final buffer = StringBuffer();
      final drained = Completer<void>();
      _replyDrained = drained;
      Object? replyError;
      StackTrace? replyStack;

      // ---- Streaming-audio pump (null in one-shot mode) ----
      // A serial synth pump runs CONCURRENTLY with the LLM subscription: the
      // token listener feeds completed clauses into [clauses], the pump
      // synthesizes them in order and emits isFinal:false chunks. It is joined
      // in the driver body below (never from the detached listener), so barge-in
      // stays bounded by the existing drain machinery.
      final splitter = _streamAudio ? ClauseSplitter() : null;
      clauses = _streamAudio ? StreamController<String>() : null;
      Object? pumpError;
      StackTrace? pumpStack;
      final clauseQueue = clauses;

      void enqueueClause(String clause) {
        if (clauseQueue == null || clauseQueue.isClosed) return;
        if (clause.trim().isEmpty) return; // TTS on whitespace is undefined
        clauseQueue.add(clause);
      }

      if (clauseQueue != null) {
        pumpDone = () async {
          try {
            await for (final clause in clauseQueue.stream) {
              // Check the stop flag on BOTH sides of the (uncancellable)
              // synthesize: `await for` keeps delivering already-buffered clauses
              // after close(), so without the pre-check a barge-in would still
              // synthesize the whole backlog, and without the post-check a stale
              // result would be emitted after teardown. We `continue`
              // (drain-and-skip) rather than `break` so the pump only ever ends
              // when the driver's queue.close() drains the last item, never on
              // its own: `break` exits the `await for` and cancels the clause
              // subscription, and the driver's later queue.close() then can't
              // join it promptly — `await pumpDone` fails to resolve within the
              // drain window, so the terminal is emitted too late. (verified:
              // with `break` the forced-drain test observes the wrong terminal —
              // no interrupted/complete event.) The load-bearing skip for that
              // test is the post-check below (the barge-in lands mid-synthesize);
              // the pre-check here guards the buffered-backlog case.
              if (stopPump || _interruptRequested) continue;
              final chunk = await _synthesizer.synthesize(clause);
              if (stopPump || _interruptRequested || controller.isClosed) {
                continue;
              }
              controller.add(
                VoiceReplyAudioEvent(
                  chunk,
                  sampleRate: _synthesizer.sampleRate,
                  isFinal: false,
                ),
              );
            }
          } catch (e, st) {
            // A synthesize stage error. NEVER throw out of the pump future;
            // capture it, then (the driver is parked on `drained`) stop the LLM
            // and arm the bounded drain so the error surfaces promptly instead
            // of after the whole reply finishes generating.
            pumpError = e;
            pumpStack = st;
            unawaited(
              _responder.stop().catchError((Object stopErr) {
                gemmaLog(
                  'VoiceSession: stopping the LLM after a synth pump error '
                  'failed: $stopErr',
                  level: GemmaLogLevel.info,
                );
              }),
            );
            _armBoundedDrain(drained, 'synth pump errored');
          }
        }();
      }

      final sub = _responder
          .respond(transcript)
          .listen(
            (token) {
              if (controller.isClosed) return; // detached / torn-down turn
              buffer.write(token);
              controller.add(VoiceReplyTextEvent(token));
              if (splitter != null) {
                for (final clause in splitter.feed(token)) {
                  enqueueClause(clause);
                }
              }
            },
            onError: (Object e, StackTrace st) {
              replyError = e;
              replyStack = st;
              if (drained.isCompleted) {
                // The bounded drain already force-completed (barge-in
                // detach, R1) — this generation is no longer observed by
                // anyone. Log so a genuinely-fatal detached error isn't a
                // fully silent swallow.
                gemmaLog(
                  'VoiceSession: detached LLM stream errored after '
                  'barge-in: $e',
                  level: GemmaLogLevel.info,
                );
              }
              if (!drained.isCompleted) drained.complete();
            },
            onDone: () {
              // ONLY complete `drained` here. The splitter flush + queue close +
              // pump join all happen in the driver body after `await
              // drained.future` — which the bounded drain guarantees resumes
              // within drainTimeout even if this onDone never fires (detach). A
              // detached onDone must not touch the queue/pump (they may be gone).
              if (!drained.isCompleted) drained.complete();
            },
            cancelOnError: false,
          );
      await drained.future;
      _drainTimer?.cancel();
      // Natural end / fatal error → safe to cancel. Forced timeout → DETACH:
      // never cancel (would skip the chat epilogue → token undercount, R1).
      if (!_drainForced) {
        await sub.cancel();
      }
      final replyText = buffer.toString();

      // ---- Join the synth pump before ANY terminal (streaming mode) ----
      // Normal end → flush the splitter tail as the last clause; error/barge-in
      // → abandon buffered clauses. Then the driver (sole closer) closes the
      // queue and waits out at most one in-flight synthesize.
      if (clauseQueue != null) {
        if (replyError != null || _interruptRequested) {
          stopPump = true;
        } else {
          enqueueClause(splitter!.flush());
        }
        if (!clauseQueue.isClosed) clauseQueue.close();
        await pumpDone;
      }

      // Error wins (whether or not interrupted): turn-fatal stream error, no
      // Interrupted/Complete event. interrupt()'s Future still completes (via
      // teardown) without rethrowing. Priority: LLM error, then pump error.
      if (replyError != null) {
        // The LLM error is the turn-fatal one, but a concurrent pump error must
        // not vanish silently — log it before it's superseded.
        if (pumpError != null) {
          gemmaLog(
            'VoiceSession: synth pump also errored (superseded by the LLM '
            'stream error): $pumpError',
            level: GemmaLogLevel.info,
          );
        }
        controller.addError(replyError!, replyStack);
        _teardown(controller);
        return;
      }
      if (pumpError != null) {
        controller.addError(pumpError!, pumpStack);
        _teardown(controller);
        return;
      }
      if (_interruptRequested) {
        finish(
          VoiceTurnInterruptedEvent(
            transcript: transcript,
            partialReplyText: replyText,
          ),
        );
        return;
      }
      if (replyText.trim().isEmpty) {
        finish(VoiceTurnCompleteEvent(transcript, ''));
        return;
      }

      // ---- TTS terminal ----
      if (_streamAudio) {
        // Chunks were emitted incrementally as isFinal:false; a zero-byte
        // isFinal:true marker keeps the "exactly one isFinal:true per successful
        // turn" invariant (harmless for a player to receive 0 bytes).
        controller.add(
          VoiceReplyAudioEvent(
            Uint8List(0),
            sampleRate: _synthesizer.sampleRate,
            isFinal: true,
          ),
        );
      } else {
        final pcmOut = await _synthesizer.synthesize(replyText);
        if (_interruptRequested) {
          // Barge-in landed during (uncancellable) synthesis → suppress audio.
          finish(
            VoiceTurnInterruptedEvent(
              transcript: transcript,
              partialReplyText: replyText,
            ),
          );
          return;
        }
        controller.add(
          VoiceReplyAudioEvent(
            pcmOut,
            sampleRate: _synthesizer.sampleRate,
            isFinal: true,
          ),
        );
      }
      finish(VoiceTurnCompleteEvent(transcript, replyText));
    } catch (e, st) {
      // Stage failure (transcribe/synthesize throw) is turn-fatal (§7). If the
      // throw landed after the streaming pump started (e.g. sub.cancel() threw),
      // stop + close the queue and join the pump first, or it leaks parked on
      // the never-closed clause stream.
      stopPump = true;
      if (clauses != null && !clauses.isClosed) clauses.close();
      if (pumpDone != null) await pumpDone;
      if (!controller.isClosed) {
        controller.addError(e, st);
        _teardown(controller);
      } else {
        // Unreachable today (every earlier return path already tears down
        // the controller before this catch could fire), but a trap for a
        // future refactor: log instead of a fully-silent swallow.
        gemmaLog(
          'VoiceSession: stage error after turn teardown (dropped): $e',
          level: GemmaLogLevel.info,
        );
      }
    }
  }

  void _teardown(StreamController<VoiceEvent> controller) {
    _drainTimer?.cancel();
    _drainTimer = null;
    if (!controller.isClosed) controller.close();
    if (identical(_activeController, controller)) {
      _activeController = null;
      _replyDrained = null;
    }
    final done = _turnDone;
    _turnDone = null;
    if (done != null && !done.isCompleted) done.complete();
  }
}

/// Per-turn cancellation token for the tool-calling respond path — an enforced
/// one-way latch: [cancelled] is read-only and [cancel] can only ever set it
/// true (never reset), so a later turn (which gets its OWN token) cannot
/// un-cancel a prior turn's still-running detached loop.
class _CancelToken {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

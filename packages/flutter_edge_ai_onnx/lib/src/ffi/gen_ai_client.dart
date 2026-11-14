// ORT-GenAI text generation over `dart:ffi`, driven from a long-lived worker
// isolate — the productionized form of the throughput spike at
// `scratchpad/ort_genai_spike/bin/main.dart` (hardened plan Phase 3, Task 1).
//
// Why a long-lived worker and not `Isolate.run` per call (mirrors core's
// embedding worker host, `flutter_edge_ai/lib/src/embedding/embedding_host_io.dart`):
//   - Model + tokenizer load costs hundreds of ms and must happen once.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries — every
//     native handle (model, tokenizer, generator) is created and used
//     entirely inside the worker; only sendable values (strings, ints,
//     bools, plain data classes) cross the port. This resolves D4 by
//     construction: no FFI handle ever crosses an isolate.
//   - ORT-GenAI has no native stream callback (unlike LiteRT-LM's
//     `stream_proxy`), so the decode loop is Dart-driven. Reloading the
//     model+tokenizer on every `Isolate.run` call (~hundreds of ms) would
//     dwarf the ~18ms/token decode cost this is trying to measure/serve.
//
// The worker loop — one request at a time, close without a kill — lives in
// `gen_ai_worker.dart`; this file holds the main-isolate client and the
// `dart:ffi` engine that loop drives (`_FfiGenAiEngine`).
//
// GOTCHA (verified in the spike, and load-bearing here): on this GenAI
// version the prompt forward pass (prefill) runs INSIDE
// `OgaGenerator_AppendTokenSequences`, not the first `GenerateNextToken`.
// Every timing/stop-flag decision below assumes that.
//
// iOS shape (verified via otool -L / nm -gU on the extracted xcframework
// slice, see `hook/build.dart`'s iOS branch doc): Microsoft ships ONE image,
// `onnxruntime-genai.framework/onnxruntime-genai`, that STATICALLY links ORT
// and DYNAMICALLY EXPORTS BOTH APIs (`Oga*` here + `OrtGetApiBase` for the
// plain-ORT embedding arm in `ort_ffi_client.dart`). So [_openGenAiLibraries]
// opens a single library on iOS and returns it as both halves of its tuple —
// see that function's iOS branch.
import 'dart:async';
import 'dart:collection' show Queue;
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_edge_ai/engine.dart';
import 'package:mutex/mutex.dart';

import '../onnx_sampling.dart';
import 'gen_ai_protocol.dart';
import 'gen_ai_turns.dart';
import 'gen_ai_worker.dart';
import 'ort_genai_bindings.g.dart';

/// Env var override for host tests / macOS dev: a directory containing both
/// `libonnxruntime` and `libonnxruntime-genai` (platform-specific names) —
/// mirrors `ort_ffi_client.dart`'s `FLUTTER_GEMMA_ORT_LIBRARY` for the plain
/// ORT embedding arm. Production app builds never set this; `hook/build.dart`
/// (Task 4) resolves the CodeAsset bundle instead once it lands.
const genAiLibsDirEnvVar = 'FLUTTER_GEMMA_ORT_GENAI_LIBS';

/// One user turn to generate a response for. [GenAiFfiClient] applies the
/// model's own chat template (`OgaTokenizerApplyChatTemplate`) inside the
/// worker — callers (`OnnxSession`) pass raw content, never pre-formatted
/// turn markers (Task 3: onnx routes through the SDK-owns-templates path).
///
/// Must stay a plain sendable data class — it crosses the isolate port.
class GenAiTurn {
  const GenAiTurn({
    required this.userContent,
    this.systemInstruction,
    this.isFirstTurn = false,
    this.maxOutputTokens,
    this.searchOptions = const {},
    this.sessionId,
  });

  /// Which session's generator this turn runs on: null is the legacy
  /// singleton session (`createSession`), any other value an `openSession`
  /// session, each with its own generator (and KV cache). Turns of different
  /// sessions never run at the same time.
  final int? sessionId;

  /// Raw user-turn content (tool responses are already folded into plain
  /// text by `Message._formatToolResponseContent` upstream, via the
  /// raw-mode `transformToChatPrompt`).
  final String userContent;

  /// System role content. Only sent (as a `system` message) on
  /// [isFirstTurn] — later turns rely on the persistent generator's KV
  /// cache to remember it, matching every other raw-mode engine's posture.
  final String? systemInstruction;

  /// True for the first turn of a session: destroys any live generator and
  /// creates a fresh one (fresh KV cache) instead of reusing it.
  final bool isFirstTurn;

  /// Cap on GENERATED tokens for this turn — distinct from the model's
  /// context-window `max_length`, which is set once when the generator is
  /// created (see [GenAiClient.load]'s `contextWindow`).
  final int? maxOutputTokens;

  /// Sampling search options (`do_sample`, `temperature`, `top_k`, `top_p`,
  /// `random_seed`) the caller set, from `onnxSearchOptions`. Applied when a
  /// fresh generator is created, so a session's first turn decides them; an
  /// option left out keeps the model's `genai_config.json` value.
  final Map<String, Object> searchOptions;
}

/// Prompt/decode counters for the most recently completed [GenAiClient.generate]
/// call — read via [GenAiClient.lastGenerationStats] for
/// [InferenceModelSession.getSessionMetrics].
class GenAiGenerationStats {
  const GenAiGenerationStats({
    required this.promptTokens,
    required this.generatedTokens,
    required this.decodeMs,
  });

  final int promptTokens;
  final int generatedTokens;

  /// Wall time of the decode loop only (excludes model load and prefill).
  final int decodeMs;

  double? get tokensPerSecond =>
      decodeMs > 0 ? generatedTokens * 1000.0 / decodeMs : null;
}

/// The `dart:ffi` seam for ORT-GenAI text generation. [GenAiFfiClient] is the
/// only implementation that touches native handles — see this file's doc for
/// why they live entirely inside a worker isolate. [OnnxSession] /
/// [OnnxInferenceModel] depend on this abstract type so unit tests can inject
/// a fake with zero dlopen (hardened plan Task 6).
abstract class GenAiClient {
  /// Loads the model + tokenizer from [modelDir] (an ORT-GenAI model
  /// directory: `genai_config.json` + `.onnx`(+`.onnx_data`) + tokenizer
  /// files). [contextWindow] sizes the persistent generator's `max_length` —
  /// the model's whole KV-cache budget (same number as
  /// `InferenceModel.maxTokens`), NOT the per-turn output cap (that's
  /// [GenAiTurn.maxOutputTokens]).
  Future<void> load(String modelDir, {int contextWindow = 1024});

  /// Streams decoded text for [turn]. Only one `generate()` call may be
  /// in-flight at a time — concrete clients serialize with a mutex; a second
  /// concurrent caller's stream doesn't start until the first completes.
  Stream<String> generate(GenAiTurn turn);

  /// Token count for [text] via the tokenizer's own encoder (no chat
  /// template applied) — used for [InferenceModelSession.sizeInTokens].
  Future<int> countTokens(String text);

  /// Stops [sessionId]'s [generate] stream if it is the one in flight (no-op
  /// otherwise; a null [sessionId] is the legacy session). A stop for one
  /// session never cuts off another's turn. Deliberately NOT covered by the
  /// `generate`/`countTokens` mutex — it must be able to interrupt a call
  /// that's holding it.
  Future<void> stopGeneration({int? sessionId});

  /// Destroys [sessionId]'s generator (null = the legacy session) so its NEXT
  /// [generate] call starts a fresh conversation (fresh KV cache) instead of
  /// continuing the live one, and so an opened session gives back its
  /// 0.75 MiB × `max_length` of cache. [OnnxSession.close] calls this so a
  /// superseded session never bleeds its history into whatever session is
  /// created next — the ORT-GenAI sibling of the `.litertlm` FFI engine's
  /// "close previous conversation before creating a new one" rule.
  Future<void> resetSession({int? sessionId});

  /// Frees every native handle (generator, tokenizer, model) and stops the
  /// worker isolate — after the call in flight, however long it takes; the
  /// worker is never killed, because a killed worker frees nothing.
  /// Idempotent.
  Future<void> shutdown();

  /// Stats from the most recently completed [generate] call of the legacy
  /// session, or `null` before the first one finishes.
  GenAiGenerationStats? get lastGenerationStats;

  /// Stats from the most recently completed [generate] call of [sessionId]
  /// (null = the legacy session), or `null` before its first one finishes or
  /// after its [resetSession].
  GenAiGenerationStats? generationStatsOf(int? sessionId);
}

/// Main-isolate handle to the ORT-GenAI worker. Spawns the isolate, performs
/// the load handshake, and multiplexes concurrent requests by id. See this
/// file's top doc for why native handles never cross the port. The message
/// protocol itself lives in `gen_ai_protocol.dart`, the worker loop in
/// `gen_ai_worker.dart`.
class GenAiFfiClient implements GenAiClient {
  /// [workerEntry] is the injection seam for tests — defaults to the real
  /// dlopen-ing `_defaultWorkerEntry`. Tests spawn a fake worker (real
  /// isolate, real ports, zero FFI) that runs the same worker loop
  /// (`serveGenAiWorker`) over a scripted engine, exercising the real
  /// dispatch/mutex/`_closed`-recheck machinery below and the real queue/close
  /// rules with no native library involved (hardened plan Task 2b) — that
  /// fake cannot speak to whether the FFI engine's native handle teardown is
  /// use-after-free-safe (only `onnx_generation_host_smoke_test.dart`, which
  /// runs against real ORT-GenAI libs, can). Never override it in production
  /// code.
  ///
  /// [slowLoadNotice] and [slowCloseNotice] are how long [load] and
  /// [shutdown] wait before saying, once, that they are still waiting; tests
  /// shorten them.
  GenAiFfiClient({
    @visibleForTesting GenAiWorkerEntry? workerEntry,
    @visibleForTesting this._slowLoadNotice = _defaultSlowLoadNotice,
    @visibleForTesting this._slowCloseNotice = _defaultSlowCloseNotice,
  }) : _workerEntry = workerEntry ?? _defaultWorkerEntry;

  /// How long [shutdown] waits, by default, before saying it is still
  /// waiting. It keeps waiting afterwards: the only way to stop sooner is to
  /// kill the isolate, and a killed isolate never frees its native model.
  static const _defaultSlowCloseNotice = Duration(seconds: 30);

  /// How long [load] waits, by default, before saying it is still waiting. It
  /// keeps waiting afterwards, for the same reason.
  static const _defaultSlowLoadNotice = Duration(seconds: 30);

  final GenAiWorkerEntry _workerEntry;
  final Duration _slowLoadNotice;
  final Duration _slowCloseNotice;

  SendPort? _commandPort;
  ReceivePort? _fromWorker;
  StreamSubscription<dynamic>? _sub;

  /// The model directory [load] was given; names the model in warnings.
  String? _modelDir;

  /// Serializes `generate`/`countTokens` calls. [stopGeneration] is
  /// deliberately NOT gated by this — see its doc.
  final Mutex _mutex = Mutex();

  bool _loaded = false;

  /// True from the moment [shutdown] is called, or the worker dies; every
  /// call refuses from then on.
  bool _closed = false;

  /// Why the worker is gone when it went without being asked to — the text
  /// every later call fails with. Null otherwise.
  String? _deathReason;

  /// The error, with its stack, an uncaught exception in the worker reported
  /// through the spawn's `onError` port, kept until the `onExit` that follows.
  String? _crashError;

  /// True once the worker's [CloseAck] arrived; the `onExit` after it is the
  /// normal end, not a death.
  bool _acked = false;

  /// True once a [LoopFailed] arrived: the worker closed its engine before the
  /// error that ends it, so the death that follows has not left the model
  /// resident — unless [_closeErrorBeforeDeath] says that close failed.
  bool _closedBeforeDeath = false;
  String? _closeErrorBeforeDeath;

  /// Completes when the worker is gone: its [CloseAck], or its onExit.
  final _gone = Completer<void>();

  /// Completes, with the reason, when the worker exits without acking a
  /// [shutdown]; read through [unexpectedExitOf].
  final _unexpectedExit = Completer<String>();

  /// The one teardown every [shutdown] call shares.
  Future<void>? _shutdownFuture;

  int _nextId = 0;
  final Map<int, StreamController<String>> _activeStreams = {};
  final Map<int, Completer<void>> _streamDone = {};
  final Map<int, Completer<int>> _countPending = {};

  /// The session of each turn in flight, by request id.
  final Map<int, int?> _streamSession = {};

  /// How each turn in flight ended, by request id; completed before its text
  /// closes.
  final Map<int, Completer<TurnEnd>> _turnEnds = {};

  /// One completer per reset sent and not yet acknowledged; the worker serves
  /// requests in order, so its acks come back in the same order.
  final Queue<Completer<void>> _resetAcks = Queue();

  final Map<int?, GenAiGenerationStats> _stats = {};
  @override
  GenAiGenerationStats? get lastGenerationStats => _stats[null];

  @override
  GenAiGenerationStats? generationStatsOf(int? sessionId) => _stats[sessionId];

  @override
  Future<void> load(String modelDir, {int contextWindow = 1024}) async {
    if (_closed) {
      throw StateError('GenAiFfiClient is closed');
    }
    if (_loaded) {
      throw StateError('GenAiFfiClient is already loaded');
    }

    final fromWorker = ReceivePort();
    final readyCompleter = Completer<Ready>();

    // First message from the worker is either Ready or a String error. A
    // two-element List is an uncaught error (the onError port), which comes
    // before the onExit `null`; if that `null` arrives before Ready, the
    // worker died during load, so fail the completer instead of hanging.
    String? uncaughtDuringLoad;
    var loadFailureReported = false;
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (msg is Ready) {
        if (!readyCompleter.isCompleted) readyCompleter.complete(msg);
      } else if (msg is String) {
        loadFailureReported = true;
        if (!readyCompleter.isCompleted) {
          readyCompleter.completeError(StateError(msg));
        }
      } else if (msg is List) {
        uncaughtDuringLoad = _describeUncaught(msg);
      } else if (msg == null) {
        if (!readyCompleter.isCompleted) {
          final reason = uncaughtDuringLoad;
          readyCompleter.completeError(
            StateError(
              reason == null
                  ? 'ONNX GenAI worker isolate exited during load'
                  : 'ONNX GenAI worker isolate exited during load: $reason',
            ),
          );
        }
      }
    });

    final notice = Timer(
      _slowLoadNotice,
      () => _warn(
        'loading the ONNX GenAI model $modelDir has taken '
        '${_describeDuration(_slowLoadNotice)}: the worker is still inside a '
        'native call. It keeps waiting rather than kill the worker, because a '
        'killed worker never frees its native model.',
      ),
    );
    final envLibsDir = Platform.environment[genAiLibsDirEnvVar];
    final Ready ready;
    try {
      await Isolate.spawn(
        _workerEntry,
        WorkerInit(
          replyTo: fromWorker.sendPort,
          modelDir: modelDir,
          contextWindow: contextWindow,
          libsDir: (envLibsDir != null && envLibsDir.isNotEmpty)
              ? envLibsDir
              : null,
          logLevel: edgeAiLogLevel,
        ),
        // onError + onExit post to fromWorker so we never wait on a dead
        // isolate, and learn why it died when it says.
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
        debugName: 'onnx-genai-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      // Nothing to kill: a killed worker never frees what its load allocated.
      // A worker that reported a load failure is still freeing it, so keep
      // listening — not waiting — until it exits, and report a close that
      // fails. Otherwise it is already gone (onExit), or was never started.
      if (loadFailureReported) {
        sub.onData((msg) => _afterFailedLoad(msg, modelDir, sub, fromWorker));
      } else {
        await sub.cancel();
        fromWorker.close();
      }
      rethrow;
    } finally {
      notice.cancel();
    }

    _fromWorker = fromWorker;
    _commandPort = ready.commandPort;
    _modelDir = modelDir;
    _loaded = true;
    sub.onData(_dispatch);
    _sub = sub;
  }

  void _dispatch(dynamic msg) {
    if (msg is Chunk) {
      _activeStreams[msg.id]?.add(msg.text);
    } else if (msg is GenerateDone) {
      if (_streamSession.containsKey(msg.id)) {
        _stats[_streamSession[msg.id]] = GenAiGenerationStats(
          promptTokens: msg.promptTokens,
          generatedTokens: msg.generatedTokens,
          decodeMs: msg.decodeMs,
        );
      }
      _streamSession.remove(msg.id);
      // The end first: a consumer reading it after the text's done finds it.
      _turnEnds.remove(msg.id)?.complete(msg.end);
      final controller = _activeStreams.remove(msg.id);
      unawaited(controller?.close());
      _streamDone.remove(msg.id)?.complete();
    } else if (msg is GenerateError) {
      _streamSession.remove(msg.id);
      _turnEnds.remove(msg.id)?.complete(msg.end ?? TurnEnd.closed);
      final controller = _activeStreams.remove(msg.id);
      // A refused input — a prompt that did not fit, nothing of it kept — is
      // core's ContextLimitException, with end contextLimit; any other
      // failure is a StateError.
      controller?.addError(
        msg.end == TurnEnd.contextLimit
            ? ContextLimitException(msg.error)
            : StateError(msg.error),
      );
      unawaited(controller?.close());
      _streamDone.remove(msg.id)?.complete();
    } else if (msg is CountTokensReply) {
      final completer = _countPending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(StateError(msg.error!));
      } else {
        completer.complete(msg.count!);
      }
    } else if (msg is ResetSessionAck) {
      if (msg.error case final error?) {
        // Not rethrown — resetSession() has no caller that could act on it —
        // but not swallowed either: the next turn may continue the old
        // conversation.
        _warn(
          'resetting the ONNX GenAI generator for $_modelDir failed, so the '
          'next turn may continue the previous conversation: $error',
        );
      }
      _completeResetAck();
    } else if (msg is CloseAck) {
      _acked = true;
      if (msg.error case final error?) {
        _warn(
          'the ONNX GenAI model $_modelDir failed to close; its native model '
          'may still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
      _completeAllResetAcks();
    } else if (msg is LoopFailed) {
      _closedBeforeDeath = true;
      _closeErrorBeforeDeath = msg.error;
    } else if (msg is List) {
      // onError: an uncaught error is about to take the worker down. The
      // onExit `null` that follows reports it.
      _crashError = _describeUncaught(msg);
    } else if (msg == null) {
      if (_acked) return; // the normal exit after a CloseAck.
      _died();
    }
  }

  /// The worker exited without acking — an uncaught error, or an isolate
  /// killed from outside: tell the owner, fail everything in flight rather
  /// than leave callers hanging, refuse new calls with the reason, and say so
  /// where release builds can see it.
  void _died() {
    final crash = _crashError;
    final what = _shutdownFuture == null
        ? 'exited unexpectedly'
        : 'exited while shutting down';
    final reason =
        'the ONNX GenAI worker isolate $what${crash == null ? '' : ': $crash'}';
    _deathReason = reason;
    _closed = true;
    // Before anything in flight fails: the owning model turns itself closed
    // first, so a caller that retries from its error handler gets a fresh
    // model instead of this one.
    if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(reason);
    _failAllPending(StateError(reason));
    _fromWorker?.close();
    final closeError = _closeErrorBeforeDeath;
    final model = !_closedBeforeDeath
        ? 'its native model may still be resident'
        : closeError == null
        ? 'its native model was freed before the worker ended'
        : 'freeing its native model failed too, so it may still be resident: '
              '$closeError';
    _warn('$reason (model $_modelDir); $model');
    if (!_gone.isCompleted) _gone.complete();
    _completeAllResetAcks();
  }

  /// Handles what a worker whose load failed sends after the error: the
  /// outcome of freeing what the load allocated, then its exit.
  static void _afterFailedLoad(
    dynamic msg,
    String modelDir,
    StreamSubscription<dynamic> sub,
    ReceivePort fromWorker,
  ) {
    if (msg is LoadCleanup) {
      final error = msg.error;
      if (error != null) {
        _warn(
          'the ONNX GenAI model $modelDir failed to close after its load '
          'failed; its native model may still be resident: $error',
        );
      }
    } else if (msg is List) {
      _warn(
        'the ONNX GenAI worker for $modelDir died while freeing what its '
        'failed load had allocated; its native model may still be resident: '
        '${_describeUncaught(msg)}',
      );
    } else if (msg == null) {
      unawaited(sub.cancel());
      fromWorker.close();
    }
  }

  /// "30 s", or "200 ms" for the short durations tests inject.
  static String _describeDuration(Duration d) => d.inMilliseconds % 1000 == 0
      ? '${d.inSeconds} s'
      : '${d.inMilliseconds} ms';

  /// An `onError` message — `[error, stack]`, both as strings — as one text.
  static String _describeUncaught(List<dynamic> message) {
    final error = message.isNotEmpty ? message[0] : null;
    final stack = message.length > 1 ? message[1] : null;
    return stack == null ? '$error' : '$error\n$stack';
  }

  /// Completes the oldest reset still waiting for its ack.
  void _completeResetAck() {
    while (_resetAcks.isNotEmpty) {
      final ack = _resetAcks.removeFirst();
      if (!ack.isCompleted) {
        ack.complete();
        return;
      }
    }
  }

  /// Completes every reset still waiting: the worker is gone, no ack follows.
  void _completeAllResetAcks() {
    while (_resetAcks.isNotEmpty) {
      final ack = _resetAcks.removeFirst();
      if (!ack.isCompleted) ack.complete();
    }
  }

  void _failAllPending(StateError error) {
    for (final end in _turnEnds.values) {
      end.complete(TurnEnd.closed);
    }
    _turnEnds.clear();
    for (final id in _activeStreams.keys.toList()) {
      final controller = _activeStreams.remove(id);
      controller?.addError(error);
      unawaited(controller?.close());
      _streamDone.remove(id)?.complete();
    }
    _streamSession.clear();
    for (final c in _countPending.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _countPending.clear();
  }

  /// The error a call gets once the client cannot serve it: [shutdown] ran,
  /// the worker died ([_deathReason]), or [load] never succeeded.
  StateError _unusable(String whenShutDown) {
    final death = _deathReason;
    return StateError(
      death == null ? whenShutDown : 'GenAiFfiClient is closed: $death',
    );
  }

  @override
  Stream<String> generate(GenAiTurn turn) => _startTurn(turn).text;

  /// [generate], guided by [guidance] (a JSON schema) when it is set, with
  /// how the turn ended. The end completes once the worker has answered —
  /// after a cancelled subscription too — and never with an error: a failed
  /// turn puts its error on the text — [ContextLimitException] with end
  /// [TurnEnd.contextLimit] when the prompt did not fit, a [StateError] with
  /// end [TurnEnd.closed] otherwise.
  ({Stream<String> text, Future<TurnEnd> end}) _startTurn(
    GenAiTurn turn, {
    String? guidance,
    List<Map<String, String>>? seedHistory,
  }) {
    final end = Completer<TurnEnd>();
    // If the consumer cancels its subscription (a plain `break` out of
    // `await for`, or a voice-loop barge-in) WITHOUT calling
    // [stopGeneration] itself, nothing would otherwise tell the worker to
    // stop decoding — it would keep generating to `max_length` while
    // `_runGenerateGuarded` sits on `done.future`, wedging `_mutex` for the
    // whole abandoned decode. Mirrors the litertlm engine's "StreamController
    // onCancel -> native cancel" fix (commit 93a5298). `stopGeneration` is
    // idempotent/cheap when the turn already finished normally.
    var cancelled = false;
    int? requestId;
    final controller = StreamController<String>(
      onCancel: () {
        // Also runs when the stream ends normally, so this only tells the
        // worker (which ignores a stop for a turn that is not live) and marks
        // this turn: another waiting turn of the session is not its business.
        // The stop names this turn's request, not its session: a consumer
        // that paused the stream and cancels it once the turn has ended —
        // and the session's next turn has started — must not stop that one.
        // A turn not sent yet sees `cancelled` and is never sent.
        cancelled = true;
        if (requestId case final id?) {
          _commandPort?.send(StopSignal.request(id));
        }
      },
    );
    unawaited(
      _runGenerateGuarded(
        controller,
        turn,
        () => cancelled,
        end,
        guidance: guidance,
        seedHistory: seedHistory,
        onSent: (id) => requestId = id,
      ),
    );
    return (text: controller.stream, end: end.future);
  }

  /// Sessions released by [resetSession]. Ids are never reused, so a turn of a
  /// released session that was still waiting on [_mutex] must not run: it
  /// would build a generator (a whole KV cache) nothing would ever free.
  final Set<int> _released = {};

  /// How many turns of each session are waiting on [_mutex], and the sessions
  /// that had a stop filed meanwhile. The worker only knows turns that were
  /// sent, so a stop for a waiting turn is kept here.
  final Map<int?, int> _waiting = {};
  final Set<int?> _stoppedWhileWaiting = {};

  Future<void> _runGenerateGuarded(
    StreamController<String> controller,
    GenAiTurn turn,
    bool Function() cancelled,
    Completer<TurnEnd> end, {
    String? guidance,
    List<Map<String, String>>? seedHistory,
    required void Function(int id) onSent,
  }) async {
    void endAs(TurnEnd how) {
      if (!end.isCompleted) end.complete(how);
    }

    if (_closed || !_loaded) {
      endAs(TurnEnd.closed);
      controller.addError(_unusable('GenAiFfiClient is not loaded'));
      await controller.close();
      return;
    }
    final session = turn.sessionId;
    _waiting[session] = (_waiting[session] ?? 0) + 1;
    await _mutex.acquire();
    final waiting = (_waiting[session] ?? 1) - 1;
    if (waiting == 0) {
      _waiting.remove(session);
    } else {
      _waiting[session] = waiting;
    }
    final stopped = _stoppedWhileWaiting.remove(session);
    if (cancelled()) {
      // The consumer is gone: nobody is left to tell.
      _mutex.release();
      endAs(TurnEnd.stopped);
      await controller.close();
      return;
    }
    // A client that shut down or died, and a released session, come before a
    // stop: closing a session files its stop first, and the caller waiting on
    // this turn must get the reason, not an empty reply that looks like
    // success.
    if (_closed) {
      _mutex.release();
      endAs(TurnEnd.closed);
      controller.addError(_unusable('GenAiFfiClient shut down'));
      await controller.close();
      return;
    }
    if (session != null && _released.contains(session)) {
      _mutex.release();
      endAs(TurnEnd.closed);
      controller.addError(StateError('ONNX session $session was closed'));
      await controller.close();
      return;
    }
    if (stopped) {
      // A stop was filed while this turn waited behind another session's.
      _mutex.release();
      endAs(TurnEnd.stopped);
      await controller.close();
      return;
    }
    // Recheck AFTER acquiring: a caller that passed the check above can park
    // on the mutex behind an in-flight generate() while shutdown() runs to
    // completion (the worker stops the holder, frees its handles and exits,
    // the ports close) — without this recheck, the send below would go into
    // a dead port and `done.future` would never complete, hanging this stream
    // forever AND wedging the mutex for every caller behind it (hardened plan
    // Task 2, the FLAG fix — see `gen_ai_client_lifecycle_test.dart`'s
    // shutdown-while-generating test).
    final commandPort = _commandPort;
    if (_closed || commandPort == null) {
      _mutex.release();
      endAs(TurnEnd.closed);
      controller.addError(_unusable('GenAiFfiClient shut down'));
      await controller.close();
      return;
    }
    final id = _nextId++;
    final done = _streamDone[id] = Completer<void>();
    _activeStreams[id] = controller;
    _streamSession[id] = turn.sessionId;
    _turnEnds[id] = end;
    try {
      commandPort.send(
        GenerateRequest(id, turn, guidance: guidance, seedHistory: seedHistory),
      );
      onSent(id);
      await done.future;
    } catch (e) {
      if (_activeStreams.containsKey(id)) {
        controller.addError(e);
        _activeStreams.remove(id);
        await controller.close();
      }
    } finally {
      _streamSession.remove(id);
      _streamDone.remove(id);
      _turnEnds.remove(id);
      endAs(TurnEnd.closed);
      _mutex.release();
    }
  }

  // `async` so a closed or unloaded client's error reaches the caller through
  // the returned Future, not as a synchronous throw. Nothing awaits before
  // `_mutex.protect`, so the mutex is still requested during the call, in
  // call order.
  @override
  Future<int> countTokens(String text) async {
    if (_closed || !_loaded) {
      throw _unusable('GenAiFfiClient is not loaded');
    }
    return _mutex.protect(() {
      // Same recheck as `_runGenerateGuarded` — see its comment. A caller
      // can pass the check above and then park on the mutex behind a
      // `shutdown()` that runs to completion before this callback gets the
      // mutex.
      final commandPort = _commandPort;
      if (_closed || commandPort == null) {
        throw _unusable('GenAiFfiClient shut down');
      }
      final id = _nextId++;
      final completer = Completer<int>();
      _countPending[id] = completer;
      commandPort.send(CountTokensRequest(id, text));
      return completer.future;
    });
  }

  @override
  Future<void> stopGeneration({int? sessionId}) async {
    if (_waiting.containsKey(sessionId)) _stoppedWhileWaiting.add(sessionId);
    _commandPort?.send(StopSignal(sessionId));
  }

  @override
  Future<void> resetSession({int? sessionId}) async {
    final commandPort = _commandPort;
    if (_closed || commandPort == null) return;
    if (sessionId != null) _released.add(sessionId);
    _stats.remove(sessionId);
    // A turn of this session still running must not write its stats back when
    // it ends: they would outlive the reset (and a new legacy session would
    // report them).
    _streamSession.removeWhere((_, session) => session == sessionId);
    final ack = Completer<void>();
    _resetAcks.add(ack);
    commandPort.send(ResetSessionRequest(sessionId));
    try {
      await ack.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // The worker is still busy with the call ahead of the reset — a long
      // prefill. Nothing more to do here: the reset stays queued in front of
      // any later request, so it still runs before the next turn.
    }
  }

  /// Stops the worker without abandoning its native model.
  ///
  /// Requests the worker has not started fail with a "shut down"
  /// [StateError]. A generation in flight stops at its next token and its
  /// stream ends normally; a token count in flight finishes. Then the worker
  /// frees the generator, tokenizer and model, acks and exits, and this
  /// returns.
  ///
  /// It waits for all of that however long the call in flight takes (a
  /// prefill is one synchronous native call), and never kills the isolate: a
  /// killed isolate runs no more Dart code, so its handles are never freed
  /// and the model stays resident for the life of the process. After
  /// [_slowCloseNotice] it says what it is waiting for, once.
  ///
  /// Idempotent; concurrent callers share one teardown.
  @override
  Future<void> shutdown() => _shutdownFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closed = true;
    final commandPort = _commandPort;
    if (commandPort == null) {
      // Never loaded (or load failed) — nothing native to tear down.
      return;
    }
    if (!_gone.isCompleted) {
      commandPort.send(const Close());
      final notice = Timer(
        _slowCloseNotice,
        () => _warn(
          'shutting down the ONNX GenAI model $_modelDir has taken '
          '${_describeDuration(_slowCloseNotice)}: the worker is still inside '
          'a native call — the call in flight, if any, or freeing the model. '
          'It keeps waiting rather than kill the worker, because a killed '
          'worker never frees its native model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    await _sub?.cancel();
    _fromWorker?.close();
    // The worker answers every request it received before it acks, and the
    // port delivers in order; if it died instead, `_died` has already failed
    // them. So nothing should be left — anything that is, is a bug here, and
    // its error says so rather than claim the request was never run.
    _failAllPending(
      StateError(
        'internal error: the ONNX GenAI worker for $_modelDir stopped without '
        'answering this request',
      ),
    );
  }

  /// `print`, not [edgeAiLog]: edgeAiLog is silent in release, and release is
  /// where a leaked native model or a hung shutdown gets debugged. Both are
  /// abnormal, so this costs nothing in the normal case.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai_onnx] WARNING: $message');
  }
}

/// Completes, with the reason, when [client]'s worker exits without being
/// asked to — an uncaught error, or an isolate killed from outside — and never
/// after a clean [GenAiClient.shutdown]. Null for a client that has no worker
/// of its own (any [GenAiClient] that is not a [GenAiFfiClient]).
///
/// `OnnxInferenceModel` listens to it to turn itself closed and fire its
/// close listeners, so nothing keeps handing out a model whose every call
/// fails. A top-level function rather than a member, and
/// not exported, so the public [GenAiClient] and [GenAiFfiClient] surface
/// stays as it is.
Future<String>? unexpectedExitOf(GenAiClient client) => switch (client) {
  GenAiFfiClient() => client._unexpectedExit.future,
  _ => null,
};

/// One turn on [client], guided by [guidance] (a JSON schema) when it is set,
/// with how it ended. A [GenAiFfiClient] reports the end; any other client
/// gives `end: null` and cannot take [guidance] ([StateError]): only the
/// worker of a [GenAiFfiClient] sets it on a generator. Not exported, like
/// [unexpectedExitOf].
///
/// [seedHistory] starts a first turn's new generator from a conversation
/// given as text — what a session rebuilt from its history holds; for tests
/// that compare against that.
({Stream<String> text, Future<TurnEnd>? end}) startGenAiTurn(
  GenAiClient client,
  GenAiTurn turn, {
  String? guidance,
  @visibleForTesting List<Map<String, String>>? seedHistory,
}) {
  if (client is GenAiFfiClient) {
    final started = client._startTurn(
      turn,
      guidance: guidance,
      seedHistory: seedHistory,
    );
    return (text: started.text, end: started.end);
  }
  if (guidance != null) {
    throw StateError(
      '${client.runtimeType} cannot take a response format: only '
      'GenAiFfiClient sets ORT-GenAI guidance.',
    );
  }
  return (text: client.generate(turn), end: null);
}

/// Whether a prompt of [promptTokens] fits a generator that holds [used] of
/// [contextWindow] tokens: it must leave room for one generated token, since
/// AppendTokenSequences takes a prompt that fills the window exactly and the
/// first GenerateNextToken then throws at max_length.
@visibleForTesting
bool promptFits(int used, int promptTokens, int contextWindow) =>
    used + promptTokens < contextWindow;

/// What a guided session sends ORT-GenAI for [format]: its schema, in the
/// caller's key order, plus llguidance's own `x-guidance` options, which
/// llguidance reads and removes before it compiles the schema.
///
/// llguidance's JSON grammar allows any run of whitespace between tokens by
/// default, and a model may never leave it: measured on Phi-3.5-mini int4,
/// every value of the reply was right and then newlines ran to
/// `maxOutputTokens` where the closing `}` belonged. With whitespace fixed,
/// the separators are the ones models write unguided (`", "`, `": "`), and
/// the only way on is the value's next token. Core validates the reply
/// against the caller's own schema; this changes nothing it checks.
String genAiGuidanceSchema(JsonSchemaResponseFormat format) => jsonEncode({
  ...format.schema,
  'x-guidance': const {
    'whitespace_flexible': false,
    'item_separator': ', ',
    'key_separator': ': ',
  },
});

/// Whether ORT-GenAI 0.19.0's archive for [abi], as `hook/build.dart` bundles
/// it, was built with guidance (llguidance). Read from the archives
/// themselves: Microsoft's macOS arm64, Linux x64, Windows x64 and Windows
/// ARM64 builds link llguidance in (its symbols and `GuidanceLogitsProcessor`
/// are there); Microsoft's iOS xcframework and this repository's Android build
/// (`build_genai_android.sh`) do not, and say "guidance is unavailable" when
/// asked for it. Keep in step with the hook's pins.
@visibleForTesting
bool genAiArchiveHasGuidance(ffi.Abi abi) => const {
  ffi.Abi.macosArm64,
  ffi.Abi.linuxX64,
  ffi.Abi.windowsX64,
  ffi.Abi.windowsArm64,
}.contains(abi);

/// The hosts whose response-format run has passed: real ORT-GenAI guidance
/// through this engine (`onnx_response_format_host_smoke_test.dart`). A host
/// whose archive has guidance stays refused, naming the missing run, until it
/// is here (design 2.6.0 §5.1: a backend is enabled after its run).
/// - macOS arm64: Mac mini, Phi-3.5-mini cpu-int4, 2026-11-04, 4/4.
/// Still to run: Linux x64 (CI or the T4 VM), Windows x64 (`intel-ptl`),
/// Windows ARM64 (the GitHub-hosted Windows 11 ARM64 runner).
const _verifiedGuidanceAbis = {ffi.Abi.macosArm64};

/// Replaces [_verifiedGuidanceAbis] in tests: the fake-worker tests drive the
/// guided path on any host, and the host smoke is the run that verifies one.
@visibleForTesting
Set<ffi.Abi>? debugVerifiedGuidanceAbis;

/// Why a model on [client] cannot take a response format, or null when it
/// can: the client must be a loaded [GenAiFfiClient], the host's archive must
/// have guidance ([genAiArchiveHasGuidance]) and its run must have passed
/// ([_verifiedGuidanceAbis]), and the model directory must
/// hold `tokenizer.json`, which ORT-GenAI's guidance reads (without it every
/// guided generator fails to create). Not exported.
String? guidanceRefusalOf(GenAiClient client, {ffi.Abi? abi}) {
  if (client is! GenAiFfiClient) {
    return 'This ONNX model runs on ${client.runtimeType}, which does not '
        'enforce a format: only GenAiFfiClient sets ORT-GenAI guidance.';
  }
  final host = abi ?? ffi.Abi.current();
  if (!genAiArchiveHasGuidance(host)) {
    return 'The ORT-GenAI runtime bundled for $host is built without '
        'guidance (llguidance), so a format cannot be enforced there. It is '
        'enforced on macOS arm64.';
  }
  if (!(debugVerifiedGuidanceAbis ?? _verifiedGuidanceAbis).contains(host)) {
    return 'ORT-GenAI guidance on $host has not been run through this engine '
        'yet: its archive includes guidance, and a format is enabled there '
        'after that run passes. It is enforced on macOS arm64.';
  }
  final modelDir = client._modelDir;
  if (modelDir == null) return 'The ONNX model is not loaded.';
  // Read each time a format is asked for, not once at load: the file is
  // what every guided generator opens when it is created.
  if (!FileSystemEntity.isFileSync('$modelDir/tokenizer.json')) {
    return 'The ONNX model directory $modelDir has no tokenizer.json, which '
        'ORT-GenAI reads to enforce a format.';
  }
  return null;
}

// ---------------------------------------------------------------------------
// Worker isolate: library loading and the dart:ffi engine.
// ---------------------------------------------------------------------------

/// Candidate paths/names to try opening [libraryName] (bare, no `lib`
/// prefix/extension) with, in priority order, for the current platform.
///
/// On macOS the FIRST candidate is the CodeAsset's framework leaf name
/// (`hook/build.dart` registers each dylib under a bare asset name; Flutter's
/// macOS build wraps every CodeAsset in its own `<name>.framework`, renaming
/// the binary inside to `<name>.framework/<name>`) — Task 4's framework-wrap
/// risk: GenAI dlopens `libonnxruntime.dylib` by BARE LEAF NAME at runtime,
/// which does not automatically resolve to an already-loaded framework-wrapped
/// image unless something opens it by its real (framework) path FIRST, putting
/// it in dyld's loaded-image set before GenAI's own lookup runs. The bare
/// `lib<name>.dylib` names are a fallback for host runs that bypass the
/// CodeAsset bundle (`flutter test`, the macOS host smoke test's `libsDir`
/// override takes priority over all of this — see [_openGenAiLibraries]).
///
/// iOS gets its OWN branch, deliberately NOT grouped with macOS: iOS dyld 4
/// cannot resolve a bare `<name>.framework/<name>` leaf name the way macOS's
/// dyld does — it needs an explicit anchor, exactly the
/// `@executable_path/Frameworks/<name>.framework/<name>` shape
/// `flutter_edge_ai_litertlm/lib/src/ffi/litert_lm_client.dart` already uses
/// (and documents, with the same "dyld 4 cannot resolve from .framework
/// names alone" reasoning) for `LiteRtLm.framework`/`StreamProxy.framework`.
/// A bare leaf name here would dlopen-fail on every real iPhone (and the
/// simulator — verified: unanchored fails there too). This list is only ever
/// consulted for `'onnxruntime-genai'` on iOS — the platform ships one image
/// serving both APIs (see [_openGenAiLibraries]'s iOS branch), so
/// `'onnxruntime'` is never opened there.
List<String> _candidateNames(String libraryName) {
  if (Platform.isIOS) {
    return [
      '@executable_path/Frameworks/$libraryName.framework/$libraryName',
      'lib$libraryName.dylib',
    ];
  }
  if (Platform.isMacOS) {
    return ['$libraryName.framework/$libraryName', 'lib$libraryName.dylib'];
  }
  if (Platform.isLinux || Platform.isAndroid) return ['lib$libraryName.so'];
  if (Platform.isWindows) return ['$libraryName.dll'];
  throw UnsupportedError(
    'ONNX GenAI is not available on ${Platform.operatingSystem}',
  );
}

ffi.DynamicLibrary _openFirst(List<String> candidates) {
  Object? lastError;
  for (final path in candidates) {
    try {
      return ffi.DynamicLibrary.open(path);
    } catch (e) {
      lastError = e;
    }
  }
  throw StateError('Could not open any of $candidates. Last error: $lastError');
}

/// POSIX `Dl_info` — only `dli_fname` (the absolute on-disk path of the image
/// a symbol lives in) is used here.
final class _DlInfo extends ffi.Struct {
  external ffi.Pointer<pkg_ffi.Utf8> dli_fname;
  external ffi.Pointer<ffi.Void> dli_fbase;
  external ffi.Pointer<pkg_ffi.Utf8> dli_sname;
  external ffi.Pointer<ffi.Void> dli_saddr;
}

typedef _DladdrNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>);
typedef _DladdrDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_DlInfo>);
typedef _SetenvNative =
    ffi.Int32 Function(
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Pointer<pkg_ffi.Utf8>,
      ffi.Int32,
    );
typedef _SetenvDart =
    int Function(ffi.Pointer<pkg_ffi.Utf8>, ffi.Pointer<pkg_ffi.Utf8>, int);

/// Resolves the absolute on-disk path of the already-loaded [ortLib] via
/// `dladdr` on its `OrtGetApiBase` symbol, then exports it as `ORT_LIB_PATH`.
///
/// This is the fix for the framework-wrap co-location blocker: onnxruntime-genai
/// resolves onnxruntime at runtime by a bare `dlopen("libonnxruntime.dylib")`
/// (a string constant, not a Mach-O load command — nothing for install_name_tool
/// to patch) with a `dladdr`-based "next to my own binary" fallback. Under
/// Flutter's Native-Assets `.framework` wrapping the two libs land in SEPARATE
/// `.framework` bundles, so that fallback fails. But GenAI's `InitApi()` checks
/// the `ORT_LIB_PATH` env var FIRST and unconditionally `dlopen`s that absolute
/// path — Microsoft's own sanctioned override. We set it before GenAI's dylib
/// static initializer runs (i.e. before opening its library), pointing at ORT's
/// real path (whatever Flutter named the framework), so resolution succeeds with
/// zero packaging/Podfile/hook changes. No-op on platforms without
/// dladdr/setenv. iOS keeps the `Platform.isIOS` gate below (this function IS
/// harmless there — genai's iOS build is static, so `ORT_LIB_PATH` is simply
/// never consulted) but [_openGenAiLibraries]'s iOS branch never calls this
/// function at all — see its doc for why an explicit skip is cleaner than
/// relying on this being a no-op.
void _exportOrtLibPath(ffi.DynamicLibrary ortLib) {
  if (!(Platform.isMacOS || Platform.isIOS || Platform.isLinux)) return;
  final proc = ffi.DynamicLibrary.process();
  final dladdr = proc.lookupFunction<_DladdrNative, _DladdrDart>('dladdr');
  final setenv = proc.lookupFunction<_SetenvNative, _SetenvDart>('setenv');
  final info = pkg_ffi.calloc<_DlInfo>();
  final namePtr = 'ORT_LIB_PATH'.toNativeUtf8();
  ffi.Pointer<pkg_ffi.Utf8>? valuePtr;
  try {
    final sym = ortLib.lookup<ffi.Void>('OrtGetApiBase');
    if (dladdr(sym, info) == 0 || info.ref.dli_fname == ffi.nullptr) return;
    final ortPath = info.ref.dli_fname.toDartString();
    valuePtr = ortPath.toNativeUtf8();
    setenv(namePtr, valuePtr, 1); // overwrite
    edgeAiLog('[OnnxGenAi] ORT_LIB_PATH=$ortPath');
  } catch (_) {
    // Best-effort: if the env override can't be set, GenAI still tries its
    // bare-name + self-directory paths (works for the flat host-test layout).
  } finally {
    pkg_ffi.calloc.free(info);
    pkg_ffi.calloc.free(namePtr);
    if (valuePtr != null) pkg_ffi.calloc.free(valuePtr);
  }
}

typedef _GetenvNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef _GetenvDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef _WputenvSNative =
    ffi.Int32 Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>);
typedef _WputenvSDart =
    int Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>);
typedef _WgetenvNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf16>);
typedef _WgetenvDart =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf16>);

/// The variable ORT-GenAI (0.17.0 and later) reads to turn its Microsoft 1DS telemetry off.
const _telemetryVariable = 'ORT_DISABLE_TELEMETRY';

/// Turns ORT-GenAI's telemetry off before its library is opened, unless the
/// app already set [_telemetryVariable] to something (its value is kept).
///
/// Since 0.17.0 ORT-GenAI ships Microsoft's 1DS telemetry on every host, on by default and with
/// the OneCollector endpoint compiled in; 0.14.0 had none. For an on-device
/// package it is off here, and the variable has to be set in the process
/// environment the C runtime sees: `setenv` on POSIX and, on Windows,
/// `_wputenv_s` from the UCRT, since genai reads it through the CRT and Dart's
/// own environment view is not that copy. `OgaSetTelemetryEnabled(false)` alone
/// is not enough (see the header).
@visibleForTesting
void disableGenAiTelemetry() {
  try {
    if (Platform.isWindows) {
      final ucrt = ffi.DynamicLibrary.open('ucrtbase.dll');
      final wgetenv = ucrt.lookupFunction<_WgetenvNative, _WgetenvDart>(
        '_wgetenv',
      );
      final wputenvS = ucrt.lookupFunction<_WputenvSNative, _WputenvSDart>(
        '_wputenv_s',
      );
      final name = _telemetryVariable.toNativeUtf16();
      final value = '1'.toNativeUtf16();
      try {
        if (wgetenv(name) == ffi.nullptr) wputenvS(name, value);
      } finally {
        pkg_ffi.calloc.free(name);
        pkg_ffi.calloc.free(value);
      }
      return;
    }
    final proc = ffi.DynamicLibrary.process();
    final getenv = proc.lookupFunction<_GetenvNative, _GetenvDart>('getenv');
    final setenv = proc.lookupFunction<_SetenvNative, _SetenvDart>('setenv');
    final name = _telemetryVariable.toNativeUtf8();
    final value = '1'.toNativeUtf8();
    try {
      if (getenv(name) == ffi.nullptr) setenv(name, value, 0);
    } finally {
      pkg_ffi.calloc.free(name);
      pkg_ffi.calloc.free(value);
    }
  } catch (e) {
    // Printed, not logged: a release build is where a telemetry that stayed
    // on gets reported, and edgeAiLog is silent there.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_onnx] Could not set $_telemetryVariable ($e); '
      'ORT-GenAI telemetry may stay on. Set the variable yourself before '
      'the first model loads.',
    );
  }
}

(ffi.DynamicLibrary, ffi.DynamicLibrary) _openGenAiLibraries(String? libsDir) {
  disableGenAiTelemetry();
  if (Platform.isIOS && libsDir == null) {
    // iOS ships ONE self-contained framework: onnxruntime-genai statically
    // links ORT and exports both APIs (`Oga*` + `OrtGetApiBase`) from the
    // same binary — verified via `otool -L` (zero LC_LOAD_DYLIB on
    // onnxruntime) and `nm -gU` (both symbol sets present) on the extracted
    // xcframework slice. See `hook/build.dart`'s iOS branch (single
    // CodeAsset, `ort: null`) and this file's top doc. Skip the two-library
    // open/`ORT_LIB_PATH` dance entirely: there is no separate onnxruntime
    // dylib to co-locate with, and genai does no runtime dlopen of ORT on
    // iOS (a static build, unlike macOS's `MACOS_USE_DLOPEN` path) — calling
    // `_exportOrtLibPath` here would be a harmless no-op (its own
    // `Platform.isIOS` gate stays for that reason) but an explicit skip is
    // cleaner than relying on it.
    final genaiLib = _openFirst(_candidateNames('onnxruntime-genai'));
    return (genaiLib, genaiLib);
  }

  final ffi.DynamicLibrary ortLib;
  if (libsDir != null) {
    // Host-test override (FLUTTER_GEMMA_ORT_GENAI_LIBS / the macOS host
    // smoke test): exact spike layout, bare platform-default names in one
    // directory — bypasses the CodeAsset bundle entirely.
    final ortName = _candidateNames('onnxruntime').last;
    ortLib = ffi.DynamicLibrary.open('$libsDir/$ortName');
  } else {
    ortLib = _openFirst(_candidateNames('onnxruntime'));
  }
  ortLib.providesSymbol('OrtGetApiBase'); // keep ortLib reachable/loaded

  // Point GenAI's InitApi() at ORT's real absolute path BEFORE its dylib static
  // initializer (which resolves ORT) runs — i.e. before we open the GenAI lib.
  _exportOrtLibPath(ortLib);

  final genaiLib = libsDir != null
      ? ffi.DynamicLibrary.open(
          '$libsDir/${_candidateNames('onnxruntime-genai').last}',
        )
      : _openFirst(_candidateNames('onnxruntime-genai'));
  return (ortLib, genaiLib);
}

Future<void> _defaultWorkerEntry(WorkerInit init) =>
    serveGenAiWorker(init, _FfiGenAiEngine(init));

/// The production [GenAiWorkerEngine]: every native handle — model,
/// tokenizer, generator — is created, used and destroyed here, on the worker
/// isolate.
final class _FfiGenAiEngine implements GenAiWorkerEngine {
  _FfiGenAiEngine(this._init);

  final WorkerInit _init;

  /// Null until [load] opened the libraries. Every handle below is created
  /// through it, so a non-null handle implies non-null bindings.
  OrtGenAiBindings? _oga;
  ffi.Pointer<OgaModel>? _model;
  ffi.Pointer<OgaTokenizer>? _tokenizer;

  /// One generator — one KV cache, 0.75 MiB × `max_length` — per session
  /// that has had a turn and not been reset; null keys the legacy session.
  final Map<int?, ffi.Pointer<OgaGenerator>> _generators = {};

  /// What each session's generator holds, turn by turn; set up by [load].
  late final SessionTurns _turns;

  /// Whether a failed rewind has been reported; once per model.
  bool _rewindFailureReported = false;

  OrtGenAiBindings get _bindings =>
      _oga ?? (throw StateError('ORT-GenAI engine used before it was loaded'));

  ffi.Pointer<OgaModel> get _loadedModel =>
      _model ?? (throw StateError('ORT-GenAI model is not loaded'));

  ffi.Pointer<OgaTokenizer> get _loadedTokenizer =>
      _tokenizer ?? (throw StateError('ORT-GenAI tokenizer is not loaded'));

  void _check(ffi.Pointer<OgaResult> result, String step) {
    if (result == ffi.nullptr) return;
    final oga = _bindings;
    // Free the result in `finally` — mirrors `ort_ffi_client.dart`'s
    // `_check()` — so a non-UTF-8 error message (toDartString() throwing)
    // can't leak the native OgaResult handle.
    try {
      final errPtr = oga.OgaResultGetError(result);
      final message = errPtr == ffi.nullptr
          ? '<no message>'
          : errPtr.cast<pkg_ffi.Utf8>().toDartString();
      throw StateError('ORT-GenAI $step failed: $message');
    } finally {
      oga.OgaDestroyResult(result);
    }
  }

  @override
  Future<void> load() async {
    // Only GenAI's handle is used from here on. ORT stays loaded whether or
    // not anything holds its handle — Dart never unloads a DynamicLibrary —
    // and opening it first is what lets GenAI's own lookup find it (see
    // [_openGenAiLibraries]).
    final (_, genaiLib) = _openGenAiLibraries(_init.libsDir);
    final oga = _oga = OrtGenAiBindings(genaiLib);

    final configPathC = _init.modelDir.toNativeUtf8();
    final modelOut = pkg_ffi.calloc<ffi.Pointer<OgaModel>>();
    try {
      _check(
        oga.OgaCreateModel(configPathC.cast(), modelOut),
        'OgaCreateModel',
      );
      _model = modelOut.value;
    } finally {
      pkg_ffi.calloc.free(configPathC);
      pkg_ffi.calloc.free(modelOut);
    }

    _turns = SessionTurns(
      contextWindow: _init.contextWindow,
      endOfTurnToken: _configEosToken(_init.modelDir),
      onRewindFailure: _reportRewindFailure,
    );

    final tokenizerOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizer>>();
    try {
      _check(
        oga.OgaCreateTokenizer(_loadedModel, tokenizerOut),
        'OgaCreateTokenizer',
      );
      _tokenizer = tokenizerOut.value;
    } finally {
      pkg_ffi.calloc.free(tokenizerOut);
    }
  }

  /// Runs one turn: (re)creates the generator if needed, applies the chat
  /// template, prefills, then decodes token-by-token, passing pieces to
  /// [emit] as they arrive. The `await Future(() {})` yields are what let a
  /// queued `StopSignal`/`ResetSessionRequest`/`Close` flip [stopRequested].
  @override
  Future<GenAiTurnResult> generate(
    GenAiTurn turn, {
    String? guidance,
    List<Map<String, String>>? seedHistory,
    required void Function(String piece) emit,
    required bool Function() stopRequested,
  }) async {
    final oga = _bindings;
    final model = _loadedModel;
    final tokenizer = _loadedTokenizer;
    ffi.Pointer<OgaTokenizerStream>? tokenizerStream;
    final session = turn.sessionId;
    // A generator created for this turn joins the session only once its
    // prompt is in: until then a failure (a prompt that does not fit, a
    // failed prefill) destroys it, and the history stays to be replayed.
    ffi.Pointer<OgaGenerator>? created;
    try {
      if (turn.isFirstTurn) {
        _dropGenerator(session);
        _turns.begin(
          session,
          system: turn.systemInstruction,
          seed: seedHistory,
        );
      }
      final existing = _generators[session];
      final generator =
          existing ??
          (created = _createGenerator(
            oga,
            model,
            turn.searchOptions,
            guidance,
          ));
      _turns.started(session, oga.OgaGenerator_GetSequenceCount(generator, 0));

      // --- Chat template (SDK-owns-templates, Task 3) ----------------------
      // A generator created now for a session with history — dropped by a
      // failed rewind — gets that history first, as text.
      final messages = <Map<String, String>>[
        if (created != null) ..._turns.history(session),
        {'role': 'user', 'content': turn.userContent},
      ];
      final messagesJsonC = jsonEncode(messages).toNativeUtf8();
      final templatedOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
      final String templated;
      try {
        _check(
          oga.OgaTokenizerApplyChatTemplate(
            tokenizer,
            ffi.nullptr, // template_str: use the tokenizer's own built-in
            messagesJsonC.cast(),
            ffi.nullptr, // tools
            true, // add_generation_prompt
            templatedOut,
          ),
          'OgaTokenizerApplyChatTemplate',
        );
        templated = templatedOut.value.cast<pkg_ffi.Utf8>().toDartString();
      } finally {
        pkg_ffi.calloc.free(messagesJsonC);
        if (templatedOut.value != ffi.nullptr) {
          oga.OgaDestroyString(templatedOut.value);
        }
        pkg_ffi.calloc.free(templatedOut);
      }

      // --- Encode + prefill (AppendTokenSequences) -------------------------
      // Prefill runs INSIDE AppendTokenSequences on this GenAI version, not
      // the first GenerateNextToken (verified spike gotcha).
      final sequencesOut = pkg_ffi.calloc<ffi.Pointer<OgaSequences>>();
      final ffi.Pointer<OgaSequences> sequences;
      try {
        _check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
        sequences = sequencesOut.value;
      } finally {
        pkg_ffi.calloc.free(sequencesOut);
      }
      final promptC = templated.toNativeUtf8();
      final int promptTokens;
      try {
        _check(
          oga.OgaTokenizerEncode(tokenizer, promptC.cast(), sequences),
          'OgaTokenizerEncode',
        );
        promptTokens = oga.OgaSequencesGetSequenceCount(sequences, 0);
        // Checked here, not left to ORT-GenAI's own throws, so the turn can
        // say it ended on the context window, and the conversation is left
        // as it was.
        final used = oga.OgaGenerator_GetSequenceCount(generator, 0);
        if (!promptFits(used, promptTokens, _init.contextWindow)) {
          throw GenAiContextFullException(
            'ORT-GenAI prompt of $promptTokens tokens does not fit the '
            'context window: $used of ${_init.contextWindow} tokens '
            '(maxTokens) are already used.',
          );
        }
        _check(
          oga.OgaGenerator_AppendTokenSequences(generator, sequences),
          'OgaGenerator_AppendTokenSequences (prefill)',
        );
        if (created != null) {
          _generators[session] = created;
          created = null;
        }
        _turns.prefilled(session, turn.userContent);
      } finally {
        pkg_ffi.calloc.free(promptC);
        oga.OgaDestroySequences(sequences);
      }

      final streamOut = pkg_ffi.calloc<ffi.Pointer<OgaTokenizerStream>>();
      try {
        _check(
          oga.OgaCreateTokenizerStream(tokenizer, streamOut),
          'OgaCreateTokenizerStream',
        );
        tokenizerStream = streamOut.value;
      } finally {
        pkg_ffi.calloc.free(streamOut);
      }
      final stream = tokenizerStream;

      var generatedCount = 0;
      int? lastToken;
      final cap = turn.maxOutputTokens;

      void decodeAndEmit() {
        final outPtr = pkg_ffi.calloc<ffi.Pointer<ffi.Int32>>();
        final outCount = pkg_ffi.calloc<ffi.Size>();
        final int token;
        try {
          _check(
            oga.OgaGenerator_GetNextTokens(generator, outPtr, outCount),
            'OgaGenerator_GetNextTokens',
          );
          token = outPtr.value[outCount.value - 1];
          lastToken = token;
        } finally {
          pkg_ffi.calloc.free(outPtr);
          pkg_ffi.calloc.free(outCount);
        }
        final decodedOut = pkg_ffi.calloc<ffi.Pointer<ffi.Char>>();
        try {
          _check(
            oga.OgaTokenizerStreamDecode(stream, token, decodedOut),
            'OgaTokenizerStreamDecode',
          );
          // `out` from OgaTokenizerStreamDecode is owned by the stream — do
          // NOT OgaDestroyString it (unlike OgaTokenizerDecode's out_string).
          final piece = decodedOut.value == ffi.nullptr
              ? ''
              : decodedOut.value.cast<pkg_ffi.Utf8>().toDartString();
          if (piece.isNotEmpty) {
            _turns.emitted(session, piece);
            emit(piece);
          }
        } finally {
          pkg_ffi.calloc.free(decodedOut);
        }
        generatedCount++;
      }

      // Prefill above is one long synchronous FFI call with no `await` in
      // it — a `StopSignal` sent while it was running sits unprocessed in
      // the isolate's mailbox the whole time (the worker's port listener
      // can't file it until this function yields), so it would otherwise
      // ALWAYS survive to force one unconditional token out of the
      // just-primed generator. Yield once here, mirroring the decode loop's
      // own per-token yield below, so that already-queued stop lands before
      // (not after) the first token is spent.
      await Future<void>(() {});
      var stopped = stopRequested();
      if (!stopped) {
        _check(
          oga.OgaGenerator_GenerateNextToken(generator),
          'OgaGenerator_GenerateNextToken (first token)',
        );
        decodeAndEmit();
      }

      // Timed separately from prefill+first-token, matching the spike: the
      // first token's forward pass rides along with AppendTokenSequences.
      final swDecode = Stopwatch()..start();
      while (!stopped &&
          !oga.OgaGenerator_IsDone(generator) &&
          (cap == null || generatedCount < cap)) {
        // Yield one event-loop turn per token so a queued StopSignal can
        // flip `stopRequested` before the next token is generated.
        await Future<void>(() {});
        if (stopRequested()) {
          stopped = true;
          break;
        }
        _check(
          oga.OgaGenerator_GenerateNextToken(generator),
          'OgaGenerator_GenerateNextToken (decode)',
        );
        decodeAndEmit();
      }
      swDecode.stop();

      // IsDone is true at an end-of-sequence token and at max_length (the
      // context window); the length tells them apart. A cap reached first
      // leaves it false. (With guidance, IsDone also resets the grammar for
      // the generator's next turn; any other end leaves it mid-value, and
      // the session starts a fresh generator.)
      final end = classifyTurnEnd(
        stopped: stopped,
        done: !stopped && oga.OgaGenerator_IsDone(generator),
        length: oga.OgaGenerator_GetSequenceCount(generator, 0),
        contextWindow: _init.contextWindow,
      );
      final endToken = lastToken;
      if (end == TurnEnd.endOfSequence && endToken != null) {
        _turns.finished(endToken);
      }
      return GenAiTurnResult(
        GenAiGenerationStats(
          promptTokens: promptTokens,
          generatedTokens: generatedCount,
          decodeMs: swDecode.elapsedMilliseconds,
        ),
        end,
      );
    } finally {
      if (tokenizerStream != null) {
        oga.OgaDestroyTokenizerStream(tokenizerStream);
      }
      final unused = created;
      if (unused != null) oga.OgaDestroyGenerator(unused);
    }
  }

  ffi.Pointer<OgaGenerator> _createGenerator(
    OrtGenAiBindings oga,
    ffi.Pointer<OgaModel> model,
    Map<String, Object> searchOptions,
    String? guidance,
  ) {
    final paramsOut = pkg_ffi.calloc<ffi.Pointer<OgaGeneratorParams>>();
    final ffi.Pointer<OgaGeneratorParams> params;
    try {
      _check(
        oga.OgaCreateGeneratorParams(model, paramsOut),
        'OgaCreateGeneratorParams',
      );
      params = paramsOut.value;
    } finally {
      pkg_ffi.calloc.free(paramsOut);
    }
    final maxLengthNameC = 'max_length'.toNativeUtf8();
    try {
      _check(
        oga.OgaGeneratorParamsSetSearchNumber(
          params,
          maxLengthNameC.cast(),
          _init.contextWindow.toDouble(),
        ),
        'OgaGeneratorParamsSetSearchNumber(max_length)',
      );
      void set(
        String name,
        ffi.Pointer<OgaResult> Function(ffi.Pointer<ffi.Char> name) call,
      ) {
        final nameC = name.toNativeUtf8();
        try {
          _check(call(nameC.cast()), 'OgaGeneratorParamsSetSearch($name)');
        } finally {
          pkg_ffi.calloc.free(nameC);
        }
      }

      applySearchOptions(
        searchOptions,
        setBool: (name, value) => set(
          name,
          (nameC) => oga.OgaGeneratorParamsSetSearchBool(params, nameC, value),
        ),
        setNumber: (name, value) => set(
          name,
          (nameC) =>
              oga.OgaGeneratorParamsSetSearchNumber(params, nameC, value),
        ),
      );
      if (guidance != null) {
        // The grammar is compiled in OgaCreateGenerator below. Fast-forward
        // tokens stay off: they append tokens the model never scored, which
        // the per-token decode and its counts here do not expect.
        final typeC = 'json_schema'.toNativeUtf8();
        final dataC = guidance.toNativeUtf8();
        try {
          _check(
            oga.OgaGeneratorParamsSetGuidance(
              params,
              typeC.cast(),
              dataC.cast(),
              false,
            ),
            'OgaGeneratorParamsSetGuidance(json_schema)',
          );
        } finally {
          pkg_ffi.calloc.free(typeC);
          pkg_ffi.calloc.free(dataC);
        }
      }
      final genOut = pkg_ffi.calloc<ffi.Pointer<OgaGenerator>>();
      try {
        _check(
          oga.OgaCreateGenerator(model, params, genOut),
          'OgaCreateGenerator',
        );
        return genOut.value;
      } finally {
        pkg_ffi.calloc.free(genOut);
      }
    } finally {
      pkg_ffi.calloc.free(maxLengthNameC);
      oga.OgaDestroyGeneratorParams(params);
    }
  }

  @override
  int countTokens(String text) {
    final oga = _bindings;
    final sequencesOut = pkg_ffi.calloc<ffi.Pointer<OgaSequences>>();
    final ffi.Pointer<OgaSequences> sequences;
    try {
      _check(oga.OgaCreateSequences(sequencesOut), 'OgaCreateSequences');
      sequences = sequencesOut.value;
    } finally {
      pkg_ffi.calloc.free(sequencesOut);
    }
    final textC = text.toNativeUtf8();
    try {
      _check(
        oga.OgaTokenizerEncode(_loadedTokenizer, textC.cast(), sequences),
        'OgaTokenizerEncode',
      );
      return oga.OgaSequencesGetSequenceCount(sequences, 0);
    } finally {
      pkg_ffi.calloc.free(textC);
      oga.OgaDestroySequences(sequences);
    }
  }

  @override
  void resetGenerator({int? sessionId}) {
    _turns.forget(sessionId);
    _dropGenerator(sessionId);
  }

  void _reportRewindFailure(Object error) {
    if (_rewindFailureReported) return;
    _rewindFailureReported = true;
    // `print`: edgeAiLog is silent in release.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_onnx] WARNING: ORT-GenAI could not rewind this model '
      '($error). After a turn that does not end on its own, a session\'s '
      "next turn rebuilds its context from the conversation's text instead, "
      'which costs a full prefill. Said once per model.',
    );
  }

  /// The first `model.eos_token_id` in [modelDir]'s genai_config.json, or
  /// null when it has none or does not parse.
  static int? _configEosToken(String modelDir) {
    try {
      final config = jsonDecode(
        File('$modelDir/genai_config.json').readAsStringSync(),
      );
      final eos = config is Map && config['model'] is Map
          ? (config['model'] as Map)['eos_token_id']
          : null;
      return switch (eos) {
        final int id => id,
        [final int id, ...] => id,
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  void _dropGenerator(int? sessionId) {
    // Forgotten first, so a throw below cannot hand the next turn a
    // generator that is half destroyed.
    final generator = _generators.remove(sessionId);
    if (generator == null) return;
    _bindings.OgaDestroyGenerator(generator);
  }

  @override
  bool endTurn({int? sessionId, required AfterTurn how}) {
    final generator = _generators[sessionId];
    return _turns.settle(
      sessionId,
      how,
      generator: generator == null
          ? null
          : _FfiGeneratorOps(_bindings, generator),
      drop: () => _dropGenerator(sessionId),
    );
  }

  /// Destroys generator, tokenizer and model — whichever exist, so a load
  /// that failed halfway is cleaned up too.
  @override
  void close() {
    final oga = _oga;
    if (oga == null) return; // the libraries never opened: nothing to free.
    final generators = _generators.values.toList();
    final tokenizer = _tokenizer;
    final model = _model;
    _generators.clear();
    _tokenizer = null;
    _model = null;
    for (final generator in generators) {
      oga.OgaDestroyGenerator(generator);
    }
    if (tokenizer != null) oga.OgaDestroyTokenizer(tokenizer);
    if (model != null) oga.OgaDestroyModel(model);
  }
}

/// [GeneratorOps] over one ORT-GenAI generator.
final class _FfiGeneratorOps implements GeneratorOps {
  _FfiGeneratorOps(this._oga, this._generator);

  final OrtGenAiBindings _oga;
  final ffi.Pointer<OgaGenerator> _generator;

  void _check(ffi.Pointer<OgaResult> result, String step) {
    if (result == ffi.nullptr) return;
    try {
      final errPtr = _oga.OgaResultGetError(result);
      final message = errPtr == ffi.nullptr
          ? '<no message>'
          : errPtr.cast<pkg_ffi.Utf8>().toDartString();
      throw StateError('ORT-GenAI $step failed: $message');
    } finally {
      _oga.OgaDestroyResult(result);
    }
  }

  @override
  int get length => _oga.OgaGenerator_GetSequenceCount(_generator, 0);

  @override
  int tokenAt(int index) =>
      _oga.OgaGenerator_GetSequenceData(_generator, 0)[index];

  @override
  void rewindTo(int length) => _check(
    _oga.OgaGenerator_RewindTo(_generator, length),
    'OgaGenerator_RewindTo',
  );

  @override
  void append(List<int> tokens) {
    final buffer = pkg_ffi.calloc<ffi.Int32>(tokens.length);
    try {
      for (var k = 0; k < tokens.length; k++) {
        buffer[k] = tokens[k];
      }
      _check(
        _oga.OgaGenerator_AppendTokens(_generator, buffer, tokens.length),
        'OgaGenerator_AppendTokens',
      );
    } finally {
      pkg_ffi.calloc.free(buffer);
    }
  }
}

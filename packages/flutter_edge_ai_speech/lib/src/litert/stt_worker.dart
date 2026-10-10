// Long-lived background isolate that owns the entire LiteRT STT native
// lifecycle (lib open, model compile, encode+decode forward passes,
// teardown) and the HF tokenizer. The forward passes (`LiteRtRunCompiledModel`,
// called once for encode and once per decode step) are blocking synchronous
// FFI calls; running them here keeps the UI isolate's event loop free,
// mirroring `litert_embedding_worker.dart` (#299).
//
// Why a long-lived worker and not `Isolate.run` per call:
//   - The compiled model is expensive to build but cheap to run, so it MUST
//     be compiled once and reused — `Isolate.run` would recompile every
//     call.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries
//     (flutter/flutter#169431). Keeping all handles inside the one worker
//     means nothing crosses the boundary.
//
// Close never kills the isolate. It used to wait five seconds for an ack and
// then `Isolate.kill` — but the worker served its port one `await for` turn at
// a time, so a close sent behind a queue of transcriptions waited for the
// whole queue, the five seconds ran out, and the kill landed before the
// worker's `finally` could call `SttCore.dispose()`. A killed isolate runs no
// more Dart code, so the compiled model stayed resident for the life of the
// process. Now the worker queues requests itself and serves one at a time, so
// a close fails everything that has not started, lets the one call in flight
// finish, disposes the model and exits on its own — the same rules as the
// core embedding worker.
//
// Only sendable values cross the port: file paths + profile + backend
// (setup), a `Float32List` of samples (request), and a transcript `String`
// (reply).

import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import '../model/stt_model_profile.dart';
import 'stt_core.dart';

/// What [SttWorker] drives inside its isolate. Production is [SttCore], loaded
/// through `_SttCoreEngine`; tests inject a fake through
/// [SttWorker.spawn]'s `engineFactory`.
abstract interface class SttWorkerEngine {
  /// Loads the model. When it throws, the worker calls [dispose] before it
  /// reports the error, so an engine that allocated anything frees it.
  Future<void> load();

  /// Transcribes one window. May block the isolate in synchronous FFI.
  String transcribe(Float32List samples, {String? language});

  /// Frees every native handle. Called exactly once, also after a failed
  /// [load], so it must cope with a partial one.
  void dispose();
}

/// Builds the engine inside the worker isolate. Must be a top-level function
/// or a static method: it crosses the isolate boundary inside the spawn
/// message. Construction must not allocate anything native — that is
/// [SttWorkerEngine.load]'s job, so a failure there can be cleaned up.
typedef SttWorkerEngineFactory =
    SttWorkerEngine Function({
      required String modelPath,
      required String tokenizerPath,
      required SttModelProfile profile,
      PreferredBackend? backend,
    });

/// Handshake payload the worker sends back once the native model is loaded.
class _Ready {
  _Ready(this.commandPort);
  final SendPort commandPort;
}

/// Request: transcribe [samples] (already `[-1,1]`-normalized float32,
/// window-sized by the caller or by `SttCore.transcribe`'s pad/trim). [id]
/// correlates the reply. [language] overrides the loaded profile's default
/// decoder-prompt language for this one request (`null` = use the default);
/// a plain `String?` is sendable, so it crosses the port like [id] does.
class _TranscribeRequest {
  _TranscribeRequest(this.id, this.samples, this.language);
  final int id;
  final Float32List samples;
  final String? language;
}

/// Reply carrying the transcript (or an error message).
class _TranscribeReply {
  _TranscribeReply(
    this.id,
    this.text,
    this.error, {
    this.badArgument = false,
    this.argName,
    this.argValue,
  });
  final int id;
  final String? text;
  final String? error;

  /// [ArgumentError.name] and [ArgumentError.invalidValue], carried separately
  /// so the rebuilt error keeps them. Rebuilding from `toString()` alone gives
  /// `name == null`, `invalidValue == null` and a doubled `Invalid argument(s):`
  /// prefix, so no caller downstream of the port could assert on the field that
  /// says WHICH argument was wrong.
  final String? argName;
  final String? argValue;

  /// The worker rejected the CALLER's input (an [ArgumentError]) rather than
  /// failing at runtime. Carried as a flag because an exception object is not
  /// sendable across a port — without it every error arrives as a `StateError`,
  /// so `transcribe(language: 'zz')` could not be caught as the argument error
  /// it is. Only the type is reconstructed; the worker-side stack is already
  /// lost here (pre-existing).
  /// Deliberately NOT set for a [RangeError]: `RangeError` and `IndexError`
  /// both EXTEND `ArgumentError` in dart:core, so a plain `e is ArgumentError`
  /// reports every out-of-range index in the decode path — a mismatched mel
  /// filterbank, a short logits row — to the app as a bad `language` argument.
  final bool badArgument;
}

/// Sentinel asking the worker to stop: fail every request that has not
/// started, let the one in flight finish, dispose the model, ack, exit.
class _Close {
  const _Close();
}

/// The worker's last message, sent through `Isolate.exit` once
/// [SttWorkerEngine.dispose] has returned — so nothing of the worker runs
/// after it. [error] is set when that dispose threw: the native model may then
/// still be resident, and the main isolate says so.
class _CloseAck {
  const _CloseAck(this.error);
  final String? error;
}

/// The error a request gets when the worker closed before it started.
const _closedBeforeRunMessage = 'SttWorker closed before this request ran';

/// Parameters needed to boot the worker isolate. Must be fully sendable.
class _WorkerInit {
  _WorkerInit({
    required this.replyTo,
    required this.modelPath,
    required this.tokenizerPath,
    required this.profile,
    required this.backend,
    required this.logLevel,
    required this.engineFactory,
  });
  final SendPort replyTo;
  final String modelPath;
  final String tokenizerPath;
  final SttModelProfile profile;
  final PreferredBackend? backend;

  /// Snapshot of the main-isolate [edgeAiLogLevel] at spawn — the worker
  /// isolate gets its own copy of the per-isolate top-level (default info),
  /// so it must be seeded explicitly.
  final EdgeAiLogLevel logLevel;

  final SttWorkerEngineFactory engineFactory;
}

/// Main-isolate handle to the STT worker. Spawns the isolate, performs the
/// load handshake, and multiplexes concurrent requests by id.
class SttWorker {
  SttWorker._(this._commandPort, this._fromWorker, this._modelPath);

  /// How long [close] waits before saying it is still waiting. It keeps
  /// waiting afterwards: the only way to stop sooner is to kill the isolate,
  /// and a killed isolate never frees its native model.
  static const _slowCloseNotice = Duration(seconds: 30);

  final SendPort _commandPort;
  final ReceivePort _fromWorker;

  /// Names the model in the warnings this class prints.
  final String _modelPath;

  final _pending = <int, Completer<String>>{};
  int _nextId = 0;

  /// True from the moment [close] is called, or the worker dies; [transcribe]
  /// refuses from then on.
  bool _closing = false;

  /// Why the worker is gone when it went without being asked to — the text
  /// every later [transcribe] fails with. Null otherwise.
  String? _deathReason;

  /// The error an uncaught exception in the worker reported through the
  /// spawn's `onError` port, kept until the `onExit` that follows it.
  String? _crashError;

  /// True once the worker's [_CloseAck] arrived; the `onExit` after it is the
  /// normal end, not a death.
  bool _acked = false;

  /// Completes when the worker is gone: its [_CloseAck], or its onExit.
  final _gone = Completer<void>();

  /// The one teardown every [close] call shares.
  Future<void>? _closeFuture;

  /// Spawn the worker and wait until the native model is loaded.
  ///
  /// [engineFactory] is the test seam; production leaves it null and gets
  /// [SttCore].
  static Future<SttWorker> spawn({
    required String modelPath,
    required String tokenizerPath,
    required SttModelProfile profile,
    PreferredBackend? backend,
    @visibleForTesting SttWorkerEngineFactory? engineFactory,
  }) async {
    final fromWorker = ReceivePort();
    final readyCompleter = Completer<_Ready>();

    // First message from the worker is either _Ready or a String error. A
    // two-element List is an uncaught error (the onError port), and a `null`
    // is the isolate's onExit signal — if either arrives before _Ready, the
    // worker died during load (e.g. a native crash compiling a corrupt
    // model), so fail the completer instead of hanging forever.
    late final StreamSubscription<dynamic> sub;
    sub = fromWorker.listen((msg) {
      if (readyCompleter.isCompleted) return;
      if (msg is _Ready) {
        readyCompleter.complete(msg);
      } else if (msg is String) {
        readyCompleter.completeError(StateError(msg));
      } else if (msg is List) {
        readyCompleter.completeError(
          StateError('STT worker isolate failed during load: ${msg.first}'),
        );
      } else if (msg == null) {
        readyCompleter.completeError(
          StateError('STT worker isolate exited during load'),
        );
      }
    });

    final _Ready ready;
    try {
      await Isolate.spawn(
        _workerEntry,
        _WorkerInit(
          replyTo: fromWorker.sendPort,
          modelPath: modelPath,
          tokenizerPath: tokenizerPath,
          profile: profile,
          backend: backend,
          logLevel: edgeAiLogLevel,
          engineFactory: engineFactory ?? _sttCoreEngine,
        ),
        // onError + onExit post to fromWorker so we never wait on a dead
        // isolate, and learn why it died when it says.
        onError: fromWorker.sendPort,
        onExit: fromWorker.sendPort,
        debugName: 'litert-stt-worker',
      );
      ready = await readyCompleter.future;
    } catch (_) {
      // Nothing to kill. A worker that fails to load disposes whatever it
      // built and leaves through `Isolate.exit` carrying the error, and the
      // onExit `null` means it is already gone. Killing it here instead could
      // land before that dispose — the leak [close] no longer has.
      await sub.cancel();
      fromWorker.close();
      rethrow;
    }

    final worker = SttWorker._(ready.commandPort, fromWorker, modelPath);
    // Re-point the subscription at the steady-state reply handler.
    sub.onData(worker._onReply);
    return worker;
  }

  void _onReply(dynamic msg) {
    if (msg is _TranscribeReply) {
      final completer = _pending.remove(msg.id);
      if (completer == null) return;
      if (msg.error != null) {
        completer.completeError(
          msg.badArgument
              ? ArgumentError.value(msg.argValue, msg.argName, msg.error)
              : StateError(msg.error!),
        );
      } else {
        completer.complete(msg.text!);
      }
    } else if (msg is _CloseAck) {
      _acked = true;
      final error = msg.error;
      if (error != null) {
        _warn(
          'the STT model $_modelPath failed to dispose; its native model may '
          'still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
    } else if (msg is List) {
      // onError: an uncaught error is about to take the worker down. The
      // onExit `null` that follows reports it.
      _crashError = '${msg.first}';
    } else if (msg == null) {
      if (_acked) return; // the normal exit after a _CloseAck.
      // The worker died without acking — an uncaught error, or an isolate
      // killed from outside. Its model may still be resident; fail every
      // pending request rather than leave callers hanging, and refuse new
      // ones with the reason.
      final crash = _crashError;
      final what = _closeFuture == null
          ? 'exited unexpectedly'
          : 'exited while closing';
      final reason =
          'the STT worker isolate $what${crash == null ? '' : ': $crash'}';
      _deathReason = reason;
      _closing = true;
      _failAllPending(reason);
      _fromWorker.close();
      _warn(
        '$reason (model $_modelPath); its native model may still be resident',
      );
      if (!_gone.isCompleted) _gone.complete();
    }
  }

  void _failAllPending(String reason) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError(reason));
    }
    _pending.clear();
  }

  /// Transcribe one window of already-normalized `[-1,1]` float32 [samples].
  /// The forward passes run in the worker; the UI isolate stays free.
  ///
  /// [language] retargets the decoder prompt for this request only. It does
  /// NOT reload anything — the worker keeps its language→id map from load, so
  /// consecutive requests may each use a different language.
  Future<String> transcribe(Float32List samples, {String? language}) {
    if (_closing) {
      final death = _deathReason;
      return Future.error(
        StateError(
          death == null ? 'SttWorker is closed' : 'SttWorker is closed: $death',
        ),
      );
    }
    final id = _nextId++;
    final completer = Completer<String>();
    _pending[id] = completer;
    _commandPort.send(_TranscribeRequest(id, samples, language));
    return completer.future;
  }

  /// Stops the worker without abandoning its native model.
  ///
  /// Requests that have not started fail with a "closed" [StateError]. The one
  /// in flight — the worker serves one at a time — finishes and gets its
  /// transcript. Then the worker disposes the model, acks and exits, and this
  /// returns.
  ///
  /// It waits for all of that however long the call in flight takes, and
  /// never kills the isolate: a killed isolate runs no more Dart code, so its
  /// model is never disposed and stays resident for the life of the process.
  /// After [_slowCloseNotice] it says what it is waiting for, once.
  ///
  /// Idempotent; concurrent callers share one teardown.
  Future<void> close() => _closeFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closing = true;
    if (!_gone.isCompleted) {
      _commandPort.send(const _Close());
      final notice = Timer(
        _slowCloseNotice,
        () => _warn(
          'SttWorker.close() has waited ${_slowCloseNotice.inSeconds} s for '
          'the STT worker of $_modelPath to finish the transcription it is '
          'running, if any, and dispose its native model. It keeps waiting '
          'rather than kill the worker, because a killed worker never frees '
          'its native model.',
        ),
      );
      try {
        await _gone.future;
      } finally {
        notice.cancel();
      }
    }
    _fromWorker.close();
    // The worker answers every request it received before it acks, and the
    // port delivers in order, so this is empty — unless the worker died, and
    // then onExit has already failed them. A net, not a path.
    _failAllPending(_closedBeforeRunMessage);
  }

  /// `print`, not [edgeAiLog]: edgeAiLog is silent in release, and release is
  /// where a leaked native model or a hung close gets debugged. Both are
  /// abnormal, so this costs nothing in the normal case.
  static void _warn(String message) {
    // ignore: avoid_print
    print('[flutter_edge_ai_speech] WARNING: $message');
  }
}

/// Production [SttWorkerEngine]: [SttCore], loaded on [load]. [SttCore.load]
/// frees whatever it allocated before it rethrows, so [dispose] after a failed
/// load has nothing to do.
final class _SttCoreEngine implements SttWorkerEngine {
  _SttCoreEngine({
    required this.modelPath,
    required this.tokenizerPath,
    required this.profile,
    required this.backend,
  });

  final String modelPath;
  final String tokenizerPath;
  final SttModelProfile profile;
  final PreferredBackend? backend;

  SttCore? _core;

  @override
  Future<void> load() async {
    _core = await SttCore.load(
      modelPath: modelPath,
      tokenizerPath: tokenizerPath,
      profile: profile,
      backend: backend,
    );
  }

  @override
  String transcribe(Float32List samples, {String? language}) {
    final core = _core;
    if (core == null) {
      throw StateError('SttCore used before it was loaded');
    }
    return core.transcribe(samples, language: language);
  }

  @override
  void dispose() => _core?.dispose();
}

SttWorkerEngine _sttCoreEngine({
  required String modelPath,
  required String tokenizerPath,
  required SttModelProfile profile,
  PreferredBackend? backend,
}) => _SttCoreEngine(
  modelPath: modelPath,
  tokenizerPath: tokenizerPath,
  profile: profile,
  backend: backend,
);

/// Disposes [engine], reporting a failure as text instead of throwing, so the
/// caller still sends its last message. Null means it disposed cleanly.
String? _disposeEngine(SttWorkerEngine engine) {
  try {
    engine.dispose();
    return null;
  } catch (e, st) {
    edgeAiLog('[SttWorker] dispose failed: $e\n$st');
    return '$e';
  }
}

/// Isolate entry point. Loads the model, then serves requests until _Close.
Future<void> _workerEntry(_WorkerInit init) async {
  // Seed this isolate's per-isolate log level from the main-isolate snapshot.
  edgeAiLogLevel = init.logLevel;

  final SttWorkerEngine engine;
  // Nullable twin of `engine`, so the failure path can tell "never built"
  // from "built, then failed" — and dispose the second.
  SttWorkerEngine? built;
  try {
    built = init.engineFactory(
      modelPath: init.modelPath,
      tokenizerPath: init.tokenizerPath,
      profile: init.profile,
      backend: init.backend,
    );
    await built.load();
    engine = built;
  } catch (e, st) {
    edgeAiLog('[SttWorker] load failed: $e\n$st');
    // Disposed BEFORE the error is sent — the main isolate gives up on this
    // worker the moment the error arrives.
    final disposeError = built == null ? null : _disposeEngine(built);
    Isolate.exit(
      init.replyTo,
      disposeError == null
          ? 'STT worker failed to load: $e'
          : 'STT worker failed to load: $e (disposing what it had loaded '
                'also failed, so native memory may still be held: '
                '$disposeError)',
    );
  }

  final commandPort = ReceivePort();
  final queued = Queue<_TranscribeRequest>();
  var closeRequested = false;
  Completer<void>? wake;

  // The listener only files messages; the loop below does the work. That
  // split is what lets a close overtake a queue: the listener sees _Close as
  // soon as the event loop is free, not after every request ahead of it ran.
  commandPort.listen((msg) {
    if (msg is _TranscribeRequest) {
      queued.add(msg);
    } else if (msg is _Close) {
      closeRequested = true;
      commandPort.close();
      // Only what has not started. The request in flight, if any, was taken
      // off the queue when it started, and it finishes on its own terms.
      while (queued.isNotEmpty) {
        final request = queued.removeFirst();
        init.replyTo.send(
          _TranscribeReply(request.id, null, _closedBeforeRunMessage),
        );
      }
    }
    final waiting = wake;
    wake = null;
    waiting?.complete();
  });

  init.replyTo.send(_Ready(commandPort.sendPort));

  final String? disposeError;
  try {
    // One request in flight at a time, in arrival order.
    while (!closeRequested) {
      if (queued.isEmpty) {
        final idle = wake = Completer<void>();
        await idle.future;
        continue;
      }
      // Yield to the event loop before every request. A transcription blocks
      // this isolate inside synchronous native calls, so a _Close sent
      // meanwhile is still in the message queue when it returns — and
      // awaiting a completed future only drains microtasks, never that queue.
      // A zero-duration timer is posted to the BACK of the same queue, so by
      // the time it fires the listener has filed the close and emptied
      // `queued`.
      await Future<void>.delayed(Duration.zero);
      if (closeRequested || queued.isEmpty) continue;
      _serve(queued.removeFirst(), engine, init.replyTo);
    }
  } finally {
    // Also on an unexpected throw out of the loop: the native model is freed
    // either way, and the throw then takes the isolate down, which the main
    // isolate's onError/onExit handling reports.
    disposeError = _disposeEngine(engine);
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the main isolate never has to kill it.
  Isolate.exit(init.replyTo, _CloseAck(disposeError));
}

/// Runs one request and replies — with the transcript, or with the error.
/// Never throws, so one bad input cannot stop the loop that serves the rest.
void _serve(_TranscribeRequest msg, SttWorkerEngine engine, SendPort replyTo) {
  try {
    final text = engine.transcribe(msg.samples, language: msg.language);
    replyTo.send(_TranscribeReply(msg.id, text, null));
  } catch (e) {
    // Bound once, as a typed local, rather than re-tested per field: a
    // `bool` flag leaves `e` an Object, so every read needs a cast — and
    // whether the analyzer calls that cast redundant differs by SDK.
    //
    // `e is! RangeError` is load-bearing — see _TranscribeReply.badArgument.
    final argError = e is ArgumentError && e is! RangeError ? e : null;
    replyTo.send(
      _TranscribeReply(
        msg.id,
        null,
        argError?.message?.toString() ?? '$e',
        badArgument: argError != null,
        argName: argError?.name,
        argValue: argError?.invalidValue?.toString(),
      ),
    );
  }
}

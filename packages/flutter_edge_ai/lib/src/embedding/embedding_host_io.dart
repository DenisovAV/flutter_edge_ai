// The isolate embedding host (R5 §4.4): a long-lived worker isolate that
// builds an engine's EmbeddingPass from its descriptor, loads it, and serves
// one request at a time until it is closed. Evolved from the #609 embedding
// worker, which it replaces: the same handshake, the same close that never
// kills the isolate, the same death reporting — now driving an EmbeddingPass
// through the shared RequestPump, with typed failures (wire.dart) instead of
// strings.
//
// Why a long-lived worker and not `Isolate.run` per call:
//   - A real pass costs hundreds of ms to load but far less to run per call,
//     so it MUST be loaded once and reused.
//   - FFI `Pointer`/`DynamicLibrary` cannot cross isolate boundaries, so every
//     native handle lives and dies inside this one worker; only the
//     descriptor (sendable config + a top-level factory), inputs and vectors
//     cross.
//
// Close never kills the isolate: the worker fails everything that has not
// started, lets the one call in flight finish, closes the pass and exits on
// its own through `Isolate.exit`. A killed isolate runs no more Dart code, so
// its pass would never be closed and the native model would stay resident for
// the life of the process.
//
// Only this file imports dart:isolate; web builds take embedding_host_web.dart.

import 'dart:async';
import 'dart:isolate';

import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:meta/meta.dart' show visibleForTesting;

import 'embedding_exceptions.dart';
import 'embedding_host.dart';
import 'embedding_input.dart';
import 'embedding_modality.dart';
import 'embedding_pass.dart';
import 'load_check.dart';
import 'request_lanes.dart';
import 'task_type.dart';
import 'wire.dart';

/// How long the load and the close wait before saying they are still waiting.
/// They keep waiting afterwards: the only way to stop sooner is to kill the
/// isolate, and a killed isolate never frees its native model.
const _slowLoadNotice = Duration(seconds: 30);
const _slowCloseNotice = Duration(seconds: 30);

/// Parameters needed to boot the worker. Fully sendable: the descriptor
/// carries sendable config and a top-level factory tear-off.
final class _Init {
  const _Init({
    required this.replyTo,
    required this.descriptor,
    required this.declaredMedia,
    required this.label,
    required this.logLevel,
  });

  final SendPort replyTo;
  final EmbeddingPassDescriptor<Object> descriptor;
  final Set<EmbeddingModality> declaredMedia;
  final String label;

  /// Snapshot of the main isolate's [edgeAiLogLevel]: a spawned isolate gets
  /// its own copy of the top-level, initialised to the default.
  final EdgeAiLogLevel logLevel;
}

/// The worker's first message once the pass is loaded and checked.
final class _Ready {
  const _Ready(this.commandPort, this.info, this.modalities);

  final SendPort commandPort;
  final EmbeddingPassInfo info;
  final Set<EmbeddingModality> modalities;
}

/// The load failed. Sent FIRST, so the caller is not held by a pass close
/// that may never return; [_LoadCleanup] follows once the worker has closed
/// the pass it built.
final class _LoadFailed {
  const _LoadFailed(this.failure);

  final EmbeddingFailure failure;
}

/// The last message of a worker whose load failed, sent through
/// `Isolate.exit`. [error] is set when closing the pass threw.
final class _LoadCleanup {
  const _LoadCleanup(this.error);

  final String? error;
}

/// One request; [id] correlates the reply.
final class _Embed {
  const _Embed(this.id, this.input, this.taskType);

  final int id;
  final EmbeddingInput input;
  final TaskType taskType;
}

final class _Reply {
  const _Reply(this.id, this.vector);

  final int id;
  final List<double> vector;
}

final class _Failure {
  const _Failure(this.id, this.failure);

  final int id;
  final EmbeddingFailure failure;
}

/// Asks the worker to stop: fail every request that has not started, let the
/// one in flight finish, close the pass, ack, exit.
final class _Close {
  const _Close();
}

/// The worker's last message, sent through `Isolate.exit` once the pass's
/// close returned — nothing of the worker runs after it. [error] is set when
/// that close threw: the native model may then still be resident.
final class _CloseAck {
  const _CloseAck(this.error);

  final String? error;
}

/// Spawns the worker, builds and loads [descriptor]'s pass in it, checks it
/// against [declaredMedia] and returns once it is ready. [label] names the
/// model file in every message.
///
/// Fails with `EmbeddingLoadException` — including when the worker dies
/// during the load. A load that fails fails this at once, even though the
/// worker still has to close the pass it built: a native close that never
/// returns must not hold the caller, which may be the embedder cache's lane —
/// and with it every embedder request in the app. The close then runs in the
/// worker on its own; [onFailedLoadCleanup] receives, before the error is
/// thrown, a future that ends when the worker has closed the pass and exited,
/// so the caller can hold the next build until then. A slow cleanup is
/// reported after [slowCloseNotice], a failed one when it fails.
Future<EmbeddingHost> startEmbeddingHost(
  EmbeddingPassDescriptor<Object> descriptor, {
  required Set<EmbeddingModality> declaredMedia,
  required String label,
  @visibleForTesting Duration slowLoadNotice = _slowLoadNotice,
  @visibleForTesting Duration slowCloseNotice = _slowCloseNotice,
  void Function(Future<void> cleanup)? onFailedLoadCleanup,
}) async {
  final engine = descriptor.engineTag;
  final fromWorker = ReceivePort();
  final ready = Completer<_Ready>();

  // The first message is _Ready or _LoadFailed. A `null` is the isolate's
  // onExit: before _Ready it means the worker died during load (a native
  // crash in a corrupt model), so fail instead of hanging forever. A `List`
  // is an uncaught error from onError, which arrives before that onExit.
  String? uncaughtDuringLoad;
  var loadFailureReported = false;
  late final StreamSubscription<dynamic> sub;
  sub = fromWorker.listen((msg) {
    if (msg is _Ready) {
      ready.complete(msg);
    } else if (msg is _LoadFailed) {
      loadFailureReported = true;
      if (!ready.isCompleted) {
        ready.completeError(msg.failure.toException(), msg.failure.stackTrace);
      }
    } else if (msg is List) {
      uncaughtDuringLoad = _describeUncaught(msg);
    } else if (msg == null && !ready.isCompleted) {
      final reason = uncaughtDuringLoad;
      warnEmbeddingHost(
        'the $engine embedding worker for $label died during load'
        '${reason == null ? '' : ' ($reason)'}; its pass may not have been '
        'closed, so its native model may still be resident.',
      );
      ready.completeError(
        EmbeddingLoadException(
          reason == null
              ? 'The $engine embedding worker for $label exited during load.'
              : 'The $engine embedding worker for $label exited during load: '
                    '$reason',
          engine: engine,
        ),
      );
    }
  });

  final notice = Timer(
    slowLoadNotice,
    () => warnEmbeddingHost(
      'loading the $engine embedder for $label has taken '
      '${describeHostDuration(slowLoadNotice)}: the worker is still inside a '
      'native call. It keeps waiting rather than kill the worker, because a '
      'killed worker never frees its native model.',
    ),
  );
  final _Ready handshake;
  try {
    await Isolate.spawn(
      _workerEntry,
      _Init(
        replyTo: fromWorker.sendPort,
        descriptor: descriptor,
        declaredMedia: declaredMedia,
        label: label,
        logLevel: edgeAiLogLevel,
      ),
      // onExit posts `null`, so nothing ever waits on a dead isolate.
      onExit: fromWorker.sendPort,
      // An uncaught error arrives as `[error, stack]` before that `null`, so a
      // worker that dies says why instead of only that it did.
      onError: fromWorker.sendPort,
      debugName: 'embedding-pass-worker',
    );
    handshake = await ready.future;
  } catch (e) {
    // Nothing to kill. A worker that reported a load failure is still closing
    // its pass, so keep listening — not waiting — until it exits, and report
    // a close that fails. Otherwise it is already gone (onExit), or was never
    // started.
    if (loadFailureReported) {
      final cleanup = _FailedLoadCleanup(
        engine: engine,
        label: label,
        slowCloseNotice: slowCloseNotice,
        sub: sub,
        fromWorker: fromWorker,
      );
      sub.onData(cleanup.onMessage);
      onFailedLoadCleanup?.call(cleanup.done);
    } else {
      await sub.cancel();
      fromWorker.close();
    }
    if (e is EmbeddingException) rethrow;
    throw EmbeddingLoadException(
      'Could not start the $engine embedding worker for $label: $e',
      engine: engine,
      cause: e,
    );
  } finally {
    notice.cancel();
  }

  final host = _IsolateEmbeddingHost(
    handshake.commandPort,
    fromWorker,
    handshake.info,
    handshake.modalities,
    engine: engine,
    label: label,
    slowCloseNotice: slowCloseNotice,
  );
  sub.onData(host._onMessage);
  return host;
}

/// Follows a worker whose load failed while it closes the pass it built: what
/// it sends after the failure is the outcome of that close, then its exit.
/// [done] ends at the exit, whatever happened.
final class _FailedLoadCleanup {
  _FailedLoadCleanup({
    required this.engine,
    required this.label,
    required Duration slowCloseNotice,
    required this.sub,
    required this.fromWorker,
  }) {
    _notice = Timer(
      slowCloseNotice,
      () => warnEmbeddingHost(
        'closing the $engine embedding pass for $label after its load failed '
        'has taken ${describeHostDuration(slowCloseNotice)}: the worker is '
        'still inside its close. No new embedder is built until it ends.',
      ),
    );
  }

  final String engine;
  final String label;
  final StreamSubscription<dynamic> sub;
  final ReceivePort fromWorker;
  late final Timer _notice;
  final _done = Completer<void>();
  bool _reported = false;

  Future<void> get done => _done.future;

  void onMessage(dynamic msg) {
    if (msg is _LoadCleanup) {
      _reported = true;
      final error = msg.error;
      if (error != null) {
        warnEmbeddingHost(
          'the $engine embedding pass for $label failed to close after its '
          'load failed; its native model may still be resident: $error',
        );
      }
    } else if (msg is List) {
      warnEmbeddingHost(
        'the $engine embedding worker for $label died while closing the pass '
        'after its load failed: ${_describeUncaught(msg)}',
      );
    } else if (msg == null) {
      if (!_reported) {
        warnEmbeddingHost(
          'the $engine embedding worker for $label exited after its load '
          'failed without reporting that the pass closed; its native model '
          'may still be resident.',
        );
      }
      _notice.cancel();
      unawaited(sub.cancel());
      fromWorker.close();
      if (!_done.isCompleted) _done.complete();
    }
  }
}

/// An `onError` message — `[error, stack]`, both as strings — as one text.
String _describeUncaught(List<dynamic> message) {
  final error = message.isNotEmpty ? message[0] : null;
  final stack = message.length > 1 ? message[1] : null;
  return stack == null ? '$error' : '$error\n$stack';
}

final class _IsolateEmbeddingHost implements EmbeddingHost {
  _IsolateEmbeddingHost(
    this._commandPort,
    this._fromWorker,
    this.info,
    this.modalities, {
    required this._engine,
    required this._label,
    required this._slowCloseNotice,
  });

  final SendPort _commandPort;
  final ReceivePort _fromWorker;
  final String _engine;
  final String _label;
  final Duration _slowCloseNotice;

  @override
  final EmbeddingPassInfo info;

  @override
  final Set<EmbeddingModality> modalities;

  final _pending = <int, Completer<List<double>>>{};
  int _nextId = 0;

  /// True from the moment [close] is called, or the worker dies.
  bool _closing = false;

  /// Completes when the worker is gone: its [_CloseAck], or its onExit.
  final _gone = Completer<void>();
  Future<void>? _closeFuture;

  /// The last uncaught error the worker reported through `onError`. An
  /// uncaught error ends the isolate, so this is the reason the onExit that
  /// follows will carry.
  String? _uncaughtError;

  String? _deathReason;
  final _unexpectedExit = Completer<String>();

  @override
  Future<String> get unexpectedExit => _unexpectedExit.future;

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) {
    if (_closing) {
      final reason = _deathReason;
      return Future.error(
        reason == null
            ? closedBeforeRun
            : EmbedderClosedException(
                'The embedding model is closed: its $_engine worker exited '
                'unexpectedly ($reason).',
              ),
      );
    }
    final id = _nextId++;
    final completer = Completer<List<double>>();
    _pending[id] = completer;
    _commandPort.send(_Embed(id, input, taskType));
    return completer.future;
  }

  void _onMessage(dynamic msg) {
    if (msg is _Reply) {
      _pending.remove(msg.id)?.complete(msg.vector);
    } else if (msg is _Failure) {
      _pending
          .remove(msg.id)
          ?.completeError(msg.failure.toException(), msg.failure.stackTrace);
    } else if (msg is _CloseAck) {
      final error = msg.error;
      if (error != null) {
        // Reported, not rethrown: the caller asked to stop using this model,
        // and there is nothing it could do with the failure.
        warnEmbeddingHost(
          'the $_engine embedding pass for $_label failed to close; its native '
          'model may still be resident: $error',
        );
      }
      if (!_gone.isCompleted) _gone.complete();
    } else if (msg is List) {
      _uncaughtError = _describeUncaught(msg);
    } else if (msg == null) {
      // onExit. After a _CloseAck the port is already closed, so this only
      // arrives when the worker died without one (W6).
      _died(
        _uncaughtError ??
            'no error was reported; the isolate was terminated under the '
                'worker',
      );
    }
  }

  /// The worker is gone without having closed its pass cleanly: fail
  /// everything waiting, say so where release builds can see it, and let the
  /// owner know, so it stops handing out this model.
  void _died(String reason) {
    final whileClosing = _closeFuture != null;
    _deathReason = reason;
    _closing = true;
    final what =
        'The $_engine embedding worker for $_label exited unexpectedly'
        '${whileClosing ? ' while closing' : ''}';
    _failAllPending(
      EmbeddingEngineException('$what: $reason', engine: _engine),
    );
    warnEmbeddingHost(
      '$what; its pass may not have been closed, so its native model may '
      'still be resident. Reason: $reason',
    );
    _fromWorker.close();
    if (!_gone.isCompleted) _gone.complete();
    if (!_unexpectedExit.isCompleted) _unexpectedExit.complete(reason);
  }

  void _failAllPending(EmbeddingException error) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<void> close() => _closeFuture ??= _shutDown();

  Future<void> _shutDown() async {
    _closing = true;
    if (!_gone.isCompleted) {
      _commandPort.send(const _Close());
      final notice = Timer(
        _slowCloseNotice,
        () => warnEmbeddingHost(
          'closing the $_engine embedder for $_label has taken '
          '${describeHostDuration(_slowCloseNotice)}: the worker is still '
          'inside a native call — the embedding request in flight or the '
          "pass's own close(). It keeps waiting rather than kill the worker, "
          'because a killed worker never frees its native model.',
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
    // port delivers in order; if it died instead, [_died] has already failed
    // them. So nothing should be left — anything that is, is a bug here, and
    // its error says so rather than claim the request was never run.
    _failAllPending(
      EmbeddingEngineException(
        'internal error: the $_engine embedding worker for $_label stopped '
        'without answering this request',
        engine: _engine,
      ),
    );
  }
}

/// Worker entry point: build, load and check the pass, then serve until
/// [_Close].
Future<void> _workerEntry(_Init init) async {
  edgeAiLogLevel = init.logLevel;
  final engine = init.descriptor.engineTag;

  // Nullable, so the failure path can tell "never built" from "built, then
  // failed" — and close the second.
  EmbeddingPass? built;
  final EmbeddingPassInfo info;
  final Set<EmbeddingModality> modalities;
  try {
    built = init.descriptor.build();
    info = await built.load();
    modalities = checkLoadedPass(
      info,
      init.declaredMedia,
      engine: engine,
      label: init.label,
    );
  } catch (e, st) {
    edgeAiLog('[EmbeddingHost] load failed: $e\n$st');
    // The failure goes FIRST (see startEmbeddingHost), then the pass is
    // closed in this same isolate — never by killing it, which would skip the
    // close. EmbeddingPass.close() must not throw for a pass that never
    // loaded, so it is always called once the pass exists (W5).
    init.replyTo.send(
      _LoadFailed(
        EmbeddingFailure.fromError(e, engine: engine, loading: true, stack: st),
      ),
    );
    final closeError = built == null
        ? null
        : await closePassReportingFailure(built);
    Isolate.exit(init.replyTo, _LoadCleanup(closeError));
  }
  final pass = built;

  edgeAiLog(
    '[EmbeddingHost] loaded: engine=$engine, dim=${info.dimension}, '
    'maxInputTokens=${info.maxInputTokens}, modalities=$modalities',
  );

  final commandPort = ReceivePort();
  final pump = RequestPump<_Embed>(
    (request) => _serve(request, pass, engine, init.replyTo),
  );

  // W1: the listener only files messages; the pump does the work. That split
  // is what lets a close overtake a queue.
  commandPort.listen((msg) {
    if (msg is _Embed) {
      if (!pump.file(msg, media: isMediaRequest(msg.input))) {
        init.replyTo.send(_Failure(msg.id, _encodeClosed(engine)));
      }
    } else if (msg is _Close) {
      commandPort.close();
      // Only what has not started. The request in flight, if any, was taken
      // off the lanes when it started, and it finishes on its own terms.
      for (final request in pump.requestClose()) {
        init.replyTo.send(_Failure(request.id, _encodeClosed(engine)));
      }
    }
  });

  init.replyTo.send(_Ready(commandPort.sendPort, info, modalities));

  Object? runError;
  StackTrace? runStack;
  try {
    await pump.run();
  } catch (e, st) {
    runError = e;
    runStack = st;
  }
  // Also after an unexpected throw out of the loop, so the native model is
  // freed either way.
  final closeError = await closePassReportingFailure(pass);
  if (runError != null) {
    // The loop's error goes on as an uncaught error and ends the isolate
    // without a _CloseAck: the main side receives it through `onError`, then
    // the onExit, and reports both as an unexpected exit. A close that also
    // failed is printed here, not dropped.
    if (closeError != null) {
      warnEmbeddingHost(
        'the $engine embedding pass for ${init.label} also failed to close '
        'after its worker loop failed; its native model may still be '
        'resident: $closeError',
      );
    }
    Error.throwWithStackTrace(runError, runStack!);
  }
  // Ack and exit in one step: nothing of this worker runs after the ack, so
  // the main side never has to kill it (W4).
  Isolate.exit(init.replyTo, _CloseAck(closeError));
}

EmbeddingFailure _encodeClosed(String engine) =>
    EmbeddingFailure.closedBeforeRun(engine: engine);

/// Runs one request and replies — with the vector, or with the failure. Never
/// throws (W7), so one bad input cannot stop the loop that serves the rest.
Future<void> _serve(
  _Embed request,
  EmbeddingPass pass,
  String engine,
  SendPort replyTo,
) async {
  try {
    final vector = await pass.embed(request.input, request.taskType);
    replyTo.send(_Reply(request.id, vector));
  } catch (e, st) {
    replyTo.send(
      _Failure(
        request.id,
        EmbeddingFailure.fromError(e, engine: engine, stack: st),
      ),
    );
  }
}
